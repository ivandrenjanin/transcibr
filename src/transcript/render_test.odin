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

// ---------------------------------------------------------------------------
// Anchors: "a timestamp Anchor every few minutes rather than on every line, so
// that I can find my place in the Recording without the text becoming a table"
// (spec story 33).
//
// Every case below pins its OWN interval rather than reading ANCHOR_INTERVAL_MS,
// except where the shipped interval is the thing under test. Five minutes is
// taste, the placement rule is not, and a suite that read the constant would
// have to be rewritten the day the constant is tuned.
// ---------------------------------------------------------------------------

// How many Anchors a rendered Transcript carries.
//
// Counted off the line start, which is what makes the count trustworthy: prose
// can never open a line with `##`, because escaping puts a backslash in front of
// a `#` that lands there.
@(private)
anchors_in :: proc(markdown: string) -> int {
	return strings.count(markdown, "\n## ")
}

// The first Anchor's time, without its heading or its newline, or "" where the
// document carries no Anchor at all.
@(private)
first_anchor_of :: proc(markdown: string) -> string {
	opening := "\n## "
	at := strings.index(markdown, opening)
	if at < 0 {
		return ""
	}
	rest := markdown[at + len(opening):]
	end := strings.index_byte(rest, '\n')
	if end < 0 {
		return ""
	}
	return rest[:end]
}

// One Paragraph start and the Anchor it must read as.
@(private)
Anchor_Case :: struct {
	start: Millis,
	reads: string,
}

@(private, rodata)
ANCHOR_CASES := []Anchor_Case {
	{0, "00:00:00"},
	// Under a second is still the same second. An Anchor is coarse on purpose,
	// and rounding up would name a moment the Paragraph had not reached yet.
	{999, "00:00:00"},
	{1_000, "00:00:01"},
	{61_000, "00:01:01"},
	{3_599_999, "00:59:59"},
	{3_600_000, "01:00:00"},
	{45_296_000, "12:34:56"},
	// Past a day. Hours RUN ON rather than wrapping: a reader seeking `01:00:00`
	// in a twenty-five hour Recording would otherwise be sent to the wrong hour,
	// and Millis holds far more than any Recording anyone will feed this.
	{90_000_000, "25:00:00"},
}

@(test)
an_anchor_reads_as_hours_minutes_and_seconds :: proc(t: ^testing.T) {
	for c in ANCHOR_CASES {
		paragraphs := []Paragraph{{c.start, c.start + 1_000, "Something said."}}
		out := render_markdown(paragraphs, SAMPLE_CONTEXT, ANCHOR_INTERVAL_MS, context.allocator)
		defer delete(out, context.allocator)

		testing.expectf(
			t,
			first_anchor_of(out) == c.reads,
			"%d ms anchored as %q, want %q",
			c.start,
			first_anchor_of(out),
			c.reads,
		)
	}
}

// An Anchor names where the Paragraph after it actually starts, not the interval
// boundary that made it due. The boundary is a moment nobody spoke at, and a
// reader who seeks to it hears the tail of the passage before.
@(test)
an_anchor_stands_in_front_of_a_paragraph_and_names_its_start :: proc(t: ^testing.T) {
	paragraphs := []Paragraph{{4_380, 8_440, "The first thing said."}}
	out := render_markdown(paragraphs, SAMPLE_CONTEXT, ANCHOR_INTERVAL_MS, context.allocator)
	defer delete(out, context.allocator)

	testing.expectf(
		t,
		strings.contains(out, "\n## 00:00:04\n\nThe first thing said.\n"),
		"the anchor does not stand in front of its paragraph:\n%s",
		out,
	)
}

// THE ACCEPTANCE CRITERION: every few minutes, never per Cue.
//
// Twelve Paragraphs a minute apart with an Anchor due every five minutes. A
// renderer anchoring per Paragraph writes twelve; one anchoring correctly writes
// three, at zero, five and ten minutes.
@(test)
anchors_stand_minutes_apart_rather_than_at_every_paragraph :: proc(t: ^testing.T) {
	MINUTE :: Millis(60_000)
	paragraphs := make([]Paragraph, 12, context.allocator)
	defer delete(paragraphs, context.allocator)
	for &paragraph, i in paragraphs {
		at := Millis(i) * MINUTE
		paragraph = Paragraph{at, at + 30_000, "A minute of speech."}
	}

	out := render_markdown(paragraphs, SAMPLE_CONTEXT, 5 * MINUTE, context.allocator)
	defer delete(out, context.allocator)

	testing.expectf(
		t,
		anchors_in(out) == 3,
		"twelve paragraphs over eleven minutes carried %d anchors, want 3:\n%s",
		anchors_in(out),
		out,
	)
	due := []string{"\n## 00:00:00\n", "\n## 00:05:00\n", "\n## 00:10:00\n"}
	for reads in due {
		testing.expectf(t, strings.contains(out, reads), "no anchor at %q", reads)
	}
}

// The negative space of the interval (CLAUDE.md A3), and the fixture's own
// shape: seven Cues over half a minute. A Recording that never reaches the
// interval still gets ONE Anchor, because a Transcript whose first Paragraph is
// unplaced gives a reader nothing to seek to at all.
@(test)
a_recording_shorter_than_one_interval_carries_exactly_one_anchor :: proc(t: ^testing.T) {
	paragraphs := []Paragraph {
		{0, 3_480, "The first thing said."},
		{4_380, 8_440, "The second thing said."},
		{9_360, 13_980, "The third thing said."},
	}
	out := render_markdown(paragraphs, SAMPLE_CONTEXT, ANCHOR_INTERVAL_MS, context.allocator)
	defer delete(out, context.allocator)

	testing.expectf(
		t,
		anchors_in(out) == 1,
		"%d anchors over half a minute:\n%s",
		anchors_in(out),
		out,
	)
	testing.expect_value(t, first_anchor_of(out), "00:00:00")
}

// An Anchor stands BEFORE a Paragraph and never inside one, so a Paragraph
// running through four intervals carries one and not four. Anchoring by elapsed
// time rather than by Paragraph would break prose apart to place them, which is
// the subtitle table story 33 refuses.
@(test)
a_paragraph_spanning_several_intervals_carries_one_anchor :: proc(t: ^testing.T) {
	MINUTE :: Millis(60_000)
	paragraphs := []Paragraph {
		{0, 20 * MINUTE, "Twenty minutes of uninterrupted explanation."},
		{20 * MINUTE + 500, 21 * MINUTE, "And then the next thing."},
	}
	out := render_markdown(paragraphs, SAMPLE_CONTEXT, 5 * MINUTE, context.allocator)
	defer delete(out, context.allocator)

	testing.expectf(
		t,
		anchors_in(out) == 2,
		"a twenty-minute paragraph and its neighbour carried %d anchors, want 2:\n%s",
		anchors_in(out),
		out,
	)
	testing.expect(
		t,
		strings.contains(out, "\n## 00:20:00\n"),
		"the second paragraph is unanchored",
	)
}

// The Engine dates an invention over trailing silence past the end of the
// Recording -- the fixture's own Cue 7 runs to 59,980 ms over a Recording of
// 30,356. Nothing clamps, here or anywhere before here: an Anchor naming the
// Recording's end instead would tell a reader to seek to a moment that holds
// different speech.
@(test)
an_anchor_past_the_end_of_the_recording_is_written_as_it_stands :: proc(t: ^testing.T) {
	paragraphs := []Paragraph {
		{0, 29_480, "Everything that was actually said."},
		{30_000, 59_980, "Thank you."},
	}
	out := render_markdown(paragraphs, SAMPLE_CONTEXT, 20_000, context.allocator)
	defer delete(out, context.allocator)

	testing.expect(
		t,
		strings.contains(out, "\n## 00:00:30\n\nThank you.\n"),
		"the anchor past the recording's end was moved or dropped",
	)
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
