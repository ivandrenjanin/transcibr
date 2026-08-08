#+vet explicit-allocators
package process

import "core:mem"
import "core:strings"
import "core:testing"

// Cloned, because `next_line` hands back a view into the reader's own buffer
// that the next call overwrites.
@(private)
lines_of :: proc(
	r: ^Line_Reader,
	chunk: string,
	into: ^[dynamic]string,
	allocator: mem.Allocator,
) {
	assert(
		allocator.procedure != nil,
		"the cloned lines outlive this procedure and need an allocator",
	)

	remaining := chunk
	for {
		line, ok := next_line(r, &remaining)
		if !ok {
			return
		}
		append(into, strings.clone(line, allocator))
	}
}

// The presence side of the assertion above (rule A3). `delete` through a nil
// allocator is not a crash: `mem_free_with_size` returns success having freed
// nothing, so the pair that hands memory back is the one place where a missing
// allocator is silent.
@(private)
free_lines :: proc(lines: ^[dynamic]string, allocator: mem.Allocator) {
	assert(
		allocator.procedure != nil,
		"the lines were cloned through an allocator and have to go back through one",
	)

	for line in lines {
		delete(line, allocator)
	}
	delete(lines^)
}

@(test)
a_line_cut_in_half_by_the_pipe_is_put_back_together :: proc(t: ^testing.T) {
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected, context.allocator)

	lines_of(&r, "whisper_print_progress_callback: prog", &collected, context.allocator)
	testing.expect_value(t, len(collected), 0)

	lines_of(&r, "ress =  42%\n", &collected, context.allocator)
	if !testing.expect_value(t, len(collected), 1) {
		return
	}
	said := read_engine_line(collected[0])
	testing.expect_value(t, said.says, Engine_Says.Progress)
	testing.expect_value(t, said.percent, 42)
}

@(test)
a_crlf_line_arrives_without_its_carriage_return :: proc(t: ^testing.T) {
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected, context.allocator)

	lines_of(&r, "whisper_model_load: loading model\r\nsecond\r\n", &collected, context.allocator)
	if !testing.expect_value(t, len(collected), 2) {
		return
	}
	testing.expect_value(t, collected[0], "whisper_model_load: loading model")
	testing.expect_value(t, collected[1], "second")
}

@(test)
a_line_too_long_to_hold_is_dropped_whole_and_the_next_one_still_reads :: proc(t: ^testing.T) {
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected, context.allocator)

	flood := strings.repeat("x", 4 * MAX_DIAGNOSTIC_LINE, context.allocator)
	defer delete(flood, context.allocator)

	lines_of(&r, flood, &collected, context.allocator)
	testing.expect_value(t, len(collected), 0)

	lines_of(
		&r,
		"\nwhisper_print_progress_callback: progress =  52%\n",
		&collected,
		context.allocator,
	)
	if !testing.expect_value(t, len(collected), 1) {
		return
	}
	testing.expect_value(t, read_engine_line(collected[0]).percent, 52)
}

@(test)
bytes_that_are_not_utf8_pass_through_and_read_as_nothing :: proc(t: ^testing.T) {
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected, context.allocator)

	lines_of(
		&r,
		"main: \xff\xfe\x80 processing\nwhisper: \xc3\x28\n",
		&collected,
		context.allocator,
	)
	if !testing.expect_value(t, len(collected), 2) {
		return
	}
	for line in collected {
		testing.expectf(t, read_engine_line(line).says == .Nothing, "%q read as something", line)
	}
}

@(test)
what_is_held_behind_no_newline_is_a_line_at_end_of_stream :: proc(t: ^testing.T) {
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected, context.allocator)

	lines_of(&r, "whisper_print_progress_callback: progress = 100%", &collected, context.allocator)
	testing.expect_value(t, len(collected), 0)

	line, ok := last_line(&r)
	if !testing.expect(t, ok, "the reader dropped what it was holding at end of stream") {
		return
	}
	testing.expect_value(t, read_engine_line(line).percent, 100)

	_, again := last_line(&r)
	testing.expect(t, !again, "the reader handed back what it had already given up")
}

@(test)
a_chunk_with_nothing_in_it_yields_nothing :: proc(t: ^testing.T) {
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected, context.allocator)

	lines_of(&r, "", &collected, context.allocator)
	testing.expect_value(t, len(collected), 0)

	lines_of(&r, "\n\n", &collected, context.allocator)
	testing.expect_value(t, len(collected), 2)
	if len(collected) == 2 {
		testing.expect_value(t, collected[0], "")
		testing.expect_value(t, collected[1], "")
	}
}

// Nonzero on purpose: a monotonic counter does not begin at zero on a machine
// that has been up for a week.
@(private)
STARTED :: i64(987_654_321_000_000)

// The factor is spelled out rather than taken from DEFAULT_REALTIME_FACTOR: the
// percentages every case below expects are worked out from it by hand.
@(private)
FOUR_TIMES :: Watch {
	factor      = 4,
	fallback_ms = FALLBACK_AFTER_MS,
	quiet_ms    = QUIET_AFTER_MS,
	silent_ms   = SILENT_AFTER_MS,
}

@(private)
@(require_results)
after :: proc(milliseconds: i64) -> i64 {
	return STARTED + milliseconds * 1_000_000
}

@(test)
the_display_shows_what_the_engine_last_said :: proc(t: ^testing.T) {
	tr := tracker_start(600_000, STARTED)
	tracker_heard(&tr, 64, after(1_000))
	tracker_said(&tr, Engine_Line{says = .Progress, percent = 42}, after(1_000))

	now := shown(tr, after(1_100))
	testing.expect_value(t, now.percent, 42)
	testing.expect_value(t, now.from, Progress_Source.Engine)
	testing.expect(t, !now.silent, "a child that has just spoken was called silent")
}

@(test)
a_reading_that_goes_backwards_does_not_take_the_bar_with_it :: proc(t: ^testing.T) {
	tr := tracker_start(600_000, STARTED)
	tracker_heard(&tr, 64, after(1_000))
	tracker_said(&tr, Engine_Line{says = .Progress, percent = 52}, after(1_000))
	tracker_said(&tr, Engine_Line{says = .Progress, percent = 40}, after(2_000))

	now := shown(tr, after(2_100))
	testing.expect_value(t, now.percent, 52)
	testing.expect_value(t, now.from, Progress_Source.Engine)
}

@(test)
the_engine_is_silent_during_model_load_and_that_is_not_a_stall :: proc(t: ^testing.T) {
	tr := tracker_start(600_000, STARTED)

	for at := i64(0); at <= 240_000; at += 20_000 {
		tracker_heard(&tr, 96, after(at))
		tracker_said(&tr, read_engine_line("whisper_model_load: loading model"), after(at))
	}

	now := shown(tr, after(240_100))
	testing.expect(t, !now.silent, "a Model still loading was reported as a stalled run")
	testing.expectf(t, now.from != .Frozen, "the display froze over a child that is talking")
}

@(test)
an_unrecognised_progress_format_engages_the_time_based_estimate :: proc(t: ^testing.T) {
	tr := tracker_start(600_000, STARTED)
	for at := i64(0); at <= 75_000; at += 5_000 {
		tracker_heard(&tr, 64, after(at))
		tracker_said(&tr, read_engine_line("whisper: progress is now 50 per cent"), after(at))
	}

	now := shown(tr, after(75_000), FOUR_TIMES)
	testing.expect_value(t, now.from, Progress_Source.Estimate)
	testing.expect_value(t, now.percent, 50)
	testing.expect(t, !now.silent, "a child that is still writing was reported as silent")
}

@(test)
the_fallback_stands_in_on_the_bound_it_was_handed :: proc(t: ^testing.T) {
	patient := Watch {
		factor      = 4,
		fallback_ms = 300,
		quiet_ms    = 5_000,
		silent_ms   = 20_000,
	}

	tr := tracker_start(600_000, STARTED)
	tracker_heard(&tr, 64, after(1_000))
	tracker_said(&tr, Engine_Line{says = .Progress, percent = 12}, after(1_000))
	tracker_heard(&tr, 64, after(1_400))
	tracker_said(&tr, read_engine_line("whisper: progress is now 50 per cent"), after(1_400))

	testing.expect_value(t, shown(tr, after(1_100), patient).from, Progress_Source.Engine)
	testing.expect_value(t, shown(tr, after(1_500), patient).from, Progress_Source.Estimate)
}

@(test)
the_estimate_never_goes_below_what_the_engine_said :: proc(t: ^testing.T) {
	tr := tracker_start(600_000, STARTED)
	tracker_heard(&tr, 64, after(5_000))
	tracker_said(&tr, Engine_Line{says = .Progress, percent = 52}, after(5_000))

	for at := i64(10_000); at <= 40_000; at += 5_000 {
		tracker_heard(&tr, 64, after(at))
	}

	now := shown(tr, after(40_000), FOUR_TIMES)
	testing.expect_value(t, now.percent, 52)
}

@(test)
the_estimate_never_claims_the_recording_is_finished :: proc(t: ^testing.T) {
	tr := tracker_start(600_000, STARTED)
	for at := i64(0); at <= 3_600_000; at += 30_000 {
		tracker_heard(&tr, 64, after(at))
	}

	now := shown(tr, after(3_600_000), FOUR_TIMES)
	testing.expect_value(t, now.from, Progress_Source.Estimate)
	testing.expect(
		t,
		now.percent < 100,
		"the estimate announced a Recording that is still running",
	)
}

@(test)
the_estimate_stops_moving_over_a_child_that_has_stopped_talking :: proc(t: ^testing.T) {
	tr := tracker_start(600_000, STARTED)
	tracker_heard(&tr, 64, after(60_000))

	first := shown(tr, after(60_000 + QUIET_AFTER_MS), FOUR_TIMES)
	second := shown(tr, after(60_000 + QUIET_AFTER_MS + 60_000), FOUR_TIMES)

	testing.expect_value(t, first.from, Progress_Source.Frozen)
	testing.expect_value(t, second.from, Progress_Source.Frozen)
	testing.expect_value(t, second.percent, first.percent)
}

@(test)
prolonged_silence_on_every_stream_is_an_operating_error :: proc(t: ^testing.T) {
	tr := tracker_start(60_000, STARTED)
	tracker_heard(&tr, 64, after(60_000))

	frozen := shown(tr, after(60_000 + QUIET_AFTER_MS), FOUR_TIMES)
	testing.expect(t, !frozen.silent, "a child quiet for a minute was already a failed run")

	gone := shown(tr, after(60_000 + SILENT_AFTER_MS), FOUR_TIMES)
	testing.expect(
		t,
		gone.silent,
		"a child that has said nothing for five minutes was not noticed",
	)
	testing.expect_value(t, gone.from, Progress_Source.Frozen)
}

// One real capture, `src/process/fixtures/engine-stderr.txt`.
@(private)
FIXTURE_READINGS :: [?]int{10, 21, 27, 33, 42, 52, 64, 75, 85, 94, 100}

@(private)
LONGEST_RECORDING_MS :: i64(168 * 60 * 1000)

// Why a short capture's readings walked across a long Recording is
// conservative rather than approximate: ADR-0012.
@(private)
never_silent_across :: proc(t: ^testing.T, duration_ms: i64, wall_ms: i64) {
	readings := FIXTURE_READINGS
	tr := tracker_start(duration_ms, STARTED)
	next := 0
	for at := i64(0); at <= wall_ms; at += 60_000 {
		for next < len(readings) && wall_ms * i64(readings[next]) / 100 <= at {
			tracker_heard(&tr, 48, after(at))
			tracker_said(&tr, Engine_Line{says = .Progress, percent = readings[next]}, after(at))
			next += 1
		}
		testing.expectf(
			t,
			!shown(tr, after(at), FOUR_TIMES).silent,
			"a healthy Engine %d ms into a %d ms run was failed for silence",
			at,
			wall_ms,
		)
	}
}

@(test)
the_longest_recording_is_not_failed_between_its_own_readings :: proc(t: ^testing.T) {
	never_silent_across(t, LONGEST_RECORDING_MS, LONGEST_RECORDING_MS)
}

@(test)
a_recording_on_the_cpu_only_fallback_is_not_failed_between_its_own_readings :: proc(
	t: ^testing.T,
) {
	never_silent_across(t, LONGEST_RECORDING_MS, LONGEST_RECORDING_MS * ENGINE_BOUND_MULTIPLE)
}

@(test)
a_long_recording_is_still_failed_once_its_own_length_of_silence_passes :: proc(t: ^testing.T) {
	tr := tracker_start(10_800_000, STARTED)
	tracker_heard(&tr, 64, after(60_000))

	early := shown(tr, after(60_000 + SILENT_AFTER_MS), FOUR_TIMES)
	testing.expect(
		t,
		!early.silent,
		"a three-hour Recording was failed on a one-minute one's bound",
	)
	testing.expect_value(t, early.from, Progress_Source.Frozen)

	gone := shown(tr, after(60_000 + 10_800_000), FOUR_TIMES)
	testing.expect(t, gone.silent, "a wedged Engine was never noticed at all")
}

@(test)
a_child_that_keeps_talking_is_never_called_silent :: proc(t: ^testing.T) {
	tr := tracker_start(10_800_000, STARTED)
	for at := i64(0); at <= 10_800_000; at += 30_000 {
		tracker_heard(&tr, 64, after(at))
		testing.expectf(
			t,
			!shown(tr, after(at), FOUR_TIMES).silent,
			"a child that spoke at %d ms was called silent",
			at,
		)
	}
}

@(test)
the_engines_own_banner_replaces_the_duration_the_tracker_started_with :: proc(t: ^testing.T) {
	tr := tracker_start(600_000, STARTED)
	tracker_heard(&tr, 96, after(1_000))
	tracker_said(&tr, Engine_Line{says = .Duration, duration_ms = 1_200_000}, after(1_000))
	for at := i64(1_000); at <= 150_000; at += 30_000 {
		tracker_heard(&tr, 96, after(at))
	}

	now := shown(tr, after(150_000), FOUR_TIMES)
	testing.expect_value(t, now.from, Progress_Source.Estimate)
	testing.expect_value(t, now.percent, 50)
}

@(test)
an_estimate_with_no_duration_to_key_on_does_not_move :: proc(t: ^testing.T) {
	tr := tracker_start(0, STARTED)
	for at := i64(0); at <= 120_000; at += 10_000 {
		tracker_heard(&tr, 64, after(at))
	}

	now := shown(tr, after(120_000), FOUR_TIMES)
	testing.expect_value(t, now.percent, 0)
	testing.expect(t, !now.silent, "a child with no known duration was reported as silent")
}

// See CLAUDE.md, Odin notes: enumerated arrays and switches. `.Engine` is
// skipped by name because it is the deliberately empty arm -- the display says
// nothing about where the number came from when the Engine itself supplied it.
@(test)
every_progress_source_says_where_the_number_came_from :: proc(t: ^testing.T) {
	for from in Progress_Source {
		if from == .Engine {
			testing.expect_value(t, progress_says(from), "")
			continue
		}
		testing.expectf(t, len(progress_says(from)) > 0, "%v says nothing at all", from)
	}
}

// What the walking test above cannot check: that two non-empty renderings are
// not the SAME non-empty rendering.
@(test)
an_estimate_and_a_frozen_bar_do_not_read_the_same :: proc(t: ^testing.T) {
	testing.expect(
		t,
		progress_says(.Estimate) != progress_says(.Frozen),
		"an estimate that is still moving reads the same as one that has stopped",
	)
}

@(test)
the_bound_one_engine_invocation_is_given_grows_with_the_recording :: proc(t: ^testing.T) {
	short := transcribe_bound_ms(60_000)
	long := transcribe_bound_ms(10_800_000)

	testing.expect(
		t,
		long > short,
		"a three-hour Recording is given no longer than a one-minute one",
	)
	testing.expect(
		t,
		short >= ENGINE_BOUND_FLOOR_MS,
		"a short Recording was given less than the floor",
	)
	testing.expect(t, long >= 10_800_000, "a three-hour Recording was given less than realtime")
}
