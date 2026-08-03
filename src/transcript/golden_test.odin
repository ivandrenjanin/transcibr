package transcript

import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------
// THE GOLDEN FIXTURE: one real Engine output beside the Markdown it must render
// as, compared IN FULL -- front matter included, not stripped first.
//
// Stripping the header is the shortcut ADR-0009 was written to refuse. It is
// what a renderer reaching for the clock, the environment and a machine-specific
// path forces on the comparison, and it takes the entire metadata block out of
// test coverage, so a malformed YAML block ships into every Transcript and
// nothing notices. Passing those in as a Render Context is what makes the header
// the most-tested part of the output rather than the least.
//
// It also pins the JSON schema this design bets on (ADR-0001): a shape change in
// the Engine's output fails HERE, rather than showing up as Transcripts that are
// quietly empty. The table beneath these two cases is where that is exercised
// one field at a time.
// ---------------------------------------------------------------------------

// What the same Engine output renders as under each Merge Profile.
//
// Two documents from ONE Engine output, which is the point rather than a
// duplicate: spec story 43 asks to change the Merge Profile and re-render, and
// these are the two answers. Between them they also show the Anchor rule holding
// on real Cues -- seven Cues become one Paragraph under the generous profile and
// seven under the aggressive one, and BOTH carry exactly one Anchor.
//
// Committed with LF endings under `**/fixtures/** -text`, so what is compared is
// what was written rather than whatever a checkout made of it.
//
// Deliberately NOT carrying a byte-length #assert the way ENGINE_JSON does. That
// one guards evidence nobody edits; these are expected output, edited on purpose
// whenever rendering changes on purpose, and a length maintained beside them
// would be a second copy of the same claim that has to be updated in the same
// commit. What the length assert buys there -- noticing a rewritten checkout --
// is bought here by the comparison itself and by no_golden_transcript_carries_a_carriage_return.
@(private)
GOLDEN_MONOLOGUE :: #load("fixtures/engine-output.monologue.md", string)
@(private)
GOLDEN_CONVERSATION :: #load("fixtures/engine-output.conversation.md", string)

// The Render Context the goldens were rendered under.
//
// The source is named for the stem the artefacts share (ADR-0008): a Recording
// at `<dir>/<stem>.<ext>` produces `<dir>/<stem>.md` beside its retained Engine
// output. The Engine version is the release this fixture was actually captured
// from, and the Model is what transcibr's own record would hold -- never the
// bare `large` the Engine reports (ADR-0003).
//
// `language` is left empty here and filled in from the Engine's own output by
// each case below, which is deliberate: it is the one front matter fact that
// output can settle (ADR-0001), so a release that renames `result` shows up in
// these bytes rather than nowhere.
@(private)
GOLDEN_CONTEXT :: Render_Context {
	now            = SAMPLE_INSTANT,
	source_display = "engine-output.mp4",
	engine_version = "whisper.cpp 1.9.1",
	model          = "ggml-large-v3-turbo.bin",
	profile        = .Monologue,
}

// The Render Context for one profile, with the detected language read out of the
// Engine output rather than spelled again beside it.
@(private)
golden_context :: proc(profile: Merge_Profile, language: string) -> Render_Context {
	assert(len(language) > 0, "a front matter field nobody settled is UNKNOWN, never empty")

	rc := GOLDEN_CONTEXT
	rc.profile = profile
	rc.language = language
	return rc
}

// One Merge Profile and the document the fixture must render as under it.
@(private)
Golden_Case :: struct {
	profile:  Merge_Profile,
	expected: string,
}

@(private, rodata)
GOLDEN_CASES := []Golden_Case {
	{profile = .Monologue, expected = GOLDEN_MONOLOGUE},
	{profile = .Conversation, expected = GOLDEN_CONVERSATION},
}

@(test)
real_engine_output_renders_as_the_golden_transcript :: proc(t: ^testing.T) {
	language, said := parse_language(ENGINE_JSON, context.allocator)
	defer if said {
		delete(language, context.allocator)
	}
	detected := said ? language : UNKNOWN

	for c in GOLDEN_CASES {
		rc := golden_context(c.profile, detected)
		markdown, err := render_transcript(
			"engine-output.json",
			ENGINE_JSON,
			FIXTURE_DURATION,
			rc,
			context.allocator,
		)
		defer delete(markdown, context.allocator)

		if !testing.expectf(t, err.fault == .None, "%v: rejected with %v", c.profile, err.fault) {
			continue
		}
		// The whole document in one comparison, header and all. A failure prints
		// both, which is what makes a golden worth having.
		testing.expectf(
			t,
			markdown == c.expected,
			"%v rendered:\n%s\n--- want ---\n%s",
			c.profile,
			markdown,
			c.expected,
		)
	}
}

// What the goldens demonstrate that no synthetic Paragraph set can: the Anchor
// rule holding over real Cues. Seven Cues, one Anchor, under both profiles --
// including the one that makes a Paragraph of every Cue.
@(test)
seven_cues_carry_one_anchor_under_either_profile :: proc(t: ^testing.T) {
	for c in GOLDEN_CASES {
		testing.expectf(
			t,
			anchors_in(c.expected) == 1,
			"%v: the golden carries %d anchors over half a minute of recording",
			c.profile,
			anchors_in(c.expected),
		)
	}
	// And the paragraphing the two profiles are FOR (ADR-0007), read off the
	// goldens rather than off a run of the merger: the same seven Cues are one
	// Paragraph under the generous profile and seven under the aggressive one.
	// Seven Paragraphs and ONE Anchor is the acceptance criterion in one line.
	testing.expect_value(t, paragraphs_in(GOLDEN_MONOLOGUE), 1)
	testing.expect_value(t, paragraphs_in(GOLDEN_CONVERSATION), 7)
}

// How many prose blocks a rendered Transcript's body holds.
@(private)
paragraphs_in :: proc(markdown: string) -> int {
	body := body_of(markdown)
	if len(body) == 0 {
		return 0
	}
	// Blocks stand one blank line apart and the document ends with a single
	// newline, so there is one more block than there are separations.
	return strings.count(body, "\n\n") + 1
}

// The tripwire ENGINE_JSON's byte-length #assert is for, stated as the property
// it actually guards rather than as a number: `#load` embeds whatever is on
// disk, so a checkout that rewrote these files' line endings would compare a
// different document under the same name.
@(test)
no_golden_transcript_carries_a_carriage_return :: proc(t: ^testing.T) {
	for c in GOLDEN_CASES {
		testing.expectf(
			t,
			strings.index_byte(c.expected, '\r') == -1,
			"%v: the golden was checked out with rewritten line endings",
			c.profile,
		)
	}
}

// ---------------------------------------------------------------------------
// THE SCHEMA CRITERION: an Engine release that changes the shape of its output
// is caught here, rather than by Transcripts that are quietly empty.
//
// One field at a time, applied to the REAL fixture so that everything except the
// change under test is exactly what the Engine wrote. Each row states what the
// change is and what it must be refused as -- never merely "it failed", because
// a mutation that broke the JSON syntax instead would pass a weaker check while
// testing nothing about the schema.
// ---------------------------------------------------------------------------

// One change to the Engine's output, and what rendering must do about it.
@(private)
Schema_Change :: struct {
	what:  string,
	from:  string,
	to:    string,
	// .None means the change must be ACCEPTED and render the golden unchanged.
	fault: Parse_Fault,
}

@(private, rodata)
SCHEMA_CHANGES := []Schema_Change {
	{
		what = "the transcription array renamed",
		from = `"transcription"`,
		to = `"segments"`,
		fault = .No_Transcription,
	},
	{what = "the offsets object renamed", from = `"offsets"`, to = `"spans"`, fault = .No_Offsets},
	{what = "the text field renamed", from = `"text"`, to = `"words"`, fault = .No_Text},
	{what = "the start offset renamed", from = `"from"`, to = `"begin"`, fault = .Offset_Missing},
	{
		what = "the end offset removed",
		from = `"to": 3480`,
		to = `"unused": 3480`,
		fault = .Offset_Missing,
	},
	{
		// The shape that would otherwise ship: offsets arriving as the
		// `hh:mm:ss,mmm` text the Engine already writes beside them. Guessing at
		// what it meant is how a schema change becomes a Transcript full of
		// plausible wrong timings.
		what  = "an offset retyped from a number to a string",
		from  = `"from": 0,`,
		to    = `"from": "0",`,
		fault = .Offset_Not_A_Number,
	},
	{
		// THE NEGATIVE SPACE (CLAUDE.md A3). A field the Engine ADDS must render
		// exactly as before: `-ojf` already adds a per-token array to every Cue,
		// and refusing an unrecognised key would turn every Engine upgrade into a
		// corrupt Transcript (ADR-0001).
		what  = "a field added to a cue",
		from  = `"text": " This is a recording`,
		to    = `"confidence": 0.98, "text": " This is a recording`,
		fault = .None,
	},
}

@(test)
an_engine_schema_change_is_refused_rather_than_rendered_empty :: proc(t: ^testing.T) {
	language, said := parse_language(ENGINE_JSON, context.allocator)
	defer if said {
		delete(language, context.allocator)
	}
	rc := golden_context(.Monologue, said ? language : UNKNOWN)

	for c in SCHEMA_CHANGES {
		changed, _ := strings.replace_all(ENGINE_JSON, c.from, c.to, context.allocator)
		defer delete(changed, context.allocator)

		// The mutation itself, checked before what it produces: a `from` that
		// matched nothing would leave every row below testing the untouched
		// fixture and passing for it.
		if !testing.expectf(t, changed != ENGINE_JSON, "%s: changed nothing", c.what) {
			continue
		}

		markdown, err := render_transcript(
			"upgraded.json",
			changed,
			FIXTURE_DURATION,
			rc,
			context.allocator,
		)
		defer delete(markdown, context.allocator)

		testing.expectf(
			t,
			err.fault == c.fault,
			"%s: gave %v, want %v",
			c.what,
			err.fault,
			c.fault,
		)
		if c.fault == .None {
			testing.expectf(t, markdown == GOLDEN_MONOLOGUE, "%s: changed the transcript", c.what)
			continue
		}
		// The whole of the criterion: caught, rather than handed to a reader as a
		// Transcript with nothing in it.
		testing.expectf(
			t,
			len(markdown) == 0,
			"%s: rendered %d bytes anyway",
			c.what,
			len(markdown),
		)
	}
}

// ---------------------------------------------------------------------------
// THE OTHER SILENT SUCCESS, and the one no schema change can reach: Engine
// output that is perfectly well-formed and says nothing at all.
//
// `.No_Cues` fires on an empty `transcription` ARRAY and never on a set that is
// full of Cues none of which said anything -- and the Engine writes empty and
// space-only Cues over silence, so a Recording of silence, of music, or of a
// dead audio track produces exactly that shape. What came out was 234 bytes of
// front matter at exit 0: a header with no Transcript under it, which is the
// "silently empty Transcript" this ticket's own criterion names as the enemy.
//
// NOT spec story 41, which is a different question deliberately left alone here.
// That one is about a Recording that produced ALMOST no text -- a threshold, a
// comparison against the Recording's length, and a judgement about how little is
// too little. This is about NONE, which needs no threshold to see: there is no
// prose to write, so there is no Transcript, and ADR-0002 already calls "exit 0
// but no or empty output" a hard per-Recording failure.
// ---------------------------------------------------------------------------

// Well-formed Engine output holding not one Saying, in the shapes the Engine
// really writes over silence.
@(private, rodata)
SILENT_OUTPUTS := []string {
	`{"transcription": [
		{"offsets": {"from": 0,     "to": 5000},  "text": " "},
		{"offsets": {"from": 5000,  "to": 10000}, "text": ""},
		{"offsets": {"from": 10000, "to": 30000}, "text": "   "}
	]}`,
	// One Cue and nothing in it, which is what a dead audio track produces.
	`{"transcription": [{"offsets": {"from": 0, "to": 30000}, "text": ""}]}`,
	// Bytes a text editor renders as nothing at all. Well-formed JSON, a Cue
	// that is not empty, and still nobody said anything.
	`{"transcription": [{"offsets": {"from": 0, "to": 30000}, "text": "  "}]}`,
}

@(test)
a_recording_nobody_said_anything_in_is_refused_rather_than_rendered_empty :: proc(t: ^testing.T) {
	rc := golden_context(.Monologue, UNKNOWN)
	for text, i in SILENT_OUTPUTS {
		markdown, err := render_transcript(
			"silence.json",
			text,
			FIXTURE_DURATION,
			rc,
			context.allocator,
		)
		defer delete(markdown, context.allocator)

		testing.expectf(t, err.fault == .Nothing_Said, "case %d: accepted with %v", i, err.fault)
		// The whole of the criterion: caught, rather than handed to a reader as a
		// document that is nothing but its own header.
		testing.expectf(t, len(markdown) == 0, "case %d: rendered %d bytes", i, len(markdown))
		// And re-running the Engine on it transcribes silence again, so this is a
		// Recording to fail rather than a file to quarantine (ADR-0002).
		testing.expectf(
			t,
			disposition_of(err.fault) == .Fail_The_Recording,
			"case %d would be re-run forever",
			i,
		)
	}
}

// The negative space of that (CLAUDE.md A3), and it is not a formality: a check
// that refused every Cue set holding ANY silence would refuse the golden
// fixture, whose seventh Cue is the Engine talking over the trailing silence.
// One Saying among the silence is a Transcript.
@(test)
one_saying_among_the_silence_is_still_a_transcript :: proc(t: ^testing.T) {
	text := `{"transcription": [
		{"offsets": {"from": 0,     "to": 5000},  "text": " "},
		{"offsets": {"from": 5000,  "to": 10000}, "text": " Something was said."},
		{"offsets": {"from": 10000, "to": 30000}, "text": ""}
	]}`
	markdown, err := render_transcript(
		"nearly-silent.json",
		text,
		FIXTURE_DURATION,
		golden_context(.Monologue, UNKNOWN),
		context.allocator,
	)
	defer delete(markdown, context.allocator)

	testing.expect_value(t, err.fault, Parse_Fault.None)
	testing.expect(
		t,
		strings.contains(markdown, "Something was said."),
		"the one saying did not reach the document",
	)
}

// ---------------------------------------------------------------------------
// Determinism, which is what makes every comparison above mean anything.
// ---------------------------------------------------------------------------

@(test)
rendering_the_same_input_twice_is_byte_identical :: proc(t: ^testing.T) {
	language, said := parse_language(ENGINE_JSON, context.allocator)
	defer if said {
		delete(language, context.allocator)
	}
	rc := golden_context(.Conversation, said ? language : UNKNOWN)

	first, first_err := render_transcript(
		"engine-output.json",
		ENGINE_JSON,
		FIXTURE_DURATION,
		rc,
		context.allocator,
	)
	defer delete(first, context.allocator)
	second, second_err := render_transcript(
		"engine-output.json",
		ENGINE_JSON,
		FIXTURE_DURATION,
		rc,
		context.allocator,
	)
	defer delete(second, context.allocator)

	testing.expect_value(t, first_err.fault, Parse_Fault.None)
	testing.expect_value(t, second_err.fault, Parse_Fault.None)
	// Two separate documents, and the same bytes in both. Compared by CONTENT and
	// not by pointer, which is the claim spec story 44 makes when it says
	// re-rendering must produce the Transcript the original run would have.
	testing.expect(t, raw_data(first) != raw_data(second), "the two renders share one buffer")
	testing.expect(t, first == second, "rendering the same input twice gave two documents")
}
