package transcript

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"
import "transcibr:version"

// What a Transcript records about how it was made, handed in rather than reached
// for.
//
// THIS IS ADR-0009's whole point. Front matter holds a clock read, an
// environment read and a machine-specific path, and a renderer that reached for
// those would stop being a pure function -- which would leave the golden fixture
// comparable only with the header stripped, removing the entire metadata block
// from test coverage and letting a malformed YAML block ship into every
// Transcript. Passed in, the front matter becomes the most-tested part of the
// output rather than the least.
//
// The Model is here and NOT read out of the Engine's JSON, which reports every
// large Model under the bare name `large` (ADR-0003): Model identity comes from
// transcibr's own record. The Engine version is not in that JSON at all.
//
// transcibr's OWN version is deliberately not a field. It is a compiled-in
// constant (src/version), so a Transcript's recorded provenance cannot disagree
// with the binary that produced it -- and a field for it would be a second
// answer that could.
//
// Every string is BORROWED for the length of the render and never freed here.
Render_Context :: struct {
	// The moment the Transcript was produced, as the shell read it. A value and
	// not a formatted string, so the format itself is pure and the fixture pins
	// it (ADR-0009).
	now:            time.Time,
	// How the Recording is spelled to a reader -- the caller's spelling, which is
	// the one they will go looking for.
	source_display: string,
	engine_version: string,
	model:          string,
	// What the Engine detected, which is the one front matter fact the Engine's
	// own output can settle (ADR-0001). Read out of that output by the shell and
	// handed in, never trusted: it reaches YAML through the same quoting as
	// everything else, because it came from outside this program.
	language:       string,
	profile:        Merge_Profile,
}

// How often an Anchor may appear: five minutes.
//
// "A timestamp Anchor every few minutes rather than on every line, so that I can
// find my place in the Recording without the text becoming a table" (spec story
// 33). Five minutes is a coarse enough grain that an hour of speech carries
// twelve of them, and fine enough that finding a remembered passage costs
// skimming one interval rather than ten.
//
// It is deliberately NOT tied to Paragraphs. A Merge Profile decides how long a
// Paragraph runs, so an Anchor placed every N Paragraphs would appear three
// times as often under `conversation` as under `monologue` on the same
// Recording -- and the reader's question, "where in the Recording am I", has
// nothing to do with paragraphing.
//
// render_markdown takes it as an argument rather than reading this, so a case
// can pin an interval a fixture can actually cross.
ANCHOR_INTERVAL_MS :: Millis(5 * 60 * 1_000)

// A few minutes, in checked code rather than in the prose above (CLAUDE.md A5).
// An interval at or below zero puts an Anchor in front of every Paragraph, which
// is the per-Cue table spec story 33 exists to refuse.
#assert(ANCHOR_INTERVAL_MS > 0)

// What the front matter names as having produced the Transcript.
//
// NOT the binary's name. The window and the command-line binary both produce
// Transcripts and must produce the same bytes from the same input (spec story
// 44), so a generator naming whichever one ran would make the two disagree over
// nothing.
@(private)
GENERATOR :: "transcibr"

// The line that opens and closes the front matter.
@(private)
FENCE :: "---"

// What a front matter field says where nobody could settle it.
//
// A word rather than an empty value or a missing key, because the two of those
// read as "transcibr forgot" where this reads as "nobody knew". ADR-0003 is the
// rule it comes from: absent provenance beats wrong provenance, and a Transcript
// re-rendered from retained Engine output genuinely does not know which Engine
// build decoded it.
UNKNOWN :: "unknown"

// Renders one piece of retained Engine output as a Markdown Transcript: parse,
// collapse repetition, merge into Paragraphs under the Render Context's Merge
// Profile, and write the document.
//
// The whole pure core in one call, and the seam the golden fixture is compared
// at (spec S1). Nothing here touches the GPU, the clock or the filesystem: the
// Engine's output arrives as text and the Recording's length as a number, both
// settled by the shell (ADR-0009), which is what makes re-rendering cost seconds
// rather than hours (spec story 43).
//
// An operating error names the input it came from and comes back with no
// document at all, never a short one: what to do about it is disposition_of, and
// ADR-0002 quarantines and re-runs most of them.
//
// The allocator is explicit and never defaulted: the document outlives this
// procedure and crosses a worker boundary (ADR-0010). Free it with `delete`,
// passing the same allocator.
render_transcript :: proc(
	json_name: string,
	json_text: string,
	recording_duration: Maybe(Millis),
	rc: Render_Context,
	allocator: mem.Allocator,
) -> (
	markdown: string,
	err: Parse_Error,
) {
	assert(
		len(json_name) > 0,
		"the input must be named; a report nobody can locate is not a report",
	)
	assert(
		allocator.procedure != nil,
		"the document outlives this procedure and needs a chosen allocator",
	)
	// Both sides of what a return means (CLAUDE.md A3), at the one place both are
	// in hand: a refusal hands back nothing to free, and an acceptance hands back
	// a document that at least holds its own header.
	defer if err.fault != .None {
		assert(len(markdown) == 0, "reported an operating error and handed back a transcript")
	} else {
		assert(len(markdown) > 0, "rendered a transcript with nothing in it, not even a header")
	}

	cues, parse_err := parse_cues(json_name, json_text, recording_duration, allocator)
	if parse_err.fault != .None {
		return "", parse_err
	}
	defer destroy_cues(cues, allocator)

	// The Cues come back CLONED, so both sets are freed and neither borrows from
	// the other (see collapse_repetition).
	kept := collapse_repetition(cues, COLLAPSE_THRESHOLDS, allocator)
	defer destroy_cues(kept, allocator)

	paragraphs := merge_paragraphs(kept, profile_params(rc.profile), allocator)
	defer destroy_paragraphs(paragraphs, allocator)

	// The other silent success, and the one no check on the JSON's SHAPE can
	// reach: output that parses perfectly and says nothing. `.No_Cues` fires on
	// an empty `transcription` array and never on a set full of the empty and
	// space-only Cues the Engine writes over silence -- so a Recording of
	// silence, of music, or of a dead audio track rendered a header with no
	// Transcript under it, at exit 0.
	//
	// Reported here rather than in parse_cues, which is lossless on purpose and
	// right to hand those Cues on: they hold the Recording's timeline and the
	// runs repetition collapse counts. It is the DOCUMENT that cannot exist.
	//
	// Spec story 41 -- a Recording that produced ALMOST no text -- is a different
	// question and is deliberately not answered here. That one needs a threshold
	// and a comparison against the Recording's length; this one needs neither,
	// because there is no prose at all to write and ADR-0002 already calls "exit
	// 0 but no or empty output" a hard per-Recording failure.
	if len(paragraphs) == 0 {
		return "", fault_at(.Nothing_Said, json_name, 0)
	}

	return render_markdown(paragraphs, rc, ANCHOR_INTERVAL_MS, allocator), Parse_Error{}
}

// Renders Paragraphs as a Markdown Transcript.
//
// Pure: the same arguments produce the same bytes, every time, which is what
// makes a golden fixture possible at all and what spec story 44 asks for when it
// says a re-render must produce the Transcript the original run would have.
//
// The allocator is explicit and never defaulted: the document outlives this
// procedure and crosses a worker boundary (ADR-0010). Free it with `delete`,
// passing the same allocator.
render_markdown :: proc(
	paragraphs: []Paragraph,
	rc: Render_Context,
	anchor_every_ms: Millis,
	allocator: mem.Allocator,
) -> (
	markdown: string,
) {
	assert(anchor_every_ms > 0, "an anchor every no time at all is an anchor at every paragraph")
	assert(
		allocator.procedure != nil,
		"the document outlives this procedure and needs a chosen allocator",
	)

	out := strings.builder_make(allocator)
	defer strings.builder_destroy(&out)

	write_front_matter(&out, rc, allocator)

	// When the next Anchor is allowed, which starts at the beginning of the
	// Recording so the FIRST Paragraph always carries one: a Transcript whose
	// opening prose is unplaced gives a reader nothing at all to seek to.
	//
	// The interval bounds how often an Anchor may appear, and never where one
	// falls: the Anchor names the Paragraph's own start, because the boundary that
	// made it due is a moment nobody spoke at, and a reader who seeks there hears
	// the tail of the passage before.
	//
	// "No more often than" and never "every": on material whose Paragraphs all
	// stand more than one interval apart -- an interview with long silences
	// between turns, under the aggressive profile -- every Paragraph is overdue
	// when it arrives and every one of them carries an Anchor. That is the rule
	// working and not failing. What spec story 33 refuses is a timestamp on every
	// LINE of a wall of fragments, and the Paragraph is what stops that being the
	// same thing.
	due := Millis(0)
	previous := Millis(0)
	for paragraph in paragraphs {
		// What merge_paragraphs hands back, checked the way every consumer in this
		// package checks a Cue set on the way in (CLAUDE.md A4). Anchors are placed
		// by comparing each start against the last one due, so a set whose starts
		// went backwards would anchor one minute repeatedly and leave the stretch
		// after it with none.
		assert(paragraph.start >= previous, "rendering a paragraph set that runs backwards")
		previous = paragraph.start

		if paragraph.start >= due {
			write_anchor(&out, paragraph.start)
			due = paragraph.start + anchor_every_ms
			assert(due > paragraph.start, "an anchor that is due again the moment it is placed")
		}
		strings.write_byte(&out, '\n')
		write_prose(&out, paragraph.text)
		strings.write_byte(&out, '\n')
	}

	markdown = strings.clone(strings.to_string(out), allocator)
	// The two shape claims every reader depends on and no sequence of writes
	// guarantees (CLAUDE.md A6): the header is there to be read, and the bytes are
	// the ones the fixture holds rather than the ones a Windows text mode would
	// have made of them.
	assert(strings.has_prefix(markdown, FENCE), "a transcript that opens with no front matter")
	assert(strings.index_byte(markdown, '\r') == -1, "a carriage return reached the document")
	return
}

// What Markdown reads as structure ANYWHERE in a line, and what therefore has to
// carry a backslash wherever the Engine wrote it.
//
// The list is short on purpose, and what is NOT in it is the point. A Transcript
// is read by a person, so an escaper backslashing its way through ordinary
// punctuation has broken the deliverable in order to protect it: apostrophes,
// quotation marks, hyphens, brackets, ampersands, hashes away from the start of
// a line and every accented character reach the reader exactly as they were said.
//
// `\` is first because it has to be: escaped last, every backslash written by
// the escapes after it would be escaped again.
//
// `>` is NOT here. It opens a blockquote only at the start of a line, and the
// closing half of a tag somebody read out (`</b>`) is far commoner in speech
// than a line beginning with one -- so it is handled at the line start instead,
// where it can actually do harm.
//
// `&` is NOT here either. That is a JUDGEMENT AND A TRADE, made deliberately,
// and it is recorded here in full because the cost of it is real.
//
// What it costs: an ampersand that opens a VALID HTML5 entity name is resolved
// by every renderer there is, and the speech carrying it changes on the page.
// Measured through the built binary against commonmark.js and marked --
//
//   `&copy; 2026`     reaches the reader as `© 2026`
//   `spaced&nbsp;out` reaches the reader with a non-breaking space in it
//   `&lt;b&gt;`       reaches the reader as `<b>`
//   `&amp;`           reaches the reader as `&`
//
// -- and one spelling even divides the two: `&notit;` is not a valid entity, so
// commonmark.js leaves it alone and marked resolves the `&not` prefix in it and
// writes `¬it;`.
//
// What escaping it would cost instead: a backslash in front of the ampersand in
// every "R&D", "AT&T", "Q&A", "H&M" and "Fish & chips" a Transcript holds --
// which is what an Engine transcribing speech actually writes. Every one of
// those was measured too, and every one of them reaches the reader verbatim
// today, because an ampersand is structure only where a valid entity NAME
// follows it.
//
// The trade is taken because the harmful spelling is one a speech model does not
// produce. `&copy;` is not a sound; it is punctuation somebody typed. A
// Transcript is transcribed speech, and the escaper that protected it from
// `&copy;` would disfigure every department, every band and every fish supper in
// it. If Engine output ever does start carrying entity spellings -- a subtitle
// track read back through it, say -- this is the line to revisit, and the
// measurements above are what it would be revisited against.
@(private)
INLINE_SPECIALS :: `\` + "`" + `*_[]<|`

// What Markdown reads as structure only where a line BEGINS with it.
//
// A Paragraph is one line, which is what makes this a set of its own: a hyphen
// or a hash in the middle of a sentence is text, and an escaper that could not
// tell the difference would put a backslash in front of every hyphenated word
// the Engine ever wrote.
//
// `-` is the dangerous one. Three of them opening a line is a thematic break,
// and three of them under prose is a setext heading that swallows the line
// above -- which is the shape a reader would mistake for a second front matter
// block.
@(private)
BLOCK_STARTERS :: "#>-+=~"

// Writes one Paragraph's speech so that nothing in it can become structure.
//
// NORMALISED FIRST, ESCAPED SECOND, and that order is the whole procedure.
// write_inline flattens every byte a reader cannot see into a space, so a
// Paragraph opening on one reaches Markdown with a space in front of it -- and
// Markdown allows up to three spaces before block structure and four before an
// indented code block. Deciding what opens the line on the byte the ENGINE wrote
// therefore decides it on a byte that is no longer there: one control character
// in front of `---` is a thematic break with the Paragraph's speech gone from
// the page entirely, and four in front of ordinary speech is a code block.
//
// So the flattened run comes off first and the block start is decided on what a
// reader will actually see first. Dropped rather than written out as a space,
// unlike the ones inside the line: a space separates what stood either side of
// it, and at the start of a line there is nothing on the left to separate.
@(private)
write_prose :: proc(out: ^strings.Builder, said: string) {
	assert(out != nil, "there is no document here to write prose into")

	prose := readable_from(said)
	// The read side of what spoken_text settles as it trims (CLAUDE.md A4): a
	// Cue holding nothing a reader could see is not a Saying, so no Paragraph is
	// built out of one, so no Paragraph's prose can flatten away to nothing.
	assert(len(prose) > 0, "a paragraph holding nothing a reader could see reached the renderer")
	assert(prose[0] != ' ', "prose still carrying the engine's padding reached the renderer")

	write_inline(out, write_block_start(out, prose))
}

// The speech from the first byte of it a reader will actually see.
//
// Every byte before that one is written out as a space by write_inline or is
// already a space, and a run of them at the start of a line is Markdown's own
// indentation. A byte at a time and never a rune at a time, for the reason
// write_inline gives: every byte this skips is ASCII, and every byte of a
// multi-byte character is at or above 0x80 and stops the scan.
@(private)
readable_from :: proc(said: string) -> (prose: string) {
	defer assert(len(prose) <= len(said), "skipping a paragraph's indentation grew it")

	at := 0
	for at < len(said) && (said[at] < 0x20 || said[at] == 0x7F || said[at] == ' ') {
		at += 1
	}
	return said[at:]
}

// Escapes what opens a block, and hands back the speech that is left.
//
// Returns `said` untouched where nothing at its start is structure, so the one
// caller's two steps cannot both write the same byte.
@(private)
write_block_start :: proc(out: ^strings.Builder, said: string) -> (rest: string) {
	assert(out != nil, "there is no document here to open a paragraph in")
	defer assert(len(rest) <= len(said), "escaping a block opener grew the speech behind it")

	if len(said) == 0 {
		return said
	}
	if strings.index_byte(BLOCK_STARTERS, said[0]) >= 0 {
		strings.write_byte(out, '\\')
		strings.write_byte(out, said[0])
		return said[1:]
	}

	// A year read out at the start of a Paragraph -- "1999. That was the year" --
	// is an ordered list numbered from 1999 to every Markdown reader there is, and
	// the year itself leaves the page. It is the stop that has to carry the
	// backslash: the digits in front of it are the text worth keeping.
	digits := 0
	for digits < len(said) && said[digits] >= '0' && said[digits] <= '9' {
		digits += 1
	}
	if digits == 0 || digits >= len(said) {
		return said
	}
	if said[digits] != '.' && said[digits] != ')' {
		return said
	}
	strings.write_string(out, said[:digits])
	strings.write_byte(out, '\\')
	strings.write_byte(out, said[digits])
	return said[digits + 1:]
}

// Escapes what is structure wherever it falls, and flattens what would end the
// line.
//
// A byte at a time and never a rune at a time, deliberately: every byte this
// touches is ASCII, and every byte of a multi-byte character is at or above 0x80
// and falls through untouched. Decoding runes to make the same decision would
// cost a pass over the speech for an answer it already has.
@(private)
write_inline :: proc(out: ^strings.Builder, said: string) {
	assert(out != nil, "there is no document here to write speech into")

	for i in 0 ..< len(said) {
		if strings.index_byte(INLINE_SPECIALS, said[i]) >= 0 {
			strings.write_byte(out, '\\')
			strings.write_byte(out, said[i])
			continue
		}
		// A line break the Engine wrote into a Cue. The parser is lossless on
		// purpose, so it arrives here intact, and a Paragraph carrying one is TWO
		// lines to a Markdown reader -- the second of which is unescaped by
		// everything above, because everything above escapes the start of the
		// Paragraph and this is the start of a line the Paragraph never had.
		// A space instead: what it separated is still separated.
		if said[i] < 0x20 || said[i] == 0x7F {
			strings.write_byte(out, ' ')
			continue
		}
		strings.write_byte(out, said[i])
	}
}

// What an Anchor is written as: a Markdown heading, so that every viewer there
// is puts it in an outline a reader can jump through.
//
// A heading and not bold text or a bare line, because "find my place in the
// Recording" (spec story 33) is navigation, and navigation is what an outline
// is. The level is the second: a Transcript has no title of its own -- the front
// matter carries the source -- so nothing sits above these for them to nest
// under, and starting at the first level would make each Anchor look like the
// heading of a separate document when several are pasted together.
@(private)
ANCHOR_HEADING :: "## "

// Writes an Anchor naming a moment in the Recording, as `hh:mm:ss`.
//
// Hours RUN ON past twenty-four rather than wrapping into days: a Recording
// longer than a day is unusual and not impossible, and an Anchor that wrapped
// would send a reader seeking `01:00:00` to whichever of the two hours they
// looked at first. Truncated rather than rounded to the second, because an
// Anchor rounded up names a moment its Paragraph had not reached.
@(private)
write_anchor :: proc(out: ^strings.Builder, at: Millis) {
	assert(out != nil, "there is no document here to place an anchor in")
	// An offset is a count from the start of the Recording, so there is nothing
	// before zero to anchor. parse_cues refuses a negative offset on the way in
	// (CLAUDE.md A4); this is the same claim where the number is finally read.
	assert(at >= 0, "an anchor at a moment before the recording started")

	seconds := i64(at) / 1_000
	assert(seconds >= 0, "a non-negative offset counted out a negative number of seconds")

	strings.write_byte(out, '\n')
	strings.write_string(out, ANCHOR_HEADING)
	fmt.sbprintf(out, "%02d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
	strings.write_byte(out, '\n')
}

// Writes the block a Transcript found on its own months later is read by.
//
// Seven fields in a fixed order. Five are spec story 39's -- Model, Merge
// Profile, Engine version, detected language, transcibr's own version -- and the
// other two are what ADR-0009 names as the rest of the Render Context. The order
// is fixed because a re-render has to produce the same bytes (spec story 44),
// and a map would not.
//
// `generator` is first and is what ADR-0008 has planning look for: an existing
// Markdown file beside a Recording counts as a Transcript only if it parses as
// transcibr's own output and carries this key, so somebody's own notes are
// reported rather than overwritten.
@(private)
write_front_matter :: proc(out: ^strings.Builder, rc: Render_Context, allocator: mem.Allocator) {
	assert(out != nil, "there is no document here to write a header into")
	assert(allocator.procedure != nil, "the version line and the date outlive their writes")

	// version.banner asserts the shape of what it hands back, so a generator line
	// that could not be read back apart fails there rather than here.
	generator := version.banner(GENERATOR, version.CURRENT, allocator)
	defer delete(generator, allocator)

	// `false` for nanoseconds: a Transcript is stamped to the second, and a
	// fractional part that appears only when the clock happened to land off a
	// second boundary is a byte the fixture could not pin.
	generated, dated := time.time_to_rfc3339(rc.now, 0, false, allocator)
	defer delete(generated, allocator)
	// The clock read comes from this program's own shell rather than from outside
	// it, so a moment no calendar can name is a defect here and not an operating
	// error (CLAUDE.md A8).
	assert(dated, "the clock read handed in is not a moment that can be written down")

	strings.write_string(out, FENCE)
	strings.write_byte(out, '\n')
	write_yaml_field(out, "generator", generator)
	write_yaml_field(out, "source", rc.source_display)
	write_yaml_field(out, "generated", generated)
	write_yaml_field(out, "engine", rc.engine_version)
	write_yaml_field(out, "model", rc.model)
	write_yaml_field(out, "language", rc.language)
	write_yaml_field(out, "merge_profile", profile_name(rc.profile))
	strings.write_string(out, FENCE)
	strings.write_byte(out, '\n')
}

// One `key: "value"` line.
//
// Every value is quoted, without exception and without asking whether this one
// needed it. A Recording called `talk: part two.mp4` breaks an unquoted scalar,
// a Model path beginning `C:\` carries an escape YAML reads, and a language the
// Engine reported as something other than two letters is text nobody vetted --
// so the rule is one rule rather than a predicate that has to be right about
// every value it waves through.
@(private)
write_yaml_field :: proc(out: ^strings.Builder, key, value: string) {
	assert(out != nil, "there is no header here to write a field into")
	assert(len(key) > 0, "a front matter field with no name")
	// The shell fills every one of these, substituting its own word where it has
	// nothing (ADR-0003 -- absent provenance beats wrong provenance). An empty one
	// is therefore a field it forgot, not a fact nobody had.
	assert(len(value) > 0, "a front matter field the shell left empty")

	strings.write_string(out, key)
	strings.write_string(out, ": ")
	write_yaml_quoted(out, value)
	strings.write_byte(out, '\n')
}

// Writes a value as a YAML double-quoted scalar.
//
// Double-quoted and not single: it is the one YAML form with an escape sequence
// for every byte, so a value carrying a newline stays on its own line instead of
// closing the header early and turning the rest of the Transcript into a
// document whose first half is metadata.
@(private)
write_yaml_quoted :: proc(out: ^strings.Builder, value: string) {
	assert(out != nil, "there is no header here to write a value into")

	strings.write_byte(out, '"')
	for i in 0 ..< len(value) {
		switch value[i] {
		case '\\':
			strings.write_string(out, `\\`)
		case '"':
			strings.write_string(out, `\"`)
		case '\n':
			strings.write_string(out, `\n`)
		case '\r':
			strings.write_string(out, `\r`)
		case '\t':
			strings.write_string(out, `\t`)
		case 0x00 ..= 0x1F, 0x7F:
			// Everything else a text editor renders as nothing at all. Written as
			// the byte it is, because a control character dropped silently is a
			// front matter field that no longer matches what planning recorded.
			//
			// Lower case, because YAML's `\x` escape is written that way and a
			// header this program cannot read back is a Transcript planning treats
			// as somebody's notes (ADR-0008). `%x` is lower case, which is the
			// whole of what a sixteen-entry table of hex digits beside this was
			// for -- and core:fmt is already how write_anchor lays out a number.
			fmt.sbprintf(out, `\x%02x`, value[i])
		case:
			strings.write_byte(out, value[i])
		}
	}
	strings.write_byte(out, '"')
}
