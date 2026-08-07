#+vet explicit-allocators
package engine

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
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
	path := fmt.aprintf("%s\\flood-%s.txt", cache, tag, allocator = context.allocator)
	_ = testkit.write_flood(
		t,
		path,
		bytes,
		"whisper: a line this reader has no reading for\r\n",
		context.allocator,
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

// Spelled the same way at all three call sites (transcibr:testkit's own
// header explains why this one is not among them): child_test.odin is part of
// package child, and a testkit that imported child could not be imported back
// by child's own tests without a cycle.
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
an_engine_that_exits_zero_and_produces_nothing_is_a_failure :: proc(t: ^testing.T) {
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

	message := error_message(err, "C:\\recordings\\lecture.mkv", context.allocator)
	defer delete(message, context.allocator)
	testing.expect(
		t,
		strings.contains(message, "exited cleanly"),
		"the No_Output message no longer names the exit it now always implies (issue #186 made .Refused, not .No_Output, the fault for a nonzero exit)",
	)
}

// `refused(ending)` runs before `landed_bounded` in `transcribe`, so an
// Engine that writes nothing and exits nonzero is `.Refused`, never
// `.No_Output` -- #206's diff changed which fault a wrote-nothing run
// reaches, and nothing pinned the changed case until this test.
@(test)
an_engine_that_exits_nonzero_and_produces_nothing_is_a_refusal :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := testkit.made_scratch_cache(t, "engine", "nothing-nonzero", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	executable := stand_in(
		t,
		cache,
		"nothing-nonzero",
		">&2 echo error: failed to read audio\r\nexit /b 5",
	)
	defer delete(executable, context.allocator)

	tools, job := job_in(cache, executable)
	produced, err := transcribe(&group, tools, job, Report{}, context.allocator, SHORT_LIMITS)
	defer delete(produced.output, context.allocator)

	testing.expect_value(t, err.fault, Fault.Refused)
	testing.expect_value(t, err.exit_code, u32(5))
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

// The #109 collapse applied to this package's own child: a whisper.cpp run
// that writes a real, non-empty output and then exits nonzero used to reach
// `placed_from_engine_output` with no refusal of its own -- `landed_bounded`
// only sees a file that is there and not empty, and the wrote-nothing case
// is the only one that surfaced as `.No_Output`. Mutation check (run by hand,
// not committed -- issue #22 bans a test that trips an assert): dropping the
// `ending.exit_code != 0` branch in `refused` leaves this test cleanly red
// (expected Fault.Refused/3, got Fault.None/0) -- this is the mutation AC2's
// "Mutation-checked per the #109 pattern" asks for. Dropping
// `on_exit = watched_exit` in `run_engine` instead trips `ending_for`'s
// `watch_state.exited` assert, which fires for every case in this file that
// reaches `.Finished`, and aborts the whole test process with a FATAL rather
// than reporting a clean failure here.
@(test)
an_engine_that_writes_output_and_then_exits_nonzero_is_a_refusal :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := testkit.made_scratch_cache(t, "engine", "nonzero-exit", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	executable := stand_in(t, cache, "nonzero-exit", ">\"%PREFIX%.json\" echo {}\r\nexit /b 3")
	defer delete(executable, context.allocator)

	tools, job := job_in(cache, executable)
	produced, err := transcribe(&group, tools, job, Report{}, context.allocator, SHORT_LIMITS)
	defer delete(produced.output, context.allocator)

	testing.expect_value(t, err.fault, Fault.Refused)
	testing.expect_value(t, err.exit_code, u32(3))
}

@(test)
a_bounded_landed_check_of_a_real_output_on_disk_finds_it :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "engine", "landed", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	output := fmt.aprintf("%s\\lecture.json", cache, allocator = context.allocator)
	defer delete(output, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(output, []u8{'{', '}'}) == nil,
		"could not write a stand-in output file",
	)

	testing.expect_value(t, landed_bounded(output, child.READ_BOUND_MS), Fault.None)
}

@(test)
a_bounded_landed_check_of_an_output_that_is_not_there_is_refused :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "engine", "landed-missing", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	output := fmt.aprintf("%s\\never-written.json", cache, allocator = context.allocator)
	defer delete(output, context.allocator)

	testing.expect_value(t, landed_bounded(output, child.READ_BOUND_MS), Fault.No_Output)
}

// Short enough that a worker stalled `LANDED_STALL_MS` past it forces
// `landed_bounded`'s wait to time out rather than finish, without the suite
// waiting long for it.
@(private)
LANDED_STALL_BOUND_MS :: i64(50)

// Comfortably past `LANDED_STALL_BOUND_MS`, and comfortably inside
// `transcibr:child`'s own `CANCEL_BOUND_MS` (5 s), so the worker's real
// `time.sleep` finishes -- and `await_or_abandon`'s poll notices it done --
// well before the `.Unstoppable` leak path would ever be reached.
@(private)
LANDED_STALL_MS :: i64(1_500)

// Generous against the worst case a correctly working bound could ever
// legitimately take -- `LANDED_STALL_BOUND_MS` plus a cancellation running
// its own full course -- rather than tuned to equal it, the same reasoning
// `artifact.model_test.odin`'s `MODEL_BOUND_TEST_SLACK` documents.
@(private)
LANDED_STALL_SLACK :: 30 * time.Second

// Finding of the PR #99 review: nothing in this suite before this case ran a
// `landed_bounded` worker for longer than its own bound, so a mutant that
// multiplied `bound_ms` by 1000 -- an effectively unbounded wait -- passed
// every test unchanged. `landed_bounded`'s own `stall_ms` parameter puts a
// real, `time.sleep`-stalled worker on the far side of a short bound, the same way
// `child`'s own `a_read_that_cannot_finish_is_abandoned_at_its_bound` puts a
// real stalled pipe read on the far side of one.
@(test)
a_landed_check_that_cannot_finish_within_its_bound_is_reported_rather_than_awaited_forever :: proc(
	t: ^testing.T,
) {
	cache := testkit.made_scratch_cache(t, "engine", "landed-stalled", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	output := fmt.aprintf("%s\\lecture.json", cache, allocator = context.allocator)
	defer delete(output, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(output, []u8{'{', '}'}) == nil,
		"could not write a stand-in output file",
	)

	started := time.tick_now()
	fault := landed_bounded(output, LANDED_STALL_BOUND_MS, LANDED_STALL_MS)
	elapsed := time.tick_since(started)

	testing.expect_value(t, fault, Fault.No_Output)
	testing.expectf(
		t,
		elapsed < LANDED_STALL_SLACK,
		"a landed check bounded at %d ms took %v to be reported, which is not being bounded at all",
		LANDED_STALL_BOUND_MS,
		elapsed,
	)
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

// Proves the bound is still reached despite a flood, not that a single drain
// has a ceiling at all: mutating MAX_DRAIN_BYTES away leaves this green,
// because an unbounded drain still runs out of flood to read and hands
// control back the same way. Only
// child.a_single_drain_stops_at_its_ceiling_even_with_a_steady_flood pins the
// ceiling itself.
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

// This run carries two readings: 10%, terminated with \r\n, which
// watched_chunk turns into a reading the ordinary way, and the trailing 77%
// written with no terminator at all, which is exactly what a
// process.Line_Reader is still holding when end of stream arrives. Nothing
// terminated the second one, so watched_chunk never turns it into a reading
// on its own; watched_end is what flushes it through process.last_line and
// tracker_said, which is the only path that trailing percentage has to the
// display at all. Because both readings arrive, watched.highest landing on
// 77 and not 10 is what proves watched_end ran.
@(test)
an_engine_that_exits_mid_line_still_hands_over_its_last_reading :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := testkit.made_scratch_cache(t, "engine", "midline", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	trailer := fmt.aprintf("%s\\trailer.txt", cache, allocator = context.allocator)
	defer delete(trailer, context.allocator)
	trailing_line := "whisper_print_progress_callback: progress = 77%"
	if !testing.expect(
		t,
		os.write_entire_file(trailer, transmute([]u8)trailing_line) == nil,
		"could not write the unterminated trailer this case types",
	) {
		return
	}

	executable := stand_in(
		t,
		cache,
		"midline",
		fmt.tprintf(
			">&2 echo whisper_print_progress_callback: progress = 10%%%%\r\n" +
			">\"%%PREFIX%%.json\" echo {{}}\r\n" +
			"type \"%s\" 1>&2",
			trailer,
		),
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

	testing.expect_value(t, watched.highest, 77)
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
		refused(Ending{run = .Stopped, reason = .Poll_Asked}).fault,
		Fault.Went_Silent,
	)
	testing.expect_value(t, refused(Ending{run = .Stopped}).fault, Fault.Did_Not_Finish)
	testing.expect_value(
		t,
		refused(Ending{run = .Stopped, reason = .Drain_Failed}).fault,
		Fault.Did_Not_Finish,
	)
	testing.expect_value(
		t,
		refused(Ending{run = .Stopped, reason = .Bound_Expired}).fault,
		Fault.Did_Not_Finish,
	)
	testing.expect_value(t, refused(Ending{run = .Finished}).fault, Fault.None)
	testing.expect_value(t, refused(Ending{run = .Finished, exit_code = 3}).fault, Fault.Refused)
	testing.expect_value(t, refused(Ending{run = .Finished, exit_code = 3}).exit_code, u32(3))
}

// An Unstoppable Engine is still the caller's only record of how long it ran
// and whether it had gone silent -- both already measured by the time stop
// was even tried, and neither has anywhere else to go.
@(test)
an_unstoppable_run_still_carries_what_it_measured :: proc(t: ^testing.T) {
	watch_state := Watch_State {
		tracker = process.Tracker{duration_ms = 4_200},
	}
	ending := ending_for(.Unstoppable, .Poll_Asked, watch_state, child.Error{})

	testing.expect_value(t, ending.run, child.Run.Unstoppable)
	testing.expect_value(t, ending.duration_ms, i64(4_200))
	testing.expect_value(t, ending.reason, child.Stop_Reason.Poll_Asked)
}

// The realtime-factor calculation divides a Recording's audio length by how
// long the Engine actually ran, wall clock -- never by `duration_ms`, which
// is the Engine's own reported audio duration and equals the divisor on
// every healthy run. `Ending.elapsed_ms` is what that calculation reads, and
// this pins it as carried from `Watch_State` through every ending shape.
@(test)
a_finished_run_carries_the_wall_clock_it_actually_took :: proc(t: ^testing.T) {
	watch_state := Watch_State {
		tracker = process.Tracker{duration_ms = 10_000},
		elapsed_ms = 588,
		exited = true,
	}
	ending := ending_for(.Finished, .None, watch_state, child.Error{})

	testing.expect_value(t, ending.elapsed_ms, i64(588))
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
	if err.fault == .Not_Started {
		testing.expect(
			t,
			err.child.fault != .None,
			"a Not_Started error carried no child fault, which error_message relies on",
		)
		if err.child.fault != .None {
			message := error_message(err, "C:\\recordings\\lecture.mkv", context.allocator)
			defer delete(message, context.allocator)
			testing.expect(t, len(message) > 0, "a refusal rendered as nothing at all")
		}
	}
}

// exit_code is nonzero for .Refused: that fault's exit_code is documented
// "Only for .Refused" and `refused` only ever constructs it under
// `ending.exit_code != 0`, so a zeroed one is a state no production path can
// build and error_message asserts against it.
@(test)
every_fault_renders_a_line_a_recordings_failure_row_can_carry :: proc(t: ^testing.T) {
	for fault in Fault {
		if fault == .None {
			continue
		}
		reason := child.Error{} if fault != .Not_Started else child.Error{fault = .Not_Started}
		exit_code := u32(0) if fault != .Refused else u32(3)
		message := error_message(
			Error{fault = fault, child = reason, exit_code = exit_code},
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

// AC1 asks for a refusal carrying the code, and `error_message`'s `.Refused`
// arm is the half a user actually sees -- `every_fault_renders_a_line_...`
// above only asserts `len(message) > 0`, which the catch-all arm satisfies
// just as well, so it cannot tell the `%q: %s (exit code %d)` arm apart from
// the catch-all `%q: %s` arm. Mirrors src/audio/fault_test.odin's
// `a_refused_fault_names_its_exit_code_in_the_message`, written for the same
// gap under #109.
@(test)
a_refused_fault_names_its_exit_code_in_the_message :: proc(t: ^testing.T) {
	err := Error {
		fault     = .Refused,
		exit_code = 13,
	}
	message := error_message(err, "C:\\recordings\\lecture.mkv", context.allocator)
	defer delete(message, context.allocator)

	testing.expectf(
		t,
		strings.contains(message, "13"),
		"%v rendered <%s>, which does not carry its exit code",
		err.fault,
		message,
	)
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
