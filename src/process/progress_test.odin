package process

import "core:strings"
import "core:testing"

// The progress display's own half: chunks off a pipe reassembled into lines,
// and what the display should show given what the Engine has said and when it
// last said anything at all.

// Everything one chunk yields, as a list a case can compare against.
//
// The lines are CLONED, because `next_line` hands back a view into the reader's
// own buffer and the next call overwrites it -- which is the whole point of a
// fixed buffer and is exactly the mistake a case would otherwise make silently.
@(private)
lines_of :: proc(
	r: ^Line_Reader,
	chunk: string,
	into: ^[dynamic]string,
	allocator := context.allocator,
) {
	remaining := chunk
	for {
		line, ok := next_line(r, &remaining)
		if !ok {
			return
		}
		append(into, strings.clone(line, allocator))
	}
}

@(private)
free_lines :: proc(lines: ^[dynamic]string, allocator := context.allocator) {
	for line in lines {
		delete(line, allocator)
	}
	delete(lines^)
}

@(test)
a_line_cut_in_half_by_the_pipe_is_put_back_together :: proc(t: ^testing.T) {
	// A read off an anonymous pipe ends wherever the kernel had bytes, and
	// nothing aligns that to a line. This is the ordinary case rather than an
	// edge one: half a progress line held over to the next read is what the
	// spawner produces every time it drains mid-line.
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected)

	lines_of(&r, "whisper_print_progress_callback: prog", &collected)
	testing.expect_value(t, len(collected), 0)

	lines_of(&r, "ress =  42%\n", &collected)
	if !testing.expect_value(t, len(collected), 1) {
		return
	}
	said := read_engine_line(collected[0])
	testing.expect_value(t, said.says, Engine_Says.Progress)
	testing.expect_value(t, said.percent, 42)
}

@(test)
a_crlf_line_arrives_without_its_carriage_return :: proc(t: ^testing.T) {
	// The Engine writes CRLF on Windows, and the carriage return is the framing
	// rather than the line -- so it is taken off HERE, once, instead of by every
	// reader downstream remembering to.
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected)

	lines_of(&r, "whisper_model_load: loading model\r\nsecond\r\n", &collected)
	if !testing.expect_value(t, len(collected), 2) {
		return
	}
	testing.expect_value(t, collected[0], "whisper_model_load: loading model")
	testing.expect_value(t, collected[1], "second")
}

@(test)
a_line_too_long_to_hold_is_dropped_whole_and_the_next_one_still_reads :: proc(t: ^testing.T) {
	// A child that writes ten megabytes with no newline in it. The buffer is
	// FIXED (A8), so what has to be true is that the memory is bounded and the
	// reader recovers -- and that the oversized line is not handed on in a
	// truncated form, which would be a reading nobody could trust.
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected)

	flood := strings.repeat("x", 4 * MAX_DIAGNOSTIC_LINE, context.allocator)
	defer delete(flood, context.allocator)

	lines_of(&r, flood, &collected)
	testing.expect_value(t, len(collected), 0)

	lines_of(&r, "\nwhisper_print_progress_callback: progress =  52%\n", &collected)
	if !testing.expect_value(t, len(collected), 1) {
		return
	}
	// The line that ENDED the flood is not handed back at all, and the one after
	// it is whole. Both halves (A3): a reader that kept the first four kilobytes
	// would answer two lines here, and one that never recovered would answer none.
	testing.expect_value(t, read_engine_line(collected[0]).percent, 52)
}

@(test)
bytes_that_are_not_utf8_pass_through_and_read_as_nothing :: proc(t: ^testing.T) {
	// NTFS permits an unpaired surrogate in a filename, the Engine quotes the
	// audio's path in its banner, and this stream carries whatever bytes the
	// child wrote. Nothing here decodes anything, so the only property that
	// matters is that a line survives being carried and reads as no reading.
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected)

	lines_of(&r, "main: \xff\xfe\x80 processing\nwhisper: \xc3\x28\n", &collected)
	if !testing.expect_value(t, len(collected), 2) {
		return
	}
	for line in collected {
		testing.expectf(t, read_engine_line(line).says == .Nothing, "%q read as something", line)
	}
}

@(test)
what_is_held_behind_no_newline_is_a_line_at_end_of_stream :: proc(t: ^testing.T) {
	// A child that exits without a final newline. Whatever it managed to say is
	// still what it said, and the last reading of a Recording is the one most
	// worth not dropping.
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected)

	lines_of(&r, "whisper_print_progress_callback: progress = 100%", &collected)
	testing.expect_value(t, len(collected), 0)

	line, ok := last_line(&r)
	if !testing.expect(t, ok, "the reader dropped what it was holding at end of stream") {
		return
	}
	testing.expect_value(t, read_engine_line(line).percent, 100)

	// The negative space (A3): asked twice, it has nothing left. A reader that
	// answered the same line again would have the shell reading one percentage
	// for ever.
	_, again := last_line(&r)
	testing.expect(t, !again, "the reader handed back what it had already given up")
}

@(test)
a_chunk_with_nothing_in_it_yields_nothing :: proc(t: ^testing.T) {
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected)

	lines_of(&r, "", &collected)
	testing.expect_value(t, len(collected), 0)

	// A run of newlines is a run of EMPTY lines and not nothing: the Engine
	// writes a blank line either side of its progress block, and a reader that
	// swallowed them would be one that could swallow a line with content too.
	lines_of(&r, "\n\n", &collected)
	testing.expect_value(t, len(collected), 2)
	if len(collected) == 2 {
		testing.expect_value(t, collected[0], "")
		testing.expect_value(t, collected[1], "")
	}
}

// ------------------------------------------- what the display should show --
//
// Every clock reading below is HANDED IN, so a child that has gone quiet, one
// that has gone silent, and a run part-way through model load are all values
// rather than states a case would have to wait several minutes for.
//
// STARTED is a nonzero tick on purpose. A monotonic counter does not begin at
// zero on a machine that has been up for a week, and arithmetic that only works
// from zero is arithmetic that works on one machine.

@(private)
STARTED :: i64(987_654_321_000_000)

// What every case below decides with, SPELLED OUT rather than defaulted. The
// expected percentages are worked out from the factor by hand, so a case that
// took it from DEFAULT_REALTIME_FACTOR would quietly start checking something
// else the day that constant moved -- and would agree with the code by
// construction rather than with an answer somebody worked out.
@(private)
FOUR_TIMES :: Watch {
	factor    = 4,
	quiet_ms  = QUIET_AFTER_MS,
	silent_ms = SILENT_AFTER_MS,
}

// Milliseconds as the nanoseconds the tracker counts in.
@(private)
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
	// NOT ASSERTED MONOTONIC, which would be an assertion on what the Engine
	// wrote (A8). The readings in the fixture do rise, and nothing promises a
	// release will not restart the count part-way -- a bar that jumped back to
	// forty is a Recording a user believes has been re-done.
	tr := tracker_start(600_000, STARTED)
	tracker_heard(&tr, 64, after(1_000))
	tracker_said(&tr, Engine_Line{says = .Progress, percent = 52}, after(1_000))
	tracker_said(&tr, Engine_Line{says = .Progress, percent = 40}, after(2_000))

	now := shown(tr, after(2_100))
	testing.expect_value(t, now.percent, 52)
	// And the LINE still counted: it was understood, so the fallback has no
	// reason to stand in. A reader that ignored the reading outright would let
	// the estimate take over on a perfectly healthy Engine.
	testing.expect_value(t, now.from, Progress_Source.Engine)
}

@(test)
the_engine_is_silent_during_model_load_and_that_is_not_a_stall :: proc(t: ^testing.T) {
	// THE TRAP THIS WHOLE FILE EXISTS FOR, and the healthy direction of it.
	// ADR-0012: the fallback "triggers on elapsed time since the last progress
	// line, NEVER on the absence of lines -- the engine is silent during model
	// load, so 'no progress yet' is normal for the first minute and is not a
	// stall". A 1.6 GB Model loading off a cold disk writes its log to this
	// stream and no progress at all, for minutes.
	tr := tracker_start(600_000, STARTED)

	// Four minutes of model-load lines: bytes, no readings. Past every bound
	// there is, and the run is healthy.
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
	// A release that renames the progress callback. The lines keep arriving, so
	// there is nothing wrong with the child; what has gone is this package's
	// reading of them, and ADR-0012 is explicit that the run must degrade to an
	// estimate rather than fail.
	//
	// Ten minutes of audio at four times realtime is an expected 150 seconds, so
	// 75 seconds in is half way. Worked out here rather than by the arithmetic
	// under test.
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
the_estimate_never_goes_below_what_the_engine_said :: proc(t: ^testing.T) {
	// The Engine reported 52% and the format then broke. A bar that dropped to
	// three would read as a Recording being started again.
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
	// A hundred per cent is a FACT and only the Engine or the finished output
	// file supplies it. An estimate that reached it would have the display
	// announce a Transcript that does not exist, for however long the run has
	// left.
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
	// ADR-0012: "Never animate the fallback over a process that has stopped
	// producing bytes. A confidently advancing estimate over a dead child is
	// worse than a frozen bar, because it hides the failure."
	//
	// The last byte is at one minute; the two readings below are a minute apart
	// and well past the quiet bound, and they must be the SAME number.
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
	// The other half of the same rule: the bar freezing is a display state, and
	// silence that goes on is a Recording that has failed. Both bounds, from the
	// same run, so the ORDER between them is what this pins -- an estimate that
	// stopped moving at the same instant the run was failed would make the frozen
	// state unobservable.
	tr := tracker_start(600_000, STARTED)
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

@(test)
a_child_that_keeps_talking_is_never_called_silent :: proc(t: ^testing.T) {
	// The negative space (A3), and the case that stops the watchdog being
	// satisfied by a rule that fails every long Recording: three hours of a child
	// writing something every half minute is a healthy run, and the Engine writes
	// every Cue to a stream this program deliberately cannot see (ADR-0004).
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
	// The two sources the spec allows, in the order they arrive: the container
	// probe answers before the Engine starts, and the banner is about the audio
	// the Engine is ACTUALLY working through, so it wins once it is there. The
	// estimate keys on whichever is current.
	tr := tracker_start(600_000, STARTED)
	tracker_heard(&tr, 96, after(1_000))
	tracker_said(&tr, Engine_Line{says = .Duration, duration_ms = 1_200_000}, after(1_000))
	// The child goes on writing its log throughout, because the watchdog is read
	// before anything else: a child that said one thing and then went quiet for
	// two minutes has a FROZEN bar however good the duration is, which is what
	// this case learned the hard way.
	for at := i64(1_000); at <= 150_000; at += 30_000 {
		tracker_heard(&tr, 96, after(at))
	}

	// Twenty minutes at four times realtime is 300 seconds expected, so 150
	// seconds in is half way. Against the ten minutes it started with it would be
	// past the ceiling.
	now := shown(tr, after(150_000), FOUR_TIMES)
	testing.expect_value(t, now.from, Progress_Source.Estimate)
	testing.expect_value(t, now.percent, 50)
}

@(test)
an_estimate_with_no_duration_to_key_on_does_not_move :: proc(t: ^testing.T) {
	// A Recording whose container could not be timed and whose banner never
	// arrived. There is nothing to divide by, so the honest answer is the last
	// thing the Engine said -- not a number invented from nothing.
	tr := tracker_start(0, STARTED)
	for at := i64(0); at <= 120_000; at += 10_000 {
		tracker_heard(&tr, 64, after(at))
	}

	now := shown(tr, after(120_000), FOUR_TIMES)
	testing.expect_value(t, now.percent, 0)
	testing.expect(t, !now.silent, "a child with no known duration was reported as silent")
}

@(test)
the_bound_one_engine_invocation_is_given_grows_with_the_recording :: proc(t: ^testing.T) {
	// A bound is what stops a wedged Engine holding a Batch for ever (issue #27),
	// and a FIXED one is either too short for a three-hour Recording or useless
	// for a three-minute one.
	short := transcribe_bound_ms(60_000)
	long := transcribe_bound_ms(10_800_000)

	testing.expect(
		t,
		long > short,
		"a three-hour Recording is given no longer than a one-minute one",
	)
	// A minute of audio still gets the floor, which is what a cold Model load
	// costs before any inference happens at all.
	testing.expect(
		t,
		short >= ENGINE_BOUND_FLOOR_MS,
		"a short Recording was given less than the floor",
	)
	// And the long one is generous against measurement: the fixture's Recording
	// ran at 58 times realtime on this machine, so three hours of audio is about
	// three minutes of work and this is hours.
	testing.expect(t, long >= 10_800_000, "a three-hour Recording was given less than realtime")
}
