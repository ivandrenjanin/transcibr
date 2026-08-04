package transcript

import "core:strings"
import "core:testing"
import "core:time"

// 2026-08-03T09:41:07Z, worked out by hand: an expectation derived by running
// the conversion the renderer runs could never disagree with it.
@(private)
SAMPLE_INSTANT :: time.Time {
	_nsec = 1_785_750_067 * 1_000_000_000,
}

@(private)
SAMPLE_CONTEXT :: Render_Context {
	now            = SAMPLE_INSTANT,
	source_display = "interview.mp4",
	engine_version = "whisper.cpp 1.9.1",
	model          = "ggml-large-v3-turbo.bin",
	language       = "en",
	profile        = .Monologue,
}

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

@(test)
front_matter_records_how_the_transcript_was_made :: proc(t: ^testing.T) {
	paragraphs := []Paragraph{{0, 3_480, "The first thing said."}}
	out := render_markdown(paragraphs, SAMPLE_CONTEXT, ANCHOR_INTERVAL_MS, context.allocator)
	defer delete(out, context.allocator)

	block := front_matter_of(out)
	if !testing.expect(t, len(block) > 0, "the document does not open with a front matter block") {
		return
	}

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

@(test)
paragraphs_are_separated_by_a_blank_line :: proc(t: ^testing.T) {
	paragraphs := []Paragraph {
		{0, 3_480, "The first thing said."},
		{4_380, 8_440, "The second thing said."},
	}
	out := render_markdown(paragraphs, SAMPLE_CONTEXT, ANCHOR_INTERVAL_MS, context.allocator)
	defer delete(out, context.allocator)

	testing.expectf(
		t,
		strings.contains(out, "The first thing said.\n\nThe second thing said.\n"),
		"the two paragraphs are not one blank line apart:\n%s",
		out,
	)
}

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

@(private)
anchors_in :: proc(markdown: string) -> (found: int) {
	assert(len(markdown) > 0, "an empty document is not a transcript to count anchors in")

	return strings.count(markdown, "\n## ")
}

@(private)
first_anchor_of :: proc(markdown: string) -> (reads: string) {
	assert(len(markdown) > 0, "an empty document is not a transcript to read an anchor out of")
	defer assert(strings.index_byte(reads, '\n') == -1, "read more than one line as an anchor")

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

@(private)
Anchor_Case :: struct {
	start: Millis,
	reads: string,
}

@(private, rodata)
ANCHOR_CASES := []Anchor_Case {
	{0, "00:00:00"},
	{999, "00:00:00"},
	{1_000, "00:00:01"},
	{61_000, "00:01:01"},
	{3_599_999, "00:59:59"},
	{3_600_000, "01:00:00"},
	{45_296_000, "12:34:56"},
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

// The Engine dates an invention past the Recording's end: the fixture's own Cue
// 7 runs to 59,980 ms over a Recording of 30,356, and nothing clamps it.
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

@(private)
body_of :: proc(markdown: string) -> string {
	assert(len(markdown) > 0, "an empty document has no body to read")

	anchor := first_anchor_of(markdown)
	if len(anchor) == 0 {
		return ""
	}
	opening := strings.index(markdown, anchor)
	rest := markdown[opening + len(anchor):]
	if !strings.has_prefix(rest, "\n\n") {
		return ""
	}
	return rest[2:]
}

@(private)
expect_body :: proc(t: ^testing.T, said, writes: string, loc := #caller_location) {
	assert(t != nil, "there is no test here to report a body against")
	assert(len(said) > 0, "a paragraph with nothing said in it is not speech to render")

	paragraphs := []Paragraph{{0, 1_000, said}}
	out := render_markdown(paragraphs, SAMPLE_CONTEXT, ANCHOR_INTERVAL_MS, context.allocator)
	defer delete(out, context.allocator)

	want := strings.concatenate({writes, "\n"}, context.allocator)
	defer delete(want, context.allocator)

	testing.expectf(t, body_of(out) == want, "%q came out as %q", said, body_of(out), loc = loc)
}

@(private, rodata)
ORDINARY_PROSE := []string {
	`It's the reader's transcript, and he said "no" and then "yes".`,
	"She said \u201Cyes\u201D, and it\u2019s hers now.",
	"A well-known, long-standing habit, and then\u2026 nothing much.",
	"Half of them (about 50%) arrived at 9:30 a.m.; the rest did not!",
	"C# and F# are languages, R&D is a department, and 3+4=7.",
	"Le caf\u00E9 fran\u00E7ais, na\u00EFve, \u00FCber, \u4F60\u597D.",
}

@(test)
ordinary_prose_reaches_the_reader_exactly_as_it_was_said :: proc(t: ^testing.T) {
	for said in ORDINARY_PROSE {
		expect_body(t, said, said)
	}
}

@(private)
Escape_Case :: struct {
	said:   string,
	writes: string,
}

@(private, rodata)
INLINE_ESCAPE_CASES := []Escape_Case {
	{"They said *that* and *this*.", `They said \*that\* and \*this\*.`},
	{"The file_name_here is odd.", `The file\_name\_here is odd.`},
	{"He said `hello` twice.", "He said \\`hello\\` twice."},
	{"[BLANK_AUDIO] and then speech.", `\[BLANK\_AUDIO\] and then speech.`},
	{"Type <b>bold</b> to start.", `Type \<b>bold\</b> to start.`},
	{`A back\slash mid-sentence.`, `A back\\slash mid-sentence.`},
	{"A pipe | in the middle.", `A pipe \| in the middle.`},
}

@(test)
what_markdown_reads_as_structure_is_escaped_wherever_it_falls :: proc(t: ^testing.T) {
	for c in INLINE_ESCAPE_CASES {
		expect_body(t, c.said, c.writes)
	}
}

@(private, rodata)
BLOCK_START_CASES := []Escape_Case {
	{"--- and so it went.", `\--- and so it went.`},
	{"# Hash, they said.", `\# Hash, they said.`},
	{"> Quoted, they said.", `\> Quoted, they said.`},
	{"- Dashed, they said.", `\- Dashed, they said.`},
	{"+ Plussed, they said.", `\+ Plussed, they said.`},
	{"= Equals, they said.", `\= Equals, they said.`},
	{"~ Tilde, they said.", `\~ Tilde, they said.`},
	{"1999. That was the year.", `1999\. That was the year.`},
	{"1) First of all, listen.", `1\) First of all, listen.`},
}

@(test)
speech_that_opens_a_paragraph_like_a_block_is_escaped :: proc(t: ^testing.T) {
	for c in BLOCK_START_CASES {
		expect_body(t, c.said, c.writes)
	}
}

@(private, rodata)
BLOCK_STARTERS_MID_LINE := []string {
	"They said # and > and - and + and = and ~ in the middle of it.",
	"It was 1999. That was the year, and the 3) option won.",
}

@(test)
a_block_character_away_from_the_start_of_a_line_is_left_alone :: proc(t: ^testing.T) {
	for said in BLOCK_STARTERS_MID_LINE {
		expect_body(t, said, said)
	}
}

@(private, rodata)
FLATTENED_START_CASES := []Escape_Case {
	{"\x01--- and so it went.", `\--- and so it went.`},
	{"\x01# Hash, they said.", `\# Hash, they said.`},
	{"\x01> Quoted, they said.", `\> Quoted, they said.`},
	{"\x01- Dashed, they said.", `\- Dashed, they said.`},
	{"\x011999. That was the year.", `1999\. That was the year.`},
	{"\x01\x01\x01\x01Ordinary speech.", "Ordinary speech."},
	{"\t--- and so it went.", `\--- and so it went.`},
	{"\r\n\x7f\v- Dashed, they said.", `\- Dashed, they said.`},
	{"\x01Ordinary speech, nothing special.", "Ordinary speech, nothing special."},
	{"\x01A back\\slash and *emphasis*.", `A back\\slash and \*emphasis\*.`},
}

@(test)
speech_that_opens_with_a_flattened_byte_still_cannot_open_a_block :: proc(t: ^testing.T) {
	for c in FLATTENED_START_CASES {
		expect_body(t, c.said, c.writes)
	}
}

@(test)
a_cue_holding_nothing_a_reader_could_see_is_not_a_saying :: proc(t: ^testing.T) {
	silent := []string{"", " ", "   ", "\x01", SILENCE_AS_BYTES, "\r\n\t\v"}
	for text, i in silent {
		testing.expectf(
			t,
			len(spoken_text(Cue{0, 1_000, text})) == 0,
			"case %d: %q was counted as having said something",
			i,
			text,
		)
	}
	testing.expect_value(t, spoken_text(Cue{0, 1_000, " \x01 Words. \x01"}), "Words.")
}

@(test)
a_line_break_inside_speech_never_reaches_the_document :: proc(t: ^testing.T) {
	expect_body(
		t,
		"Speech that carries\n--- a break\rand a return\tand a tab.",
		"Speech that carries --- a break and a return and a tab.",
	)
}

@(test)
speech_that_looks_like_front_matter_does_not_reopen_the_header :: proc(t: ^testing.T) {
	paragraphs := []Paragraph {
		{0, 1_000, "Real speech, before the trouble."},
		{2_000, 3_000, "--- generator: not transcibr"},
	}
	out := render_markdown(paragraphs, SAMPLE_CONTEXT, ANCHOR_INTERVAL_MS, context.allocator)
	defer delete(out, context.allocator)

	block := front_matter_of(out)
	testing.expect_value(t, strings.count(block, "\n"), 7)
	testing.expect(
		t,
		strings.contains(out, `\--- generator: not transcibr`),
		"the fake header reached the document unescaped",
	)
}

@(test)
a_front_matter_value_cannot_close_the_header_early :: proc(t: ^testing.T) {
	hostile := Render_Context {
		now            = SAMPLE_INSTANT,
		source_display = "evil\n---\n# not a transcript.mp4",
		engine_version = `a "quoted" version`,
		model          = `C:\models\ggml-large-v3.bin`,
		language       = "en\tand\x7f",
		profile        = .Conversation,
	}
	paragraphs := []Paragraph{{0, 1_000, "Real speech."}}
	out := render_markdown(paragraphs, hostile, ANCHOR_INTERVAL_MS, context.allocator)
	defer delete(out, context.allocator)

	block := front_matter_of(out)
	testing.expect_value(t, strings.count(block, "\n"), 7)

	wanted := []string {
		`source: "evil\n---\n# not a transcript.mp4"`,
		`engine: "a \"quoted\" version"`,
		`model: "C:\\models\\ggml-large-v3.bin"`,
		`language: "en\tand\x7f"`,
	}
	for want in wanted {
		testing.expectf(t, strings.contains(block, want), "no %q in:\n%s", want, block)
	}
}

// LF on a Windows-only program, deliberately: the alternative is a golden
// fixture whose bytes depend on what checked it out.
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
