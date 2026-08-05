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
		bump(counters, which, 1)
	}
	return ok
}

@(private)
@(require_results)
queue_recv :: proc(
	c: chan.Chan(Indexed($T)),
	counters: ^Counters,
	which: Metric,
) -> (
	item: Indexed(T),
	ok: bool,
) {
	item, ok = chan.recv(c)
	if ok {
		bump(counters, which, -1)
	}
	return
}

@(private)
Extract_Worker_State :: struct($Job, $Extracted: typeid) {
	extract_queue:    chan.Chan(Indexed(Job)),
	transcribe_queue: chan.Chan(Indexed(Extracted)),
	stages:           ^Stages(Job, Extracted),
	results:          []Terminal,
	counters:         ^Counters,
}

// A closed non-empty channel still yields every buffered Job before `recv`
// finally answers `false` -- that is `core:sync/chan`'s own guarantee (ADR-0006)
// -- so a Job already admitted when the Batch is asked to stop still reaches
// extraction, and this loop is what carries that through to the second queue.
//
// Run through `run_extract_worker` on its own thread; it does not read
// `state` after handing it off, so it never mutates one still reachable from
// a worker `spawn_extract_workers` had to abandon.
@(private)
extract_worker_body :: proc(state: ^Extract_Worker_State($Job, $Extracted)) {
	assert(state != nil, "an extraction worker was started with no state to run")
	assert(state.stages.extract != nil, "an extraction worker was started with no Stage to run")

	for {
		item, ok := queue_recv(state.extract_queue, state.counters, .Extract_Depth)
		if !ok {
			return
		}

		bump(state.counters, .Extract_Active, 1)
		extracted, extracted_ok := state.stages.extract(item.value)
		bump(state.counters, .Extract_Active, -1)
		if !extracted_ok {
			state.results[item.index] = .Extraction_Failed
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
		state.results[item.index] = .Transcribe_Queue_Send_Failed
	}
}

@(private)
Transcribe_Worker_State :: struct($Job, $Extracted: typeid) {
	transcribe_queue: chan.Chan(Indexed(Extracted)),
	stages:           ^Stages(Job, Extracted),
	results:          []Terminal,
	counters:         ^Counters,
}

@(private)
transcribe_worker_body :: proc(state: ^Transcribe_Worker_State($Job, $Extracted)) {
	assert(state != nil, "a transcription worker was started with no state to run")
	assert(
		state.stages.transcribe != nil,
		"a transcription worker was started with no Stage to run",
	)

	for {
		item, ok := queue_recv(state.transcribe_queue, state.counters, .Transcribe_Depth)
		if !ok {
			return
		}

		bump(state.counters, .Transcribe_Active, 1)
		transcribed := state.stages.transcribe(item.value)
		bump(state.counters, .Transcribe_Active, -1)
		state.results[item.index] = .Transcribed if transcribed else .Transcription_Failed
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
	results: []Terminal,
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
			results          = results,
			counters         = counters,
		}
		threads[i] = thread.create_and_start_with_poly_data(state, run_extract_worker)
	}
	return threads
}

@(private)
@(require_results)
spawn_transcribe_worker :: proc(
	transcribe_queue: chan.Chan(Indexed($Extracted)),
	stages: ^Stages($Job, Extracted),
	results: []Terminal,
	counters: ^Counters,
) -> ^thread.Thread {
	run_transcribe_worker :: proc(state: ^Transcribe_Worker_State(Job, Extracted)) {
		transcribe_worker_body(state)
	}

	state := new(Transcribe_Worker_State(Job, Extracted), runtime.heap_allocator())
	state^ = Transcribe_Worker_State(Job, Extracted) {
		transcribe_queue = transcribe_queue,
		stages           = stages,
		results          = results,
		counters         = counters,
	}
	return thread.create_and_start_with_poly_data(state, run_transcribe_worker)
}

// A Job that will never reach a Stage -- cancelled before it was admitted, or
// refused by an already-closed queue -- still owns whatever `abandon_job`
// knows how to free. `stopped_at` is where admission actually stopped, so
// every index at or past it is `.Not_Admitted` and never merely absent.
@(private)
admit_jobs :: proc(
	jobs: []$Job,
	extract_queue: chan.Chan(Indexed(Job)),
	results: []Terminal,
	counters: ^Counters,
	cancelled: ^bool,
	stages: ^Stages(Job, $Extracted),
) {
	assert(
		len(jobs) == len(results),
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
			results[i] = .Extract_Queue_Send_Failed
			stages.abandon_job(job)
		}
	}
	for i in stopped_at ..< len(jobs) {
		results[i] = .Not_Admitted
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
		switch child.await_or_abandon(t, bound_ms) {
		case .Finished, .Stopped:
			thread.destroy(t)
		case .Unstoppable:
			all_joined = false
		}
	}
	return all_joined
}

// Job count, worker configuration and fake Stages in, observed concurrency
// out (S4, docs/spec/0001-transcibr-v1.md). `results` and `observed` answer
// together: every index of the first is a terminal Terminal by the time this
// returns, asserted below, and the second is what a topology test checks its
// invariants against.
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
	counters := new(Counters, runtime.heap_allocator())
	stages_box := new(Stages(Job, Extracted), runtime.heap_allocator())
	stages_box^ = stages

	extract_queue, _ := chan.create(chan.Chan(Indexed(Job)), config.queue_depth, allocator)
	transcribe_queue, _ := chan.create(
		chan.Chan(Indexed(Extracted)),
		config.queue_depth,
		allocator,
	)

	extract_threads := spawn_extract_workers(
		config.extract_workers,
		extract_queue,
		transcribe_queue,
		stages_box,
		results,
		counters,
	)
	transcribe_thread := spawn_transcribe_worker(transcribe_queue, stages_box, results, counters)

	admit_jobs(jobs, extract_queue, results, counters, cancelled, stages_box)

	extract_clean := close_and_join(extract_queue, extract_threads, config.join_bound_ms)
	transcribe_clean := close_and_join(
		transcribe_queue,
		[]^thread.Thread{transcribe_thread},
		config.join_bound_ms,
	)
	delete(extract_threads, runtime.heap_allocator())

	observed = observed_of(counters)
	if extract_clean {
		chan.destroy(extract_queue)
	}
	if transcribe_clean {
		chan.destroy(transcribe_queue)
	}
	if extract_clean && transcribe_clean {
		free(stages_box, runtime.heap_allocator())
		free(counters, runtime.heap_allocator())
	}
	for status in results {
		assert(status != .Unset, "a job never reached a terminal state")
	}
	return
}
