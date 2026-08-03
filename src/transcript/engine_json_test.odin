package transcript

import "core:testing"

// One real whisper.cpp v1.9.1 run, committed verbatim -- systeminfo block,
// absolute model path, hallucinated closing Cue and all. Regenerating it is in
// the pull request that added it; the point of keeping it unedited is that it
// pins the schema this design bets on (ADR-0001), so an Engine release that
// changes the shape fails HERE rather than silently emitting empty Transcripts.
//
// `#load` rather than a runtime read: the core is pure (ADR-0009), and a test
// that opens a file is testing the filesystem too.
ENGINE_JSON :: #load("fixtures/engine-output.json", string)

// What ffprobe reports for the Recording the fixture was transcribed from:
// 30.355875 s. Passed as the Recording's length rather than derived from the
// Cues, which is the circular measurement ADR-0009 rules out.
FIXTURE_DURATION :: Millis(30_356)

@(test)
parses_real_engine_output_into_cues :: proc(t: ^testing.T) {
	cues, err := parse_cues("engine-output.json", ENGINE_JSON, FIXTURE_DURATION, context.allocator)
	defer destroy_cues(cues, context.allocator)

	if !testing.expect_value(t, err.fault, Parse_Fault.None) {
		return
	}
	if !testing.expect_value(t, len(cues), 7) {
		return
	}

	// The offsets the Engine actually wrote, in milliseconds. Copied off the
	// fixture by eye, not recomputed the way the parser computes them -- an
	// expectation derived the same way as the code can never disagree with it.
	expected := [7]Cue {
		{0, 3_480, " This is a recording made to exercise the Q-Parser."},
		{4_380, 8_440, " The engine emits one time-stamped fragment of speech at a time."},
		{9_360, 13_980, " Each fragment carries a start offset, an end offset, and its text."},
		{
			14_960,
			19_720,
			" The offsets arrive in miliscans, counted from the beginning of the recording.",
		},
		{
			20_760,
			26_200,
			" A parser that reads them as integers will find none, because the numbers are floating point.",
		},
		{26_860, 29_480, " That is the whole point of this fixture."},
		// The Engine hallucinates over the trailing silence and dates the
		// invention past the end of the Recording. Kept: this parser is
		// lossless, stripping is a later stage, and clamping to the probed
		// duration here would hide the very thing that stage looks for.
		{30_000, 59_980, " Thank you."},
	}
	for want, i in expected {
		testing.expect_value(t, cues[i].start, want.start)
		testing.expect_value(t, cues[i].end, want.end)
		testing.expect_value(t, cues[i].text, want.text)
	}
}
