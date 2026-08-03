package transcript

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
	for paragraph in paragraphs {
		strings.write_byte(&out, '\n')
		strings.write_string(&out, paragraph.text)
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
			strings.write_string(out, `\x`)
			strings.write_byte(out, HEX[value[i] >> 4])
			strings.write_byte(out, HEX[value[i] & 0x0F])
		case:
			strings.write_byte(out, value[i])
		}
	}
	strings.write_byte(out, '"')
}

// Lower case, because YAML's `\x` escape is written that way and a header this
// program cannot read back is a Transcript planning treats as somebody's notes
// (ADR-0008).
@(private, rodata)
HEX := [16]u8{'0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f'}
