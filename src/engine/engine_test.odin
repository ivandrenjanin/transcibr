package engine

import "core:fmt"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"
import "core:testing"
import "transcibr:child"
import "transcibr:process"

// THE SHELL HALF, against real children and a real scratch cache.
//
// ADR-0009 puts a ceiling on this: "the pipeline, the subprocess layer, the
// Win32 window and the GPU path will never have unit tests". Every DECISION this
// package rests on is next door in `transcibr:process` and has a suite there --
// the progress reading, the fallback, the watchdog's two bounds, the argument
// list. What is left here is wiring, and what these cases check is that the
// wiring is connected: that a child's diagnostic output reaches the display,
// that a child which says nothing is stopped, and that what is on the disk
// afterwards is what settles the Recording.
//
// WHAT IS VERIFIED BY HAND AND RECORDED IN THE PULL REQUEST is the one thing
// that needs the Engine itself: a Recording transcribed end to end on the GPU.
// A case that did that would spend real GPU time and real minutes in every
// sweep, on every machine, for a coupling the committed fixture in
// `transcibr:process` already pins byte for byte.
//
// EVERY CHILD HERE IS BOUNDED, which is a rule and not a habit: `odin test` runs
// what it builds, and a child that never exits wedges the whole sweep behind
// scripts\common.ps1's ceiling with nothing naming the case that did it (issue
// #27). Every machine-wide name carries the process id, the shape
// `lonely_signal` has in `src/child`, so two sweeps in one checkout cannot reach
// each other's objects.

// The watchdog a case hands in, with bounds it can actually reach. The shipped
// program takes process.DEFAULT_WATCH, whose silent bound is five minutes.
@(private)
SHORT_WATCH :: process.Watch {
	factor      = 4,
	fallback_ms = 200,
	quiet_ms    = 400,
	silent_ms   = 1_200,
}

// The watchdog for the case that has to watch the ESTIMATE stand in.
//
// The other way round from SHORT_WATCH: the bound a case must reach here is the
// FALLBACK's, and the two silence bounds have to stay out of reach for the whole
// of a child that is talking steadily. So the fallback is half a second, and the
// quiet bound is three -- longer than the one-second gaps the stand-in leaves
// between its lines, which would otherwise freeze the bar before the estimate
// ever got to supply a number.
@(private)
PATIENT_WATCH :: process.Watch {
	factor      = 4,
	fallback_ms = 500,
	quiet_ms    = 3_000,
	silent_ms   = 6_000,
}

// The two watchdogs above as the limits a case hands `transcribe`, plus the one
// whose RUN BOUND a case can reach.
//
// A bound far shorter than the child that has to outlive it, the shape
// `src/audio`'s SHORT_BOUND_MS has: derived from the Recording, the bound is at
// least the ten-minute floor a cold Model load needs, so no case could ever
// reach it and `Fault.Did_Not_Finish` was a member no run in the sweep produced.
@(private)
SHORT_LIMITS :: Limits {
	watch = SHORT_WATCH,
}

@(private)
PATIENT_LIMITS :: Limits {
	watch = PATIENT_WATCH,
}

@(private)
EXPIRING_LIMITS :: Limits {
	watch    = PATIENT_WATCH,
	bound_ms = 500,
}

// How long the child that must outlive the watchdog waits before ending itself,
// whatever this suite does or fails to do.
@(private)
LONGER_SECONDS :: 25

// A signal name no other run can reach, so a child of this suite's cannot be
// released by anybody else's -- `waitfor` names are machine-wide.
@(private)
lonely_signal :: proc(tag: string) -> string {
	assert(len(tag) > 0, "a signal name shared by two cases is a signal one of them cannot have")

	return fmt.aprintf(
		"transcibrEngineNoSignal%d%s",
		win32.GetCurrentProcessId(),
		tag,
		allocator = context.allocator,
	)
}

// A scratch cache of this case's own. The caller frees the path and removes the
// directory.
@(private)
scratch_cache :: proc(t: ^testing.T, tag: string) -> string {
	directory := os.get_env("TEMP", context.allocator)
	defer delete(directory, context.allocator)
	testing.expect(t, len(directory) > 0, "TEMP names nowhere to put a scratch cache")

	cache := fmt.aprintf(
		"%s\\transcibr-engine-%d-%s",
		directory,
		os.get_pid(),
		tag,
		allocator = context.allocator,
	)
	testing.expect(t, os.make_directory_all(cache) == nil, "could not make a scratch cache")
	return cache
}

@(private)
remove_cache :: proc(cache: string) {
	listing, unreadable := os.read_all_directory_by_path(cache, context.allocator)
	if unreadable == nil {
		defer os.file_info_slice_delete(listing, context.allocator)
		for info in listing {
			os.remove(info.fullpath)
		}
	}
	os.remove(cache)
}

// A stand-in Engine: a script that reads the same `-of` prefix the real Engine
// is given, writes what the case wants on its diagnostic output, and produces or
// withholds the output file.
//
// A SCRIPT AND NOT A PROGRAM WRITTEN FOR THE PURPOSE, because what is being
// checked is the wiring rather than the Engine: the argument list is already
// pinned in `transcibr:process` against the real binary's own help, and a
// stand-in that answered it would be a test of the stand-in. What this has to be
// is a child that really runs, really writes to the stream the spawner pipes,
// and really leaves a file behind.
//
// It walks its own arguments for `-of` rather than being handed the path,
// because that is the property worth having: the file transcibr goes back to
// afterwards must be the one the Engine was told to write.
@(private)
stand_in :: proc(t: ^testing.T, cache: string, tag: string, body: string) -> string {
	assert(len(body) > 0, "a stand-in Engine that does nothing at all says nothing")

	path := fmt.aprintf("%s\\stand-in-%s.cmd", cache, tag, allocator = context.allocator)
	script := fmt.aprintf(
		"@echo off\r\nsetlocal\r\nset \"PREFIX=\"\r\n:next\r\nif \"%%~1\"==\"\" goto ready\r\nif /i \"%%~1\"==\"-of\" set \"PREFIX=%%~2\"\r\nshift\r\ngoto next\r\n:ready\r\n%s\r\n",
		body,
		allocator = context.allocator,
	)
	defer delete(script, context.allocator)

	testing.expect(
		t,
		os.write_entire_file(path, transmute([]u8)script) == nil,
		"could not write the stand-in Engine",
	)
	return path
}

// A file of many unreadable lines, for the case whose stand-in floods the
// diagnostic stream. The caller frees the path; remove_cache takes the file.
@(private)
flood_file :: proc(t: ^testing.T, cache: string, tag: string, bytes: int) -> string {
	assert(bytes > 0, "a flood of nothing at all floods nothing")

	path := fmt.aprintf("%s\\flood-%s.txt", cache, tag, allocator = context.allocator)
	written := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&written)
	for strings.builder_len(written) < bytes {
		strings.write_string(&written, "whisper: a line this reader has no reading for\r\n")
	}

	testing.expect(
		t,
		os.write_entire_file(path, written.buf[:]) == nil,
		"could not write the flood the stand-in types",
	)
	return path
}

// The job every case runs, against a cache and a stand-in of its own.
//
// `container_ms` IS A CASE'S TO CHOOSE, and two seconds is the default because
// the watchdog's failing bound is the Recording's own length once that is longer
// than the floor (process.silent_after_ms). A ten-minute Recording here would
// mean a case waiting ten minutes to see a silent Engine noticed, which is a
// sweep nobody runs -- the same reason SHORT_WATCH exists.
@(private)
job_in :: proc(
	cache: string,
	engine: string,
	container_ms := i64(2_000),
) -> (
	tools: Tools,
	job: Job,
) {
	assert(container_ms > 0, "a Recording nobody could time was handed to a case")

	tools = Tools {
		engine = engine,
	}
	// The audio and the Model are paths no stand-in opens: what the stand-in is
	// for is the wiring, and the argument list carrying them is pinned next door
	// against the real binary's own help.
	job = Job {
		audio        = "C:\\nowhere\\lecture.wav",
		cache        = cache,
		name         = "lecture",
		model        = "C:\\nowhere\\model.bin",
		container_ms = container_ms,
	}
	return tools, job
}

@(private)
open_group :: proc(t: ^testing.T) -> (group: child.Job_Object, ok: bool) {
	opened, err := child.job_object_open()
	if !testing.expectf(t, err.fault == .None, "no job object: %v", err.fault) {
		return {}, false
	}
	return opened, true
}

// Everything the display was told, in order.
@(private)
Watched :: struct {
	seen:    [dynamic]process.Progress,
	highest: int,
}

@(private)
note :: proc(shown: process.Progress, user: rawptr) {
	watched := (^Watched)(user)
	append(&watched.seen, shown)
	watched.highest = max(watched.highest, shown.percent)
}

@(test)
a_stand_in_engine_that_reports_progress_drives_the_display :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := scratch_cache(t, "reports")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)

	// The readings are the fixture's own, in the Engine's own spelling. `%%` is
	// how a script writes one per cent sign.
	executable := stand_in(
		t,
		cache,
		"reports",
		">&2 echo whisper_print_progress_callback: progress =  42%%\r\n" +
		">&2 echo whisper_print_progress_callback: progress = 100%%\r\n" +
		">\"%PREFIX%.json\" echo {}",
	)
	defer delete(executable, context.allocator)

	watched := Watched {
		seen = make([dynamic]process.Progress, context.allocator),
	}
	defer delete(watched.seen)

	tools, job := job_in(cache, executable)
	produced, err := transcribe(
		&group,
		tools,
		job,
		Report{on_progress = note, user = &watched},
		context.allocator,
		SHORT_LIMITS,
	)
	defer delete(produced.output, context.allocator)
	if !testing.expectf(t, err.fault == .None, "the Engine failed: %v", err.fault) {
		return
	}

	// The Engine's output landed in the SCRATCH CACHE, under the prefix it was
	// given plus the extension the Engine appends (ADR-0002).
	expected := fmt.aprintf("%s\\lecture.json", cache, allocator = context.allocator)
	defer delete(expected, context.allocator)
	testing.expect_value(t, produced.output, expected)
	testing.expect(t, os.exists(produced.output), "the Engine's output is not where it was named")

	// And the readings reached the display. A hundred is the last thing the
	// stand-in said, so a display that never saw one saw none of them.
	testing.expect(t, len(watched.seen) > 0, "the display was never told anything")
	testing.expect_value(t, watched.highest, 100)
}

@(test)
an_engine_that_produced_nothing_is_a_failure_whatever_it_exited_with :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := scratch_cache(t, "nothing")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)

	// ADR-0002: "Exit code 0 means nothing. A failed audio read is a `continue`
	// that falls through to `return 0`, so a truncated WAV yields success, one
	// stderr line, and no output file." This stand-in is exactly that shape, and
	// what settles the Recording is what is on the disk.
	executable := stand_in(
		t,
		cache,
		"nothing",
		">&2 echo error: failed to read audio\r\nexit /b 0",
	)
	defer delete(executable, context.allocator)

	tools, job := job_in(cache, executable)
	produced, err := transcribe(&group, tools, job, Report{}, context.allocator, SHORT_LIMITS)
	defer delete(produced.output, context.allocator)

	testing.expect_value(t, err.fault, Fault.No_Output)
}

@(test)
an_engine_that_produced_an_empty_file_is_a_failure :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := scratch_cache(t, "empty")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)

	// Distinct from producing nothing, and worth telling apart: a file that
	// exists and is empty is what a full disk or a Stop press leaves behind, and
	// ADR-0002 wants "exit 0 but no OR EMPTY output" failed rather than taken for
	// finished work by the next run.
	executable := stand_in(t, cache, "empty", "type nul > \"%PREFIX%.json\"")
	defer delete(executable, context.allocator)

	tools, job := job_in(cache, executable)
	produced, err := transcribe(&group, tools, job, Report{}, context.allocator, SHORT_LIMITS)
	defer delete(produced.output, context.allocator)

	testing.expect_value(t, err.fault, Fault.Output_Empty)
}

@(test)
an_engine_that_says_nothing_at_all_is_stopped_before_its_bound_runs_out :: proc(t: ^testing.T) {
	// The watchdog, wired up. The pure decision has cases of its own next door in
	// both directions; what this checks is that this package acts on it -- and
	// that it does so on the SILENCE and not on the run bound, which is minutes
	// away here because a Recording of ten minutes is given at least the floor.
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := scratch_cache(t, "silent")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)

	name := lonely_signal("silent")
	defer delete(name, context.allocator)
	executable := stand_in(
		t,
		cache,
		"silent",
		fmt.tprintf("waitfor /t %d %s", LONGER_SECONDS, name),
	)
	defer delete(executable, context.allocator)

	tools, job := job_in(cache, executable)
	produced, err := transcribe(&group, tools, job, Report{}, context.allocator, SHORT_LIMITS)
	defer delete(produced.output, context.allocator)

	testing.expect_value(t, err.fault, Fault.Went_Silent)
}

// Whether the display was ever told a number that came from there.
@(private)
was_shown :: proc(watched: Watched, from: process.Progress_Source) -> bool {
	for shown in watched.seen {
		if shown.from == from {
			return true
		}
	}
	return false
}

// ACCEPTANCE CRITERION 3, end to end. The decision has a case next door, and a
// decision nothing ever calls with reachable bounds is a decision no run
// exercises: this is the one that puts `Progress_Source.Estimate` in front of a
// display over a real child.
//
// A release that renames the progress callback. The lines keep arriving, so
// there is nothing wrong with the child; what has gone is this package's reading
// of them, and ADR-0012 is explicit that the run degrades to an estimate rather
// than failing.
//
// Four seconds of audio at four times realtime is an expected second, so the
// estimate has something to key on and reaches half way while the stand-in is
// still on its first wait.
@(test)
an_engine_whose_progress_format_this_reader_cannot_read_still_drives_the_display :: proc(
	t: ^testing.T,
) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := scratch_cache(t, "estimate")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)

	name := lonely_signal("estimate")
	defer delete(name, context.allocator)
	executable := stand_in(
		t,
		cache,
		"estimate",
		fmt.tprintf(
			">&2 echo whisper: progress is now 50 per cent\r\n" +
			"waitfor /t 1 %s\r\n" +
			">&2 echo whisper: progress is now 90 per cent\r\n" +
			"waitfor /t 1 %s\r\n" +
			">\"%%PREFIX%%.json\" echo {}",
			name,
			name,
		),
	)
	defer delete(executable, context.allocator)

	watched := Watched {
		seen = make([dynamic]process.Progress, context.allocator),
	}
	defer delete(watched.seen)

	tools, job := job_in(cache, executable, 4_000)
	produced, err := transcribe(
		&group,
		tools,
		job,
		Report{on_progress = note, user = &watched},
		context.allocator,
		PATIENT_LIMITS,
	)
	defer delete(produced.output, context.allocator)
	if !testing.expectf(
		t,
		err.fault == .None,
		"an unreadable format failed the run: %v",
		err.fault,
	) {
		return
	}

	testing.expect(
		t,
		was_shown(watched, .Estimate),
		"the estimate never stood in for an Engine nobody could read",
	)
	// And it MOVED. The Engine said nothing this reader understands, so a bar still
	// reading zero is one the estimate never supplied a number for.
	testing.expect(t, watched.highest > 0, "the estimate stood in and reported nothing at all")
}

@(test)
an_engine_that_outlives_its_bound_is_stopped_and_told_apart_from_a_silent_one :: proc(
	t: ^testing.T,
) {
	// Issue #27's rule, wired up: a wedged Engine holds a Batch for ever, and one
	// GPU worker means it holds every Recording behind it (ADR-0006). The bound is
	// what stops that.
	//
	// The bound is handed in for the reason `src/audio`'s SHORT_BOUND_MS exists:
	// derived from the Recording, it is at least the ten-minute floor a cold Model
	// load needs, so `Fault.Did_Not_Finish` was a member no run in this sweep
	// could produce.
	//
	// AND IT IS THE BOUND AND NOT THE WATCHDOG THAT FIRES, which is the half worth
	// having: silence is read first in the poll loop, so a case whose silent bound
	// sat under its run bound would answer `.Went_Silent` and check nothing. This
	// watchdog gives the child six seconds of silence and the bound gives it half
	// of one.
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := scratch_cache(t, "bound")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)

	name := lonely_signal("bound")
	defer delete(name, context.allocator)
	executable := stand_in(
		t,
		cache,
		"bound",
		fmt.tprintf("waitfor /t %d %s", LONGER_SECONDS, name),
	)
	defer delete(executable, context.allocator)

	// A tenth of a second of audio, so the bound handed in is above the
	// Recording's own length -- which is what transcribe_bound_ms requires of any
	// bound, and what silent_after_ms keys the watchdog's floor on.
	tools, job := job_in(cache, executable, 100)
	produced, err := transcribe(&group, tools, job, Report{}, context.allocator, EXPIRING_LIMITS)
	defer delete(produced.output, context.allocator)

	testing.expect_value(t, err.fault, Fault.Did_Not_Finish)
}

@(test)
an_engine_that_floods_its_diagnostic_stream_is_still_stopped_at_its_bound :: proc(t: ^testing.T) {
	// The drain is the one loop inside a bounded run that could refuse to end.
	// While it runs, neither the watchdog nor the run bound is looked at -- so an
	// Engine that entered a diagnostic loop was an Engine nothing stopped, which is
	// the wedge issue #27 and the bound both exist to prevent, arriving on the one
	// stream this program can see.
	//
	// A megabyte off the pipe, then a child that outlives its bound. What this
	// requires is that the flood is drained AND the bound is still honoured, which
	// is what the ceiling on one drain buys.
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := scratch_cache(t, "flood")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)

	flood := flood_file(t, cache, "flood", 1 << 20)
	defer delete(flood, context.allocator)
	name := lonely_signal("flood")
	defer delete(name, context.allocator)
	executable := stand_in(
		t,
		cache,
		"flood",
		fmt.tprintf(">&2 type \"%s\"\r\nwaitfor /t %d %s", flood, LONGER_SECONDS, name),
	)
	defer delete(executable, context.allocator)

	tools, job := job_in(cache, executable, 100)
	produced, err := transcribe(&group, tools, job, Report{}, context.allocator, EXPIRING_LIMITS)
	defer delete(produced.output, context.allocator)

	testing.expect_value(t, err.fault, Fault.Did_Not_Finish)
}

@(test)
every_way_a_run_can_end_is_the_fault_that_names_it :: proc(t: ^testing.T) {
	// The ending table, checked directly. Four of the five endings a run has are
	// produced by a real child in this suite; `.Unstoppable` is not, and cannot
	// be -- it is a child that survived `TerminateJobObject` and would not leave
	// its job, which is not something a case can arrange and not something a
	// sweep should try to. So the mapping is what is pinned, and
	// `Fault.Not_Stopped` stops being a member nothing in the repository produces.
	//
	// The pair that matters is the two `.Stopped` arms: an Engine too slow for the
	// time it was given is a Recording to re-run, and one that stopped saying
	// anything is a wedge, and the caller acts on them differently (ADR-0012).
	started := child.Error {
		fault = .Not_Started,
	}
	testing.expect_value(
		t,
		refused(Ending{run = .Not_Started, child = started}).fault,
		Fault.Not_Started,
	)
	testing.expect_value(t, refused(Ending{run = .Unstoppable}).fault, Fault.Not_Stopped)
	testing.expect_value(
		t,
		refused(Ending{run = .Stopped, silent = true}).fault,
		Fault.Went_Silent,
	)
	testing.expect_value(t, refused(Ending{run = .Stopped}).fault, Fault.Did_Not_Finish)
	// The one ending that is not a refusal: the Engine exited by itself, which
	// says nothing about whether it did anything (ADR-0002). The disk settles it.
	testing.expect_value(t, refused(Ending{run = .Finished}).fault, Fault.None)
}

@(test)
an_executable_that_is_not_there_is_reported_and_not_asserted :: proc(t: ^testing.T) {
	// A8: the Engine's path is a settings field, so one naming nothing that
	// exists is an operating error against this Recording and the Batch carries
	// on (ADR-0002). The reason travels from the spawner, which knows what
	// Windows said.
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := scratch_cache(t, "absent")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)

	tools, job := job_in(cache, "C:\\nowhere\\no-such-engine.exe")
	produced, err := transcribe(&group, tools, job, Report{}, context.allocator, SHORT_LIMITS)
	defer delete(produced.output, context.allocator)

	testing.expect_value(t, err.fault, Fault.Not_Started)

	message := error_message(err, "C:\\recordings\\lecture.mkv", context.allocator)
	defer delete(message, context.allocator)
	testing.expect(t, len(message) > 0, "a refusal rendered as nothing at all")
}

@(test)
every_fault_renders_a_line_a_recordings_failure_row_can_carry :: proc(t: ^testing.T) {
	// The guard the switch cannot give on its own: an arm that is present and
	// says nothing compiles, and is then found by the renderer's own assertion in
	// front of a user, on a Recording that is already failing.
	for fault in Fault {
		if fault == .None {
			continue
		}
		// `.Not_Started` borrows its reason from the spawner and is the one
		// member that must carry one. Handed a real refusal rather than a zero
		// record, because this suite checks the renderer and not what happens
		// when this package loses a report between the failure and the row.
		reason := child.Error{} if fault != .Not_Started else child.Error{fault = .Not_Started}
		message := error_message(
			Error{fault = fault, child = reason},
			"C:\\recordings\\lecture.mkv",
			context.allocator,
		)
		defer delete(message, context.allocator)

		testing.expectf(t, len(message) > 0, "%v rendered as nothing at all", fault)
		testing.expectf(
			t,
			len(message) > len("\"C:\\\\recordings\\\\lecture.mkv\": "),
			"%v rendered as the Recording's name and nothing else",
			fault,
		)
	}
}
