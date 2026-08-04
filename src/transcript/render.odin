#+vet explicit-allocators
package transcript

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"
import "transcibr:version"

// Every string is BORROWED for the length of the render and never freed here.
Render_Context :: struct {
	now:            time.Time,
	source_display: string,
	engine_version: string,
	model:          string,
	language:       string,
	profile:        Merge_Profile,
}

// Five minutes: an hour of speech carries twelve Anchors, and a remembered
// passage costs skimming one interval. Deliberately not tied to paragraphing,
// which a Merge Profile changes.
ANCHOR_INTERVAL_MS :: Millis(5 * 60 * 1_000)

#assert(ANCHOR_INTERVAL_MS > 0)

// NOT the binary's name: the window and the command-line binary both produce
// Transcripts and must produce the same bytes from the same input.
@(private)
GENERATOR :: "transcibr"

@(private)
FENCE :: "---"

// The first field of the front matter, and the one a Transcript is RECOGNISED
// by. Named rather than spelled at the write below, because `written_by_this_-`
// `program` is built out of the same three facts and a second copy of any of
// them would go stale in silence.
@(private)
GENERATOR_KEY :: "generator"

// The bytes a Transcript this program wrote OPENS with: the fence, the first
// field's key, and the name `version.banner` puts before the space and the
// number -- so a Transcript an OLDER transcibr wrote is still transcibr's, and a
// generator merely beginning with the same letters is not.
TRANSCRIPT_PREFIX :: FENCE + "\n" + GENERATOR_KEY + ": \"" + GENERATOR + " "

// Whether these bytes open a Transcript this program wrote. A PREFIX and never
// a search: a hand-authored note that quotes a Transcript somewhere in its body
// carries the same bytes, and only a file that opens with them was written here
// (ADR-0008).
//
// Exported from the package that WRITES the bytes, so the question and the
// answer cannot drift: a reader that kept its own copy of the marker would go on
// recognising nothing after a renderer change, and refuse every Recording in a
// corpus for having a stranger's Markdown beside it.
@(require_results)
written_by_transcibr :: proc(head: string) -> bool {
	return strings.has_prefix(head, TRANSCRIPT_PREFIX)
}

// A word rather than an empty value or a missing key: those two read as
// "transcibr forgot" where this reads as "nobody knew" (ADR-0003).
UNKNOWN :: "unknown"

// The document outlives this call and crosses a worker boundary (ADR-0010):
// free it with `delete`, passing the same allocator.
@(require_results)
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

	kept := collapse_repetition(cues, COLLAPSE_THRESHOLDS, allocator)
	defer destroy_cues(kept, allocator)

	paragraphs := merge_paragraphs(kept, profile_params(rc.profile), allocator)
	defer destroy_paragraphs(paragraphs, allocator)

	if len(paragraphs) == 0 {
		return "", fault_at(.Nothing_Said, json_name, 0)
	}

	return render_markdown(paragraphs, rc, ANCHOR_INTERVAL_MS, allocator), Parse_Error{}
}

// The document outlives this call and crosses a worker boundary (ADR-0010):
// free it with `delete`, passing the same allocator.
@(require_results)
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

	due := Millis(0)
	previous := Millis(0)
	for paragraph in paragraphs {
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
	assert(strings.has_prefix(markdown, FENCE), "a transcript that opens with no front matter")
	assert(strings.index_byte(markdown, '\r') == -1, "a carriage return reached the document")
	return
}

// Why this set, and what is deliberately left out of it: ADR-0021.
@(private)
INLINE_SPECIALS :: `\` + "`" + `*_[]<|`

// Why this set applies only to the byte a reader sees first: ADR-0021.
@(private)
BLOCK_STARTERS :: "#>-+=~"

// Normalised first, escaped second: write_inline flattens every byte a reader
// cannot see into a space, so deciding what opens the line on the byte the
// Engine wrote would decide it on a byte that is no longer there.
@(private)
write_prose :: proc(out: ^strings.Builder, said: string) {
	assert(out != nil, "there is no document here to write prose into")

	prose := strings.trim_left_proc(said, says_nothing)
	assert(len(prose) > 0, "a paragraph holding nothing a reader could see reached the renderer")
	assert(
		!ends_on_silence(prose),
		"a paragraph ending on something nobody said reached the renderer",
	)

	write_inline(out, write_block_start(out, prose))
}

@(private)
@(require_results)
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

// A byte at a time and never a rune at a time: every byte this touches is ASCII,
// and every byte of a multi-byte character is at or above 0x80 and falls through
// untouched.
@(private)
write_inline :: proc(out: ^strings.Builder, said: string) {
	assert(out != nil, "there is no document here to write speech into")

	for i in 0 ..< len(said) {
		if strings.index_byte(INLINE_SPECIALS, said[i]) >= 0 {
			strings.write_byte(out, '\\')
			strings.write_byte(out, said[i])
			continue
		}
		if renders_as_nothing(rune(said[i])) {
			strings.write_byte(out, ' ')
			continue
		}
		strings.write_byte(out, said[i])
	}
}

// A heading, so every viewer there is puts an Anchor in an outline a reader can
// jump through. The second level: nothing sits above these for them to nest
// under, and a first-level Anchor reads as the heading of a separate document.
@(private)
ANCHOR_HEADING :: "## "

// Hours run on past twenty-four rather than wrapping into days: an Anchor that
// wrapped would send a reader seeking `01:00:00` to whichever of the two hours
// they looked at first. Truncated rather than rounded, because an Anchor rounded
// up names a moment its Paragraph had not reached.
@(private)
write_anchor :: proc(out: ^strings.Builder, at: Millis) {
	assert(out != nil, "there is no document here to place an anchor in")
	assert(at >= 0, "an anchor at a moment before the recording started")

	seconds := i64(at) / 1_000
	assert(seconds >= 0, "a non-negative offset counted out a negative number of seconds")

	strings.write_byte(out, '\n')
	strings.write_string(out, ANCHOR_HEADING)
	fmt.sbprintf(out, "%02d:%02d:%02d", seconds / 3_600, (seconds % 3_600) / 60, seconds % 60)
	strings.write_byte(out, '\n')
}

@(private)
write_front_matter :: proc(out: ^strings.Builder, rc: Render_Context, allocator: mem.Allocator) {
	assert(out != nil, "there is no document here to write a header into")
	assert(allocator.procedure != nil, "the version line and the date outlive their writes")

	generator := version.banner(GENERATOR, version.CURRENT, allocator)
	defer delete(generator, allocator)

	generated, dated := time.time_to_rfc3339(rc.now, 0, false, allocator)
	defer delete(generated, allocator)
	assert(dated, "the clock read handed in is not a moment that can be written down")

	strings.write_string(out, FENCE)
	strings.write_byte(out, '\n')
	write_yaml_field(out, GENERATOR_KEY, generator)
	write_yaml_field(out, "source", rc.source_display)
	write_yaml_field(out, "generated", generated)
	write_yaml_field(out, "engine", rc.engine_version)
	write_yaml_field(out, "model", rc.model)
	write_yaml_field(out, "language", rc.language)
	write_yaml_field(out, "merge_profile", profile_name(rc.profile))
	strings.write_string(out, FENCE)
	strings.write_byte(out, '\n')
}

// Every value is quoted, without asking whether this one needed it: a Recording
// called `talk: part two.mp4` breaks an unquoted scalar and a Model path
// beginning `C:\` carries an escape YAML reads.
@(private)
write_yaml_field :: proc(out: ^strings.Builder, key, value: string) {
	assert(out != nil, "there is no header here to write a field into")
	assert(len(key) > 0, "a front matter field with no name")
	assert(len(value) > 0, "a front matter field the shell left empty")

	strings.write_string(out, key)
	strings.write_string(out, ": ")
	write_yaml_quoted(out, value)
	strings.write_byte(out, '\n')
}

// Double-quoted and not single: it is the one YAML form with an escape sequence
// for every byte, so a value carrying a newline cannot close the header early.
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
		case:
			if renders_as_nothing(rune(value[i])) {
				fmt.sbprintf(out, `\x%02x`, value[i])
			} else {
				strings.write_byte(out, value[i])
			}
		}
	}
	strings.write_byte(out, '"')
}
