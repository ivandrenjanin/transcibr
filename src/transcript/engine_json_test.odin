#+vet explicit-allocators
package transcript

import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"
import "transcibr:process"

// One real whisper.cpp v1.9.1 run, committed verbatim. Kept unedited because it
// pins the schema this design bets on (ADR-0001): an Engine release that changes
// the shape fails here rather than silently emitting empty Transcripts.
@(private)
ENGINE_JSON :: #load("fixtures/engine-output.json", string)

// A tripwire on this one committed artefact: `#load` embeds whatever is on disk,
// so a checkout that rewrote the file's line endings would leave every test below
// reading a different file. .gitattributes marks fixtures `-text` to stop that.
#assert(len(ENGINE_JSON) == 2335)

// What ffprobe reports for the Recording the fixture was transcribed from:
// 30.355875 s, measured off the container and never derived from the Cues.
@(private)
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
		{30_000, 59_980, " Thank you."},
	}
	for want, i in expected {
		testing.expect_value(t, cues[i], want)
	}
}

@(test)
reads_the_language_the_engine_detected :: proc(t: ^testing.T) {
	language := parse_language(ENGINE_JSON, context.allocator)
	defer delete(language, context.allocator)

	testing.expect_value(t, language, "en")
}

@(test)
reads_the_systeminfo_the_engine_reported :: proc(t: ^testing.T) {
	systeminfo := parse_systeminfo(ENGINE_JSON, context.allocator)
	defer delete(systeminfo, context.allocator)

	testing.expect(
		t,
		strings.contains(systeminfo, "CUDA"),
		"the fixture's own CUDA mention is missing",
	)
}

@(private)
Systeminfo_Case :: struct {
	name:  string,
	json:  string,
	reads: string,
}

@(private, rodata)
SYSTEMINFO_CASES := []Systeminfo_Case {
	{name = "no-systeminfo.json", json = `{"result": {"language": "en"}}`, reads = UNKNOWN},
	{name = "systeminfo-not-a-string.json", json = `{"systeminfo": 7}`, reads = UNKNOWN},
	{name = "not-an-object.json", json = `["systeminfo"]`, reads = UNKNOWN},
	{name = "systeminfo-said-empty.json", json = `{"systeminfo": ""}`, reads = UNKNOWN},
	{name = "empty.json", json = "", reads = UNKNOWN},
	{name = "whitespace.json", json = "  \r\n\t ", reads = UNKNOWN},
	{name = "not-json.json", json = "this is not json at all", reads = UNKNOWN},
	{name = "truncated.json", json = `{"systeminfo": "CUD`, reads = UNKNOWN},
}

@(test)
a_document_that_names_no_systeminfo_is_read_as_naming_none :: proc(t: ^testing.T) {
	for c in SYSTEMINFO_CASES {
		systeminfo := parse_systeminfo(c.json, context.allocator)
		defer delete(systeminfo, context.allocator)

		testing.expectf(
			t,
			systeminfo == c.reads,
			"%s: read %q, want %q",
			c.name,
			systeminfo,
			c.reads,
		)
	}
}

@(private)
Language_Case :: struct {
	name:  string,
	json:  string,
	reads: string,
}

@(private, rodata)
LANGUAGE_CASES := []Language_Case {
	{
		name = "detected-differs-from-requested.json",
		json = `{"params": {"language": "auto"}, "result": {"language": "de"}}`,
		reads = "de",
	},
	{name = "only-requested.json", json = `{"params": {"language": "en"}}`, reads = UNKNOWN},
	{name = "result-without-language.json", json = `{"result": {"beam": 5}}`, reads = UNKNOWN},
	{name = "language-not-a-string.json", json = `{"result": {"language": 7}}`, reads = UNKNOWN},
	{name = "result-not-an-object.json", json = `{"result": "en"}`, reads = UNKNOWN},
	{name = "language-said-empty.json", json = `{"result": {"language": ""}}`, reads = UNKNOWN},
	{name = "empty.json", json = "", reads = UNKNOWN},
	{name = "whitespace.json", json = "  \r\n\t ", reads = UNKNOWN},
	{name = "not-json.json", json = "this is not json at all", reads = UNKNOWN},
	{name = "not-an-object.json", json = `[{"language": "en"}]`, reads = UNKNOWN},
	{name = "truncated.json", json = `{"result": {"language": "e`, reads = UNKNOWN},
}

@(test)
a_document_that_names_no_language_is_read_as_naming_none :: proc(t: ^testing.T) {
	for c in LANGUAGE_CASES {
		language := parse_language(c.json, context.allocator)
		defer delete(language, context.allocator)

		testing.expectf(t, language == c.reads, "%s: read %q, want %q", c.name, language, c.reads)
	}
}

@(test)
reports_empty_input_against_its_name :: proc(t: ^testing.T) {
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
		`{"transcription": [], /* a comment */}`,
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

// The Engine opens its output with a truncating stream under the final name, so a
// Stop press or a full disk leaves exactly this (ADR-0002).
@(test)
reports_truncated_input_against_its_name :: proc(t: ^testing.T) {
	cut := ENGINE_JSON[:len(ENGINE_JSON) / 2]
	cues, err := parse_cues("cut-short.json", cut, FIXTURE_DURATION, context.allocator)
	defer destroy_cues(cues, context.allocator)

	testing.expect(t, len(cues) == 0, "handed back cues from a truncated file")
	testing.expect_value(t, err.fault, Parse_Fault.Malformed_Json)
	testing.expect_value(t, err.json_name, "cut-short.json")
}

// The nesting sits under a key this parser ignores, so an accepted document is
// accepted with its Cue and depth is the only thing these cases vary.
@(private)
@(require_results)
nested_engine_json :: proc(inner_depth: int, allocator: mem.Allocator) -> string {
	assert(inner_depth > 0, "a document nested no levels deep tests nothing")
	assert(allocator.procedure != nil, "the document outlives this procedure")

	out := strings.builder_make(allocator)
	strings.write_string(&out, `{"a_key_from_2027": `)
	for _ in 0 ..< inner_depth {
		strings.write_byte(&out, '[')
	}
	for _ in 0 ..< inner_depth {
		strings.write_byte(&out, ']')
	}
	strings.write_string(
		&out,
		`, "transcription": [{"offsets": {"from": 0, "to": 3480}, "text": " one"}]}`,
	)

	text := strings.to_string(out)
	assert(len(text) > inner_depth * 2, "the nesting never reached the document")
	return text
}

// See CLAUDE.md, Odin notes: core:encoding/json.
@(test)
refuses_nesting_that_would_crash_the_decoder :: proc(t: ^testing.T) {
	deep := nested_engine_json(800, context.allocator)
	defer delete(deep, context.allocator)

	cues, err := parse_cues("deep.json", deep, FIXTURE_DURATION, context.allocator)
	defer destroy_cues(cues, context.allocator)

	testing.expect(t, len(cues) == 0, "handed back cues from a file that cannot be decoded")
	testing.expect_value(t, err.fault, Parse_Fault.Too_Deeply_Nested)
	testing.expect_value(t, err.json_name, "deep.json")
}

@(test)
accepts_nesting_up_to_the_limit :: proc(t: ^testing.T) {
	either_side := [2]int{MAX_JSON_DEPTH - 1, MAX_JSON_DEPTH}
	for inner_depth, i in either_side {
		text := nested_engine_json(inner_depth, context.allocator)
		defer delete(text, context.allocator)

		cues, err := parse_cues("nested.json", text, FIXTURE_DURATION, context.allocator)
		defer destroy_cues(cues, context.allocator)

		want := Parse_Fault.None if i == 0 else Parse_Fault.Too_Deeply_Nested
		testing.expectf(
			t,
			err.fault == want,
			"%d levels gave %v, want %v",
			inner_depth + 1,
			err.fault,
			want,
		)
	}
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
	testing.expect(
		t,
		strings.contains(message, "third.json"),
		"the report does not name the input",
	)
	testing.expect(t, strings.contains(message, "cue 3"), "the report does not name the cue")
}

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
	testing.expect_value(t, err.cue, 2)

	message := error_message(err, context.allocator)
	defer delete(message, context.allocator)
	testing.expect(
		t,
		strings.contains(message, "all-zero.json"),
		"the report does not name the input",
	)
	testing.expect(t, strings.contains(message, "cue 2"), "the report does not name the cue")
}

@(test)
accepts_zero_offsets_when_the_recording_is_not_known_to_be_longer :: proc(t: ^testing.T) {
	text := `{"transcription": [{"offsets": {"from": 0, "to": 0}, "text": ""}]}`
	lengths := []Maybe(Millis){nil, Millis(0)}
	for length, i in lengths {
		cues, err := parse_cues("all-zero.json", text, length, context.allocator)
		defer destroy_cues(cues, context.allocator)

		testing.expectf(t, err.fault == .None, "case %d rejected with %v", i, err.fault)
		testing.expectf(t, len(cues) == 1, "case %d handed back %d cues", i, len(cues))
	}
}

@(test)
every_fault_says_what_adr_0002_does_with_it :: proc(t: ^testing.T) {
	hard := []Parse_Fault{.Empty_Input, .No_Cues, .Nothing_Said}

	for fault in Parse_Fault {
		if fault == .None {
			continue
		}
		want := process.Disposition.Quarantine_And_Rerun
		if slice.contains(hard, fault) {
			want = .Fail_The_Recording
		}
		got := disposition_of(fault)
		testing.expectf(t, got == want, "%v is %v, want %v", fault, got, want)
	}
}

// Reads FAULT directly rather than through disposition_of, exactly as
// src/audio/fault_test.odin reads its own table directly: a row written present
// and empty is not caught by the enumerated array, so nothing but a test that
// looks at the row itself catches it (see CLAUDE.md, Odin notes: enumerated
// arrays and switches).
@(test)
every_parse_fault_names_a_disposition :: proc(t: ^testing.T) {
	for fault in Parse_Fault {
		if fault == .None {
			continue
		}
		testing.expectf(
			t,
			FAULT[fault].disposition != .Unset,
			"%v has no disposition in FAULT",
			fault,
		)
	}
}

// Reads FAULT[fault].says directly rather than through fault_facts, exactly as
// src/audio/fault_test.odin reads its own table directly: a row written
// present and empty is not caught by the enumerated array, so nothing but a
// test that looks at the row itself catches it (see CLAUDE.md, Odin notes:
// enumerated arrays and switches).
@(test)
every_parse_fault_names_a_sentence :: proc(t: ^testing.T) {
	for fault in Parse_Fault {
		if fault == .None {
			continue
		}
		testing.expectf(t, len(FAULT[fault].says) > 0, "%v has an empty says in FAULT", fault)
	}
}

// Reads FAULT[fault].scope directly rather than through fault_facts, exactly
// as the two tests above read their own fields: a row written present and
// empty (`.scope` left at its zero value, `.Unset`) is not caught by the
// enumerated array, so nothing but a test that looks at the field itself
// catches it (see CLAUDE.md, Odin notes: enumerated arrays and switches).
@(test)
every_parse_fault_names_a_scope :: proc(t: ^testing.T) {
	for fault in Parse_Fault {
		if fault == .None {
			continue
		}
		testing.expectf(t, FAULT[fault].scope != .Unset, "%v has no scope in FAULT", fault)
	}
}

@(test)
an_engine_that_transcribed_nothing_fails_its_recording :: proc(t: ^testing.T) {
	empty := []string{"", `{"transcription": []}`}
	for text, i in empty {
		cues, err := parse_cues("nothing.json", text, FIXTURE_DURATION, context.allocator)
		defer destroy_cues(cues, context.allocator)

		testing.expectf(t, err.fault != .None, "case %d was accepted", i)
		testing.expectf(
			t,
			disposition_of(err.fault) == .Fail_The_Recording,
			"case %d (%v) would be re-run forever",
			i,
			err.fault,
		)
	}
}

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

@(test)
real_engine_output_is_ordered_on_the_way_out :: proc(t: ^testing.T) {
	cues, err := parse_cues("engine-output.json", ENGINE_JSON, FIXTURE_DURATION, context.allocator)
	defer destroy_cues(cues, context.allocator)

	testing.expect_value(t, err.fault, Parse_Fault.None)
	testing.expect(
		t,
		cues_are_ordered(cues),
		"the parser promises an ordered set and did not deliver one",
	)
	testing.expect_value(t, first_disordered_cue(cues), 0)
}

@(private)
Accepted_Case :: struct {
	name:     string,
	json:     string,
	expected: []Cue,
}

@(private, rodata)
ACCEPTED_CASES := []Accepted_Case {
	{
		name = "single-cue.json",
		json = `{"transcription": [{"offsets": {"from": 0, "to": 3480}, "text": " Alone."}]}`,
		expected = []Cue{{0, 3_480, " Alone."}},
	},
	{
		name = "empty-text.json",
		json = `{"transcription": [
			{"offsets": {"from": 0,    "to": 1000}, "text": ""},
			{"offsets": {"from": 1000, "to": 2000}, "text": " "},
			{"offsets": {"from": 2000, "to": 3000}, "text": " Words."}
		]}`,
		expected = []Cue{{0, 1_000, ""}, {1_000, 2_000, " "}, {2_000, 3_000, " Words."}},
	},
	{
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
		name = "disagreeing-timestamps.json",
		json = `{"transcription": [{
			"timestamps": {"from": "00:00:11,111", "to": "00:00:22,222"},
			"offsets": {"from": 4380, "to": 8440},
			"text": " Words."
		}]}`,
		expected = []Cue{{4_380, 8_440, " Words."}},
	},
	{
		name = "float-offsets.json",
		json = `{"transcription": [
			{"offsets": {"from": 0.0,    "to": 3480.0}, "text": " one"},
			{"offsets": {"from": 4.38e3, "to": 8440e0}, "text": " two"}
		]}`,
		expected = []Cue{{0, 3_480, " one"}, {4_380, 8_440, " two"}},
	},
	{
		name = "offset-at-the-limit.json",
		json = `{"transcription": [
			{"offsets": {"from": 0, "to": 9007199254740991},                "text": " one"},
			{"offsets": {"from": 9007199254740991, "to": 9007199254740991.0}, "text": " two"}
		]}`,
		expected = []Cue {
			{0, 9_007_199_254_740_991, " one"},
			{9_007_199_254_740_991, 9_007_199_254_740_991, " two"},
		},
	},
	{
		name = "escaped-text.json",
		json = `{"transcription": [{"offsets": {"from": 0, "to": 1000},
			"text": " \"quoted\", a \\ backslash, and café."}]}`,
		expected = []Cue{{0, 1_000, ` "quoted", a \ backslash, and café.`}},
	},
	{
		name = "bracketed-text.json",
		json = `{"transcription": [{"offsets": {"from": 0, "to": 1000},
			"text": " [[[[[ {{{ \" ]] }} \\"}]}`,
		expected = []Cue{{0, 1_000, ` [[[[[ {{{ " ]] }} \`}},
	},
}

@(test)
parses_the_ugly_cases :: proc(t: ^testing.T) {
	for c in ACCEPTED_CASES {
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
			testing.expectf(
				t,
				cues[i] == want,
				"%s: cue %d is %v, want %v",
				c.name,
				i + 1,
				cues[i],
				want,
			)
		}
	}
}

@(private)
Rejected_Case :: struct {
	name:  string,
	json:  string,
	fault: Parse_Fault,
	// The 1-based Cue the report must blame, or 0 where the fault is about the
	// input as a whole.
	cue:   int,
}

@(private, rodata)
REJECTED_CASES := []Rejected_Case {
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
	{name = "no-cues.json", json = `{"transcription": []}`, fault = .No_Cues},
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
		name = "offset-out-of-range.json",
		json = `{"transcription": [{"offsets": {"from": 0, "to": 1e300}, "text": " one"}]}`,
		fault = .Offset_Out_Of_Range,
		cue = 1,
	},
	{
		name = "integer-offset-overflows.json",
		json = `{"transcription": [{"offsets": {"from": 0, "to": 99999999999999999999999},
			"text": " one"}]}`,
		fault = .Offset_Out_Of_Range,
		cue = 1,
	},
	{
		// 2^64 + 5000, which no range check downstream of a wrapped i64 could see.
		// See CLAUDE.md, Odin notes: core:encoding/json.
		name  = "integer-offset-wraps-into-range.json",
		json  = `{"transcription": [{"offsets": {"from": 0, "to": 18446744073709556616},
			"text": " one"}]}`,
		fault = .Offset_Out_Of_Range,
		cue   = 1,
	},
	{
		name = "offset-past-the-limit.json",
		json = `{"transcription": [{"offsets": {"from": 0, "to": 9007199254740992}, "text": " one"}]}`,
		fault = .Offset_Out_Of_Range,
		cue = 1,
	},
	{
		name = "offset-rounding-onto-the-limit.json",
		json = `{"transcription": [{"offsets": {"from": 0, "to": 9007199254740993}, "text": " one"}]}`,
		fault = .Offset_Out_Of_Range,
		cue = 1,
	},
	{
		name = "offset-below-the-limit.json",
		json = `{"transcription": [{"offsets": {"from": -9007199254740992, "to": 0}, "text": " one"}]}`,
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
	{
		name = "backwards.json",
		json = `{"transcription": [
			{"offsets": {"from": 4000, "to": 8000}, "text": " second"},
			{"offsets": {"from": 1000, "to": 3000}, "text": " first"}
		]}`,
		fault = .Cues_Out_Of_Order,
		cue = 2,
	},
	{
		name = "inverted.json",
		json = `{"transcription": [{"offsets": {"from": 8000, "to": 4000}, "text": " backwards"}]}`,
		fault = .Cue_Ends_Before_It_Starts,
		cue = 1,
	},
	{
		name = "negative.json",
		json = `{"transcription": [{"offsets": {"from": -500, "to": 4000}, "text": " early"}]}`,
		fault = .Negative_Offset,
		cue = 1,
	},
}

@(test)
rejects_the_ugly_cases :: proc(t: ^testing.T) {
	for c in REJECTED_CASES {
		cues, err := parse_cues(c.name, c.json, FIXTURE_DURATION, context.allocator)
		defer destroy_cues(cues, context.allocator)

		testing.expectf(t, len(cues) == 0, "%s: handed back %d cues", c.name, len(cues))
		testing.expectf(t, err.fault == c.fault, "%s: got %v, want %v", c.name, err.fault, c.fault)
		testing.expectf(t, err.cue == c.cue, "%s: blamed cue %d, want %d", c.name, err.cue, c.cue)
		testing.expectf(
			t,
			err.json_name == c.name,
			"%s: reported against %q",
			c.name,
			err.json_name,
		)

		message := error_message(err, context.allocator)
		defer delete(message, context.allocator)
		testing.expectf(
			t,
			strings.contains(message, c.name),
			"%s: report does not name it",
			c.name,
		)
	}
}
