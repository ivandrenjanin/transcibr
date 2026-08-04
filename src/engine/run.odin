#+vet explicit-allocators
package engine

import "core:fmt"
import "core:mem"
import "core:os"
import "core:time"
import "transcibr:child"
import "transcibr:process"

// This file starts the Engine, drains what it says while it runs, and reads back
// what it left.

// A quarter of a second stays well under the 64 KiB diagnostic pipe filling
// against an Engine that writes a few kilobytes over a whole Recording
// (ADR-0004), and paints far more often than a hundred-position bar can show.
@(private)
POLL_MS :: u32(250)

@(private)
DRAIN_BYTES :: 4096

// Why one drain has a ceiling at all, and why a megabyte: ADR-0020.
@(private)
MAX_DRAIN_BYTES :: 1 << 20

#assert(MAX_DRAIN_BYTES > DRAIN_BYTES)

@(private)
Run :: enum u8 {
	Not_Started = 0,
	Finished,
	Stopped,
	Unstoppable,
}

@(private)
Ending :: struct {
	run:         Run,
	silent:      bool,
	duration_ms: i64,
	child:       child.Error,
}

// Offset by one because the first tick since a start reads zero, and
// `process.tracker_start` refuses that.
@(private)
@(require_results)
elapsed_ns :: proc(started: time.Tick) -> i64 {
	reading := 1 + i64(time.duration_nanoseconds(time.tick_since(started)))
	assert(reading > 0, "a monotonic counter that went backwards or has not started")
	return reading
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

	bound_ms := limits.bound_ms
	if bound_ms <= 0 {
		bound_ms = process.transcribe_bound_ms(job.container_ms)
	}
	assert(bound_ms > 0, "an Engine given no time at all cannot transcribe anything")

	c, refusal := child.start(group, executable, arguments, allocator)
	if refusal.fault != .None {
		return Ending{run = .Not_Started, child = refusal}
	}
	defer child.close(&c)

	started := time.tick_now()
	tracker := process.tracker_start(job.container_ms, elapsed_ns(started))
	reader: process.Line_Reader
	painted := process.Progress {
		percent = UNPAINTED,
	}
	for {
		if !drain(&c, &tracker, &reader, started) {
			return stopped(&c, false, tracker.duration_ms)
		}
		now_ns := elapsed_ns(started)
		now := process.shown(tracker, now_ns, limits.watch)
		tell(report, now, &painted)
		if now.silent {
			return stopped(&c, true, tracker.duration_ms)
		}
		if child.wait(&c, POLL_MS) {
			return finished(&c, &tracker, &reader, started, report, limits.watch, &painted)
		}
		if now_ns / 1_000_000 > bound_ms {
			return stopped(&c, false, tracker.duration_ms)
		}
	}
}

// The pipe outlives the child that wrote to it, and the readings worth having
// most are the ones written just before exit.
@(private)
@(require_results)
finished :: proc(
	c: ^child.Child,
	tracker: ^process.Tracker,
	reader: ^process.Line_Reader,
	started: time.Tick,
	report: Report,
	watch: process.Watch,
	painted: ^process.Progress,
) -> Ending {
	assert(c != nil, "there is no child here to read out")
	assert(tracker != nil, "there is no Recording here to track")

	_ = drain(c, tracker, reader, started)
	tell(report, process.shown(tracker^, elapsed_ns(started), watch), painted)
	return Ending{run = .Finished, duration_ms = tracker.duration_ms}
}

@(private)
@(require_results)
stopped :: proc(c: ^child.Child, silent: bool, duration_ms: i64) -> Ending {
	assert(c != nil, "there is no child here to stop")

	return Ending {
		run = .Stopped if child.stop(c) else .Unstoppable,
		silent = silent,
		duration_ms = duration_ms,
	}
}

// tracker_heard is called for every read that produced bytes, whether or not any
// of them read as a line: an Engine writing a log this reader has no reading for
// is still alive (ADR-0012).
@(private)
@(require_results)
drain :: proc(
	c: ^child.Child,
	tracker: ^process.Tracker,
	reader: ^process.Line_Reader,
	started: time.Tick,
) -> (
	readable: bool,
) {
	assert(c != nil, "there is no child here to read")
	assert(tracker != nil, "there is no Recording here to track")
	assert(reader != nil, "there is nowhere to assemble the child's lines")

	buffer: [DRAIN_BYTES]u8 = ---
	taken := 0
	for taken < MAX_DRAIN_BYTES {
		read, at_end, reading := child.read_diagnostics(c, buffer[:])
		if reading.fault != .None {
			return false
		}
		if read > 0 {
			assert(read <= len(buffer), "the pipe wrote past the end of the buffer it was given")
			took(tracker, reader, string(buffer[:read]), elapsed_ns(started))
			taken += read
		}
		if at_end {
			if line, held := process.last_line(reader); held {
				process.tracker_said(tracker, process.read_engine_line(line), elapsed_ns(started))
			}
			return true
		}
		if read == 0 {
			return true
		}
	}
	assert(taken >= MAX_DRAIN_BYTES, "a drain left its loop with room to spare")
	return true
}

@(private)
took :: proc(tracker: ^process.Tracker, reader: ^process.Line_Reader, chunk: string, now_ns: i64) {
	assert(tracker != nil, "there is no Recording here to track")
	assert(len(chunk) > 0, "a read that took nothing was reported as the Engine talking")

	process.tracker_heard(tracker, len(chunk), now_ns)
	remaining := chunk
	for {
		line, ok := process.next_line(reader, &remaining)
		if !ok {
			return
		}
		process.tracker_said(tracker, process.read_engine_line(line), now_ns)
	}
}

// Below any percentage `shown` can answer, so the first poll of a run always
// paints.
@(private)
UNPAINTED :: -1

#assert(UNPAINTED < 0)

// Only on a change: this is called four times a second, so a three-hour
// Recording is 43,200 console writes to show the forty-odd distinct frames a bar
// with a hundred positions and three annotations can have.
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
