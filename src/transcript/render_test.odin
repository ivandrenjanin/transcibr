package transcript

import "core:strings"
import "core:testing"
import "core:time"

// The instant every case below renders at: 2026-08-03T09:41:07Z, as a count of
// nanoseconds from the Unix epoch.
//
// A LITERAL, and worked out by hand rather than by asking core:time to convert
// one -- 20,668 days to the third of August 2026, plus nine hours forty-one and
// seven seconds. An expectation derived by running the same conversion the
// renderer runs can never disagree with it.
@(private)
SAMPLE_INSTANT :: time.Time {
	_nsec = 1_785_750_067 * 1_000_000_000,
}

// One Render Context, so every case is about what the renderer DOES with these
// rather than about assembling them. None of it is read from the world: that is
// the whole of ADR-0009, and the reason the front matter below can be compared
// byte for byte instead of stripped before comparison.
@(private)
SAMPLE_CONTEXT :: Render_Context {
	now            = SAMPLE_INSTANT,
	source_display = "interview.mp4",
	engine_version = "whisper.cpp 1.9.1",
	model          = "ggml-large-v3-turbo.bin",
	language       = "en",
	profile        = .Monologue,
}

// The front matter of a rendered Transcript, fences excluded, or "" where the
// document does not open with one.
//
// Cases assert against THIS and not against the whole document, so a field that
// landed in the prose instead of in the header fails rather than passing on a
// substring search that never cared where it was.
@(private)
front_matter_of :: proc(markdown: string) -> string {
	assert(len(markdown) > 0, "an empty document is not a transcript to read the header out of")

	opening := "---\n"
	if !strings.has_prefix(markdown, opening) {
		return ""
	}
	rest := markdown[len(opening):]
	closing := strings.index(rest, "\n---\n")
	if closing < 0 {
		return ""
	}
	return rest[:closing + 1]
}

// ---------------------------------------------------------------------------
// Front matter: what a Transcript found on its own months later says about
// itself (spec story 39), and what tells planning it is transcibr's own output
// rather than somebody's notes (ADR-0008).
// ---------------------------------------------------------------------------

@(test)
front_matter_records_how_the_transcript_was_made :: proc(t: ^testing.T) {
	paragraphs := []Paragraph{{0, 3_480, "The first thing said."}}
	out := render_markdown(paragraphs, SAMPLE_CONTEXT, ANCHOR_INTERVAL_MS, context.allocator)
	defer delete(out, context.allocator)

	block := front_matter_of(out)
	if !testing.expect(t, len(block) > 0, "the document does not open with a front matter block") {
		return
	}

	// The five facts spec story 39 names, plus the source and the clock read
	// ADR-0009 puts in the Render Context. The generator's VERSION is not pinned
	// here -- it moves with every release, and the golden fixture is where the
	// exact bytes belong; what this pins is the key and the program it names,
	// which is what ADR-0008 has planning look for.
	wanted := []string {
		`generator: "transcibr `,
		`source: "interview.mp4"`,
		`generated: "2026-08-03T09:41:07Z"`,
		`engine: "whisper.cpp 1.9.1"`,
		`model: "ggml-large-v3-turbo.bin"`,
		`language: "en"`,
		`merge_profile: "monologue"`,
	}
	for want in wanted {
		testing.expectf(t, strings.contains(block, want), "no %q in:\n%s", want, block)
	}
}

// The negative space of the block above (CLAUDE.md A3): a header nothing closes
// swallows the whole Transcript into itself, and every reader shows an empty
// document rather than a broken one.
@(test)
front_matter_is_opened_and_closed_before_any_prose :: proc(t: ^testing.T) {
	paragraphs := []Paragraph{{0, 3_480, "The first thing said."}}
	out := render_markdown(paragraphs, SAMPLE_CONTEXT, ANCHOR_INTERVAL_MS, context.allocator)
	defer delete(out, context.allocator)

	testing.expect(t, strings.has_prefix(out, "---\n"), "the document does not open with a fence")
	block := front_matter_of(out)
	testing.expect(t, len(block) > 0, "the header is never closed")
	testing.expect(
		t,
		!strings.contains(block, "The first thing said."),
		"prose landed inside the front matter",
	)
	testing.expect(
		t,
		strings.contains(out, "The first thing said."),
		"the prose did not reach the document at all",
	)
}

// ---------------------------------------------------------------------------
// The body: prose, and the shape of the document around it.
// ---------------------------------------------------------------------------

@(test)
paragraphs_are_separated_by_a_blank_line :: proc(t: ^testing.T) {
	paragraphs := []Paragraph {
		{0, 3_480, "The first thing said."},
		{4_380, 8_440, "The second thing said."},
	}
	out := render_markdown(paragraphs, SAMPLE_CONTEXT, ANCHOR_INTERVAL_MS, context.allocator)
	defer delete(out, context.allocator)

	// Run together on one line they are one paragraph to every reader there is,
	// which is the subtitle-fragment wall this program exists to avoid.
	testing.expectf(
		t,
		strings.contains(out, "The first thing said.\n\nThe second thing said.\n"),
		"the two paragraphs are not one blank line apart:\n%s",
		out,
	)
}

// One newline and no more. A document ending in a run of blank lines is not
// wrong to a reader, but it is a byte a re-render has to reproduce exactly, and
// the cheapest place to settle it is here.
@(test)
the_document_ends_with_exactly_one_newline :: proc(t: ^testing.T) {
	paragraphs := []Paragraph{{0, 3_480, "The only thing said."}}
	out := render_markdown(paragraphs, SAMPLE_CONTEXT, ANCHOR_INTERVAL_MS, context.allocator)
	defer delete(out, context.allocator)

	if !testing.expect(t, len(out) > 1, "the renderer produced no document at all") {
		return
	}
	testing.expect(t, out[len(out) - 1] == '\n', "the document does not end with a newline")
	testing.expect(t, out[len(out) - 2] != '\n', "the document ends with a blank line")
}

// LF, on a Windows-only program, deliberately. A Transcript is read by editors
// and viewers that all take LF, and the alternative is that the golden fixture's
// bytes depend on what checked it out -- which is the defect .gitattributes
// records against the Engine output beside it.
@(test)
the_document_carries_no_carriage_returns :: proc(t: ^testing.T) {
	paragraphs := []Paragraph {
		{0, 3_480, "The first thing said."},
		{4_380, 8_440, "The second thing said."},
	}
	out := render_markdown(paragraphs, SAMPLE_CONTEXT, ANCHOR_INTERVAL_MS, context.allocator)
	defer delete(out, context.allocator)

	testing.expect(
		t,
		strings.index_byte(out, '\r') == -1,
		"the document carries a carriage return",
	)
}
