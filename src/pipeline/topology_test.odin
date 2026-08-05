#+vet explicit-allocators
package pipeline

// S4 -- Pipeline topology (docs/spec/0001-transcibr-v1.md): job count, worker
// configuration and fake Stages in, observed concurrency out. No GPU, no
// subprocesses. Every invariant here is proved by an exact count the pipeline's
// own bookkeeping kept, never by a fake stage happening to run slowly enough
// for a race to go the way the test expects -- a fake that blocks on a gate the
// test itself opens is what makes "at most N were ever inside the Stage
// together" a fact rather than a guess about scheduling.
//
// Every wait a test performs is bounded, the same discipline issue #27 already
// holds production code to: a gate that never opens must fail the case, not
// hang the runner.

import "core:sync/chan"
import "core:testing"
import "core:thread"
import "core:time"
import "transcibr:child"

@(private)
GATE_BOUND_MS :: 5_000

@(private)
JOIN_BOUND_MS :: i64(2_000)

@(private)
TEST_CONFIG :: Config {
	extract_workers = 1,
	queue_depth     = 1,
	join_bound_ms   = JOIN_BOUND_MS,
}

// What a fake Stage rendezvouses through: `entered` is buffered wide enough
// that announcing arrival never blocks, `proceed` is unbuffered so the test
// releases exactly the jobs it means to and no more.
@(private)
Gate :: struct {
	entered: chan.Chan(int),
	proceed: chan.Chan(int),
}

@(private)
@(require_results)
make_gate :: proc(capacity: int, allocator := context.allocator) -> Gate {
	assert(capacity > 0, "a gate with no room for an arrival announces nothing")

	entered, _ := chan.create(chan.Chan(int), capacity, allocator)
	proceed, _ := chan.create(chan.Chan(int), allocator)
	return Gate{entered = entered, proceed = proceed}
}

@(private)
destroy_gate :: proc(gate: Gate) {
	chan.destroy(gate.entered)
	chan.destroy(gate.proceed)
}

// Polls rather than blocks, and fails the case rather than hanging the runner
// when nothing shows up within GATE_BOUND_MS -- the same poll-then-give-up
// shape `child.await_or_abandon` uses against a thread this package cannot
// otherwise wait on with a ceiling.
@(private)
@(require_results)
await_entry :: proc(t: ^testing.T, gate: Gate) -> (id: int, ok: bool) {
	deadline := time.tick_now()
	for {
		id, ok = chan.try_recv(gate.entered)
		if ok {
			return
		}
		if i64(time.duration_milliseconds(time.tick_since(deadline))) > GATE_BOUND_MS {
			testing.expect(t, false, "nothing entered the gated Stage within its bound")
			return 0, false
		}
		time.sleep(time.Millisecond)
	}
}

// The negative half of await_entry: proves nothing entered within a generous
// window, rather than merely that nothing had entered YET.
@(private)
@(require_results)
nothing_entered :: proc(t: ^testing.T, gate: Gate, within_ms: i64) -> bool {
	deadline := time.tick_now()
	for i64(time.duration_milliseconds(time.tick_since(deadline))) < within_ms {
		if _, ok := chan.try_recv(gate.entered); ok {
			return testing.expect(
				t,
				false,
				"a job entered the gated Stage that should have been blocked",
			)
		}
		time.sleep(time.Millisecond)
	}
	return true
}

@(private)
release :: proc(gate: Gate, times: int) {
	assert(times > 0, "releasing a gate zero times holds every worker blocked")

	for _ in 0 ..< times {
		chan.send(gate.proceed, 1)
	}
}

@(private)
Fake_Job :: struct {
	id:              int,
	extract_ok:      bool,
	transcribe_ok:   bool,
	extract_gate:    Gate,
	transcribe_gate: Gate,
	gated:           bool,
}

@(private)
Fake_Extracted :: struct {
	id:              int,
	transcribe_ok:   bool,
	transcribe_gate: Gate,
	gated:           bool,
}

@(private)
@(require_results)
fake_extract :: proc(job: Fake_Job) -> (extracted: Fake_Extracted, ok: bool) {
	if job.gated {
		_ = chan.send(job.extract_gate.entered, job.id)
		_, _ = chan.recv(job.extract_gate.proceed)
	}
	return Fake_Extracted{id = job.id, transcribe_ok = job.transcribe_ok}, job.extract_ok
}

@(private)
@(require_results)
fake_extract_ungated :: proc(job: Fake_Job) -> (extracted: Fake_Extracted, ok: bool) {
	return Fake_Extracted{id = job.id, transcribe_ok = job.transcribe_ok}, job.extract_ok
}

@(private)
@(require_results)
fake_transcribe :: proc(extracted: Fake_Extracted) -> bool {
	return extracted.transcribe_ok
}

@(private)
@(require_results)
gated_fake_transcribe :: proc(extracted: Fake_Extracted) -> bool {
	if extracted.gated {
		_ = chan.send(extracted.transcribe_gate.entered, extracted.id)
		_, _ = chan.recv(extracted.transcribe_gate.proceed)
	}
	return extracted.transcribe_ok
}

@(private)
fake_discard :: proc(extracted: Fake_Extracted) {
}

@(private)
fake_abandon :: proc(job: Fake_Job) {
}

@(private)
FAKE_STAGES := Stages(Fake_Job, Fake_Extracted) {
	extract     = fake_extract,
	transcribe  = fake_transcribe,
	discard     = fake_discard,
	abandon_job = fake_abandon,
}

@(private)
UNGATED_STAGES := Stages(Fake_Job, Fake_Extracted) {
	extract     = fake_extract_ungated,
	transcribe  = fake_transcribe,
	discard     = fake_discard,
	abandon_job = fake_abandon,
}

@(private)
GATED_TRANSCRIBE_STAGES := Stages(Fake_Job, Fake_Extracted) {
	extract     = fake_extract_ungated,
	transcribe  = gated_fake_transcribe,
	discard     = fake_discard,
	abandon_job = fake_abandon,
}

@(private)
Run_Box :: struct {
	jobs:      []Fake_Job,
	stages:    Stages(Fake_Job, Fake_Extracted),
	config:    Config,
	cancelled: ^bool,
	results:   []Terminal,
	observed:  Observed,
}

@(private)
run_box_driver :: proc(box: ^Run_Box) {
	assert(box != nil, "a driver thread was started with no box to run a Batch into")

	box.results, box.observed = run_batch(
		box.jobs,
		box.stages,
		box.config,
		context.allocator,
		box.cancelled,
	)
}

// Runs a Batch on its own thread, so the calling test can meanwhile hold gated
// Stages open and observe the pipeline mid-flight. Joined with a bound well
// past the Batch's own -- a Batch that has not finished by then failed the
// case rather than hanging the runner.
@(private)
@(require_results)
start_batch :: proc(box: ^Run_Box) -> ^thread.Thread {
	assert(box != nil, "there is no box here to run a Batch into")

	context.allocator = context.allocator
	return thread.create_and_start_with_poly_data(box, run_box_driver)
}

@(private)
@(require_results)
join_batch :: proc(t: ^testing.T, driver: ^thread.Thread, bound_ms: i64) -> bool {
	assert(driver != nil, "there is no driver thread here to join")

	switch child.await_or_abandon(driver, bound_ms) {
	case .Finished, .Stopped:
		thread.destroy(driver)
		return true
	case .Unstoppable:
		testing.expect(t, false, "a Batch driver thread did not finish within its bound")
		return false
	}
	unreachable()
}

@(test)
extraction_never_runs_more_than_its_configured_worker_count_at_once :: proc(t: ^testing.T) {
	gate := make_gate(4, context.allocator)
	defer destroy_gate(gate)

	jobs := []Fake_Job {
		{id = 0, extract_ok = true, transcribe_ok = true, extract_gate = gate, gated = true},
		{id = 1, extract_ok = true, transcribe_ok = true, extract_gate = gate, gated = true},
		{id = 2, extract_ok = true, transcribe_ok = true, extract_gate = gate, gated = true},
		{id = 3, extract_ok = true, transcribe_ok = true, extract_gate = gate, gated = true},
	}
	config := Config {
		extract_workers = 2,
		queue_depth     = 4,
		join_bound_ms   = JOIN_BOUND_MS,
	}

	box := Run_Box {
		jobs   = jobs,
		stages = FAKE_STAGES,
		config = config,
	}
	driver := start_batch(&box)

	_, first_ok := await_entry(t, gate)
	_, second_ok := await_entry(t, gate)
	if !testing.expect(t, first_ok && second_ok, "two workers should both have entered the gate") {
		release(gate, len(jobs))
		_ = join_batch(t, driver, JOIN_BOUND_MS * 4)
		return
	}
	testing.expect(
		t,
		nothing_entered(t, gate, 300),
		"a third extraction ran ahead of its worker count",
	)

	release(gate, 2)
	_, third_ok := await_entry(t, gate)
	_, fourth_ok := await_entry(t, gate)
	testing.expect(t, third_ok && fourth_ok, "the remaining two jobs never reached extraction")
	release(gate, 2)

	testing.expect(t, join_batch(t, driver, JOIN_BOUND_MS * 4), "the Batch driver never finished")
	testing.expect_value(t, box.observed.max_active_extractions, 2)
	for status in box.results {
		testing.expect_value(t, status, Terminal.Transcribed)
	}
}

@(test)
exactly_one_transcription_runs_at_a_time_however_many_are_queued :: proc(t: ^testing.T) {
	gate := make_gate(4, context.allocator)
	defer destroy_gate(gate)

	jobs := []Fake_Job {
		{id = 0, extract_ok = true, transcribe_ok = true},
		{id = 1, extract_ok = true, transcribe_ok = true},
		{id = 2, extract_ok = true, transcribe_ok = true},
	}
	for &job in jobs {
		job.transcribe_gate = gate
		job.gated = false
	}
	config := Config {
		extract_workers = 2,
		queue_depth     = 3,
		join_bound_ms   = JOIN_BOUND_MS,
	}

	stages := GATED_TRANSCRIBE_STAGES
	stages.extract = proc(job: Fake_Job) -> (extracted: Fake_Extracted, ok: bool) {
		return Fake_Extracted {
				id = job.id,
				transcribe_ok = job.transcribe_ok,
				transcribe_gate = job.transcribe_gate,
				gated = true,
			},
			job.extract_ok
	}

	box := Run_Box {
		jobs   = jobs,
		stages = stages,
		config = config,
	}
	driver := start_batch(&box)

	_, first_ok := await_entry(t, gate)
	testing.expect(t, first_ok, "the first transcription never started")
	testing.expect(
		t,
		nothing_entered(t, gate, 300),
		"a second transcription ran while the first was still inside the Stage",
	)

	release(gate, 1)
	_, second_ok := await_entry(t, gate)
	testing.expect(t, second_ok, "the second transcription never started once the first finished")
	release(gate, 1)
	_, third_ok := await_entry(t, gate)
	testing.expect(t, third_ok, "the third transcription never started once the second finished")
	release(gate, 1)

	testing.expect(t, join_batch(t, driver, JOIN_BOUND_MS * 4), "the Batch driver never finished")
	testing.expect_value(t, box.observed.max_active_transcriptions, 1)
}

@(test)
the_extract_queue_never_holds_more_jobs_than_its_configured_bound :: proc(t: ^testing.T) {
	gate := make_gate(6, context.allocator)
	defer destroy_gate(gate)

	jobs := make([dynamic]Fake_Job, 0, 5, context.allocator)
	defer delete(jobs)
	for i in 0 ..< 5 {
		append(
			&jobs,
			Fake_Job {
				id = i,
				extract_ok = true,
				transcribe_ok = true,
				extract_gate = gate,
				gated = true,
			},
		)
	}
	config := Config {
		extract_workers = 1,
		queue_depth     = 2,
		join_bound_ms   = JOIN_BOUND_MS,
	}

	box := Run_Box {
		jobs   = jobs[:],
		stages = FAKE_STAGES,
		config = config,
	}
	driver := start_batch(&box)

	for _ in jobs {
		if _, ok := await_entry(t, gate); !ok {
			break
		}
		release(gate, 1)
	}

	testing.expect(t, join_batch(t, driver, JOIN_BOUND_MS * 6), "the Batch driver never finished")
	testing.expect(
		t,
		box.observed.max_extract_queue_depth <= config.queue_depth,
		"the extract queue held more jobs than its configured bound",
	)
	for status in box.results {
		testing.expect_value(t, status, Terminal.Transcribed)
	}
}

// The queue's own depth matches the job count, so admitting all five never
// blocks the producer -- every one of them is sitting buffered, unread, by
// the moment run_batch closes the queue right after admission finishes.
@(test)
closing_the_extract_queue_still_delivers_every_job_already_buffered :: proc(t: ^testing.T) {
	gate := make_gate(5, context.allocator)
	defer destroy_gate(gate)

	jobs := make([dynamic]Fake_Job, 0, 5, context.allocator)
	defer delete(jobs)
	for i in 0 ..< 5 {
		append(
			&jobs,
			Fake_Job {
				id = i,
				extract_ok = true,
				transcribe_ok = true,
				extract_gate = gate,
				gated = true,
			},
		)
	}
	config := Config {
		extract_workers = 1,
		queue_depth     = 5,
		join_bound_ms   = JOIN_BOUND_MS,
	}

	box := Run_Box {
		jobs   = jobs[:],
		stages = FAKE_STAGES,
		config = config,
	}
	driver := start_batch(&box)

	for _ in jobs {
		if _, ok := await_entry(t, gate); !ok {
			break
		}
		release(gate, 1)
	}

	testing.expect(t, join_batch(t, driver, JOIN_BOUND_MS * 6), "the Batch driver never finished")
	for status, i in box.results {
		testing.expectf(
			t,
			status == .Transcribed,
			"job %d never reached a terminal state past the queue close",
			i,
		)
	}
}

@(test)
every_job_reaches_a_terminal_state_success_and_failure_alike :: proc(t: ^testing.T) {
	jobs := []Fake_Job {
		{id = 0, extract_ok = true, transcribe_ok = true},
		{id = 1, extract_ok = false, transcribe_ok = true},
		{id = 2, extract_ok = true, transcribe_ok = false},
	}
	config := Config {
		extract_workers = 2,
		queue_depth     = 2,
		join_bound_ms   = JOIN_BOUND_MS,
	}

	results, _ := run_batch(jobs, UNGATED_STAGES, config, context.allocator)
	defer delete(results, context.allocator)

	testing.expect_value(t, results[0], Terminal.Transcribed)
	testing.expect_value(t, results[1], Terminal.Extraction_Failed)
	testing.expect_value(t, results[2], Terminal.Transcription_Failed)
	for status in results {
		testing.expect(t, status != .Unset, "a job never reached a terminal state")
	}
}

@(test)
cancelling_admits_no_job_past_the_point_it_was_asked_to_stop :: proc(t: ^testing.T) {
	cancelled := true
	jobs := []Fake_Job {
		{id = 0, extract_ok = true, transcribe_ok = true},
		{id = 1, extract_ok = true, transcribe_ok = true},
		{id = 2, extract_ok = true, transcribe_ok = true},
	}
	config := Config {
		extract_workers = 1,
		queue_depth     = 2,
		join_bound_ms   = JOIN_BOUND_MS,
	}

	results, _ := run_batch(jobs, UNGATED_STAGES, config, context.allocator, &cancelled)
	defer delete(results, context.allocator)

	for status, i in results {
		testing.expectf(
			t,
			status == .Not_Admitted,
			"job %d should never have been admitted, got %v",
			i,
			status,
		)
	}
}
