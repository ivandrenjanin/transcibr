package transcript

import "core:testing"

// Stated in the TEST rather than taken from COLLAPSE_THRESHOLDS: a case reading
// the shipped constant would change its meaning when the constant was tuned.
@(private)
PINNED_COLLAPSE :: Collapse_Params {
	max_run      = 3,
	invention_at = 14,
}

// ADR-0001's measured case: 16 identical Cues of " you" over 4.5 minutes of silence.
@(test)
collapses_an_invented_repetition_run :: proc(t: ^testing.T) {
	shape := make([dynamic]Shaped_Cue, context.allocator)
	defer delete(shape)
	append(&shape, Shaped_Cue{duration_ms = 3_000, text = " And that is all I had to say."})
	say_repeatedly(&shape, " you", 16, 16_900, 0)

	cues := shaped_cues(shape[:], context.allocator)
	defer delete(cues, context.allocator)

	kept := collapse_repetition(cues, PINNED_COLLAPSE, context.allocator)
	defer destroy_cues(kept, context.allocator)

	expected := []Cue {
		{0, 3_000, " And that is all I had to say."},
		{3_000, 19_900, " you"},
		{19_900, 36_800, " you"},
		{36_800, 53_700, " you"},
	}
	if !testing.expect_value(t, len(kept), len(expected)) {
		return
	}
	for want, i in expected {
		testing.expect_value(t, kept[i], want)
	}
}

@(private)
Real_Repetition :: struct {
	name:        string,
	text:        string,
	count:       int,
	duration_ms: Millis,
	gap_ms:      Millis,
}

// Why elapsed time cannot tell these rows from an invention: ADR-0016.
@(private, rodata)
REAL_REPETITIONS := []Real_Repetition {
	{name = "a flat refusal", text = " No.", count = 3, duration_ms = 700, gap_ms = 120},
	{name = "urging somebody on", text = " Go!", count = 6, duration_ms = 480, gap_ms = 90},
	{
		name = "agreeing in conversation",
		text = " Yeah.",
		count = 4,
		duration_ms = 600,
		gap_ms = 300,
	},
	{name = "a stutter", text = " I--", count = 4, duration_ms = 260, gap_ms = 0},
	{
		name = "a repeated chorus line",
		text = " Hey Jude.",
		count = 5,
		duration_ms = 1_800,
		gap_ms = 200,
	},
	{
		name = "a phrase repeated after a pause",
		text = " Never again.",
		count = 4,
		duration_ms = 1_400,
		gap_ms = 1_600,
	},
	{
		name = "an instruction repeated slowly",
		text = " Breathe.",
		count = 5,
		duration_ms = 1_500,
		gap_ms = 5_250,
	},
	{
		name = "calling somebody who is not answering",
		text = " Sam!",
		count = 7,
		duration_ms = 500,
		gap_ms = 2_500,
	},
	{
		name = "a vocabulary drill",
		text = " Bonjour.",
		count = 10,
		duration_ms = 900,
		gap_ms = 3_100,
	},
	{
		name = "a call-hold announcement",
		text = " Your call is important to us.",
		count = 8,
		duration_ms = 2_400,
		gap_ms = 27_600,
	},
	{
		name = "a guided meditation",
		text = " Breathe in, and out.",
		count = 11,
		duration_ms = 1_800,
		gap_ms = 14_400,
	},
}

// Whatever survives is checked BYTE FOR BYTE against what went in: a row that came
// back the right LENGTH with the wrong Cues in it is the same silent deletion by
// another route.
@(private)
real_repetitions_truncated :: proc(
	t: ^testing.T,
	p: Collapse_Params,
	whose: string,
) -> (
	truncated: int,
) {
	assert(len(REAL_REPETITIONS) > 0, "no real repetitions to run past the thresholds")
	assert(len(whose) > 0, "a report naming no thresholds says nothing about which ones failed")
	defer assert(
		truncated <= len(REAL_REPETITIONS),
		"counted more rows truncated than there were rows",
	)

	for said in REAL_REPETITIONS {
		shape := make([dynamic]Shaped_Cue, context.allocator)
		defer delete(shape)
		say_repeatedly(&shape, said.text, said.count, said.duration_ms, said.gap_ms)

		cues := shaped_cues(shape[:], context.allocator)
		defer delete(cues, context.allocator)

		kept := collapse_repetition(cues, p, context.allocator)
		defer destroy_cues(kept, context.allocator)

		if len(kept) < len(cues) {
			truncated += 1
		}
		for cue, i in kept {
			testing.expectf(
				t,
				cue == cues[i],
				"%s, %s: saying %d came back as %v",
				whose,
				said.name,
				i + 1,
				cue,
			)
		}
	}
	return
}

@(test)
legitimately_repeated_speech_survives :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		real_repetitions_truncated(t, PINNED_COLLAPSE, "the pinned thresholds"),
		0,
	)
}

// The case that holds invention_at down: eleven sayings is the longest real row.
@(test)
the_shipped_collapse_thresholds_leave_real_speech_alone :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		real_repetitions_truncated(t, COLLAPSE_THRESHOLDS, "the shipped thresholds"),
		0,
	)
}

@(test)
a_cap_on_length_alone_would_delete_real_words :: proc(t: ^testing.T) {
	length_only := Collapse_Params {
		max_run      = PINNED_COLLAPSE.max_run,
		invention_at = PINNED_COLLAPSE.max_run + 1,
	}

	testing.expect_value(
		t,
		real_repetitions_truncated(t, length_only, "a cap on length alone"),
		10,
	)
}

@(private, rodata)
INVENTION_LOOPS := []Real_Repetition {
	{
		name = "the classic tail loop",
		text = " Thank you for watching!",
		count = 19,
		duration_ms = 1_000,
	},
	{name = "a subscribe loop", text = " Please subscribe.", count = 40, duration_ms = 400},
	{name = "a single word at machine speed", text = " you", count = 100, duration_ms = 150},
}

@(test)
a_fast_invention_loop_collapses_however_little_recording_it_spans :: proc(t: ^testing.T) {
	for loop in INVENTION_LOOPS {
		shape := make([dynamic]Shaped_Cue, context.allocator)
		defer delete(shape)
		say_repeatedly(&shape, loop.text, loop.count, loop.duration_ms, loop.gap_ms)

		cues := shaped_cues(shape[:], context.allocator)
		defer delete(cues, context.allocator)

		kept := collapse_repetition(cues, COLLAPSE_THRESHOLDS, context.allocator)
		defer destroy_cues(kept, context.allocator)

		spanned := cues[len(cues) - 1].end - cues[0].start
		testing.expectf(
			t,
			len(kept) == 3,
			"%s: %d sayings over %v ms came back as %d",
			loop.name,
			loop.count,
			spanned,
			len(kept),
		)
	}
}

// Every other collapse case states its own thresholds, so without this one
// COLLAPSE_THRESHOLDS could be tuned to collapse nothing and the suite still pass.
@(test)
the_shipped_collapse_thresholds_collapse_the_measured_invention :: proc(t: ^testing.T) {
	shape := make([dynamic]Shaped_Cue, context.allocator)
	defer delete(shape)
	append(&shape, Shaped_Cue{duration_ms = 3_000, text = " And that is all I had to say."})
	say_repeatedly(&shape, " you", 16, 16_900, 0)

	cues := shaped_cues(shape[:], context.allocator)
	defer delete(cues, context.allocator)

	kept := collapse_repetition(cues, COLLAPSE_THRESHOLDS, context.allocator)
	defer destroy_cues(kept, context.allocator)

	testing.expect_value(t, len(kept), 4)
}

@(test)
collapsing_no_cues_yields_no_cues :: proc(t: ^testing.T) {
	kept := collapse_repetition(nil, PINNED_COLLAPSE, context.allocator)
	defer destroy_cues(kept, context.allocator)

	testing.expect_value(t, len(kept), 0)
	testing.expect(t, kept == nil, "an empty cue set came back with memory behind it to free")
}

// A run walk demanding strictly adjacent sayings sees sixteen runs of one here.
@(test)
an_invention_with_silence_written_through_it_still_collapses :: proc(t: ^testing.T) {
	shape := make([dynamic]Shaped_Cue, context.allocator)
	defer delete(shape)
	for _ in 0 ..< 16 {
		append(&shape, Shaped_Cue{duration_ms = 8_000, text = " you"})
		append(&shape, Shaped_Cue{duration_ms = 9_000, text = ""})
	}

	cues := shaped_cues(shape[:], context.allocator)
	defer delete(cues, context.allocator)

	kept := collapse_repetition(cues, PINNED_COLLAPSE, context.allocator)
	defer destroy_cues(kept, context.allocator)

	if !testing.expect_value(t, len(kept), 5) {
		return
	}
	sayings := 0
	for cue in kept {
		if len(spoken_text(cue)) > 0 {
			sayings += 1
		}
	}
	testing.expect_value(t, sayings, PINNED_COLLAPSE.max_run)
}

// Counted as a Saying, the byte splits ADR-0001's measured invention into two runs
// of eight, neither of which reaches invention_at.
@(test)
a_cue_of_bytes_nobody_said_carries_a_repetition_run_on :: proc(t: ^testing.T) {
	shape := make([dynamic]Shaped_Cue, context.allocator)
	defer delete(shape)
	say_repeatedly(&shape, " you", 8, 16_900, 0)
	append(&shape, Shaped_Cue{duration_ms = 9_000, text = SILENCE_AS_BYTES})
	say_repeatedly(&shape, " you", 8, 16_900, 0)

	cues := shaped_cues(shape[:], context.allocator)
	defer delete(cues, context.allocator)
	testing.expect_value(t, len(cues), 17)

	kept := collapse_repetition(cues, PINNED_COLLAPSE, context.allocator)
	defer destroy_cues(kept, context.allocator)

	testing.expect_value(t, len(kept), 3)
	sayings := 0
	for cue in kept {
		if len(spoken_text(cue)) > 0 {
			sayings += 1
		}
	}
	testing.expect_value(t, sayings, PINNED_COLLAPSE.max_run)
}

// Silence is identical to silence: a walk counting Cues would call it an invention.
@(test)
silence_the_engine_wrote_cues_over_is_never_collapsed :: proc(t: ^testing.T) {
	shape := make([dynamic]Shaped_Cue, context.allocator)
	defer delete(shape)
	say_repeatedly(&shape, "", 20, 24_000, 0)

	cues := shaped_cues(shape[:], context.allocator)
	defer delete(cues, context.allocator)

	kept := collapse_repetition(cues, PINNED_COLLAPSE, context.allocator)
	defer destroy_cues(kept, context.allocator)

	testing.expect_value(t, len(kept), 20)
}
