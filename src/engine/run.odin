#+vet explicit-allocators
package engine

import "core:fmt"
import "core:mem"
import "core:os"
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
	silent:      bool,
	duration_ms: i64,
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
		process.Engine_Job{model = job.model, audio = job.audio, prefix = prefix},
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
	if missing := landed(output); missing != .None {
		return {}, Error{fault = missing}
	}
	return Transcribed{output = output, duration_ms = ending.duration_ms}, Error{}
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
		return Error{fault = .Went_Silent if ending.silent else .Did_Not_Finish}
	case .Finished:
	}
	return Error{}
}

// One open and no stat, so the length belongs to the same file the handle does.
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

// The caller's own reading of a chunk: a Tracker fed through a Line_Reader,
// exactly what transcibr:child knows nothing about.
@(private)
Watch_State :: struct {
	tracker: process.Tracker,
	reader:  process.Line_Reader,
	report:  Report,
	watch:   process.Watch,
	painted: process.Progress,
	silent:  bool,
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
}

// Only on a change: this is called four times a second, so a three-hour
// Recording is 43,200 console writes to show the forty-odd distinct frames a
// bar with a hundred positions and three annotations can have. Called once
// more after the child finishes, so the display's last paint reflects the
// Engine's true final reading.
//
// It also carries a second duty `on_poll`'s `-> bool` signature has no room
// for: `child.Run` collapses a bound expiry, this callback asking to stop,
// and a drain failure into one `.Stopped`, so this writes the distinction
// into `watch_state.silent` for `ending_for` to read back once `run_bounded`
// has already returned. Correct only because a `true` return here exits the
// loop immediately, so nothing between the write and `ending_for`'s read can
// see a stale value. A future `on_poll` that sets the flag and returns
// `false` -- a "warn, don't stop" reading -- would leave a wall-clock-expiry
// ending reporting `.Went_Silent` for a run that was never silent. Carrying
// the stop reason in `child.Run`'s own return would close this, but that is
// a shape change to a type two other callers already share; recorded here
// rather than done in this pass.
@(private)
@(require_results)
watched_poll :: proc(elapsed_ns: i64, user: rawptr) -> bool {
	assert(user != nil, "there is no Recording here to track")
	assert(elapsed_ns > 0, "a poll arrived before the child's clock could have started")

	watch_state := (^Watch_State)(user)
	now := process.shown(watch_state.tracker, elapsed_ns, watch_state.watch)
	tell(watch_state.report, now, &watch_state.painted)
	watch_state.silent = now.silent
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

	run, refusal := child.run_bounded(
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
	return ending_for(run, watch_state, refusal)
}

// What run_engine's loop measured survives every ending, stopped or not: an
// Engine that ran for two hours and then would not stop still ran for two
// hours, and a caller deciding what to do with an Unstoppable Engine is
// exactly the caller that most needs to know how long it had been running.
@(private)
@(require_results)
ending_for :: proc(run: child.Run, watch_state: Watch_State, refusal: child.Error) -> Ending {
	switch run {
	case .Not_Started:
		return Ending{run = .Not_Started, child = refusal}
	case .Unstoppable:
		return Ending {
			run = .Unstoppable,
			silent = watch_state.silent,
			duration_ms = watch_state.tracker.duration_ms,
		}
	case .Stopped:
		return Ending {
			run = .Stopped,
			silent = watch_state.silent,
			duration_ms = watch_state.tracker.duration_ms,
		}
	case .Finished:
	}
	return Ending{run = .Finished, duration_ms = watch_state.tracker.duration_ms}
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
