package engine

import "core:fmt"
import "core:os"
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
	factor    = 4,
	quiet_ms  = 400,
	silent_ms = 1_200,
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

// The job every case runs, against a cache and a stand-in of its own.
@(private)
job_in :: proc(cache: string, engine: string) -> (tools: Tools, job: Job) {
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
		container_ms = 600_000,
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
		SHORT_WATCH,
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
	produced, err := transcribe(&group, tools, job, Report{}, context.allocator, SHORT_WATCH)
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
	produced, err := transcribe(&group, tools, job, Report{}, context.allocator, SHORT_WATCH)
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
	produced, err := transcribe(&group, tools, job, Report{}, context.allocator, SHORT_WATCH)
	defer delete(produced.output, context.allocator)

	testing.expect_value(t, err.fault, Fault.Went_Silent)
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
	produced, err := transcribe(&group, tools, job, Report{}, context.allocator, SHORT_WATCH)
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
