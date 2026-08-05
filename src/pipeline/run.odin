#+vet explicit-allocators
package pipeline

// Orchestration: creating the two bounded channels, spawning the extraction
// tier and the one transcription worker, admitting Jobs, and shutting down in
// the order ADR-0006 fixes -- close, then join every worker, then destroy,
// asserted in that order below.

import "base:runtime"
import "core:mem"
import "core:sync"
import "core:sync/chan"
import "core:thread"
import "transcibr:child"

@(private)
@(require_results)
queue_send :: proc(
	c: chan.Chan(Indexed($T)),
	item: Indexed(T),
	counters: ^Counters,
	which: Metric,
) -> bool {
	ok := chan.send(c, item)
	if ok {
		record_depth(counters, which, chan.len(c))
	}
	return ok
}

@(private)
@(require_results)
queue_recv :: proc(c: chan.Chan(Indexed($T))) -> (item: Indexed(T), ok: bool) {
	item, ok = chan.recv(c)
	return
}

@(private)
Extract_Worker_State :: struct($Job, $Extracted: typeid) {
	extract_queue:    chan.Chan(Indexed(Job)),
	transcribe_queue: chan.Chan(Indexed(Extracted)),
	stages:           ^Stages(Job, Extracted),
	working:          []Terminal,
	counters:         ^Counters,
}

// A closed non-empty channel still yields every buffered Job before `recv`
// finally answers `false` -- that is `core:sync/chan`'s own guarantee (ADR-0006)
// -- so a Job already admitted when the Batch is asked to stop still reaches
// extraction, and this loop is what carries that through to the second queue.
//
// `working` is `run_batch`'s own heap-owned buffer and never the slice it
// hands back to its own caller (see `settle_results`): a Stage this loop is
// still inside when `close_and_join` gives up on it goes on writing here after
// `run_batch` has already returned, and here is memory nobody frees out from
// under it (finding 1 of PR #67's review).
@(private)
extract_worker_body :: proc(state: ^Extract_Worker_State($Job, $Extracted)) {
	assert(state != nil, "an extraction worker was started with no state to run")
	defer free(state, runtime.heap_allocator())
	assert(state.stages.extract != nil, "an extraction worker was started with no Stage to run")

	for {
		item, ok := queue_recv(state.extract_queue)
		if !ok {
			return
		}

		bump(state.counters, .Extract_Active, 1)
		extracted, extracted_ok := state.stages.extract(item.value)
		bump(state.counters, .Extract_Active, -1)
		if !extracted_ok {
			state.working[item.index] = .Extraction_Failed
			continue
		}

		sent := Indexed(Extracted) {
			index = item.index,
			value = extracted,
		}
		if queue_send(state.transcribe_queue, sent, state.counters, .Transcribe_Depth) {
			continue
		}
		state.stages.discard(extracted)
		state.working[item.index] = .Transcribe_Queue_Send_Failed
	}
}

@(private)
Transcribe_Worker_State :: struct($Job, $Extracted: typeid) {
	transcribe_queue: chan.Chan(Indexed(Extracted)),
	stages:           ^Stages(Job, Extracted),
	working:          []Terminal,
	counters:         ^Counters,
}

@(private)
transcribe_worker_body :: proc(state: ^Transcribe_Worker_State($Job, $Extracted)) {
	assert(state != nil, "a transcription worker was started with no state to run")
	defer free(state, runtime.heap_allocator())
	assert(
		state.stages.transcribe != nil,
		"a transcription worker was started with no Stage to run",
	)

	for {
		item, ok := queue_recv(state.transcribe_queue)
		if !ok {
			return
		}

		bump(state.counters, .Transcribe_Active, 1)
		transcribed := state.stages.transcribe(item.value)
		bump(state.counters, .Transcribe_Active, -1)
		state.working[item.index] = .Transcribed if transcribed else .Transcription_Failed
	}
}

// A nested, non-generic entry point for every extraction worker this Batch
// spawns. `core:thread`'s poly-data helper wants a concretely typed `proc(data:
// T)`, and `Job`/`Extracted` are already concrete BY THE TIME this instantiation
// of `spawn_extract_workers` exists -- declaring the entry point here, rather
// than handing `thread.create_and_start_with_poly_data` a still-generic
// procedure value, is what makes its type match exactly.
@(private)
@(require_results)
spawn_extract_workers :: proc(
	count: int,
	extract_queue: chan.Chan(Indexed($Job)),
	transcribe_queue: chan.Chan(Indexed($Extracted)),
	stages: ^Stages(Job, Extracted),
	working: []Terminal,
	counters: ^Counters,
) -> []^thread.Thread {
	assert(count > 0, "a pipeline with no extraction workers admits nothing")

	run_extract_worker :: proc(state: ^Extract_Worker_State(Job, Extracted)) {
		extract_worker_body(state)
	}

	threads := make([]^thread.Thread, count, runtime.heap_allocator())
	for i in 0 ..< count {
		state := new(Extract_Worker_State(Job, Extracted), runtime.heap_allocator())
		state^ = Extract_Worker_State(Job, Extracted) {
			extract_queue    = extract_queue,
			transcribe_queue = transcribe_queue,
			stages           = stages,
			working          = working,
			counters         = counters,
		}
		t := thread.create_and_start_with_poly_data(state, run_extract_worker)
		if t == nil {
			free(state, runtime.heap_allocator())
		}
		threads[i] = t
	}
	return threads
}

@(private)
@(require_results)
spawn_transcribe_worker :: proc(
	transcribe_queue: chan.Chan(Indexed($Extracted)),
	stages: ^Stages($Job, Extracted),
	working: []Terminal,
	counters: ^Counters,
) -> ^thread.Thread {
	run_transcribe_worker :: proc(state: ^Transcribe_Worker_State(Job, Extracted)) {
		transcribe_worker_body(state)
	}

	state := new(Transcribe_Worker_State(Job, Extracted), runtime.heap_allocator())
	state^ = Transcribe_Worker_State(Job, Extracted) {
		transcribe_queue = transcribe_queue,
		stages           = stages,
		working          = working,
		counters         = counters,
	}
	t := thread.create_and_start_with_poly_data(state, run_transcribe_worker)
	if t == nil {
		free(state, runtime.heap_allocator())
	}
	return t
}

// A Job that will never reach a Stage -- cancelled before it was admitted, or
// refused by an already-closed queue -- still owns whatever `abandon_job`
// knows how to free. `stopped_at` is where admission actually stopped, so
// every index at or past it is `.Not_Admitted` and never merely absent.
@(private)
admit_jobs :: proc(
	jobs: []$Job,
	extract_queue: chan.Chan(Indexed(Job)),
	working: []Terminal,
	counters: ^Counters,
	cancelled: ^bool,
	stages: ^Stages(Job, $Extracted),
) {
	assert(
		len(jobs) == len(working),
		"a Batch was admitted with more or fewer jobs than it has results for",
	)

	stopped_at := len(jobs)
	for job, i in jobs {
		if cancelled != nil && sync.atomic_load(cancelled) {
			stopped_at = i
			break
		}
		if !queue_send(
			extract_queue,
			Indexed(Job){index = i, value = job},
			counters,
			.Extract_Depth,
		) {
			working[i] = .Extract_Queue_Send_Failed
			stages.abandon_job(job)
		}
	}
	for i in stopped_at ..< len(jobs) {
		working[i] = .Not_Admitted
		stages.abandon_job(jobs[i])
	}
}

// Close, then join every worker in this tier, bounded rather than INFINITE
// (issue #27) -- and never `thread.destroy` one `await_or_abandon` reports
// `.Unstoppable`, for the reason `child.Worker.wedged` guards `release_worker`
// the same way: the thread may still be inside the Stage it was abandoned for,
// and a bound sized against that Stage's own internal bound (Config.join_-
// `bound_ms`) is what makes `.Unstoppable` here mean a genuine wedge rather
// than a Stage still legitimately working.
//
// A `nil` entry is a worker this tier never managed to start (thread creation
// failed under resource exhaustion, an operating condition and not a
// programmer error -- A8, finding 9 of PR #67's review) and is skipped rather
// than handed to `await_or_abandon`, which asserts its thread is non-nil.
@(private)
@(require_results)
close_and_join :: proc(
	queue: chan.Chan(Indexed($T)),
	threads: []^thread.Thread,
	bound_ms: i64,
) -> bool {
	assert(len(threads) > 0, "there is no worker tier here to close and join")

	closed_now := chan.close(queue)
	assert(closed_now, "a worker tier's queue was already closed before its own shutdown began")

	all_joined := true
	for t in threads {
		if t == nil {
			continue
		}
		switch child.await_or_abandon(t, bound_ms) {
		case .Finished, .Stopped:
			thread.destroy(t)
		case .Unstoppable:
			all_joined = false
		}
	}
	return all_joined
}

// `working` is copied into the caller's own `results` here, and only here:
// every write a worker thread makes lands on `working`, never on `results`
// directly, so a Stage `close_and_join` gave up on can go on writing after
// this returns without ever touching memory the caller might already have
// freed (finding 1 of PR #67's review). An index still `.Unset` once every
// worker has genuinely joined is `run_batch`'s own postcondition and stays an
// assertion; one still `.Unset` because some Stage never came back within its
// bound is the operating condition A8 asks for -- reported as
// `.Stage_Abandoned` against that Recording, and the Batch goes on rather
// than crashing.
//
// Reading `working` here while an abandoned worker may still be writing it is
// a benign race and not a memory hazard: `working` is never freed while
// `clean` is false (the caller leaks it deliberately, the same precedent
// issue #27 set for `child.Read_Job.bytes`), and `Terminal` is one byte, so
// there is no tearing to observe -- only a value that may still be `.Unset`
// a moment before the abandoned worker finally writes it, which is exactly
// the case `.Stage_Abandoned` is for.
@(private)
settle_results :: proc(results: []Terminal, working: []Terminal, clean: bool) {
	assert(
		len(results) == len(working),
		"a Batch's own results and working buffers drifted apart in length",
	)

	for status, i in working {
		results[i] = status
	}
	if clean {
		for status in results {
			assert(
				status != .Unset,
				"a job never reached a terminal state though every worker joined cleanly",
			)
		}
		return
	}
	for &status in results {
		if status == .Unset {
			status = .Stage_Abandoned
		}
	}
}

// A queue that could not even be created is a resource this Batch ran out of,
// not a programmer error (A8, finding 9 of PR #67's review): every Job is
// refused up front, directly into the caller's own `results` -- no worker
// tier was ever spawned here, so nothing crosses a thread boundary and
// `results` is safe to write synchronously. `chan.destroy` is nil-safe (see
// `core:sync/chan`'s own `destroy`), so the queue that failed to create and
// the one that came through both go through the same call unconditionally.
@(private)
@(require_results)
queues_unavailable :: proc(
	jobs: []$Job,
	results: []Terminal,
	stages: ^Stages(Job, $Extracted),
	counters: ^Counters,
	extract_queue: chan.Chan(Indexed(Job)),
	transcribe_queue: chan.Chan(Indexed(Extracted)),
) -> Observed {
	assert(
		len(jobs) == len(results),
		"a Batch was refused more or fewer Jobs than it has results for",
	)

	for job, i in jobs {
		results[i] = .Extract_Queue_Send_Failed
		stages.abandon_job(job)
	}
	chan.destroy(extract_queue)
	chan.destroy(transcribe_queue)
	free(stages, runtime.heap_allocator())
	free(counters, runtime.heap_allocator())
	return Observed{}
}

// Both channels or neither: `run_batch` never runs a Batch through one
// channel it could create and one it could not. `queues_unavailable` settles
// `results` and frees `stages`/`counters` on the failure path, so `run_batch`
// itself only has a length to decide.
@(private)
@(require_results)
open_queues :: proc(
	jobs: []$Job,
	results: []Terminal,
	stages: ^Stages(Job, $Extracted),
	counters: ^Counters,
	depth: int,
	allocator: mem.Allocator,
) -> (
	extract_queue: chan.Chan(Indexed(Job)),
	transcribe_queue: chan.Chan(Indexed(Extracted)),
	observed: Observed,
	ok: bool,
) {
	extract_err, transcribe_err: runtime.Allocator_Error
	extract_queue, extract_err = chan.create(chan.Chan(Indexed(Job)), depth, allocator)
	transcribe_queue, transcribe_err = chan.create(chan.Chan(Indexed(Extracted)), depth, allocator)
	if extract_err == .None && transcribe_err == .None {
		return extract_queue, transcribe_queue, Observed{}, true
	}
	observed = queues_unavailable(jobs, results, stages, counters, extract_queue, transcribe_queue)
	return extract_queue, transcribe_queue, observed, false
}

// Close and join both tiers, in ADR-0006's order, then decide what every
// buffer this Batch owns gets to become: `transcribe_queue` is written by
// BOTH tiers (extraction sends into it, transcription receives from it), so
// it is only ever destroyed once both have actually joined -- destroying it
// while an extraction worker `close_and_join` gave up on might still be
// blocked sending into it is the identical hazard `settle_results` guards
// `working` against, just against a queue rather than a slice.
@(private)
@(require_results)
shut_down_and_settle :: proc(
	extract_queue: chan.Chan(Indexed($Job)),
	extract_threads: []^thread.Thread,
	transcribe_queue: chan.Chan(Indexed($Extracted)),
	transcribe_thread: ^thread.Thread,
	stages: ^Stages(Job, Extracted),
	counters: ^Counters,
	results: []Terminal,
	working: []Terminal,
	bound_ms: i64,
) -> Observed {
	extract_clean := close_and_join(extract_queue, extract_threads, bound_ms)

	transcribe_threads := []^thread.Thread{transcribe_thread}
	assert(
		len(transcribe_threads) == 1,
		"ADR-0006's one transcription Worker is asserted, not merely intended",
	)
	transcribe_clean := close_and_join(transcribe_queue, transcribe_threads, bound_ms)
	delete(extract_threads, runtime.heap_allocator())

	observed := observed_of(counters)
	clean := extract_clean && transcribe_clean
	if extract_clean {
		chan.destroy(extract_queue)
	}
	if clean {
		chan.destroy(transcribe_queue)
		free(stages, runtime.heap_allocator())
		free(counters, runtime.heap_allocator())
	}

	settle_results(results, working, clean)
	if clean {
		delete(working, runtime.heap_allocator())
	}
	return observed
}

// Job count, worker configuration and fake Stages in, observed concurrency
// out (S4, docs/spec/0001-transcibr-v1.md). `results` and `observed` answer
// together: every index of the first is a terminal Terminal by the time this
// returns, asserted in `settle_results`, and the second is what a topology
// test checks its invariants against.
@(require_results)
run_batch :: proc(
	jobs: []$Job,
	stages: Stages(Job, $Extracted),
	config: Config,
	allocator: mem.Allocator,
	cancelled: ^bool = nil,
) -> (
	results: []Terminal,
	observed: Observed,
) {
	assert(config.extract_workers > 0, "a pipeline with no extraction workers admits nothing")
	assert(config.queue_depth > 0, "an unbounded queue is the leak ADR-0006 exists to stop")
	assert(
		config.join_bound_ms > 0,
		"a shutdown wait of no time cannot tell a wedge from a fast worker",
	)
	assert(allocator.procedure != nil, "the results outlive this procedure and need an allocator")

	results = make([]Terminal, len(jobs), allocator)
	working := make([]Terminal, len(jobs), runtime.heap_allocator())
	counters := new(Counters, runtime.heap_allocator())
	stages_box := new(Stages(Job, Extracted), runtime.heap_allocator())
	stages_box^ = stages

	extract_queue, transcribe_queue, early_observed, opened := open_queues(
		jobs,
		results,
		stages_box,
		counters,
		config.queue_depth,
		allocator,
	)
	if !opened {
		observed = early_observed
		delete(working, runtime.heap_allocator())
		return
	}

	extract_threads := spawn_extract_workers(
		config.extract_workers,
		extract_queue,
		transcribe_queue,
		stages_box,
		working,
		counters,
	)
	transcribe_thread := spawn_transcribe_worker(transcribe_queue, stages_box, working, counters)
	admit_jobs(jobs, extract_queue, working, counters, cancelled, stages_box)

	observed = shut_down_and_settle(
		extract_queue,
		extract_threads,
		transcribe_queue,
		transcribe_thread,
		stages_box,
		counters,
		results,
		working,
		config.join_bound_ms,
	)
	return
}
