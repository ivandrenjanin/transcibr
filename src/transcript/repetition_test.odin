package transcript

import "core:testing"

// The thresholds the cases below pin for themselves. Named here so they read as
// "fourteen sayings of one phrase, three of them kept" rather than as two numbers
// repeated down the file -- and stated in the TEST rather than taken from
// COLLAPSE_THRESHOLDS, because a case that read the shipped constant would change
// its meaning when the constant was tuned.
//
// The shipped constant gets cases of its own, above and below, and those are the
// ones that stop it being tuned into something that strips everything or nothing
// (ADR-0016).
@(private)
PINNED_COLLAPSE :: Collapse_Params {
	max_run      = 3,
	invention_at = 14,
}

// ADR-0001's measured case, laid out as it was measured: 16 identical Cues of
// the single word "you" over four and a half minutes of silence at the end of a
// Recording. Per-Cue confidence does not exist in Engine output, so the shape of
// the run is the only handle there is on this.
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

	// The speech, then three of the sixteen inventions: offsets copied off the
	// shape by hand rather than recomputed the way the layout computes them.
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

// ---------------------------------------------------------------------------
// The test that matters more than the one above.
//
// An over-eager filter deletes real words and nobody notices for weeks: the
// Transcript still reads as prose, the missing sayings are short, and there is
// nothing in the deliverable to compare it against. A run left uncollapsed, by
// contrast, is four minutes of "you" that anybody spots on sight.
//
// So every row here is speech a person genuinely produces, and the whole of it
// has to come back byte for byte. At package scope because a table is DATA, and
// data inside a procedure body is what carries a test past the 70-line limit
// (CLAUDE.md F1).
// ---------------------------------------------------------------------------

// One phrase a person really does say several times over, and how fast.
@(private)
Real_Repetition :: struct {
	name:        string,
	text:        string,
	count:       int,
	duration_ms: Millis,
	gap_ms:      Millis,
}

// Ten of the eleven rows say the phrase MORE than PINNED_COLLAPSE.max_run times,
// which is the point: a filter that condemned a run the moment it passed what
// survives it would truncate every one of them.
//
// The rows deliberately span the clock from end to end -- a stutter over in a
// second, a hold announcement over three and a half minutes -- because the whole
// of ADR-0016 is that elapsed time does not tell these apart from an invention.
// The row that says so loudest is the hold announcement: it repeats every half a
// minute, which is SLOWER than the Engine's measured invention of "you".
@(private, rodata)
REAL_REPETITIONS := []Real_Repetition {
	{
		// The rhetorical triple. Inside the cap, so it survives on length
		// alone -- the row that would still pass if the span threshold were
		// deleted, and the one that says which rows below prove anything.
		name        = "a flat refusal",
		text        = " No.",
		count       = 3,
		duration_ms = 700,
		gap_ms      = 120,
	},
	{
		// Six sayings in under four seconds. A cap on length alone deletes
		// half of them and the Transcript reads perfectly well without them.
		name        = "urging somebody on",
		text        = " Go!",
		count       = 6,
		duration_ms = 480,
		gap_ms      = 90,
	},
	{
		name = "agreeing in conversation",
		text = " Yeah.",
		count = 4,
		duration_ms = 600,
		gap_ms = 300,
	},
	{name = "a stutter", text = " I--", count = 4, duration_ms = 260, gap_ms = 0},
	{
		// A chorus, which is the slowest thing on this list that is still
		// unmistakably speech: five sayings across ten seconds.
		name        = "a repeated chorus line",
		text        = " Hey Jude.",
		count       = 5,
		duration_ms = 1_800,
		gap_ms      = 200,
	},
	{
		// Repetition with real pauses between the sayings. The gap is longer
		// than the saying, which is exactly the shape a naive "sparse means
		// invented" rule would condemn.
		name        = "a phrase repeated after a pause",
		text        = " Never again.",
		count       = 4,
		duration_ms = 1_400,
		gap_ms      = 1_600,
	},
	{
		// A meditation instructor, and the worked example the source comment
		// itself offers as the false positive it is willing to make: five
		// sayings across twenty-eight and a half seconds.
		name        = "an instruction repeated slowly",
		text        = " Breathe.",
		count       = 5,
		duration_ms = 1_500,
		gap_ms      = 5_250,
	},
	{
		// A parent calling a child in from the garden. Seven sayings, and the
		// pauses between them are the listening.
		name        = "calling somebody who is not answering",
		text        = " Sam!",
		count       = 7,
		duration_ms = 500,
		gap_ms      = 2_500,
	},
	{
		// A language drill: the same word said back ten times over, with the
		// teacher's correction in the silence between.
		name        = "a vocabulary drill",
		text        = " Bonjour.",
		count       = 10,
		duration_ms = 900,
		gap_ms      = 3_100,
	},
	{
		// THE row that says a rate cannot separate the two populations. A
		// hold announcement repeats every half a minute, which is SLOWER than
		// the Engine's measured invention of " you" -- one saying every
		// seventeen seconds (ADR-0001). Anything reading "sparse means
		// invented" deletes three and a half minutes of a real recording.
		name        = "a call-hold announcement",
		text        = " Your call is important to us.",
		count       = 8,
		duration_ms = 2_400,
		gap_ms      = 27_600,
	},
	{
		// The longest row in this table, and the one that pins the ceiling from
		// below: eleven sayings across two and three-quarter minutes of a guided
		// meditation. The ceiling of the TABLE, not of human repetition -- no rig
		// was ever run for this end of the band, and ADR-0016 says so plainly.
		name        = "a guided meditation",
		text        = " Breathe in, and out.",
		count       = 11,
		duration_ms = 1_800,
		gap_ms      = 14_400,
	},
}

// Every row of the table through one set of thresholds, reporting how many rows
// came back short. Whatever survives is checked BYTE FOR BYTE against what went
// in, on every row and under every threshold set: a row that came back the right
// LENGTH with the wrong Cues in it is the same silent deletion by another route.
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

// The same speech through the constant that actually ships. PINNED_COLLAPSE is
// what the cases above are stated in, so nothing there would notice
// COLLAPSE_THRESHOLDS being tuned into something that strips real words -- and
// the shipped constant is the one every Recording is run through.
//
// This is the case that holds invention_at DOWN. The longest row is eleven
// sayings, so a ceiling dropped to eleven deletes a real guided meditation and
// this fails (ADR-0016).
@(test)
the_shipped_collapse_thresholds_leave_real_speech_alone :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		real_repetitions_truncated(t, COLLAPSE_THRESHOLDS, "the shipped thresholds"),
		0,
	)
}

// Why the ceiling sits above what survives rather than at it, said in checked
// code rather than in a comment (CLAUDE.md A6).
//
// The same rows through a ceiling of max_run + 1, which is what a cap on LENGTH
// alone is: every run is condemned the moment it passes what survives it. Ten of
// the eleven rows lose the difference, and those are real words nobody would
// have missed.
@(test)
a_cap_on_length_alone_would_delete_real_words :: proc(t: ^testing.T) {
	length_only := Collapse_Params {
		max_run      = PINNED_COLLAPSE.max_run,
		invention_at = PINNED_COLLAPSE.max_run + 1,
	}

	// Ten of the eleven rows say their phrase more than three times over; the
	// eleventh is inside the cap and survives either way.
	testing.expect_value(
		t,
		real_repetitions_truncated(t, length_only, "a cap on length alone"),
		10,
	)
}

// ---------------------------------------------------------------------------
// The other end of the same constant, and the half a wall-clock threshold could
// not see at all: the Engine looping FAST.
//
// A filter reading elapsed time hands every one of these to the reader intact,
// however long the loop runs, because none of them covers much Recording. The
// first row is whisper's classic tail loop at one saying a second; the last says
// a four-character word a hundred times inside fifteen seconds, which is not a
// thing a person does at all.
// ---------------------------------------------------------------------------

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

		// THREE, spelled out. Reading COLLAPSE_THRESHOLDS.max_run here would
		// recompute the expectation from the constant under test, and the case
		// would agree with that constant whatever it was tuned to.
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

// ADR-0001's measured shape through the constant that ships, which is the only
// place acceptance criterion 1 meets it. Every other collapse case states its own
// thresholds, so without this one COLLAPSE_THRESHOLDS could be tuned to collapse
// NOTHING -- invention_at raised past sixteen, or past a million -- and the whole
// suite would still pass (ADR-0016).
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

	// FOUR, spelled out: the speech, and then three of the sixteen inventions.
	// Stated as a number rather than as COLLAPSE_THRESHOLDS.max_run + 1, which
	// would recompute the expectation from the constant this case exists to pin
	// and would agree with it whatever it was tuned to.
	testing.expect_value(t, len(kept), 4)
}

@(test)
collapsing_no_cues_yields_no_cues :: proc(t: ^testing.T) {
	kept := collapse_repetition(nil, PINNED_COLLAPSE, context.allocator)
	defer destroy_cues(kept, context.allocator)

	testing.expect_value(t, len(kept), 0)
	testing.expect(t, kept == nil, "an empty cue set came back with memory behind it to free")
}

// ---------------------------------------------------------------------------
// Silence, which the Engine writes Cues over and which lands in exactly the
// place inventions do.
// ---------------------------------------------------------------------------

// ADR-0001's measured shape with the Engine's own silence Cues written through
// it. A run walk that demanded strictly adjacent sayings sees sixteen runs of
// one here and strips nothing at all -- and what reaches the reader is sixteen
// paragraphs reading "you".
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

	// Everything up to and including the third saying: three sayings and the two
	// stretches of silence that sat between them.
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

// The Engine's silence written as BYTES rather than as spaces, which is the edge
// says_nothing moved and the one this file had no fixture for.
//
// A Cue of control characters is not a Saying: CONTEXT.md says the Engine's empty
// and space-only Cues over silence are not Sayings, and a Cue a text editor
// renders as nothing at all is that same statement in bytes. So it carries a run
// ON, exactly as an empty Cue does and for the same reason.
//
// Counted as a Saying it was a DIFFERENT phrase standing between the eighth and
// the ninth "you", and it split ADR-0001's measured invention into two runs of
// eight. Neither reaches invention_at, so neither collapses, and sixteen
// paragraphs reading "you" reach the reader -- over one stray byte the Engine
// chose to write. Seventeen Cues came back where three do now.
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

	// THREE, spelled out, and the same three the unbroken run collapses to: the
	// byte between the two halves changed nothing about what was said.
	testing.expect_value(t, len(kept), 3)
	sayings := 0
	for cue in kept {
		if len(spoken_text(cue)) > 0 {
			sayings += 1
		}
	}
	testing.expect_value(t, sayings, PINNED_COLLAPSE.max_run)
}

// The negative space of that (CLAUDE.md A3). Silence is identical to silence, so
// a run walk that counted CUES rather than sayings makes eight minutes of the
// Engine's own silence Cues an invention and deletes all but three of them --
// taking the Recording's timeline with them, and none of it was ever speech.
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
