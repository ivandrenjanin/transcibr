#+vet explicit-allocators
package engine

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"
import "transcibr:child"
import "transcibr:process"

// This file starts the Engine, drains what it says while it runs, and reads
// back what it left. The poll loop and the drain that bounds it live in
// transcibr:child; what stays here is what an Engine's chunk means -- fed to a
// process.Tracker through a process.Line_Reader -- and what one bounded run of
// it is called.

@(private)
Ending :: struct {
	run:         child.Run,
	reason:      child.Stop_Reason,
	duration_ms: i64,
	elapsed_ms:  i64,
	child:       child.Error,
}

@(require_results)
transcribe :: proc(
	group: ^child.Job_Object,
	tools: Tools,
	job: Job,
	report: Report,
	allocator: mem.Allocator,
	limits := DEFAULT_LIMITS,
) -> (
	produced: Transcribed,
	err: Error,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(job.name) > 0, "a Recording with no artifact stem has nowhere to put its output")
	assert(len(job.cache) > 0, "the Engine may write into the scratch cache and nowhere else")
	assert(allocator.procedure != nil, "an Engine invocation needs an allocator to work in")
	assert(job.container_ms > 0, "a Recording nobody could time reached the Engine")

	prefix := fmt.aprintf("%s\\%s", job.cache, job.name, allocator = allocator)
	defer delete(prefix, allocator)
	if !openable_by_the_engine(job, prefix) {
		return {}, Error{fault = .Path_Not_Ascii}
	}
	arguments := process.engine_arguments(
		process.Engine_Job {
			model = job.model,
			audio = job.audio,
			prefix = prefix,
			prompt = job.prompt,
		},
		allocator,
	)
	defer delete(arguments, allocator)

	ending := run_engine(group, tools.engine, arguments, job, report, limits, allocator)
	output := process.engine_output_path(prefix, allocator)
	defer if err.fault != .None {
		delete(output, allocator)
	}

	if refusal := refused(ending); refusal.fault != .None {
		return {}, refusal
	}
	if missing := landed_bounded(output, child.READ_BOUND_MS); missing != .None {
		return {}, Error{fault = missing}
	}
	return Transcribed {
		output = output,
		duration_ms = ending.duration_ms,
		elapsed_ms = ending.elapsed_ms,
	}, Error{}
}

// Why all three paths, and why this does not subsume `open_cache`: ADR-0025.
@(private)
@(require_results)
openable_by_the_engine :: proc(job: Job, prefix: string) -> bool {
	assert(len(prefix) > 0, "the Engine was given nowhere to write its output")

	if !process.ascii_only(job.model) {
		return false
	}
	if !process.ascii_only(job.audio) {
		return false
	}
	if !process.ascii_only(prefix) {
		return false
	}
	return true
}

@(private)
@(require_results)
refused :: proc(ending: Ending) -> Error {
	switch ending.run {
	case .Not_Started:
		return Error{fault = .Not_Started, child = ending.child}
	case .Unstoppable:
		return Error{fault = .Not_Stopped}
	case .Stopped:
		switch ending.reason {
		case .Poll_Asked:
			return Error{fault = .Went_Silent}
		case .None, .Bound_Expired, .Drain_Failed:
			return Error{fault = .Did_Not_Finish}
		}
		return Error{fault = .Did_Not_Finish}
	case .Finished:
	}
	return Error{}
}

// One open and no stat, so the length belongs to the same file the handle does.
//
// Runs only on `landed_bounded`'s worker thread below: `os.open` can wedge on
// the same stalled scratch cache `child.read_bounded` guards the read that
// follows this one against, in `artifact.complete` (issue #65).
@(private)
@(require_results)
landed :: proc(output: string) -> Fault {
	assert(len(output) > 0, "there is nowhere here to look for the Engine's output")

	handle, unopenable := os.open(output)
	if unopenable != nil {
		return .No_Output
	}
	defer os.close(handle)

	length, unmeasurable := os.file_size(handle)
	if unmeasurable != nil {
		return .No_Output
	}
	if length == 0 {
		return .Output_Empty
	}
	return .None
}

// `landed`'s own worker, bounded the same shape as `audio.read_head_bounded`
// and `artifact.digest_of_bounded`: a small worker thread plus
// `child.await_and_reclaim`, its job on `child.job_allocator`'s heap so an
// abandoned thread has somewhere safe to keep writing after this procedure
// has already returned to its caller.
@(private)
Landed_Job :: struct {
	output:   string,
	fault:    Fault,
	stall_ms: i64,
}

@(private)
landed_worker :: proc(data: rawptr) {
	job := (^Landed_Job)(data)
	assert(job != nil, "a landed-check thread was started with no job to check")
	assert(len(job.output) > 0, "a landed-check thread was started with no path to check")

	if job.stall_ms > 0 {
		time.sleep(time.Duration(job.stall_ms) * time.Millisecond)
	}
	job.fault = landed(job.output)
}

// Every wait outcome that is not `.Finished` collapses onto `.No_Output`, the
// same fault `landed` itself already answers for an output it could not
// open: a caller cannot tell a wedge from an ordinary open failure apart, and
// A8 asks it to reject the read rather than assert on it either way.
@(private)
@(require_results)
landed_bounded :: proc(output: string, bound_ms: i64) -> Fault {
	return landed_bounded_stalled(output, bound_ms, 0)
}

// `landed_bounded`'s own body, plus a worker-side stall no production caller
// ever passes: `landed_bounded_stalled(output, bound_ms, 0)` behaves
// identically to the code above it. A stall greater than `bound_ms` is what
// `engine_test.odin` uses to reach the `.Stopped` branch with a real,
// running thread rather than a mocked wait outcome (issue #65's coverage
// finding).
@(private)
@(require_results)
landed_bounded_stalled :: proc(output: string, bound_ms: i64, stall_ms: i64) -> Fault {
	assert(len(output) > 0, "there is nowhere here to look for the Engine's output")
	assert(bound_ms > 0, "a check given no time at all cannot do anything")
	assert(stall_ms >= 0, "a stall cannot run for negative time")

	job := new(Landed_Job, child.job_allocator())
	job.output = strings.clone(output, child.job_allocator())
	job.stall_ms = stall_ms

	context.allocator = child.job_allocator()
	t := thread.create_and_start_with_data(job, landed_worker)
	if t == nil {
		delete(job.output, child.job_allocator())
		free(job, child.job_allocator())
		return .No_Output
	}

	finished, reclaim := child.await_and_reclaim(t, bound_ms)
	if finished {
		fault := job.fault
		release_landed_job(t, job)
		return fault
	}
	if reclaim {
		release_landed_job(t, job)
	}
	return .No_Output
}

@(private)
release_landed_job :: proc(t: ^thread.Thread, job: ^Landed_Job) {
	assert(t != nil, "there is no thread here to release")
	assert(job != nil, "there is no job here to release")

	delete(job.output, child.job_allocator())
	free(job, child.job_allocator())
	thread.destroy(t)
}

// The caller's own reading of a chunk: a Tracker fed through a Line_Reader,
// exactly what transcibr:child knows nothing about.
@(private)
Watch_State :: struct {
	tracker:    process.Tracker,
	reader:     process.Line_Reader,
	report:     Report,
	watch:      process.Watch,
	painted:    process.Progress,
	elapsed_ms: i64,
}

// Called for every read that produced bytes, whether or not any of them read
// as a line: an Engine writing a log this reader has no reading for is still
// alive (ADR-0012).
@(private)
watched_chunk :: proc(chunk: string, elapsed_ns: i64, user: rawptr) {
	assert(user != nil, "there is no Recording here to track")
	assert(elapsed_ns > 0, "a chunk arrived before the child's clock could have started")
	assert(len(chunk) > 0, "a read that took nothing was reported as the Engine talking")

	watch_state := (^Watch_State)(user)
	process.tracker_heard(&watch_state.tracker, len(chunk), elapsed_ns)
	remaining := chunk
	for {
		line, ok := process.next_line(&watch_state.reader, &remaining)
		if !ok {
			return
		}
		process.tracker_said(&watch_state.tracker, process.read_engine_line(line), elapsed_ns)
	}
}

// The pipe outlives the child that wrote to it, and the reading worth having
// most is the one written just before exit.
@(private)
watched_end :: proc(elapsed_ns: i64, user: rawptr) {
	assert(user != nil, "there is no Recording here to track")
	assert(elapsed_ns > 0, "an end arrived before the child's clock could have started")

	watch_state := (^Watch_State)(user)
	if line, held := process.last_line(&watch_state.reader); held {
		process.tracker_said(&watch_state.tracker, process.read_engine_line(line), elapsed_ns)
	}
	watch_state.elapsed_ms = elapsed_ns / 1_000_000
}

// Only on a change: this is called four times a second, so a three-hour
// Recording is 43,200 console writes to show the forty-odd distinct frames a
// bar with a hundred positions and three annotations can have. Called once
// more after the child finishes, so the display's last paint reflects the
// Engine's true final reading.
@(private)
@(require_results)
watched_poll :: proc(elapsed_ns: i64, user: rawptr) -> bool {
	assert(user != nil, "there is no Recording here to track")
	assert(elapsed_ns > 0, "a poll arrived before the child's clock could have started")

	watch_state := (^Watch_State)(user)
	now := process.shown(watch_state.tracker, elapsed_ns, watch_state.watch)
	tell(watch_state.report, now, &watch_state.painted)
	return now.silent
}

@(private)
@(require_results)
run_engine :: proc(
	group: ^child.Job_Object,
	executable: string,
	arguments: []string,
	job: Job,
	report: Report,
	limits: Limits,
	allocator: mem.Allocator,
) -> (
	ending: Ending,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(arguments) > 0, "the Engine was started with no arguments at all")
	assert(job.container_ms > 0, "a Recording nobody could time reached the Engine")

	bound_ms := limits.bound_ms
	if bound_ms <= 0 {
		bound_ms = process.transcribe_bound_ms(job.container_ms)
	}
	assert(bound_ms > 0, "an Engine given no time at all cannot transcribe anything")

	watch_state := Watch_State {
		tracker = process.tracker_start(job.container_ms, 1),
		report = report,
		watch = limits.watch,
		painted = process.Progress{percent = UNPAINTED},
	}

	run, reason, refusal := child.run_bounded(
		group,
		executable,
		arguments,
		bound_ms,
		allocator,
		child.Run_Callbacks {
			user = &watch_state,
			on_chunk = watched_chunk,
			on_end = watched_end,
			on_poll = watched_poll,
		},
	)
	return ending_for(run, reason, watch_state, refusal)
}

// What run_engine's loop measured survives every ending, stopped or not: an
// Engine that ran for two hours and then would not stop still ran for two
// hours, and a caller deciding what to do with an Unstoppable Engine is
// exactly the caller that most needs to know how long it had been running.
@(private)
@(require_results)
ending_for :: proc(
	run: child.Run,
	reason: child.Stop_Reason,
	watch_state: Watch_State,
	refusal: child.Error,
) -> Ending {
	switch run {
	case .Not_Started:
		return Ending{run = .Not_Started, child = refusal}
	case .Unstoppable:
		return Ending {
			run = .Unstoppable,
			reason = reason,
			duration_ms = watch_state.tracker.duration_ms,
			elapsed_ms = watch_state.elapsed_ms,
		}
	case .Stopped:
		return Ending {
			run = .Stopped,
			reason = reason,
			duration_ms = watch_state.tracker.duration_ms,
			elapsed_ms = watch_state.elapsed_ms,
		}
	case .Finished:
	}
	return Ending {
		run = .Finished,
		duration_ms = watch_state.tracker.duration_ms,
		elapsed_ms = watch_state.elapsed_ms,
	}
}

// Below any percentage `shown` can answer, so the first poll of a run always
// paints.
@(private)
UNPAINTED :: -1

#assert(UNPAINTED < 0)

@(private)
tell :: proc(report: Report, shown: process.Progress, painted: ^process.Progress) {
	assert(painted != nil, "there is nowhere to remember what the display was last told")
	assert(shown.percent >= 0, "a display was handed a negative percentage")
	assert(shown.percent <= 100, "a display was handed a percentage past a hundred")

	if shown == painted^ {
		return
	}
	painted^ = shown
	if report.on_progress == nil {
		return
	}
	report.on_progress(shown, report.user)
}
