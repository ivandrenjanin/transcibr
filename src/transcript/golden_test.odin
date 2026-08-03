package transcript

import "core:mem"
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
// output can settle (ADR-0001). Every case reads it out of the document it is
// about to render and never out of the pristine fixture, which is what lets the
// schema table below move it -- a release that renames `result` renders a
// complete Transcript recording that nobody settled the language, and the row
// for it is the only row in that table about a key the Cues do not live under.
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
	detected := parse_language(ENGINE_JSON, context.allocator)
	defer delete(detected, context.allocator)

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
	what:     string,
	from:     string,
	to:       string,
	// .None means the change must be ACCEPTED and render the golden with the
	// language below written into it.
	fault:    Parse_Fault,
	// What the CHANGED document still settles about the detected language.
	//
	// Read out of the mutated document by the test, the way the shell reads it
	// out of the file it is about to render. Read out of the PRISTINE fixture
	// instead -- which is what this did -- no row in this table could move the
	// one front matter field the Engine's own output settles, and the row below
	// that renames `result` would have been checked against a language it could
	// not possibly have affected.
	language: string,
}

@(private, rodata)
SCHEMA_CHANGES := []Schema_Change {
	{
		what = "the transcription array renamed",
		from = `"transcription"`,
		to = `"segments"`,
		fault = .No_Transcription,
		language = "en",
	},
	{
		what = "the offsets object renamed",
		from = `"offsets"`,
		to = `"spans"`,
		fault = .No_Offsets,
		language = "en",
	},
	{
		what = "the text field renamed",
		from = `"text"`,
		to = `"words"`,
		fault = .No_Text,
		language = "en",
	},
	{
		what = "the start offset renamed",
		from = `"from"`,
		to = `"begin"`,
		fault = .Offset_Missing,
		language = "en",
	},
	{
		what = "the end offset removed",
		from = `"to": 3480`,
		to = `"unused": 3480`,
		fault = .Offset_Missing,
		language = "en",
	},
	{
		// The shape that would otherwise ship: offsets arriving as the
		// `hh:mm:ss,mmm` text the Engine already writes beside them. Guessing at
		// what it meant is how a schema change becomes a Transcript full of
		// plausible wrong timings.
		what     = "an offset retyped from a number to a string",
		from     = `"from": 0,`,
		to       = `"from": "0",`,
		fault    = .Offset_Not_A_Number,
		language = "en",
	},
	{
		// THE NEGATIVE SPACE (CLAUDE.md A3). A field the Engine ADDS must render
		// exactly as before: `-ojf` already adds a per-token array to every Cue,
		// and refusing an unrecognised key would turn every Engine upgrade into a
		// corrupt Transcript (ADR-0001).
		what     = "a field added to a cue",
		from     = `"text": " This is a recording`,
		to       = `"confidence": 0.98, "text": " This is a recording`,
		fault    = .None,
		language = "en",
	},
	{
		// The row this table could not previously hold, and the only one that
		// moves a FRONT MATTER field rather than a Cue. `result` is where the
		// Engine writes what it detected (ADR-0001), and it is the one fact that
		// output settles.
		//
		// ACCEPTED, and deliberately so. Refusing a Recording because a key the
		// Cues do not live under moved would turn an Engine upgrade into a failed
		// Recording, which is the mistake ADR-0001 warns about; and ADR-0003 says
		// absent provenance beats wrong provenance. So the Transcript is rendered
		// in full, every other byte of it unchanged, and it records that nobody
		// settled the language.
		what     = "the result object renamed",
		from     = `"result"`,
		to       = `"outcome"`,
		fault    = .None,
		language = UNKNOWN,
	},
}

@(test)
an_engine_schema_change_is_refused_rather_than_rendered_empty :: proc(t: ^testing.T) {
	for c in SCHEMA_CHANGES {
		// The allocated flag is READ, not discarded. replace_all hands the input
		// straight back when nothing matched, and freeing that frees the embedded
		// fixture itself -- golden_reading below documents the identical hazard and
		// handles it, and the row that reaches it here is exactly the one the check
		// beneath this reports.
		changed, allocated := strings.replace_all(ENGINE_JSON, c.from, c.to, context.allocator)
		defer if allocated {
			delete(changed, context.allocator)
		}

		// The mutation itself, checked before what it produces: a `from` that
		// matched nothing would leave every row below testing the untouched
		// fixture and passing for it.
		if !testing.expectf(t, changed != ENGINE_JSON, "%s: changed nothing", c.what) {
			continue
		}

		// Out of the document under test and never out of the pristine one, so a
		// change that moves the detected language is a change this table can see.
		detected := parse_language(changed, context.allocator)
		defer delete(detected, context.allocator)
		testing.expectf(
			t,
			detected == c.language,
			"%s: the language reads %q, want %q",
			c.what,
			detected,
			c.language,
		)

		markdown, err := render_transcript(
			"upgraded.json",
			changed,
			FIXTURE_DURATION,
			golden_context(.Monologue, detected),
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
			want := golden_reading(c.language, context.allocator)
			defer delete(want, context.allocator)
			testing.expectf(t, markdown == want, "%s: changed the transcript", c.what)
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

// The golden, with the one field a schema change can move written as the row
// says and every other byte of it exactly as committed.
//
// A substitution and not a second fixture: what the row claims is that ONLY the
// language moved, and a second committed document would let anything else move
// with it unnoticed.
@(private)
golden_reading :: proc(language: string, allocator: mem.Allocator) -> (document: string) {
	assert(len(language) > 0, "a front matter field nobody settled is UNKNOWN, never empty")
	// The golden is what the fixture renders as, and the fixture says `en`. Said
	// here rather than left to a comparison to fail confusingly: a substitution
	// that matched nothing hands the golden straight back and would pass every
	// accepted row for the wrong reason (CLAUDE.md A6).
	assert(
		strings.contains(GOLDEN_MONOLOGUE, `language: "en"`),
		"the golden carries no language line to move",
	)

	line := strings.concatenate({`language: "`, language, `"`}, allocator)
	defer delete(line, allocator)

	// ALWAYS a document of its own, whatever the substitution did. replace_all
	// hands the input straight back when the two spellings are the same, and a
	// caller freeing that would free the embedded fixture itself.
	replaced, allocated := strings.replace_all(GOLDEN_MONOLOGUE, `language: "en"`, line, allocator)
	if !allocated {
		return strings.clone(GOLDEN_MONOLOGUE, allocator)
	}
	return replaced
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
	//
	// Written as JSON's own escapes and never as the raw bytes. RFC 8259 forbids
	// an unescaped U+0000-U+001F inside a string, so the raw form made this row's
	// own claim to be well-formed JSON false -- and it was invisible in an editor
	// and in every diff, which is the harder half: a byte nobody can see is not
	// something a reviewer can check, and this table is evidence.
	`{"transcription": [{"offsets": {"from": 0, "to": 30000}, "text": " \u0001\u007f "}]}`,
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

// A byte nobody said inside a Cue too long to admit whole, through the WHOLE
// pipeline and under a shipped profile.
//
// merge_paragraphs has the case that isolates this; what this adds is the route
// a Recording really takes. The core is what both binaries call, so a Cue like
// this took the whole Batch down and not merely one command line -- and the
// Engine writes long Cues and stray bytes without being provoked.
//
// The Cue is built against the profile's OWN cap rather than a number written
// out beside it: what is pinned is that a carve landing on a byte nobody said
// renders, not any particular arithmetic in a threshold ADR-0007 expects to be
// tuned.
@(test)
a_byte_nobody_said_inside_a_carved_cue_still_renders :: proc(t: ^testing.T) {
	room := profile_params(.Conversation).max_para_chars
	if !testing.expect(t, room > 0, "the aggressive profile holds no characters at all") {
		return
	}

	// Two runs of speech, each of them as long as the cap, either side of one
	// byte a reader cannot see -- so the merger has to carve, and the second
	// carve is offered speech opening on that byte.
	said := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&said)
	strings.write_string(&said, `{"transcription":[{"offsets":{"from":0,"to":1000},"text":" `)
	for _ in 0 ..< room {
		strings.write_byte(&said, 'a')
	}
	strings.write_string(&said, ` \u0001 `)
	for _ in 0 ..< room {
		strings.write_byte(&said, 'b')
	}
	strings.write_string(&said, `"}]}`)

	markdown, err := render_transcript(
		"carved.json",
		strings.to_string(said),
		nil,
		golden_context(.Conversation, "en"),
		context.allocator,
	)
	defer delete(markdown, context.allocator)

	if !testing.expect_value(t, err.fault, Parse_Fault.None) {
		return
	}
	// Every letter that was said arrives, and the byte nobody said does not.
	// Counted off the BODY, because the front matter carries letters of its own.
	body := body_of(markdown)
	testing.expect_value(t, strings.count(body, "a"), room)
	testing.expect_value(t, strings.count(body, "b"), room)
	testing.expect(t, !strings.contains(body, "\x01"), "a control byte reached the document")
	// And no Paragraph came back as Markdown's own indentation, which is what a
	// line of prose that flattened away to a run of spaces reads as.
	testing.expect(t, !strings.has_prefix(body, " "), "the first line of prose opens on a space")
	testing.expect(t, !strings.contains(body, "\n "), "a line of the document opens on a space")
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
	detected := parse_language(ENGINE_JSON, context.allocator)
	defer delete(detected, context.allocator)
	rc := golden_context(.Conversation, detected)

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
