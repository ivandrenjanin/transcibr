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

// ---------------------------------------------------------------------------
// Escaping: transcribed speech is arbitrary text, and Markdown reads several of
// its characters as structure.
//
// BOTH DIRECTIONS, and the first one matters more. A Transcript is read by a
// person, so an escaper that backslashes its way through ordinary punctuation
// has broken the deliverable to protect it -- apostrophes, quotation marks,
// hyphens, brackets in the ordinary sense and accented speech all have to reach
// the reader exactly as they were said. What is escaped is what would otherwise
// stop being text.
// ---------------------------------------------------------------------------

// The prose a rendered Transcript holds, from the first Paragraph on. The header
// and the leading Anchor are cut off, so a case can compare the body outright.
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

// One piece of speech through the renderer, against the bytes the body must
// hold.
//
// Four tables below asked exactly this question and each spelled the same six
// lines to ask it -- render, defer the delete, concatenate the trailing newline,
// defer that delete, compare, report. What differed between them was the table,
// which is the only thing that should.
//
// #caller_location, so a failure names the case that failed rather than naming
// this.
@(private)
expect_body :: proc(t: ^testing.T, said, writes: string, loc := #caller_location) {
	paragraphs := []Paragraph{{0, 1_000, said}}
	out := render_markdown(paragraphs, SAMPLE_CONTEXT, ANCHOR_INTERVAL_MS, context.allocator)
	defer delete(out, context.allocator)

	// The trailing newline is the document's and not the speech's: a Paragraph is
	// one line, and the line has to end.
	want := strings.concatenate({writes, "\n"}, context.allocator)
	defer delete(want, context.allocator)

	testing.expectf(t, body_of(out) == want, "%q came out as %q", said, body_of(out), loc = loc)
}

// Speech carrying nothing Markdown reads as structure. Every one of these must
// arrive byte for byte.
@(private, rodata)
ORDINARY_PROSE := []string {
	// Apostrophes and quotation marks, straight and curly, which is most of what
	// the Engine actually writes.
	`It's the reader's transcript, and he said "no" and then "yes".`,
	"She said \u201Cyes\u201D, and it\u2019s hers now.",
	// Hyphens, a dash used as punctuation, and the Engine's own trailing-off.
	"A well-known, long-standing habit, and then\u2026 nothing much.",
	// The rest of what a speaker reaches for.
	"Half of them (about 50%) arrived at 9:30 a.m.; the rest did not!",
	"C# and F# are languages, R&D is a department, and 3+4=7.",
	// Bytes above 0x7F, which an escaper walking one byte at a time would carve
	// in half and leave as a broken character in the deliverable.
	"Le caf\u00E9 fran\u00E7ais, na\u00EFve, \u00FCber, \u4F60\u597D.",
}

@(test)
ordinary_prose_reaches_the_reader_exactly_as_it_was_said :: proc(t: ^testing.T) {
	for said in ORDINARY_PROSE {
		expect_body(t, said, said)
	}
}

// One piece of speech and the bytes it must reach the document as.
@(private)
Escape_Case :: struct {
	said:   string,
	writes: string,
}

// What Markdown reads as structure ANYWHERE in a line.
@(private, rodata)
INLINE_ESCAPE_CASES := []Escape_Case {
	// Emphasis. Left alone, a pair of these italicises whatever stands between
	// them and the asterisks the speaker meant disappear from the page.
	{"They said *that* and *this*.", `They said \*that\* and \*this\*.`},
	{"The file_name_here is odd.", `The file\_name\_here is odd.`},
	// A code span swallows everything up to the next backtick -- and where there
	// is no next one, everything to the end of the paragraph.
	{"He said `hello` twice.", "He said \\`hello\\` twice."},
	// The Engine writes these itself over non-speech, so this is not a
	// hypothetical piece of text: unescaped they are a link that goes nowhere.
	{"[BLANK_AUDIO] and then speech.", `\[BLANK\_AUDIO\] and then speech.`},
	// A tag somebody read out is text, not markup. `>` is structure only at the
	// start of a line, so it stays as it was said.
	{"Type <b>bold</b> to start.", `Type \<b>bold\</b> to start.`},
	// FIRST, or every escape written after it is doubled by its own backslash.
	{`A back\slash mid-sentence.`, `A back\\slash mid-sentence.`},
	{"A pipe | in the middle.", `A pipe \| in the middle.`},
}

@(test)
what_markdown_reads_as_structure_is_escaped_wherever_it_falls :: proc(t: ^testing.T) {
	for c in INLINE_ESCAPE_CASES {
		expect_body(t, c.said, c.writes)
	}
}

// What Markdown reads as structure only where a line BEGINS with it. A Paragraph
// is one line, so a Paragraph's first character is the only place these can do
// any harm -- and escaping them everywhere would put a backslash in front of
// every hyphen the Engine ever wrote.
@(private, rodata)
BLOCK_START_CASES := []Escape_Case {
	// THE DANGEROUS ONE. Three dashes opening a line is a thematic break, and
	// three dashes under prose is a setext heading that eats the line above.
	{"--- and so it went.", `\--- and so it went.`},
	{"# Hash, they said.", `\# Hash, they said.`},
	{"> Quoted, they said.", `\> Quoted, they said.`},
	{"- Dashed, they said.", `\- Dashed, they said.`},
	{"+ Plussed, they said.", `\+ Plussed, they said.`},
	{"= Equals, they said.", `\= Equals, they said.`},
	{"~ Tilde, they said.", `\~ Tilde, they said.`},
	// A year read out at the start of a Paragraph is an ordered list numbered
	// from 1999 to every Markdown reader there is, and the year leaves the page.
	{"1999. That was the year.", `1999\. That was the year.`},
	{"1) First of all, listen.", `1\) First of all, listen.`},
}

@(test)
speech_that_opens_a_paragraph_like_a_block_is_escaped :: proc(t: ^testing.T) {
	for c in BLOCK_START_CASES {
		expect_body(t, c.said, c.writes)
	}
}

// The negative space of that (CLAUDE.md A3), and the reason the two sets are two
// sets: away from the start of a line none of these is structure, and an escaper
// that could not tell puts a backslash in front of every hyphen and every date.
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

// THE NEGATIVE SPACE OF THE BLOCK STARTERS (CLAUDE.md A3), and the one the table
// above cannot reach: speech whose first byte is not what OPENS the line.
//
// A control character is written out as a space, so speech carrying one in front
// of it reaches a Markdown reader with a space in front of it -- and up to three
// spaces are allowed before block structure, four before an indented code block.
// Every row here is a Paragraph whose speech LEAVES THE PAGE if the block start
// is decided on the byte the Engine wrote rather than on the byte a reader sees:
// one control character is enough for the first five, and four for the last.
@(private, rodata)
FLATTENED_START_CASES := []Escape_Case {
	{"\x01--- and so it went.", `\--- and so it went.`},
	{"\x01# Hash, they said.", `\# Hash, they said.`},
	{"\x01> Quoted, they said.", `\> Quoted, they said.`},
	{"\x01- Dashed, they said.", `\- Dashed, they said.`},
	{"\x011999. That was the year.", `1999\. That was the year.`},
	// Four of them, which is the indented code block: the whole Paragraph
	// rendered as monospace, and every escape inside it shown as a backslash.
	{"\x01\x01\x01\x01Ordinary speech.", "Ordinary speech."},
	// A tab and a carriage return are the same problem in a different byte, and
	// so is a run of them mixed together.
	{"\t--- and so it went.", `\--- and so it went.`},
	{"\r\n\x7f\v- Dashed, they said.", `\- Dashed, they said.`},
	// The other side of it: what follows the flattened run is escaped exactly as
	// it would have been had the run never been there, and nothing else moves.
	{"\x01Ordinary speech, nothing special.", "Ordinary speech, nothing special."},
	{"\x01A back\\slash and *emphasis*.", `A back\\slash and \*emphasis\*.`},
}

@(test)
speech_that_opens_with_a_flattened_byte_still_cannot_open_a_block :: proc(t: ^testing.T) {
	for c in FLATTENED_START_CASES {
		expect_body(t, c.said, c.writes)
	}
}

// The write side of the same claim (CLAUDE.md A4): a Cue holding nothing a
// reader could see is not a Saying, so no Paragraph is ever built out of one.
//
// CONTEXT.md already says the Engine's empty and space-only Cues are not
// Sayings. A Cue of control characters is the same statement in bytes a text
// editor renders as nothing at all -- and one admitted as speech would open a
// Paragraph whose whole prose flattens to whitespace.
@(test)
a_cue_holding_nothing_a_reader_could_see_is_not_a_saying :: proc(t: ^testing.T) {
	silent := []string{"", " ", "   ", "\x01", " \x01\x7f ", "\r\n\t\v"}
	for text, i in silent {
		testing.expectf(
			t,
			len(spoken_text(Cue{0, 1_000, text})) == 0,
			"case %d: %q was counted as having said something",
			i,
			text,
		)
	}
	// The negative space of THAT (CLAUDE.md A3): a Cue that says something keeps
	// every byte of it that a reader could see, whatever stands either side.
	testing.expect_value(t, spoken_text(Cue{0, 1_000, " \x01 Words. \x01"}), "Words.")
}

// A Paragraph is ONE line, and everything above rests on it: "the start of a
// line" and "the start of a Paragraph" are the same place only while that holds.
// The parser is lossless on purpose, so a line break the Engine wrote into a Cue
// arrives here intact, and the second line it makes can be anything at all --
// three dashes among them.
@(test)
a_line_break_inside_speech_never_reaches_the_document :: proc(t: ^testing.T) {
	said := "Speech that carries\n--- a break\rand a return\tand a tab."
	paragraphs := []Paragraph{{0, 1_000, said}}
	out := render_markdown(paragraphs, SAMPLE_CONTEXT, ANCHOR_INTERVAL_MS, context.allocator)
	defer delete(out, context.allocator)

	testing.expect_value(
		t,
		body_of(out),
		"Speech that carries --- a break and a return and a tab.\n",
	)
}

// A Paragraph that reads like a header cannot become one. Front matter is only
// front matter at the top of a document, so what this refuses is the thematic
// break and the setext heading -- but the shape is the one a reader would look
// at and mistrust, and the escaping that stops it is the same escaping.
@(test)
speech_that_looks_like_front_matter_does_not_reopen_the_header :: proc(t: ^testing.T) {
	paragraphs := []Paragraph {
		{0, 1_000, "Real speech, before the trouble."},
		{2_000, 3_000, "--- generator: not transcibr"},
	}
	out := render_markdown(paragraphs, SAMPLE_CONTEXT, ANCHOR_INTERVAL_MS, context.allocator)
	defer delete(out, context.allocator)

	// Seven lines in the header and no more: one per field, whatever the prose
	// beneath it says.
	block := front_matter_of(out)
	testing.expect_value(t, strings.count(block, "\n"), 7)
	testing.expect(
		t,
		strings.contains(out, `\--- generator: not transcibr`),
		"the fake header reached the document unescaped",
	)
}

// The other half of the same question, and the one ADR-0009 names: the front
// matter's own VALUES come from outside this program -- a Recording named by
// whoever named it, a language string the Engine chose -- and a value carrying a
// newline would close the header and turn the rest of the Transcript into
// metadata.
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
