package transcript

import "core:mem"
import "core:slice"
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
@(private)
ENGINE_JSON :: #load("fixtures/engine-output.json", string)

// The size the Engine wrote, in checked code rather than in prose (CLAUDE.md
// A5). Not a claim about the JSON format -- a tripwire on this one committed
// artefact: `#load` embeds whatever is on disk, so a checkout that rewrote the
// file's line endings would leave every test below reading a different file
// under the same names, and reports_truncated_input_against_its_name cutting it
// at a different byte. .gitattributes marks fixtures `-text` to stop that; this
// is what notices if it ever stops working.
#assert(len(ENGINE_JSON) == 2335)

// What ffprobe reports for the Recording the fixture was transcribed from:
// 30.355875 s. Passed as the Recording's length rather than derived from the
// Cues, which is the circular measurement ADR-0009 rules out.
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
	// A Cue is comparable, so this is one question and not three, and a failure
	// prints the whole Cue rather than the field that happened to be checked
	// first.
	for want, i in expected {
		testing.expect_value(t, cues[i], want)
	}
}

// ---------------------------------------------------------------------------
// The detected language, which is the one front matter fact the Engine's own
// output can settle.
//
// ADR-0001 chose JSON over SRT partly because it "carries the detected language
// and model parameters we want in the transcript's front matter". Everything
// else a Transcript records -- the Engine version, the Model's identity -- comes
// from transcibr's own record instead, because the Engine reports every large
// Model under the bare name `large` and does not report its own version at all
// (ADR-0003).
// ---------------------------------------------------------------------------

@(test)
reads_the_language_the_engine_detected :: proc(t: ^testing.T) {
	language, said := parse_language(ENGINE_JSON, context.allocator)
	defer if said {
		delete(language, context.allocator)
	}

	testing.expect(t, said, "the fixture's detected language was not read")
	testing.expect_value(t, language, "en")
}

// One document and the language it must be read as, where "" means the Engine
// did not say.
@(private)
Language_Case :: struct {
	name:  string,
	json:  string,
	reads: string,
}

@(private, rodata)
LANGUAGE_CASES := []Language_Case {
	{
		// `result` and NOT `params`. The Engine writes what it was ASKED for in
		// `params.language`, which is `auto` on every Recording nobody set a
		// language for, and what it DETECTED in `result.language`. A Transcript
		// stamped `auto` says nothing, and one stamped the requested language when
		// the two disagree says something false.
		name  = "detected-differs-from-requested.json",
		json  = `{"params": {"language": "auto"}, "result": {"language": "de"}}`,
		reads = "de",
	},
	{name = "only-requested.json", json = `{"params": {"language": "en"}}`},
	{name = "result-without-language.json", json = `{"result": {"beam": 5}}`},
	{name = "language-not-a-string.json", json = `{"result": {"language": 7}}`},
	{name = "result-not-an-object.json", json = `{"result": "en"}`},
	{name = "language-said-empty.json", json = `{"result": {"language": ""}}`},
	// Everything parse_cues would refuse. The language is read for the front
	// matter, so a document that is not Engine output has no language in it --
	// reported as nothing rather than crashing, because it came from outside this
	// program (CLAUDE.md A8).
	{name = "empty.json", json = ""},
	{name = "whitespace.json", json = "  \r\n\t "},
	{name = "not-json.json", json = "this is not json at all"},
	{name = "not-an-object.json", json = `[{"language": "en"}]`},
	{name = "truncated.json", json = `{"result": {"language": "e`},
}

@(test)
a_document_that_names_no_language_is_read_as_naming_none :: proc(t: ^testing.T) {
	for c in LANGUAGE_CASES {
		language, said := parse_language(c.json, context.allocator)
		defer if said {
			delete(language, context.allocator)
		}

		testing.expectf(
			t,
			said == (len(c.reads) > 0),
			"%s: said=%v for %q, want %v",
			c.name,
			said,
			language,
			len(c.reads) > 0,
		)
		testing.expectf(t, language == c.reads, "%s: read %q, want %q", c.name, language, c.reads)
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

// `{"a_key_from_2027": [[[...]]], "transcription": [one good Cue]}` -- the
// nesting sits under a key this parser ignores, so a document that is accepted
// is accepted WITH its Cue, and depth is the only thing these cases vary.
@(private)
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

// A8, and the one input that cannot be reported through the error return at
// all. `core:encoding/json` is a recursive descent with no depth limit, so
// nesting deep enough runs the thread off its stack and takes the PROCESS down
// -- 0xC00000FD, no return value, no report, nothing for a caller to catch.
// The only place to stop it is before the decoder sees the text.
@(test)
refuses_nesting_that_would_crash_the_decoder :: proc(t: ^testing.T) {
	// Past the depth recorded at MAX_JSON_DEPTH as the one that ended the run
	// rather than failing it, and an order of magnitude past the limit itself.
	deep := nested_engine_json(800, context.allocator)
	defer delete(deep, context.allocator)

	cues, err := parse_cues("deep.json", deep, FIXTURE_DURATION, context.allocator)
	defer destroy_cues(cues, context.allocator)

	testing.expect(t, len(cues) == 0, "handed back cues from a file that cannot be decoded")
	testing.expect_value(t, err.fault, Parse_Fault.Too_Deeply_Nested)
	testing.expect_value(t, err.json_name, "deep.json")
}

// The negative space of that limit (CLAUDE.md A3). A ceiling low enough to be
// safe is only useful while everything the Engine can write stays under it, and
// a check written with the wrong comparison refuses a document it should read.
@(test)
accepts_nesting_up_to_the_limit :: proc(t: ^testing.T) {
	// The root object is one level, so this is the deepest inner array that
	// still fits under the limit -- and one past it is the first that does not.
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
	testing.expect(
		t,
		strings.contains(message, "third.json"),
		"the report does not name the input",
	)
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
	testing.expect(
		t,
		strings.contains(message, "all-zero.json"),
		"the report does not name the input",
	)
	testing.expect(t, strings.contains(message, "cue 2"), "the report does not name the cue")
}

// The negative space of the check above (CLAUDE.md A3), on both sides of it.
//
// A Recording whose length the shell could not settle arrives as nothing at
// all, and a comparison against an unknown has nothing to say -- inventing a
// failure out of missing information is how a working Recording gets
// quarantined forever. A Recording MEASURED at zero is a different statement
// with the same answer: a Cue set covering none of it covers all of it.
//
// The two are separate cases because the type keeps them separate. They shared
// one spelling while an unmeasured Recording arrived as the number zero.
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

// ---------------------------------------------------------------------------
// What ADR-0002 does about each fault.
//
// "A validated JSON that fails to parse is treated as ABSENT: quarantine it and
// re-run the full pipeline, rather than reporting a permanent failure. Exit 0
// but no or empty output is a hard per-Recording failure." The fault's own name
// does not say which side it falls on, and a caller that had to work it out
// would work it out with a switch in another package that nothing keeps in step
// with this enumeration.
// ---------------------------------------------------------------------------

@(test)
every_fault_says_what_adr_0002_does_with_it :: proc(t: ^testing.T) {
	// The three the ADR calls a hard per-Recording failure: the Engine exited
	// having transcribed nothing, and re-running it transcribes nothing again.
	// Everything else is a file that is not what the Engine writes, which says
	// nothing about whether the Engine can write it.
	hard := []Parse_Fault{.Empty_Input, .No_Cues, .Nothing_Said}

	for fault in Parse_Fault {
		if fault == .None {
			continue
		}
		want := Disposition.Quarantine_And_Rerun
		if slice.contains(hard, fault) {
			want = .Fail_The_Recording
		}
		got := disposition_of(fault)
		testing.expectf(t, got == want, "%v is %v, want %v", fault, got, want)
	}
}

// And the two the parser really produces for it, reached through the parser
// rather than read off the table the answer comes from.
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
// operating error naming the Cue that does it (CLAUDE.md A8) -- the three
// shapes that can be are rows in REJECTED_CASES below. What parse_cues then
// ASSERTS is its own promise about what it hands back, which is a different
// claim reached by a different route (A4), and that is what this observes.
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// The ugly cases, as two tables.
//
// At package scope rather than inside the tests that read them. A table is
// DATA, and data written into a procedure body is what carried both of these
// past the 70-line limit (CLAUDE.md F1) -- which exempts nothing, tests
// included. What is left below each table is the test: the same four questions
// asked of every row.
// ---------------------------------------------------------------------------

// One shape the parser must accept, and the Cues it must produce from it.
@(private)
Accepted_Case :: struct {
	name:     string,
	json:     string,
	expected: []Cue,
}

// Everything here is Engine output a Recording can genuinely produce, and every
// one of them is a shape some stricter-looking parser gets wrong.
@(private, rodata)
ACCEPTED_CASES := []Accepted_Case {
	{
		name = "single-cue.json",
		json = `{"transcription": [{"offsets": {"from": 0, "to": 3480}, "text": " Alone."}]}`,
		expected = []Cue{{0, 3_480, " Alone."}},
	},
	{
		// The Engine emits these over silence. Dropping them shortens the
		// Cue set the repetition filter downstream counts runs in, and a
		// run it cannot see is a hallucination it cannot strip (ADR-0001).
		name     = "empty-text.json",
		json     = `{"transcription": [
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
		name     = "overlapping.json",
		json     = `{"transcription": [
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
		name     = "unexpected-fields.json",
		json     = `{
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
		name     = "disagreeing-timestamps.json",
		json     = `{"transcription": [{
			"timestamps": {"from": "00:00:11,111", "to": "00:00:22,222"},
			"offsets": {"from": 4380, "to": 8440},
			"text": " Words."
		}]}`,
		expected = []Cue{{4_380, 8_440, " Words."}},
	},
	{
		// The other half of read_millis' trap. Nothing here asks
		// core:encoding/json for integers, so every offset in every case
		// above arrives as a json.Float already -- these are the spellings
		// that would ALSO have been Floats under `parse_integers`, and an
		// Engine release that starts writing them this way must read the
		// same as the plain ones do.
		name     = "float-offsets.json",
		json     = `{"transcription": [
			{"offsets": {"from": 0.0,    "to": 3480.0}, "text": " one"},
			{"offsets": {"from": 4.38e3, "to": 8440e0}, "text": " two"}
		]}`,
		expected = []Cue{{0, 3_480, " one"}, {4_380, 8_440, " two"}},
	},
	{
		// The negative space of the range check (CLAUDE.md A3). 2^53 - 1 is
		// the limit and not one short of it, and the same value written with
		// a decimal point and without reads the same, because both spellings
		// arrive as the one f64 -- so a check written with the wrong
		// comparison rejects a value it should read, in either.
		name     = "offset-at-the-limit.json",
		json     = `{"transcription": [
			{"offsets": {"from": 0, "to": 9007199254740991},                "text": " one"},
			{"offsets": {"from": 9007199254740991, "to": 9007199254740991.0}, "text": " two"}
		]}`,
		expected = []Cue {
			{0, 9_007_199_254_740_991, " one"},
			{9_007_199_254_740_991, 9_007_199_254_740_991, " two"},
		},
	},
	{
		// Escapes are undone exactly once. Twice mangles a Transcript;
		// not at all leaves a literal backslash-n mid-sentence.
		name     = "escaped-text.json",
		json     = `{"transcription": [{"offsets": {"from": 0, "to": 1000},
			"text": " \"quoted\", a \\ backslash, and café."}]}`,
		expected = []Cue{{0, 1_000, ` "quoted", a \ backslash, and café.`}},
	},
	{
		// A bracket inside a string is text the Engine transcribed, and a
		// trailing backslash before the closing quote is an escaped
		// backslash and not an escaped quote. The depth scan runs over the
		// bytes ahead of the decoder, so a scan that could not tell either
		// of those would refuse a Recording for what was said in it.
		name     = "bracketed-text.json",
		json     = `{"transcription": [{"offsets": {"from": 0, "to": 1000},
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

// One shape the parser must refuse, and what it must say about it.
@(private)
Rejected_Case :: struct {
	name:  string,
	json:  string,
	fault: Parse_Fault,
	// The 1-based Cue the report must blame, or 0 where the fault is about the
	// input as a whole. Stated on every row, including the zero: a row that
	// left it out would pass whatever the parser blamed.
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
	{
		// "Exit 0 but nothing transcribed" is a per-Recording failure, not
		// a Transcript with no words in it (ADR-0002).
		name  = "no-cues.json",
		json  = `{"transcription": []}`,
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
		name  = "offset-as-text.json",
		json  = `{"transcription": [{"offsets": {"from": "00:00:00,000", "to": "00:00:03,480"},
			"text": " one"}]}`,
		fault = .Offset_Not_A_Number,
		cue   = 1,
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
		name  = "offset-out-of-range.json",
		json  = `{"transcription": [{"offsets": {"from": 0, "to": 1e300}, "text": " one"}]}`,
		fault = .Offset_Out_Of_Range,
		cue   = 1,
	},
	{
		// The same magnitude written WITHOUT a decimal point. Under
		// `parse_integers` the tokenizer classifies this one as an integer,
		// core:encoding/json reads it with strconv.parse_i64 and DISCARDS
		// the error, and the overflow arrives as a plausible small number --
		// 2e17 or so, about six million years -- rather than as a refusal. A
		// corrupt cache file is ADR-0002's explicit case, and this one used
		// to parse.
		name  = "integer-offset-overflows.json",
		json  = `{"transcription": [{"offsets": {"from": 0, "to": 99999999999999999999999},
			"text": " one"}]}`,
		fault = .Offset_Out_Of_Range,
		cue   = 1,
	},
	{
		// The same overflow written so that it wraps back INSIDE the limit:
		// 2^64 + 5000, which strconv.parse_i64 reports as 5000 with
		// ok = true. No range check can see that one -- 5000 is an ordinary
		// offset, and the token text is the only thing that ever knew
		// otherwise. It is refused here because nobody asks
		// core:encoding/json for an integer, so the magnitude arrives as the
		// float 1.8446744073709556e19 with nothing wrapped away.
		name  = "integer-offset-wraps-into-range.json",
		json  = `{"transcription": [{"offsets": {"from": 0, "to": 18446744073709556616},
			"text": " one"}]}`,
		fault = .Offset_Out_Of_Range,
		cue   = 1,
	},
	{
		// One past the limit, which is 2^53 exactly: the first value where
		// the spacing between representable f64s becomes two, so it is also
		// what 9007199254740993 arrives as. Reading either one back would be
		// reading a number nobody wrote, and both are refused.
		name  = "offset-past-the-limit.json",
		json  = `{"transcription": [{"offsets": {"from": 0, "to": 9007199254740992}, "text": " one"}]}`,
		fault = .Offset_Out_Of_Range,
		cue   = 1,
	},
	{
		name = "offset-rounding-onto-the-limit.json",
		json = `{"transcription": [{"offsets": {"from": 0, "to": 9007199254740993}, "text": " one"}]}`,
		fault = .Offset_Out_Of_Range,
		cue = 1,
	},
	{
		// And below it, which Negative_Offset never sees: read_millis
		// refuses the magnitude before cue_follows is asked about the sign.
		name  = "offset-below-the-limit.json",
		json  = `{"transcription": [{"offsets": {"from": -9007199254740992, "to": 0}, "text": " one"}]}`,
		fault = .Offset_Out_Of_Range,
		cue   = 1,
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

	// The three ways Engine output can break the ordering this package
	// promises. Every one of them is REPORTED, naming the Cue that does it,
	// because the Engine is outside this program (A8); what parse_cues asserts
	// on the way out is a different claim by a different route (A4), and
	// real_engine_output_is_ordered_on_the_way_out is where that is observed.
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
		// An offset is a count from the start of the Recording, so there is
		// nothing before zero for a Cue to start in.
		name  = "negative.json",
		json  = `{"transcription": [{"offsets": {"from": -500, "to": 4000}, "text": " early"}]}`,
		fault = .Negative_Offset,
		cue   = 1,
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

		// Every rejection renders, and every rendering names the input: a fault
		// added without a row in FAULT trips the assertion inside.
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
