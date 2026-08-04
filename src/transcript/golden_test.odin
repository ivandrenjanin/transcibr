#+vet explicit-allocators
package transcript

import "core:mem"
import "core:strings"
import "core:testing"

// Why the whole document is compared, front matter included: ADR-0009.
@(private)
GOLDEN_MONOLOGUE :: #load("fixtures/engine-output.monologue.md", string)
@(private)
GOLDEN_CONVERSATION :: #load("fixtures/engine-output.conversation.md", string)

// `language` is left empty here and filled in by each case out of the document it
// is about to render: it is the one front matter fact the Engine's output settles.
@(private)
GOLDEN_CONTEXT :: Render_Context {
	now            = SAMPLE_INSTANT,
	source_display = "engine-output.mp4",
	engine_version = "whisper.cpp 1.9.1",
	model          = "ggml-large-v3-turbo.bin",
	profile        = .Monologue,
}

@(private)
@(require_results)
golden_context :: proc(profile: Merge_Profile, language: string) -> Render_Context {
	assert(len(language) > 0, "a front matter field nobody settled is UNKNOWN, never empty")

	rc := GOLDEN_CONTEXT
	rc.profile = profile
	rc.language = language
	return rc
}

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
	testing.expect_value(t, paragraphs_in(GOLDEN_MONOLOGUE), 1)
	testing.expect_value(t, paragraphs_in(GOLDEN_CONVERSATION), 7)
}

@(private)
@(require_results)
paragraphs_in :: proc(markdown: string) -> int {
	body := body_of(markdown)
	if len(body) == 0 {
		return 0
	}
	return strings.count(body, "\n\n") + 1
}

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

@(private)
Schema_Change :: struct {
	what:     string,
	from:     string,
	to:       string,
	// .None means the change must be ACCEPTED and render the golden with the
	// language below written into it.
	fault:    Parse_Fault,
	// What the CHANGED document settles, read out of the mutation and never out
	// of the pristine fixture.
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
		what = "an offset retyped from a number to a string",
		from = `"from": 0,`,
		to = `"from": "0",`,
		fault = .Offset_Not_A_Number,
		language = "en",
	},
	{
		// The Engine's own `-ojf` adds a per-token array to every Cue, so an
		// unrecognised key is an upgrade rather than a corruption.
		what     = "a field added to a cue",
		from     = `"text": " This is a recording`,
		to       = `"confidence": 0.98, "text": " This is a recording`,
		fault    = .None,
		language = "en",
	},
	{
		// Accepted: absent provenance beats a Recording failed over a key no Cue
		// lives under (ADR-0003).
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
		changed, allocated := strings.replace_all(ENGINE_JSON, c.from, c.to, context.allocator)
		defer if allocated {
			delete(changed, context.allocator)
		}

		if !testing.expectf(t, changed != ENGINE_JSON, "%s: changed nothing", c.what) {
			continue
		}

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
		testing.expectf(
			t,
			len(markdown) == 0,
			"%s: rendered %d bytes anyway",
			c.what,
			len(markdown),
		)
	}
}

// A substitution rather than a second committed fixture: what the row claims is
// that ONLY the language moved.
@(private)
@(require_results)
golden_reading :: proc(language: string, allocator: mem.Allocator) -> (document: string) {
	assert(len(language) > 0, "a front matter field nobody settled is UNKNOWN, never empty")
	assert(
		strings.contains(GOLDEN_MONOLOGUE, `language: "en"`),
		"the golden carries no language line to move",
	)

	line := strings.concatenate({`language: "`, language, `"`}, allocator)
	defer delete(line, allocator)

	replaced, allocated := strings.replace_all(GOLDEN_MONOLOGUE, `language: "en"`, line, allocator)
	if !allocated {
		return strings.clone(GOLDEN_MONOLOGUE, allocator)
	}
	return replaced
}

// `.No_Cues` fires on an empty `transcription` array and never on a set full of
// Cues none of which said anything, which is what silence, music and a dead audio
// track all produce.
@(private, rodata)
SILENT_OUTPUTS := []string {
	`{"transcription": [
		{"offsets": {"from": 0,     "to": 5000},  "text": " "},
		{"offsets": {"from": 5000,  "to": 10000}, "text": ""},
		{"offsets": {"from": 10000, "to": 30000}, "text": "   "}
	]}`,
	`{"transcription": [{"offsets": {"from": 0, "to": 30000}, "text": ""}]}`,
	// The same two bytes as SILENCE_AS_BYTES, in JSON's own escapes rather than
	// raw: RFC 8259 forbids an unescaped U+0000-U+001F inside a string, so the raw
	// form made this row's own claim to be well-formed JSON false.
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
		testing.expectf(t, len(markdown) == 0, "case %d: rendered %d bytes", i, len(markdown))
		testing.expectf(
			t,
			disposition_of(err.fault) == .Fail_The_Recording,
			"case %d would be re-run forever",
			i,
		)
	}
}

// Built against the profile's OWN cap rather than a number beside it, so what is
// pinned is the carve and not a threshold ADR-0007 expects to be tuned.
@(test)
a_byte_nobody_said_inside_a_carved_cue_still_renders :: proc(t: ^testing.T) {
	room := profile_params(.Conversation).max_para_chars
	if !testing.expect(t, room > 0, "the aggressive profile holds no characters at all") {
		return
	}

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
	body := body_of(markdown)
	testing.expect_value(t, strings.count(body, "a"), room)
	testing.expect_value(t, strings.count(body, "b"), room)
	testing.expect(t, !strings.contains(body, "\x01"), "a control byte reached the document")
	testing.expect(t, !strings.has_prefix(body, " "), "the first line of prose opens on a space")
	testing.expect(t, !strings.contains(body, "\n "), "a line of the document opens on a space")
}

// A check refusing every Cue set holding any silence would refuse the golden
// fixture itself, whose seventh Cue is the Engine talking over trailing silence.
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
	testing.expect(t, raw_data(first) != raw_data(second), "the two renders share one buffer")
	testing.expect(t, first == second, "rendering the same input twice gave two documents")
}
