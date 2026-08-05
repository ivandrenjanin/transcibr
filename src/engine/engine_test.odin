#+vet explicit-allocators
package engine

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "transcibr:child"
import "transcibr:process"
import "transcibr:testkit"

// The shell half, against real children and a real scratch cache. Every child
// here is bounded; see ADR-0020.

// Bounds a case can actually reach. The shipped program takes
// process.DEFAULT_WATCH, whose silent bound is five minutes.
@(private)
SHORT_WATCH :: process.Watch {
	factor      = 4,
	fallback_ms = 200,
	quiet_ms    = 400,
	silent_ms   = 1_200,
}

// The other way round from SHORT_WATCH: the bound a case must reach here is the
// fallback's, so the two silence bounds stay clear of the one-second gaps a
// stand-in leaves between its lines.
@(private)
PATIENT_WATCH :: process.Watch {
	factor      = 4,
	fallback_ms = 500,
	quiet_ms    = 3_000,
	silent_ms   = 6_000,
}

// A derived bound is at least the ten-minute floor a cold Model load needs, so a
// case that has to reach one hands it in.
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

@(private)
LONGER_SECONDS :: 25

// It walks its own arguments for `-of` rather than being handed the path, so the
// file transcibr goes back to afterwards must be the one the Engine was told to
// write.
@(private)
@(require_results)
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

// The caller frees the path; remove_cache takes the file.
@(private)
@(require_results)
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

// Two seconds of container by default: the watchdog's failing bound is the
// Recording's own length once that is longer than the floor
// (process.silent_after_ms), so a longer one is a case that waits that long.
@(private)
@(require_results)
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
	job = Job {
		audio        = "C:\\nowhere\\lecture.wav",
		cache        = cache,
		name         = "lecture",
		model        = "C:\\nowhere\\model.bin",
		container_ms = container_ms,
	}
	return tools, job
}

// Kept local rather than moved into transcibr:testkit: testkit carries no
// dependency on transcibr:child, on purpose, because src/child/child_test.odin
// is itself part of that package and could not import a testkit that imported
// it back. audio and engine each keep this same handful of lines rather than
// the one package gaining a cycle only child's own suite would hit.
@(private)
@(require_results)
open_group :: proc(t: ^testing.T) -> (group: child.Job_Object, ok: bool) {
	opened, err := child.job_object_open()
	if !testing.expectf(t, err.fault == .None, "no job object: %v", err.fault) {
		return {}, false
	}
	return opened, true
}

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

	cache := testkit.made_scratch_cache(t, "engine", "reports", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

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

	expected := fmt.aprintf("%s\\lecture.json", cache, allocator = context.allocator)
	defer delete(expected, context.allocator)
	testing.expect_value(t, produced.output, expected)
	testing.expect(t, os.exists(produced.output), "the Engine's output is not where it was named")

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

	cache := testkit.made_scratch_cache(t, "engine", "nothing", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

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

	cache := testkit.made_scratch_cache(t, "engine", "empty", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	executable := stand_in(t, cache, "empty", "type nul > \"%PREFIX%.json\"")
	defer delete(executable, context.allocator)

	tools, job := job_in(cache, executable)
	produced, err := transcribe(&group, tools, job, Report{}, context.allocator, SHORT_LIMITS)
	defer delete(produced.output, context.allocator)

	testing.expect_value(t, err.fault, Fault.Output_Empty)
}

@(test)
an_engine_that_says_nothing_at_all_is_stopped_before_its_bound_runs_out :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := testkit.made_scratch_cache(t, "engine", "silent", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	name := testkit.lonely_signal("Engine", "silent", context.allocator)
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

@(private)
@(require_results)
was_shown :: proc(watched: Watched, from: process.Progress_Source) -> bool {
	for shown in watched.seen {
		if shown.from == from {
			return true
		}
	}
	return false
}

@(test)
an_engine_whose_progress_format_this_reader_cannot_read_still_drives_the_display :: proc(
	t: ^testing.T,
) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := testkit.made_scratch_cache(t, "engine", "estimate", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	name := testkit.lonely_signal("Engine", "estimate", context.allocator)
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
	testing.expect(t, watched.highest > 0, "the estimate stood in and reported nothing at all")
}

@(test)
an_engine_that_outlives_its_bound_is_stopped_and_told_apart_from_a_silent_one :: proc(
	t: ^testing.T,
) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := testkit.made_scratch_cache(t, "engine", "bound", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	name := testkit.lonely_signal("Engine", "bound", context.allocator)
	defer delete(name, context.allocator)
	executable := stand_in(
		t,
		cache,
		"bound",
		fmt.tprintf("waitfor /t %d %s", LONGER_SECONDS, name),
	)
	defer delete(executable, context.allocator)

	tools, job := job_in(cache, executable, 100)
	produced, err := transcribe(&group, tools, job, Report{}, context.allocator, EXPIRING_LIMITS)
	defer delete(produced.output, context.allocator)

	testing.expect_value(t, err.fault, Fault.Did_Not_Finish)
}

@(test)
an_engine_that_floods_its_diagnostic_stream_is_still_stopped_at_its_bound :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := testkit.made_scratch_cache(t, "engine", "flood", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	flood := flood_file(t, cache, "flood", 1 << 20)
	defer delete(flood, context.allocator)
	name := testkit.lonely_signal("Engine", "flood", context.allocator)
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
	testing.expect_value(t, refused(Ending{run = .Finished}).fault, Fault.None)
}

@(test)
an_executable_that_is_not_there_is_reported_and_not_asserted :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := testkit.made_scratch_cache(t, "engine", "absent", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

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
	for fault in Fault {
		if fault == .None {
			continue
		}
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

@(private)
@(require_results)
marker_in :: proc(cache: string) -> string {
	return fmt.aprintf("%s\\started.txt", cache, allocator = context.allocator)
}

@(test)
a_recording_whose_scratch_paths_the_engine_cannot_open_never_starts_one :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := testkit.made_scratch_cache(t, "engine", "not-ascii", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	marker := marker_in(cache)
	defer delete(marker, context.allocator)
	executable := stand_in(
		t,
		cache,
		"not-ascii",
		fmt.tprintf(">\"%s\" echo yes\r\n>\"%%PREFIX%%.json\" echo {{}}", marker),
	)
	defer delete(executable, context.allocator)

	tools, job := job_in(cache, executable)
	job.name = "Bj\u00f6rn interview"

	produced, err := transcribe(&group, tools, job, Report{}, context.allocator, SHORT_LIMITS)
	defer delete(produced.output, context.allocator)

	testing.expect_value(t, err.fault, Fault.Path_Not_Ascii)
	testing.expect(t, !os.exists(marker), "the Engine was started with a path it cannot open")
}

@(test)
every_path_one_invocation_is_handed_is_checked_and_not_just_the_prefix :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := testkit.made_scratch_cache(t, "engine", "each-path", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	marker := marker_in(cache)
	defer delete(marker, context.allocator)
	executable := stand_in(
		t,
		cache,
		"each-path",
		fmt.tprintf(">\"%s\" echo yes\r\n>\"%%PREFIX%%.json\" echo {{}}", marker),
	)
	defer delete(executable, context.allocator)

	for spoiled in ([?]int{0, 1}) {
		tools, job := job_in(cache, executable)
		if spoiled == 0 {
			job.model = "C:\\models\\ggml-large-v3-t\u00fcrkce.bin"
		} else {
			job.audio = "C:\\nowhere\\\u5f55\u97f3.wav"
		}

		produced, err := transcribe(&group, tools, job, Report{}, context.allocator, SHORT_LIMITS)
		defer delete(produced.output, context.allocator)

		testing.expectf(t, err.fault == Fault.Path_Not_Ascii, "path %d was handed over", spoiled)
		testing.expectf(t, !os.exists(marker), "path %d started the Engine anyway", spoiled)
	}
}
