package transcript

import "core:testing"

// The thresholds every test below pins for itself. Named here so the cases read
// as "more than three sayings, spread over more than twenty seconds" rather than
// as two numbers repeated down the file -- and stated in the TEST rather than
// taken from COLLAPSE_DEFAULT, because those are taste and are expected to move
// (ADR-0007). A test that read them would change its meaning when they did.
@(private)
PINNED_COLLAPSE :: Collapse_Params {
	max_run    = 3,
	min_run_ms = 20_000,
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

// Five of the six rows say the phrase MORE than PINNED_COLLAPSE.max_run times,
// which is the point: a filter that counted sayings and stopped there would
// truncate every one of them. What saves them is that real repetition is fast --
// the slowest row here is over in eleven seconds, against the four and a half
// minutes the Engine spent inventing "you" (ADR-0001).
@(private, rodata)
REAL_REPETITIONS := []Real_Repetition {
	{
		// The rhetorical triple. Inside the cap, so it survives on length
		// alone -- the row that would still pass if the span threshold were
		// deleted, and the one that says which rows below prove anything.
		name = "a flat refusal",
		text = " No.",
		count = 3,
		duration_ms = 700,
		gap_ms = 120,
	},
	{
		// Six sayings in under four seconds. A cap on length alone deletes
		// half of them and the Transcript reads perfectly well without them.
		name = "urging somebody on",
		text = " Go!",
		count = 6,
		duration_ms = 480,
		gap_ms = 90,
	},
	{
		name = "agreeing in conversation",
		text = " Yeah.",
		count = 4,
		duration_ms = 600,
		gap_ms = 300,
	},
	{
		name = "a stutter",
		text = " I--",
		count = 4,
		duration_ms = 260,
		gap_ms = 0,
	},
	{
		// A chorus, which is the slowest thing on this list that is still
		// unmistakably speech: five sayings across ten seconds.
		name = "a repeated chorus line",
		text = " Hey Jude.",
		count = 5,
		duration_ms = 1_800,
		gap_ms = 200,
	},
	{
		// Repetition with real pauses between the sayings. The gap is longer
		// than the saying, which is exactly the shape a naive "sparse means
		// invented" rule would condemn.
		name = "a phrase repeated after a pause",
		text = " Never again.",
		count = 4,
		duration_ms = 1_400,
		gap_ms = 1_600,
	},
}

@(test)
legitimately_repeated_speech_survives :: proc(t: ^testing.T) {
	for said in REAL_REPETITIONS {
		shape := make([dynamic]Shaped_Cue, context.allocator)
		defer delete(shape)
		say_repeatedly(&shape, said.text, said.count, said.duration_ms, said.gap_ms)

		cues := shaped_cues(shape[:], context.allocator)
		defer delete(cues, context.allocator)

		kept := collapse_repetition(cues, PINNED_COLLAPSE, context.allocator)
		defer destroy_cues(kept, context.allocator)

		if !testing.expectf(
			t,
			len(kept) == len(cues),
			"%s: %d of the %d sayings of %q survived",
			said.name,
			len(kept),
			len(cues),
			said.text,
		) {
			continue
		}
		for cue, i in cues {
			testing.expectf(t, kept[i] == cue, "%s: saying %d came back as %v", said.name, i + 1, kept[i])
		}
	}
}

// The shipped thresholds against the same speech. PINNED_COLLAPSE is what the
// cases above are stated in, so nothing there would notice COLLAPSE_DEFAULT
// being tuned into something that strips real words -- and the shipped constant
// is the one every Recording is actually run through.
@(test)
the_shipped_collapse_thresholds_leave_real_speech_alone :: proc(t: ^testing.T) {
	for said in REAL_REPETITIONS {
		shape := make([dynamic]Shaped_Cue, context.allocator)
		defer delete(shape)
		say_repeatedly(&shape, said.text, said.count, said.duration_ms, said.gap_ms)

		cues := shaped_cues(shape[:], context.allocator)
		defer delete(cues, context.allocator)

		kept := collapse_repetition(cues, COLLAPSE_DEFAULT, context.allocator)
		defer destroy_cues(kept, context.allocator)

		testing.expectf(
			t,
			len(kept) == len(cues),
			"%s: the shipped thresholds kept %d of the %d sayings of %q",
			said.name,
			len(kept),
			len(cues),
			said.text,
		)
	}
}

// Why there are two thresholds and not one, said in checked code rather than in
// a comment (CLAUDE.md A6).
//
// The same rows, run through a span threshold low enough that every run clears
// it -- which is what a cap on LENGTH alone is. Every row saying its phrase more
// than max_run times loses the difference, and those are real words nobody would
// have missed.
@(test)
a_cap_on_length_alone_would_delete_real_words :: proc(t: ^testing.T) {
	length_only := Collapse_Params{max_run = PINNED_COLLAPSE.max_run, min_run_ms = 1}
	truncated := 0

	for said in REAL_REPETITIONS {
		shape := make([dynamic]Shaped_Cue, context.allocator)
		defer delete(shape)
		say_repeatedly(&shape, said.text, said.count, said.duration_ms, said.gap_ms)

		cues := shaped_cues(shape[:], context.allocator)
		defer delete(cues, context.allocator)

		kept := collapse_repetition(cues, length_only, context.allocator)
		defer destroy_cues(kept, context.allocator)

		if len(kept) < len(cues) {
			truncated += 1
		}
	}

	// Five of the six rows say their phrase more than three times over; the
	// sixth is inside the cap and survives either way.
	testing.expect_value(t, truncated, 5)
}

@(test)
collapsing_no_cues_yields_no_cues :: proc(t: ^testing.T) {
	kept := collapse_repetition(nil, PINNED_COLLAPSE, context.allocator)
	defer destroy_cues(kept, context.allocator)

	testing.expect_value(t, len(kept), 0)
	testing.expect(t, kept == nil, "an empty cue set came back with memory behind it to free")
}
