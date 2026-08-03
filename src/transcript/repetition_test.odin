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
