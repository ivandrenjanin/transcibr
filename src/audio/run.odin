#+vet explicit-allocators
package audio

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import "transcibr:child"
import "transcibr:crashlog"
import "transcibr:process"

Tools :: struct {
	ffmpeg:  string,
	ffprobe: string,
}

// Bare names, which is what asks CreateProcessW to search PATH -- and safely,
// because argv[0] is always quoted by the Process contract. A bundled build
// names the paths instead.
FFMPEG :: "ffmpeg.exe"
FFPROBE :: "ffprobe.exe"

// Called AFTER a caller's own command-line loop has read every option:
// `--ffmpeg ""` is an ordinary shell invocation with an unset variable in it,
// and a default set only before the loop would be overwritten by the empty
// value.
defaulted_tools :: proc(tools: ^Tools) {
	assert(tools != nil, "there is nowhere here to put a Tools default into")
	defer {
		assert(len(tools.ffmpeg) > 0, "a default that was put back is still empty")
		assert(len(tools.ffprobe) > 0, "a default that was put back is still empty")
	}

	if len(tools.ffmpeg) == 0 {
		tools.ffmpeg = FFMPEG
	}
	if len(tools.ffprobe) == 0 {
		tools.ffprobe = FFPROBE
	}
}

// The length a piece of audio's own header works out to, in milliseconds, and
// never a duration for anything downstream to use. Distinct so that handing one
// where a duration belongs is a compile error rather than a Sidecar wrong by a
// second, permanently.
Measured_Ms :: distinct i64

Extracted :: struct {
	// Owned by the caller and freed with the allocator that was handed in.
	audio:        string,
	container_ms: i64,
	measured_ms:  Measured_Ms,
}

PROBE_BOUND_MS :: i64(60_000)

// Half an hour against a corpus whose longest Recording is 168 minutes: ffmpeg
// decodes far faster than realtime, and the cost that scales is reading the
// source. What it bounds is a wedge, not slowness.
EXTRACTION_BOUND_MS :: i64(30 * 60 * 1000)

// The head and never the file: a Recording's audio is hundreds of megabytes and
// the chunk table ffmpeg writes lands in the first hundred bytes, so this is six
// hundred times what is needed.
@(private)
AUDIO_HEAD_BYTES :: 64 * 1024

// Why `taken_ns` is a wall clock and not a monotonic tick: ADR-0023.
@(require_results)
read_source :: proc(source: string, allocator: mem.Allocator) -> (reading: Reading, err: Error) {
	assert(len(source) > 0, "there is no Recording here to read")
	assert(allocator.procedure != nil, "a stat needs an allocator for the path it hands back")

	info, refusal := os.stat(source, allocator)
	if refusal != nil {
		return {}, Error{fault = .Source_Unreadable}
	}
	defer os.file_info_delete(info, allocator)

	return Reading {
		bytes = info.size,
		modified_ns = time.time_to_unix_nano(info.modification_time),
		taken_ns = time.time_to_unix_nano(time.now()),
	}, Error{}
}

@(require_results)
settle :: proc(
	source: string,
	planned: Reading,
	gap_ns: i64,
	allocator: mem.Allocator,
) -> (
	err: Error,
) {
	assert(gap_ns > 0, "a gap of no time at all says nothing about anything")
	assert(len(source) > 0, "there is no Recording here to settle")
	assert(allocator.procedure != nil, "a stat needs an allocator for the path it hands back")

	if planned.taken_ns <= 0 {
		return Error{fault = .Planned_Reading_Unusable}
	}

	for attempt in 0 ..< SETTLING_ATTEMPTS {
		now, unreadable := read_source(source, allocator)
		if unreadable.fault != .None {
			return unreadable
		}
		fault, again := settling_fault(
			settling(planned, now, gap_ns),
			SETTLING_ATTEMPTS - attempt - 1,
		)
		if !again {
			return Error{fault = fault}
		}
		time.sleep(time.Duration(remaining_gap_ns(planned, now, gap_ns)))
	}
	unreachable()
}

// Whether the answer file `probe` below wrote is safe to remove:
// `child.read_bounded` answers `Read_Fault.Did_Not_Finish` for BOTH a
// worker `child.await_or_abandon` cancelled and reclaimed and one it gave up
// on outright, and `Read_Error` carries nothing this far that tells those two
// apart -- so this treats the fault conservatively and refuses removal on
// it, leaking the answer file deliberately the same way `child.Read_Job`'s
// own doc comment (`src\child\read.odin`) states its worker leaks for the
// identical reason: there is no safe way to touch a file a thread may still
// be reading, short of `TerminateThread`, which CLAUDE.md's own notes on
// this repository's test runner already found abandons locks mid-use
// (issue #125, filed from the #66 review).
//
// An exhaustive switch, not `!= .Did_Not_Finish`: issue #33's compile guard
// applies to a switch that names every member itself exactly as it does to
// an enumerated array, and it is what makes a member added to `Read_Fault`
// without a case here a build failure rather than a silent
// settled-for-removal default (issue #125's round-2 review -- the `!=` form
// fails OPEN, toward removing a file a child may still hold, the identical
// shape `model_probe_wav_settled` in `src\doctor\model_probe.odin` already
// closed for `child.Run`).
@(private)
@(require_results)
answer_read_settled :: proc(fault: child.Read_Fault) -> bool {
	switch fault {
	case .None, .Not_Started, .Unreadable:
		return true
	case .Did_Not_Finish:
		return false
	}
	unreachable()
}

// `probe`'s removal of `answer` is threaded through this type rather than
// calling `os.remove` inline, so a test can prove the ordering by passing a
// counting stand-in through `probe_using` below instead of calling
// `os.remove` and inspecting the file afterward: `DeleteFileW` is measured
// to be a complete no-op against a named pipe -- the wedge this file's own
// tests use to reach `Read_Fault.Did_Not_Finish` -- returning
// `ERROR_INVALID_PARAMETER` with no connected reader and `ERROR_PIPE_BUSY`
// with one, in both cases leaving the pipe exactly as it was, so "was
// removal attempted" is unobservable from outside a pipe path by any
// filesystem effect (issue #125's round-1 review, finding 1). A package
// variable would race every other test in this package calling `probe`
// concurrently (`odin test` runs 12 threads by default), so this is a
// parameter, not shared state.
@(private)
Answer_Remove :: #type proc(path: string)

@(private)
os_remove_answer :: proc(path: string) {
	os.remove(path)
}

// Pulled out of `probe_using` so its removal effect is provable directly, by
// handing it a `settled` value straight from a test, rather than only ever
// proving `answer_read_settled` classifies a `Read_Fault` correctly in
// isolation from anything that touches disk.
@(private)
remove_answer_if_settled :: proc(answer: string, settled: bool, remove: Answer_Remove) {
	assert(len(answer) > 0, "there is no answer file here to conditionally remove")
	if settled {
		remove(answer)
	}
}

// `probe_using`'s spawn of ffprobe itself is threaded through this type
// rather than calling `child.run_bounded` inline, so a test can supply the
// run's INPUT (a `child.Run.Stopped`, with no real 60 s `PROBE_BOUND_MS`
// wait needed) while `probe_using` still supplies the DECISION -- the
// `.Stopped` branch's own guarded removal -- distinguishing a covered call
// site from a dead one, the same way `Probe_Maker` already does for
// `src\doctor\model_probe.odin`'s `.Unstoppable` arm (issue #125's round-4
// review, finding 2: nothing in the tree drove `probe` onto its own
// `.Stopped` branch, so deleting that branch's `remove(answer)` left all
// 588 tests green).
//
// `callbacks` is threaded straight through to `child.run_bounded` rather than
// left off this signature: issue #109 generalizes `on_exit` (`run.odin`'s own
// doc comment on `Run_Callbacks`) into the one way any caller here learns the
// exit code, and a stub standing in for a real run has to be able to fake
// that callback exactly like a real one fires it.
@(private)
Probe_Run :: #type proc(
	group: ^child.Job_Object,
	executable: string,
	arguments: []string,
	bound_ms: i64,
	allocator: mem.Allocator,
	callbacks: child.Run_Callbacks,
) -> (
	ending: child.Run,
	reason: child.Stop_Reason,
	err: child.Error,
)

@(private)
@(require_results)
run_probe_child :: proc(
	group: ^child.Job_Object,
	executable: string,
	arguments: []string,
	bound_ms: i64,
	allocator: mem.Allocator,
	callbacks: child.Run_Callbacks,
) -> (
	ending: child.Run,
	reason: child.Stop_Reason,
	err: child.Error,
) {
	return child.run_bounded(group, executable, arguments, bound_ms, allocator, callbacks)
}

// What `probe_using` and `produce` below both read back after a `.Finished`
// run: issue #109's generalization of `on_exit` into the one way a caller in
// this package learns the exit code. A run that never reaches `.Finished`
// leaves this at its zero value, which is exactly why neither caller reads
// it before checking `ending` first.
@(private)
Exit_Observed :: struct {
	code:   u32,
	exited: bool,
}

@(private)
observe_exit :: proc(code: u32, user: rawptr) {
	assert(user != nil, "there is no exit observer here to record an exit status against")

	state := (^Exit_Observed)(user)
	state.code = code
	state.exited = true
}

// The read of ffprobe's own answer file below is bounded the same way
// `child.read_bounded` bounds a hand-typed `--from-json` path (issue #27): a
// stalled scratch cache wedges this identically, and this is already a
// whole-file read of a path this program itself built -- `child.read_bounded`
// fits directly, with no caller-specific worker needed around it (issue #65).
@(require_results)
probe :: proc(
	group: ^child.Job_Object,
	tools: Tools,
	source: string,
	answer: string,
	allocator: mem.Allocator,
) -> (
	probed: process.Probe,
	err: Error,
) {
	return probe_using(group, tools, source, answer, allocator, os_remove_answer, run_probe_child)
}

// The real body of `probe`, taking its remover and its child runner as
// parameters rather than package variables so a test can swap either
// without racing every other test in this package that calls `probe`
// concurrently (issue #125's round-1 review, finding 1; the runner
// parameter is round-4's finding 2).
//
// The `.Unstoppable` arm below never calls `remove`: an ffprobe process this
// run could not stop may still be running and may still hold `answer` open,
// exactly as the member comment on `child.Run.Unstoppable`
// (`src\child\run.odin`) states -- so the answer file is leaked deliberately
// there, the same way `child.read_bounded`'s own doc comment
// (`src\child\read.odin`) states its worker leaks for the identical reason.
// Nothing drove `probe_using` onto that branch before
// issue #150's sweep, so a mutation adding an unconditional `remove(answer)`
// to it left the whole suite green (the #125 recipe applied to the one arm
// its own round-4 review left uncovered);
// `a_probe_whose_ffprobe_run_is_unstoppable_never_calls_the_remover` in
// `run_test.odin` is what now catches that mutation.
@(private)
@(require_results)
probe_using :: proc(
	group: ^child.Job_Object,
	tools: Tools,
	source: string,
	answer: string,
	allocator: mem.Allocator,
	remove: Answer_Remove,
	run: Probe_Run,
) -> (
	probed: process.Probe,
	err: Error,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(answer) > 0, "a probe with nowhere to write its answer says nothing")
	assert(len(source) > 0, "there is no Recording here to probe")

	arguments := process.probe_arguments(source, answer, allocator)
	defer delete(arguments, allocator)

	observed: Exit_Observed
	ending, _, refusal := run(
		group,
		tools.ffprobe,
		arguments,
		PROBE_BOUND_MS,
		allocator,
		child.Run_Callbacks{user = &observed, on_exit = observe_exit},
	)
	switch ending {
	case .Not_Started:
		return {}, Error{fault = .Probe_Not_Started, child = refusal}
	case .Unstoppable:
		return {}, Error{fault = .Probe_Not_Stopped}
	case .Stopped, .Finished:
	}
	if ending == .Stopped {
		remove_answer_if_settled(answer, true, remove)
		return {}, Error{fault = .Probe_Did_Not_Finish}
	}
	assert(observed.exited, "a finished ffprobe run reported no exit status at all")
	if observed.code != 0 {
		remove_answer_if_settled(answer, true, remove)
		return {}, Error{fault = .Probe_Refused, exit_code = observed.code}
	}

	said, unreadable := child.read_bounded(answer, child.READ_BOUND_MS, allocator)
	remove_answer_if_settled(answer, answer_read_settled(unreadable.fault), remove)
	if unreadable.fault != .None {
		return {}, Error{fault = .Probe_Answer_Unreadable}
	}
	defer delete(said, allocator)

	answered, fault := process.read_probe(string(said))
	if fault != .None {
		return {}, Error{fault = .Probe_Unreadable, probe = fault}
	}
	return answered, Error{}
}

// Issue #112: `container_ms > 0` below is internal, not a check on external
// input. `check_audio`'s only caller is `produce`, which takes the same
// value straight from `extract`'s `probed.duration_ms` -- and
// `process.read_probe` (see its own doc comment) guarantees that value is
// positive on every path that returns `fault == .None`.
@(private)
@(require_results)
check_audio :: proc(
	part: string,
	container_ms: i64,
	tolerance: Tolerance,
	allocator: mem.Allocator,
) -> (
	produced_ms: Measured_Ms,
	err: Error,
) {
	assert(len(part) > 0, "there is no audio here to check")
	assert(container_ms > 0, "a container with no duration was never accepted by the probe")
	assert(allocator.procedure != nil, "a bounded head read needs an allocator for its answer")

	head, bytes, unreadable := read_head_bounded(part, child.READ_BOUND_MS, allocator)
	if unreadable.fault != .None {
		return 0, unreadable
	}
	defer delete(head, allocator)

	facts, malformed := read_wav_facts(head, bytes)
	if malformed != .None {
		return 0, Error{fault = .Audio_Malformed, riff = malformed}
	}
	if !as_asked_for(facts) {
		return 0, Error{fault = .Audio_Not_As_Asked_For}
	}

	measured := audio_ms(facts)
	if !durations_agree(container_ms, measured, tolerance) {
		return 0, Error{fault = .Durations_Disagree, said = container_ms, got = measured}
	}
	return Measured_Ms(measured), Error{}
}

// One open for both the length and the bytes, so the length belongs to the same
// file the bytes came from: a stat taken separately can name a file something
// has replaced in between.
//
// Runs only on `read_head_bounded`'s worker thread below: `os.open` and
// `os.read_at` can wedge on a stalled scratch cache the same way a hand-typed
// `--from-json` path wedges `child.read_bounded` (issue #27), and nothing
// about a blocked Win32 call can be polled from outside it (issue #65).
@(private)
@(require_results)
read_head :: proc(path: string, into: []u8) -> (head: []u8, bytes: i64, err: Error) {
	assert(len(path) > 0, "there is no audio here to read")
	assert(len(into) > 0, "a head with nowhere to be read into reads nothing")

	handle, refused := os.open(path)
	if refused != nil {
		return nil, 0, Error{fault = .Audio_Unreadable}
	}
	defer os.close(handle)

	length, unmeasurable := os.file_size(handle)
	if unmeasurable != nil {
		return nil, 0, Error{fault = .Audio_Unreadable}
	}

	wanted := into[:min(int(length), len(into))]
	read, _ := os.read_at(handle, wanted, 0)
	if read == 0 {
		return nil, 0, Error{fault = .Audio_Unreadable}
	}
	assert(read <= len(wanted), "more of the head came back than there was room for it")
	return wanted[:read], length, Error{}
}

// `read_head`'s own worker: the buffer it reads into has to outlive the
// caller's stack frame the way `child.Read_Job.bytes` does, because a
// `.Stopped` or `.Unstoppable` wait leaves this thread abandoned rather than
// joined -- so it lives on `child.job_allocator`'s heap and never on the
// caller's own `allocator`, the identical reasoning `child.job_allocator`
// and `artifact.digest_of_bounded`'s `Digest_Job` give for the same shape.
@(private)
Head_Job :: struct {
	path:     string,
	buffer:   []u8,
	head:     []u8,
	bytes:    i64,
	err:      Error,
	stall_ms: i64,
}

// A fresh `core:thread` context arrives without the crash hook; see
// `transcibr:child`'s `read_worker` doc comment for why the line is written
// here rather than installed once by a helper.
@(private)
head_worker :: proc(data: rawptr) {
	context.assertion_failure_proc = crashlog.assertion_hook
	job := (^Head_Job)(data)
	assert(job != nil, "a head-read thread was started with no job to read")
	assert(len(job.path) > 0, "a head-read thread was started with no path to read")

	if job.stall_ms > 0 {
		time.sleep(time.Duration(job.stall_ms) * time.Millisecond)
	}
	job.head, job.bytes, job.err = read_head(job.path, job.buffer)
}

// Bounded the same shape as `artifact.digest_of_bounded` and
// `planning.transcript_state_bounded`: a small worker thread plus
// `child.await_and_reclaim`. Every wait outcome that is not `.Finished`
// collapses onto `.Audio_Unreadable`, the same fault a `read_head` that
// genuinely could not open the file already answers -- a caller cannot tell
// a wedge from an ordinary open failure apart, and does not need to (A8: an
// external read that times out is reported against the file that caused it).
//
// `stall_ms` is a worker-side stall no production caller ever passes --
// `read_head_bounded(path, bound_ms, allocator)` behaves identically to a
// call that spells the default out. A stall greater than `bound_ms` is what
// `run_test.odin` uses to reach the `.Stopped` branch with a real, running
// thread rather than a mocked wait outcome (issue #65's coverage finding);
// the one-line forwarding wrapper that used to carry that case's own name is
// gone (issue #66).
@(private)
@(require_results)
read_head_bounded :: proc(
	path: string,
	bound_ms: i64,
	allocator: mem.Allocator,
	stall_ms: i64 = 0,
) -> (
	head: []u8,
	bytes: i64,
	err: Error,
) {
	assert(len(path) > 0, "there is no audio here to read")
	assert(bound_ms > 0, "a read given no time at all cannot do anything")
	assert(allocator.procedure != nil, "a head outliving this procedure needs an allocator")
	assert(stall_ms >= 0, "a stall cannot run for negative time")

	job := new(Head_Job, child.job_allocator())
	job.path = strings.clone(path, child.job_allocator())
	job.buffer = make([]u8, AUDIO_HEAD_BYTES, child.job_allocator())
	job.stall_ms = stall_ms

	context.allocator = child.job_allocator()
	t := thread.create_and_start_with_data(job, head_worker)
	if t == nil {
		delete(job.buffer, child.job_allocator())
		delete(job.path, child.job_allocator())
		free(job, child.job_allocator())
		return nil, 0, Error{fault = .Audio_Unreadable}
	}

	finished, reclaim := child.await_and_reclaim(t, bound_ms)
	if finished {
		return head_finished(t, job, allocator)
	}
	if reclaim {
		release_head_job(t, job)
	}
	return nil, 0, Error{fault = .Audio_Unreadable}
}

@(private)
release_head_job :: proc(t: ^thread.Thread, job: ^Head_Job) {
	assert(t != nil, "there is no thread here to release")
	assert(job != nil, "there is no job here to release")
	assert(thread.is_done(t), "release_head_job called on a thread that never finished")

	delete(job.buffer, child.job_allocator())
	delete(job.path, child.job_allocator())
	free(job, child.job_allocator())
	thread.destroy(t)
}

// Where a completed head's answer crosses from `child.job_allocator`'s
// heap onto the allocator the caller actually asked for -- the same
// copy-then-release shape `child.read.odin`'s `finished` uses.
@(private)
@(require_results)
head_finished :: proc(
	t: ^thread.Thread,
	job: ^Head_Job,
	allocator: mem.Allocator,
) -> (
	head: []u8,
	bytes: i64,
	err: Error,
) {
	assert(t != nil, "there is no thread here to close out")
	assert(job != nil, "a finished head read has no job to read its answer from")

	err = job.err
	bytes = job.bytes
	if err.fault == .None {
		head = make([]u8, len(job.head), allocator)
		copy(head, job.head)
	}
	release_head_job(t, job)
	return
}

// Why the two intermediates carry the process id and `<name>.wav` does not,
// what the process id does not separate, and why the wav's own name also
// carries a key derived from `source`: ADR-0023.
Job :: struct {
	source:  string,
	cache:   string,
	name:    string,
	planned: Reading,
}

// The cache is not checked here: a cache that will not open is not a fact about
// this Recording, it fails every Recording identically, and it is `open_cache`'s
// answer -- which a Batch calls once, before the first extraction.
@(require_results)
extract :: proc(
	group: ^child.Job_Object,
	tools: Tools,
	job: Job,
	allocator: mem.Allocator,
	tolerance := DEFAULT_TOLERANCE,
) -> (
	produced: Extracted,
	err: Error,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(job.name) > 0, "a Recording with no artifact stem has nowhere to put its audio")
	assert(allocator.procedure != nil, "an extraction needs an allocator to work in")

	if unsettled := settle(job.source, job.planned, MINIMUM_SETTLING_GAP_NS, allocator);
	   unsettled.fault != .None {
		return {}, unsettled
	}

	answer := fmt.aprintf(
		"%s\\%s.%d.probe",
		job.cache,
		job.name,
		os.get_pid(),
		allocator = allocator,
	)
	defer delete(answer, allocator)
	probed, unprobed := probe(group, tools, job.source, answer, allocator)
	if unprobed.fault != .None {
		return {}, unprobed
	}
	if probed.audio_streams == 0 {
		return {}, Error{fault = .No_Audio_Stream}
	}
	return produce(group, tools, job, probed.duration_ms, tolerance, allocator)
}

// Long enough that two different Recordings' sources collide on a wav key by
// chance only far below any Batch this program will ever run against (a
// birthday bound over 2^64 keys), short enough that the filename stays
// legible next to the artifact stem it still carries. Issue #256, item 3.
SOURCE_KEY_BYTES :: 8
SOURCE_KEY_CHARS :: 2 * SOURCE_KEY_BYTES

#assert(SOURCE_KEY_BYTES <= sha2.DIGEST_SIZE_256)

// A short, deterministic key over a Recording's own source path -- not its
// bytes, which `produce` has not read yet and `extract` never will read as a
// whole. Two Recordings sharing an artifact stem from different subfolders
// of one Batch root are a real, legitimate shape (ADR-0008's own injectivity
// note is scoped to one directory), and `job.name` alone cannot tell them
// apart in the flat scratch cache.
@(private)
@(require_results)
source_key :: proc(source: string, allocator: mem.Allocator) -> string {
	assert(len(source) > 0, "there is no Recording source here to key")
	assert(allocator.procedure != nil, "a key outliving this procedure needs an allocator")

	context_256: sha2.Context_256
	sha2.init_256(&context_256)
	sha2.update(&context_256, transmute([]u8)source)
	sum: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&context_256, sum[:])

	encoded, _ := hex.encode(sum[:SOURCE_KEY_BYTES], allocator)
	key := string(encoded)
	assert(len(key) == SOURCE_KEY_CHARS, "a source key rendered to the wrong number of characters")
	return key
}

// `produce`'s own wav path, pulled out so a test can prove two Recordings
// sharing a stem key to two different paths without spawning ffmpeg at all --
// the collision issue #256's item 3 measured is in this string, not in
// anything ffmpeg does. The caller frees the answer with `delete` and the
// same allocator.
@(private)
@(require_results)
wav_cache_path :: proc(job: Job, allocator: mem.Allocator) -> string {
	assert(len(job.cache) > 0, "there is no cache here to place audio into")
	assert(len(job.name) > 0, "a Recording with no artifact stem has nowhere to put its audio")
	assert(len(job.source) > 0, "there is no Recording source here to key its audio to")

	key := source_key(job.source, allocator)
	defer delete(key, allocator)
	path := fmt.aprintf("%s\\%s.%s.wav", job.cache, job.name, key, allocator = allocator)
	assert(len(path) > len(job.cache), "a wav cache path was not built at all")
	return path
}

// Issue #112: `container_ms > 0` below is internal, not a check on external
// input. `extract` is the only caller, and it passes `probed.duration_ms`
// straight through -- `probed` only reaches here when `probe`'s call to
// `process.read_probe` returned `fault == .None`, which that procedure's own
// doc comment establishes never happens with a non-positive duration. The
// `probed.audio_streams == 0` guard above this call in `extract` answers a
// different question (whether there is audio to extract at all) and is not
// what keeps this value positive.
@(private)
@(require_results)
produce :: proc(
	group: ^child.Job_Object,
	tools: Tools,
	job: Job,
	container_ms: i64,
	tolerance: Tolerance,
	allocator: mem.Allocator,
) -> (
	produced: Extracted,
	err: Error,
) {
	assert(container_ms > 0, "a container with no duration was never accepted by the probe")
	assert(len(job.name) > 0, "a Recording with no artifact stem has nowhere to put its audio")

	audio := wav_cache_path(job, allocator)
	part := fmt.aprintf("%s.%d.part", audio, os.get_pid(), allocator = allocator)
	defer delete(part, allocator)
	defer if err.fault != .None {
		discard_part(part, err.fault)
		delete(audio, allocator)
	}

	arguments := process.extract_arguments(job.source, part, allocator)
	defer delete(arguments, allocator)
	observed: Exit_Observed
	ending, _, refusal := child.run_bounded(
		group,
		tools.ffmpeg,
		arguments,
		EXTRACTION_BOUND_MS,
		allocator,
		child.Run_Callbacks{user = &observed, on_exit = observe_exit},
	)
	switch ending {
	case .Not_Started:
		return {}, Error{fault = .Extraction_Not_Started, child = refusal}
	case .Stopped:
		return {}, Error{fault = .Extraction_Did_Not_Finish}
	case .Unstoppable:
		return {}, Error{fault = .Extraction_Not_Stopped}
	case .Finished:
	}
	assert(observed.exited, "a finished ffmpeg run reported no exit status at all")
	if observed.code != 0 {
		return {}, Error{fault = .Extraction_Refused, exit_code = observed.code}
	}

	measured, unusable := check_audio(part, container_ms, tolerance, allocator)
	if unusable.fault != .None {
		return {}, unusable
	}
	if os.rename(part, audio) != nil {
		return {}, Error{fault = .Audio_Not_Published}
	}
	return Extracted{audio = audio, container_ms = container_ms, measured_ms = measured}, Error{}
}

// `.Extraction_Not_Stopped` reports a wait that never completed, so ffmpeg may
// still be running and may still hold this file; the sweep takes it on age
// instead. Every other failure leaves a half-written file the next run would
// find and take for finished work.
@(private)
discard_part :: proc(part: string, fault: Fault) {
	assert(len(part) > 0, "there is no half-written audio here to discard")
	assert(fault != .None, "an extraction that came through has no half-written audio")

	if fault == .Extraction_Not_Stopped {
		return
	}
	os.remove(part)
}

// A drive path's root is `X:\` and a UNC path's root is `\\server\share\` --
// trimming past either turns a root into a different, relative-on-that-drive
// path (`C:\` into `C:`), so this is the floor `trim_trailing_separators`
// will not cross.
@(require_results)
volume_root_len :: proc(path: string) -> int {
	assert(len(path) > 0, "there is no path here to find a volume root in")

	if len(path) >= 3 && path[1] == ':' && os.is_path_separator(path[2]) {
		return 3
	}
	if len(path) >= 2 && os.is_path_separator(path[0]) && os.is_path_separator(path[1]) {
		seps := 0
		for i := 2; i < len(path); i += 1 {
			if os.is_path_separator(path[i]) {
				seps += 1
				if seps == 2 {
					return i + 1
				}
			}
		}
		return len(path)
	}
	return 0
}

// A trailing separator on an otherwise ordinary leaf (`...\leaf\`) makes
// `os.dir` answer the leaf itself rather than its parent -- `_split_path`
// walks back from the last byte, and the last byte is the separator. Strip it
// before asking for the parent, down to but never past the volume root.
@(require_results)
trim_trailing_separators :: proc(path: string) -> string {
	assert(len(path) > 0, "there is no path here to trim")

	floor := volume_root_len(path)
	trimmed := path
	for len(trimmed) > floor && os.is_path_separator(trimmed[len(trimmed) - 1]) {
		trimmed = trimmed[:len(trimmed) - 1]
	}
	return trimmed
}

// The resolved path is what is checked: a relative cache path is perfectly ASCII
// and resolves under an account name that may not be. A path that is not valid
// UTF-8 answers `.Unusable` rather than `.Path_Not_Ascii`, because
// `get_absolute_path` refuses it before the ASCII check ever sees it.
//
// `--cache` is hand-typed, and this is the FIRST thing `--transcribe` does
// with it -- before any bound the rest of a run relies on. `make_directory-`
// `_bounded` is `os.make_directory_all` run the way `child.read_bounded`
// runs a whole-file read, so a scratch cache on a share that stops
// answering is reported rather than wedging the Batch before its first
// Recording (PR #64's third review, finding 6).
//
// A regular file at the cache path is refused here, by name, rather than
// left to fail confusingly later in `sweep_cache` (issue #120). A cache
// whose immediate parent directory does not exist is refused rather than
// created: `--cache` is hand-typed, and creating an implausible multi-level
// tree for a typo (`C:\this\does\not\exist\x`) is worse than refusing it --
// the one level `make_directory_bounded` still creates below an existing
// parent is what a fresh, not-yet-used cache directory actually needs.
@(require_results)
open_cache :: proc(cache: string, allocator: mem.Allocator) -> Cache_Fault {
	assert(len(cache) > 0, "there is no scratch cache here to open")
	assert(allocator.procedure != nil, "resolving a path needs an allocator to resolve it into")

	resolved, unresolvable := os.get_absolute_path(cache, allocator)
	if unresolvable != nil {
		return .Unusable
	}
	defer delete(resolved, allocator)

	if !process.ascii_only(resolved) {
		return .Path_Not_Ascii
	}
	if os.is_file(resolved) {
		return .Not_A_Directory
	}
	if !os.exists(resolved) {
		parent := os.dir(trim_trailing_separators(resolved))
		if !os.exists(parent) {
			return .Parent_Missing
		}
	}
	if !child.make_directory_bounded(cache, child.READ_BOUND_MS) {
		return .Unusable
	}
	return verify_cache_ownership(cache, allocator)
}

// Written into a cache directory transcibr created or has already verified it
// owns, so the NEXT `open_cache` against the same directory does not have to
// re-walk its contents to answer the same question again. Its own name is
// not one of the four shapes `entry_name_transcibr_written` below
// recognizes, so it is never itself read as evidence of ownership.
CACHE_MARKER_NAME :: ".transcibr-cache"

// The ownership boundary: transcibr may write into a cache directory it
// created, one already carrying its own marker, or a directory holding
// nothing but the four shapes this package itself ever writes there --
// yesterday's cache, from before this ticket, adopted rather than stranded.
// Anything else is a directory this program did not make and cannot prove it
// owns, and `sweep_cache`'s age/size sweep or `produce`'s unconditional
// rename over `<cache>\<name>...wav` is what a wrong answer here would hand
// to it. Issue #256: `sweep_cache` gates through `open_cache` on every call,
// so this is the one seam that has to hold; `produce` and `extract` do not
// re-verify ownership per Recording, exactly as `extract`'s own doc comment
// already states for cache validity in general -- a Batch calls this once.
@(private)
@(require_results)
verify_cache_ownership :: proc(cache: string, allocator: mem.Allocator) -> Cache_Fault {
	assert(len(cache) > 0, "there is no scratch cache here to check ownership of")
	assert(allocator.procedure != nil, "an ownership check needs an allocator for its listing")

	marker := fmt.aprintf("%s\\%s", cache, CACHE_MARKER_NAME, allocator = allocator)
	defer delete(marker, allocator)
	if os.exists(marker) {
		return .None
	}

	listing, readable := child.list_directory_bounded(cache, child.READ_BOUND_MS, allocator)
	if !readable {
		return .Unusable
	}
	defer os.file_info_slice_delete(listing, allocator)

	if !cache_directory_is_transcibr_shaped(listing) {
		return .Foreign_Directory
	}
	if !write_cache_marker(marker) {
		return .Unusable
	}
	return .None
}

// A directory nothing has marked reads as transcibr's own only when every
// entry is a plain file (never a subdirectory transcibr never creates) whose
// name is one of the four shapes `produce`, `probe` and the Engine's own
// output ever write into a scratch cache -- an empty directory satisfies this
// trivially, since there is nothing in it to fail the check.
@(private)
@(require_results)
cache_directory_is_transcibr_shaped :: proc(listing: []os.File_Info) -> bool {
	for info in listing {
		if info.type != .Regular && info.type != .Undetermined {
			return false
		}
		if !entry_name_transcibr_written(info.name) {
			return false
		}
	}
	return true
}

// The four suffixes this package (`.wav`, `.probe`, `.part`) and the Engine
// (`.json`, `process.ENGINE_OUTPUT_SUFFIX`) ever write into a scratch cache.
// Narrow on purpose: a directory of a user's own recordings is realistically
// video (`.mp4`, `.mov`, `.mkv`) rather than any of these four, with one
// accepted exception recorded in ADR-0023's #256 addendum -- a folder of
// nothing but raw `.wav` voice memos reads as transcibr's own too, and is
// adopted the same way a real leftover cache is.
@(private)
@(require_results)
entry_name_transcibr_written :: proc(name: string) -> bool {
	assert(len(name) > 0, "there is no cache entry name here to classify")
	return(
		strings.has_suffix(name, ".wav") ||
		strings.has_suffix(name, ".json") ||
		strings.has_suffix(name, ".probe") ||
		strings.has_suffix(name, ".part") \
	)
}

@(private)
@(require_results)
write_cache_marker :: proc(marker: string) -> bool {
	assert(len(marker) > 0, "there is no marker path here to write")
	return os.write_entire_file(marker, []u8{}) == nil
}

// Best effort by construction: Windows refuses to delete a file another process
// holds open without sharing delete permission, so the file stays, the sweep
// carries on, and what is answered is what actually went.
//
// `child.list_directory_bounded` and not `os.read_all_directory_by_path`
// directly, for the identical reason `open_cache` no longer calls
// `os.make_directory_all` directly: the listing this sweep starts with is
// the same call `planning.directory_listing_bounded` already bounds, two
// packages over, and `--cache` reaches it unbounded until this does (PR
// #64's third review, finding 6).
@(require_results)
sweep_cache :: proc(
	cache: string,
	limits: Sweep_Limits,
	allocator: mem.Allocator,
) -> (
	taken: int,
	fault: Cache_Fault,
) {
	assert(len(cache) > 0, "there is no scratch cache here to sweep")
	assert(allocator.procedure != nil, "a listing needs an allocator to be read into")

	if opening := open_cache(cache, allocator); opening != .None {
		return 0, opening
	}
	listing, readable := child.list_directory_bounded(cache, child.READ_BOUND_MS, allocator)
	if !readable {
		return 0, .Unusable
	}
	defer os.file_info_slice_delete(listing, allocator)

	entries := cache_entries(listing, allocator)
	defer delete(entries, allocator)
	chosen := sweep_choice(entries, limits, allocator)
	defer delete(chosen, allocator)

	for index in chosen {
		if os.remove(entries[index].name) == nil {
			taken += 1
		}
	}
	return taken, .None
}

// Why the listing counts entries `core:os` cannot classify: ADR-0023. The
// ownership marker is excluded on top of that (issue #256): it is metadata
// about the cache, not content a Recording ever produced, and letting the
// age/size sweep take it would let one aggressive sweep call strand the very
// directory it just finished clearing -- the next `open_cache` would find no
// marker, list only a leftover subdirectory the sweep itself never touches,
// and refuse a directory transcibr had already proven it owned.
@(private)
@(require_results)
cache_entries :: proc(listing: []os.File_Info, allocator: mem.Allocator) -> []Cache_Entry {
	assert(allocator.procedure != nil, "a listing needs an allocator to be turned into entries")

	now := time.time_to_unix_nano(time.now())
	entries := make([dynamic]Cache_Entry, 0, len(listing), allocator)
	for info in listing {
		if info.type != .Regular && info.type != .Undetermined {
			continue
		}
		if info.name == CACHE_MARKER_NAME {
			continue
		}
		append(
			&entries,
			Cache_Entry {
				name = info.fullpath,
				bytes = info.size,
				age_ns = now - time.time_to_unix_nano(info.modification_time),
			},
		)
	}
	shrink(&entries)
	return entries[:]
}
