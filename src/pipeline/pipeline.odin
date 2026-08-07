#+vet explicit-allocators
// Package pipeline is the topology issue #12 asks for: extraction runs ahead of
// transcription through a bounded queue so the GPU never waits on disk, while
// exactly one transcription runs at a time because a GPU is a serial resource
// (ADR-0006). It knows nothing about Recordings, ffmpeg or the Engine -- what a
// Job is, what an Extracted value is, and what the two Stages actually do are
// all supplied by the caller, so a test drives it with fake stages and no
// subprocess, and src/pipeline/recording.odin drives it with the real ones.
package pipeline

import "core:sync"

// One or two extraction workers, and exactly one transcription worker -- the
// second is never a field, because ADR-0006's whole point is that it cannot be
// tuned. `queue_depth` bounds BOTH channels: the one feeding extraction and the
// one feeding transcription, because an unbounded queue on either side is the
// disk-filling failure ADR-0006 exists to stop.
Config :: struct {
	extract_workers: int,
	queue_depth:     int,
	// How long shutdown waits for one worker to go idle before treating it as
	// wedged rather than merely slow. Sized against the stage's own worst case
	// by the caller -- production sizes it against a real Engine run, a test
	// against however long its gated fakes take to release.
	join_bound_ms:   i64,
}

// ADR-0006's own bounds on a real Batch, asserted by `run_recordings` rather
// than merely intended: at most two extraction Workers, and a queue depth of
// at most two. `run_batch` itself stays generic -- a topology test drives it
// at whatever depth its own invariant needs, `closing_the_extract_queue_-`
// `still_delivers_every_job_already_buffered` among them -- so these bounds
// are asserted at the one caller ADR-0006 is actually about, and enforced
// before that at the command line (`src/cli/batch.odin`'s `read_worker_-`
// `count`), so a value outside them is refused rather than reaching an
// assertion at all (A8).
MAX_EXTRACT_WORKERS :: 2
MAX_QUEUE_DEPTH :: 2

#assert(MAX_EXTRACT_WORKERS > 0)
#assert(MAX_QUEUE_DEPTH > 0)

// ADR-0006's own recorded bound -- "one or two CPU workers ... a bounded
// channel of depth one or two" -- held in checked code rather than only in
// the comment above (A5), so raising either past two fails the build instead
// of silently passing every test (issue #192).
#assert(MAX_EXTRACT_WORKERS <= 2)
#assert(MAX_QUEUE_DEPTH <= 2)

// `worker_count_within_ceiling` relocated to `transcibr:process` with
// ADR-0038's batch migration (#75): `src/cliargs`'s own worker-count reader
// needed the check and cannot import `pipeline` (its import closure is
// `transcript`/`process` only), and the check's own body was never
// pipeline-specific to begin with -- it takes `ceiling` as a parameter
// rather than reading `MAX_EXTRACT_WORKERS`/`MAX_QUEUE_DEPTH` by name. Its
// relocated test is `src/process/worker_ceiling_test.odin`.

// One or two extraction workers feeding exactly one transcription worker
// through a bounded channel of depth one or two (ADR-0006) -- the shipped
// defaults `--batch` puts back when its own command line left either unset,
// overridable per Batch because a machine's disk and GPU are not this
// program's to assume. `#assert` rather than a runtime check because both
// defaults are compile-time constants that can never drift past the ceiling
// beside them without the build itself refusing.
DEFAULT_EXTRACT_WORKERS :: 1
DEFAULT_QUEUE_DEPTH :: 2

#assert(DEFAULT_EXTRACT_WORKERS > 0)
#assert(DEFAULT_EXTRACT_WORKERS <= MAX_EXTRACT_WORKERS)
#assert(DEFAULT_QUEUE_DEPTH > 0)
#assert(DEFAULT_QUEUE_DEPTH <= MAX_QUEUE_DEPTH)

// How long shutdown waits for a worker to go idle once the last job has been
// admitted, before treating it as wedged rather than merely still working.
// Forty-five days is comfortably above any real Recording's own transcribe
// bound -- `process.transcribe_bound_ms` of even a full day of audio is a
// handful of days -- and comfortably below what `child.await_or_abandon`
// will accept at all. Both orderings are held by a test
// (`defaults_test.odin`) rather than by this comment alone.
DEFAULT_JOIN_BOUND_MS :: i64(45 * 24 * 60 * 60 * 1000)

// Every job passes through exactly one of these on the way out. `Unset` is the
// zero value and never a real answer -- see `run_batch`'s own postcondition --
// the same pattern `process.Disposition` already carries for the identical
// reason.
Terminal :: enum u8 {
	Unset = 0,
	Transcribed,
	Extraction_Failed,
	Transcription_Failed,
	Not_Admitted,
	Extract_Queue_Send_Failed,
	Transcribe_Queue_Send_Failed,
	// A Stage `close_and_join` gave up on rather than a Stage that answered --
	// the job's own outcome is genuinely unknown, so it is reported as failed
	// against its Recording (A8) and never asserted (finding 1 of PR #67's
	// review).
	Stage_Abandoned,
}

// The two Stages a caller supplies, and the two cleanup hooks for a Job or an
// Extracted value that reaches no Stage at all -- cancelled before admission, or
// produced by extraction and then unable to reach transcription. Every one of
// these runs on a worker thread and must not reach for `context.temp_allocator`
// for anything that outlives the call (ADR-0010).
Stages :: struct($Job, $Extracted: typeid) {
	extract:     proc(job: Job) -> (extracted: Extracted, ok: bool),
	transcribe:  proc(extracted: Extracted) -> bool,
	discard:     proc(extracted: Extracted),
	abandon_job: proc(job: Job),
}

// What a topology test observes, in place of timing: exact high-water marks
// kept by the pipeline's own bookkeeping rather than sampled by polling, so a
// mutation that admits one job too many is caught even when it lasts a single
// instant.
Observed :: struct {
	max_active_extractions:     int,
	max_active_transcriptions:  int,
	max_extract_queue_depth:    int,
	max_transcribe_queue_depth: int,
}

@(private)
Indexed :: struct($T: typeid) {
	index: int,
	value: T,
}

@(private)
Metric :: enum u8 {
	Extract_Active,
	Transcribe_Active,
	Extract_Depth,
	Transcribe_Depth,
}

@(private)
Counters :: struct {
	lock:                       sync.Mutex,
	active_extractions:         int,
	active_transcriptions:      int,
	max_active_extractions:     int,
	max_active_transcriptions:  int,
	max_extract_queue_depth:    int,
	max_transcribe_queue_depth: int,
}

// ADR-0006's one transcription Worker, checked where a second one running would
// actually show up -- the live count a second concurrent transcription pushes
// past one -- rather than by a slice length fixed at one element on the line
// that builds it, which cannot fail under any input, mutation or future edit
// (finding 2 of PR #67's round-2 review). `exactly_one_transcription_runs_-`
// `at_a_time_however_many_are_queued` (topology_test.odin) is the same
// invariant proved from outside; this is the production assertion that backs
// it at the one place the count itself changes.
@(private)
bump :: proc(c: ^Counters, which: Metric, delta: int) {
	assert(c != nil, "there is no counters block here to bump")
	assert(delta == 1 || delta == -1, "a counter moved by something other than one job")

	sync.guard(&c.lock)
	switch which {
	case .Extract_Active:
		c.active_extractions += delta
		c.max_active_extractions = max(c.max_active_extractions, c.active_extractions)
	case .Transcribe_Active:
		c.active_transcriptions += delta
		assert(
			c.active_transcriptions <= 1,
			"ADR-0006's one transcription Worker is asserted, not merely intended",
		)
		c.max_active_transcriptions = max(c.max_active_transcriptions, c.active_transcriptions)
	case .Extract_Depth, .Transcribe_Depth:
		unreachable()
	}
}

// The channel's own occupancy right after a successful send, read through
// `core:sync/chan`'s own mutex (`chan.len`) rather than kept by a second,
// separately-incremented counter. A counter bumped after `chan.send` returns
// can both over- and under-report against a concurrent `recv`: this can do
// neither, because there is nothing here to race -- `true_len` already IS the
// truth at the instant this runs (finding 2 of PR #67's review).
@(private)
record_depth :: proc(c: ^Counters, which: Metric, true_len: int) {
	assert(c != nil, "there is no counters block here to record a depth into")
	assert(true_len >= 0, "a channel cannot hold a negative number of jobs")

	sync.guard(&c.lock)
	switch which {
	case .Extract_Depth:
		c.max_extract_queue_depth = max(c.max_extract_queue_depth, true_len)
	case .Transcribe_Depth:
		c.max_transcribe_queue_depth = max(c.max_transcribe_queue_depth, true_len)
	case .Extract_Active, .Transcribe_Active:
		unreachable()
	}
}

@(private)
@(require_results)
observed_of :: proc(c: ^Counters) -> Observed {
	assert(c != nil, "there is no counters block here to report")

	sync.guard(&c.lock)
	return Observed {
		max_active_extractions = c.max_active_extractions,
		max_active_transcriptions = c.max_active_transcriptions,
		max_extract_queue_depth = c.max_extract_queue_depth,
		max_transcribe_queue_depth = c.max_transcribe_queue_depth,
	}
}
