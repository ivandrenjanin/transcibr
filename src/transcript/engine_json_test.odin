package transcript

import "core:strings"
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

// ---------------------------------------------------------------------------
// Input that is not Engine output at all.
//
// Every one of these is an OPERATING error naming the file it came from, never
// an assertion (CLAUDE.md A8). ADR-0002 is what makes that the whole answer:
// output that will not parse is treated as absent, quarantined and re-run, so
// the report only has to say which file to go and look at.
// ---------------------------------------------------------------------------

@(test)
reports_empty_input_against_its_name :: proc(t: ^testing.T) {
	// Nothing at all, and nothing but whitespace: a zero-byte file and a file
	// the Engine opened and never wrote to are the same operating error.
	blank := []string{"", "   \r\n\t "}
	for text, i in blank {
		cues, err := parse_cues("empty.json", text, FIXTURE_DURATION, context.allocator)
		defer destroy_cues(cues, context.allocator)

		testing.expectf(t, len(cues) == 0, "case %d handed back cues", i)
		testing.expect_value(t, err.fault, Parse_Fault.Empty_Input)
		testing.expect_value(t, err.json_name, "empty.json")
		testing.expect_value(t, err.cue, 0)
	}
}

@(test)
reports_malformed_input_against_its_name :: proc(t: ^testing.T) {
	malformed := []string {
		"this is not json at all",
		`{"transcription": [}`,
		// Valid JSON5, which is core:encoding/json's DEFAULT specification and
		// is NOT what the Engine writes. A trailing comma means something other
		// than the Engine produced this file.
		`{"transcription": [], /* a comment */}`,
		// Valid JSON, wrong shape: the array is there and holds the wrong thing.
		`{"transcription": "00:00:00,000 --> 00:00:03,480"}`,
	}
	for text, i in malformed {
		cues, err := parse_cues("garbled.json", text, FIXTURE_DURATION, context.allocator)
		defer destroy_cues(cues, context.allocator)

		testing.expectf(t, len(cues) == 0, "case %d handed back cues", i)
		testing.expectf(t, err.fault != .None, "case %d was accepted: %q", i, text)
		testing.expect_value(t, err.json_name, "garbled.json")
	}
}

// The ADR-0002 case, and the reason resume may not branch on a file existing:
// the Engine opens its output with a truncating stream under the final name, so
// a Stop press or a full disk leaves exactly this.
@(test)
reports_truncated_input_against_its_name :: proc(t: ^testing.T) {
	cut := ENGINE_JSON[:len(ENGINE_JSON) / 2]
	cues, err := parse_cues("cut-short.json", cut, FIXTURE_DURATION, context.allocator)
	defer destroy_cues(cues, context.allocator)

	testing.expect(t, len(cues) == 0, "handed back cues from a truncated file")
	testing.expect_value(t, err.fault, Parse_Fault.Malformed_Json)
	testing.expect_value(t, err.json_name, "cut-short.json")
}

@(test)
error_message_names_the_input :: proc(t: ^testing.T) {
	_, err := parse_cues(`C:\cache\9f2a.json`, "not json", FIXTURE_DURATION, context.allocator)
	message := error_message(err, context.allocator)
	defer delete(message, context.allocator)

	testing.expect(
		t,
		strings.contains(message, `C:\cache\9f2a.json`),
		"an operating error that does not say which file to go and look at",
	)
}

@(test)
error_message_names_the_offending_cue :: proc(t: ^testing.T) {
	// Third Cue, and only the third, carries a text field that is not text.
	text := `{"transcription": [
		{"offsets": {"from": 0,    "to": 1000}, "text": "one"},
		{"offsets": {"from": 1000, "to": 2000}, "text": "two"},
		{"offsets": {"from": 2000, "to": 3000}, "text": 3}
	]}`
	cues, err := parse_cues("third.json", text, FIXTURE_DURATION, context.allocator)
	defer destroy_cues(cues, context.allocator)

	testing.expect_value(t, err.fault, Parse_Fault.No_Text)
	testing.expect_value(t, err.cue, 3)

	message := error_message(err, context.allocator)
	defer delete(message, context.allocator)
	testing.expect(t, strings.contains(message, "third.json"), "the report does not name the input")
	testing.expect(t, strings.contains(message, "cue 3"), "the report does not name the cue")
}

// ---------------------------------------------------------------------------
// The Cue set that looks healthy and is not.
//
// Well-formed Cues, every offset zero, and perfectly monotonic -- which is what
// an offset reader that matched nothing leaves behind (see read_millis). It is
// REPORTED and not asserted: a genuine Engine failure produces the same shape,
// and nothing outside this program may crash it (CLAUDE.md A8).
// ---------------------------------------------------------------------------

@(test)
rejects_a_cue_set_whose_final_offset_is_zero :: proc(t: ^testing.T) {
	text := `{"transcription": [
		{"offsets": {"from": 0, "to": 0}, "text": " This is a recording"},
		{"offsets": {"from": 0, "to": 0}, "text": " made to exercise the cue parser."}
	]}`
	cues, err := parse_cues("all-zero.json", text, FIXTURE_DURATION, context.allocator)
	defer destroy_cues(cues, context.allocator)

	testing.expect(t, len(cues) == 0, "handed back a cue set that covers none of the recording")
	testing.expect_value(t, err.fault, Parse_Fault.Final_Offset_Is_Zero)
	testing.expect_value(t, err.json_name, "all-zero.json")
	// The fault is about the set, and the last Cue is the one it is read off,
	// so that is the one a reader is sent to look at.
	testing.expect_value(t, err.cue, 2)

	message := error_message(err, context.allocator)
	defer delete(message, context.allocator)
	testing.expect(t, strings.contains(message, "all-zero.json"), "the report does not name the input")
	testing.expect(t, strings.contains(message, "cue 2"), "the report does not name the cue")
}

// The negative space of the check above (CLAUDE.md A3). A Recording whose
// length the shell could not settle arrives as zero, and a comparison against
// an unknown has nothing to say -- inventing a failure out of missing
// information is how a working Recording gets quarantined forever.
@(test)
accepts_zero_offsets_when_the_recording_length_is_unknown :: proc(t: ^testing.T) {
	text := `{"transcription": [{"offsets": {"from": 0, "to": 0}, "text": ""}]}`
	cues, err := parse_cues("all-zero.json", text, 0, context.allocator)
	defer destroy_cues(cues, context.allocator)

	testing.expect_value(t, err.fault, Parse_Fault.None)
	testing.expect_value(t, len(cues), 1)
}

// It is the FINAL offset that decides, not the first. Every Recording's first
// Cue starts at zero, and a check that read that as the signature would reject
// every Recording there is.
@(test)
accepts_a_cue_set_that_starts_at_offset_zero :: proc(t: ^testing.T) {
	text := `{"transcription": [{"offsets": {"from": 0, "to": 3480}, "text": " one"}]}`
	cues, err := parse_cues("from-zero.json", text, FIXTURE_DURATION, context.allocator)
	defer destroy_cues(cues, context.allocator)

	if !testing.expect_value(t, err.fault, Parse_Fault.None) {
		return
	}
	testing.expect_value(t, len(cues), 1)
	testing.expect_value(t, cues[0].start, Millis(0))
	testing.expect_value(t, cues[0].end, Millis(3_480))
}

// ---------------------------------------------------------------------------
// Ordering: rejected on the way IN, asserted on the way OUT.
//
// The Engine is outside this program, so output that goes backwards is an
// operating error naming the Cue that does it (CLAUDE.md A8). What parse_cues
// then ASSERTS is its own promise about what it hands back, which is a different
// claim reached by a different route (A4).
// ---------------------------------------------------------------------------

@(test)
real_engine_output_is_ordered_on_the_way_out :: proc(t: ^testing.T) {
	cues, err := parse_cues("engine-output.json", ENGINE_JSON, FIXTURE_DURATION, context.allocator)
	defer destroy_cues(cues, context.allocator)

	testing.expect_value(t, err.fault, Parse_Fault.None)
	testing.expect(t, cues_are_ordered(cues), "the parser promises an ordered set and did not deliver one")
	testing.expect_value(t, first_disordered_cue(cues), 0)
}

@(test)
rejects_cues_that_go_backwards :: proc(t: ^testing.T) {
	text := `{"transcription": [
		{"offsets": {"from": 4000, "to": 8000}, "text": " second"},
		{"offsets": {"from": 1000, "to": 3000}, "text": " first"}
	]}`
	cues, err := parse_cues("backwards.json", text, FIXTURE_DURATION, context.allocator)
	defer destroy_cues(cues, context.allocator)

	testing.expect(t, len(cues) == 0, "handed back a cue set that goes backwards")
	testing.expect_value(t, err.fault, Parse_Fault.Cues_Out_Of_Order)
	testing.expect_value(t, err.cue, 2)
}

@(test)
rejects_a_cue_that_ends_before_it_starts :: proc(t: ^testing.T) {
	text := `{"transcription": [{"offsets": {"from": 8000, "to": 4000}, "text": " backwards"}]}`
	cues, err := parse_cues("inverted.json", text, FIXTURE_DURATION, context.allocator)
	defer destroy_cues(cues, context.allocator)

	testing.expect(t, len(cues) == 0, "handed back a cue that ends before it starts")
	testing.expect_value(t, err.fault, Parse_Fault.Cue_Ends_Before_It_Starts)
	testing.expect_value(t, err.cue, 1)
}

@(test)
rejects_an_offset_before_the_start_of_the_recording :: proc(t: ^testing.T) {
	text := `{"transcription": [{"offsets": {"from": -500, "to": 4000}, "text": " early"}]}`
	cues, err := parse_cues("negative.json", text, FIXTURE_DURATION, context.allocator)
	defer destroy_cues(cues, context.allocator)

	testing.expect(t, len(cues) == 0, "handed back a cue starting before the recording")
	testing.expect_value(t, err.fault, Parse_Fault.Negative_Offset)
	testing.expect_value(t, err.cue, 1)
}

// ---------------------------------------------------------------------------
// The ugly cases, as a table.
//
// Everything here is Engine output a Recording can genuinely produce, and every
// one of them is a shape some stricter-looking parser gets wrong.
// ---------------------------------------------------------------------------

@(test)
parses_the_ugly_cases :: proc(t: ^testing.T) {
	Case :: struct {
		name:     string,
		json:     string,
		expected: []Cue,
	}

	cases := []Case {
		{
			name = "single-cue.json",
			json = `{"transcription": [{"offsets": {"from": 0, "to": 3480}, "text": " Alone."}]}`,
			expected = []Cue{{0, 3_480, " Alone."}},
		},
		{
			// The Engine emits these over silence. Dropping them shortens the
			// Cue set the repetition filter downstream counts runs in, and a
			// run it cannot see is a hallucination it cannot strip (ADR-0001).
			name = "empty-text.json",
			json = `{"transcription": [
				{"offsets": {"from": 0,    "to": 1000}, "text": ""},
				{"offsets": {"from": 1000, "to": 2000}, "text": " "},
				{"offsets": {"from": 2000, "to": 3000}, "text": " Words."}
			]}`,
			expected = []Cue{{0, 1_000, ""}, {1_000, 2_000, " "}, {2_000, 3_000, " Words."}},
		},
		{
			// Overlap is ordinary Engine output, and a check demanding a
			// strictly increasing, disjoint sequence would look stricter while
			// rejecting real Recordings.
			name = "overlapping.json",
			json = `{"transcription": [
				{"offsets": {"from": 0,    "to": 5000}, "text": " first"},
				{"offsets": {"from": 3000, "to": 8000}, "text": " second"},
				{"offsets": {"from": 3000, "to": 4000}, "text": " third"}
			]}`,
			expected = []Cue {
				{0, 5_000, " first"},
				{3_000, 8_000, " second"},
				{3_000, 4_000, " third"},
			},
		},
		{
			// Keys this parser has never heard of, at both levels. Rejecting
			// them would turn an Engine upgrade into a corrupt Transcript, and
			// `-ojf` already adds a per-token array to every Cue (ADR-0001).
			name = "unexpected-fields.json",
			json = `{
				"systeminfo": "irrelevant",
				"model": {"type": "large"},
				"a_key_from_2027": [1, 2, 3],
				"transcription": [{
					"timestamps": {"from": "00:00:00,000", "to": "00:00:03,480"},
					"offsets": {"from": 0, "to": 3480},
					"text": " Words.",
					"tokens": [{"text": " Words", "p": 0.98}]
				}]
			}`,
			expected = []Cue{{0, 3_480, " Words."}},
		},
		{
			// `offsets` is the source of truth, not `timestamps` (ADR-0001).
			// The two disagree here so that a parser quietly re-deriving
			// milliseconds from the hh:mm:ss,mmm text cannot pass.
			name = "disagreeing-timestamps.json",
			json = `{"transcription": [{
				"timestamps": {"from": "00:00:11,111", "to": "00:00:22,222"},
				"offsets": {"from": 4380, "to": 8440},
				"text": " Words."
			}]}`,
			expected = []Cue{{4_380, 8_440, " Words."}},
		},
		{
			// The other half of read_millis' trap. The tokenizer classifies on
			// the decimal point, so these stay json.Float even with
			// `parse_integers` on, and an Engine release that starts writing
			// them this way must not silently zero every offset.
			name = "float-offsets.json",
			json = `{"transcription": [
				{"offsets": {"from": 0.0,    "to": 3480.0}, "text": " one"},
				{"offsets": {"from": 4.38e3, "to": 8440e0}, "text": " two"}
			]}`,
			expected = []Cue{{0, 3_480, " one"}, {4_380, 8_440, " two"}},
		},
		{
			// Escapes are undone exactly once. Twice mangles a Transcript;
			// not at all leaves a literal backslash-n mid-sentence.
			name = "escaped-text.json",
			json = `{"transcription": [{"offsets": {"from": 0, "to": 1000},
				"text": " \"quoted\", a \\ backslash, and café."}]}`,
			expected = []Cue{{0, 1_000, ` "quoted", a \ backslash, and café.`}},
		},
	}

	for c in cases {
		cues, err := parse_cues(c.name, c.json, FIXTURE_DURATION, context.allocator)
		defer destroy_cues(cues, context.allocator)

		if !testing.expectf(t, err.fault == .None, "%s: rejected with %v", c.name, err.fault) {
			continue
		}
		if !testing.expectf(
			t,
			len(cues) == len(c.expected),
			"%s: got %d cues, want %d",
			c.name,
			len(cues),
			len(c.expected),
		) {
			continue
		}
		for want, i in c.expected {
			testing.expectf(t, cues[i] == want, "%s: cue %d is %v, want %v", c.name, i + 1, cues[i], want)
		}
	}
}

@(test)
rejects_the_ugly_cases :: proc(t: ^testing.T) {
	Case :: struct {
		name:  string,
		json:  string,
		fault: Parse_Fault,
		cue:   int,
	}

	cases := []Case {
		{
			name = "no-transcription.json",
			json = `{"systeminfo": "irrelevant", "result": {"language": "en"}}`,
			fault = .No_Transcription,
		},
		{
			name = "transcription-not-an-array.json",
			json = `{"transcription": {"offsets": {"from": 0, "to": 1}, "text": " one"}}`,
			fault = .No_Transcription,
		},
		{
			// "Exit 0 but nothing transcribed" is a per-Recording failure, not
			// a Transcript with no words in it (ADR-0002).
			name = "no-cues.json",
			json = `{"transcription": []}`,
			fault = .No_Cues,
		},
		{
			name = "not-an-object.json",
			json = `[{"offsets": {"from": 0, "to": 1}, "text": " one"}]`,
			fault = .Not_An_Object,
		},
		{
			name = "cue-not-an-object.json",
			json = `{"transcription": ["00:00:00,000 --> 00:00:03,480  One."]}`,
			fault = .Cue_Not_An_Object,
			cue = 1,
		},
		{
			name = "no-offsets.json",
			json = `{"transcription": [{"timestamps": {"from": "00:00:00,000"}, "text": " one"}]}`,
			fault = .No_Offsets,
			cue = 1,
		},
		{
			name = "offsets-not-an-object.json",
			json = `{"transcription": [{"offsets": [0, 3480], "text": " one"}]}`,
			fault = .No_Offsets,
			cue = 1,
		},
		{
			name = "no-end-offset.json",
			json = `{"transcription": [{"offsets": {"from": 0}, "text": " one"}]}`,
			fault = .Offset_Missing,
			cue = 1,
		},
		{
			// The hh:mm:ss,mmm form in the wrong field. Reported rather than
			// re-parsed: guessing at what the Engine meant is how a schema
			// change becomes a Transcript full of plausible wrong timings.
			name = "offset-as-text.json",
			json = `{"transcription": [{"offsets": {"from": "00:00:00,000", "to": "00:00:03,480"},
				"text": " one"}]}`,
			fault = .Offset_Not_A_Number,
			cue = 1,
		},
		{
			name = "offset-not-whole.json",
			json = `{"transcription": [{"offsets": {"from": 0, "to": 3480.5}, "text": " one"}]}`,
			fault = .Offset_Not_Whole,
			cue = 1,
		},
		{
			// Past 2^53 an f64 no longer holds the value it was written with,
			// so converting is guessing at a number nobody has.
			name = "offset-out-of-range.json",
			json = `{"transcription": [{"offsets": {"from": 0, "to": 1e300}, "text": " one"}]}`,
			fault = .Offset_Out_Of_Range,
			cue = 1,
		},
		{
			name = "no-text.json",
			json = `{"transcription": [{"offsets": {"from": 0, "to": 3480}}]}`,
			fault = .No_Text,
			cue = 1,
		},
		{
			name = "text-not-a-string.json",
			json = `{"transcription": [
				{"offsets": {"from": 0,    "to": 1000}, "text": " one"},
				{"offsets": {"from": 1000, "to": 2000}, "text": ["two"]}
			]}`,
			fault = .No_Text,
			cue = 2,
		},
	}

	for c in cases {
		cues, err := parse_cues(c.name, c.json, FIXTURE_DURATION, context.allocator)
		defer destroy_cues(cues, context.allocator)

		testing.expectf(t, len(cues) == 0, "%s: handed back %d cues", c.name, len(cues))
		testing.expectf(t, err.fault == c.fault, "%s: got %v, want %v", c.name, err.fault, c.fault)
		testing.expectf(t, err.cue == c.cue, "%s: blamed cue %d, want %d", c.name, err.cue, c.cue)
		testing.expectf(t, err.json_name == c.name, "%s: reported against %q", c.name, err.json_name)

		// Every rejection renders, and every rendering names the input: a fault
		// added without a sentence in FAULT_TEXT trips the assertion inside.
		message := error_message(err, context.allocator)
		defer delete(message, context.allocator)
		testing.expectf(t, strings.contains(message, c.name), "%s: report does not name it", c.name)
	}
}
