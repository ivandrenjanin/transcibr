#+vet explicit-allocators
package transcript

import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"

// Pinned here so that tuning MONOLOGUE and CONVERSATION moves no case's meaning.
@(private)
PINNED_MERGE :: Merge_Params {
	max_gap_ms     = 1_000,
	hard_gap_ms    = 3_000,
	max_para_chars = 2_000,
}

@(test)
a_short_gap_does_not_break_a_paragraph :: proc(t: ^testing.T) {
	shape := []Shaped_Cue {
		{duration_ms = 3_480, text = " This is a recording made to exercise the merger."},
		{
			gap_ms = 400,
			duration_ms = 4_060,
			text = " The engine emits one fragment of speech at a time,",
		},
		{gap_ms = 120, duration_ms = 4_620, text = " and the merger puts them back together."},
	}
	cues := shaped_cues(shape, context.allocator)
	defer delete(cues, context.allocator)

	paragraphs := merge_paragraphs(cues, PINNED_MERGE, context.allocator)
	defer destroy_paragraphs(paragraphs, context.allocator)

	if !testing.expect_value(t, len(paragraphs), 1) {
		return
	}
	testing.expect_value(t, paragraphs[0].start, Millis(0))
	testing.expect_value(t, paragraphs[0].end, Millis(12_680))
	testing.expect_value(
		t,
		paragraphs[0].text,
		"This is a recording made to exercise the merger. The engine emits one fragment of speech at a time, and the merger puts them back together.",
	)
}

@(test)
a_long_gap_after_a_sentence_breaks_a_paragraph :: proc(t: ^testing.T) {
	shape := []Shaped_Cue {
		{duration_ms = 3_480, text = " That is the first thing I wanted to say."},
		{
			gap_ms = 2_400,
			duration_ms = 4_060,
			text = " The second one needs a paragraph of its own.",
		},
	}
	cues := shaped_cues(shape, context.allocator)
	defer delete(cues, context.allocator)

	paragraphs := merge_paragraphs(cues, PINNED_MERGE, context.allocator)
	defer destroy_paragraphs(paragraphs, context.allocator)

	expected := []Paragraph {
		{0, 3_480, "That is the first thing I wanted to say."},
		{5_880, 9_940, "The second one needs a paragraph of its own."},
	}
	if !testing.expect_value(t, len(paragraphs), len(expected)) {
		return
	}
	for want, i in expected {
		testing.expect_value(t, paragraphs[i], want)
	}
}

@(test)
the_same_gap_in_the_middle_of_a_sentence_does_not :: proc(t: ^testing.T) {
	shape := []Shaped_Cue {
		{duration_ms = 3_480, text = " That is the first thing I wanted to say,"},
		{
			gap_ms = 2_400,
			duration_ms = 4_060,
			text = " and the second follows straight on from it.",
		},
	}
	cues := shaped_cues(shape, context.allocator)
	defer delete(cues, context.allocator)

	paragraphs := merge_paragraphs(cues, PINNED_MERGE, context.allocator)
	defer destroy_paragraphs(paragraphs, context.allocator)

	if !testing.expect_value(t, len(paragraphs), 1) {
		return
	}
	testing.expect_value(
		t,
		paragraphs[0].text,
		"That is the first thing I wanted to say, and the second follows straight on from it.",
	)
}

@(test)
a_gap_past_the_hard_threshold_breaks_a_paragraph_mid_sentence :: proc(t: ^testing.T) {
	shape := []Shaped_Cue {
		{duration_ms = 3_480, text = " That is the first thing I wanted to say,"},
		{
			gap_ms = 5_000,
			duration_ms = 4_060,
			text = " and this is what came after a very long pause.",
		},
	}
	cues := shaped_cues(shape, context.allocator)
	defer delete(cues, context.allocator)

	paragraphs := merge_paragraphs(cues, PINNED_MERGE, context.allocator)
	defer destroy_paragraphs(paragraphs, context.allocator)

	expected := []Paragraph {
		{0, 3_480, "That is the first thing I wanted to say,"},
		{8_480, 12_540, "and this is what came after a very long pause."},
	}
	if !testing.expect_value(t, len(paragraphs), len(expected)) {
		return
	}
	for want, i in expected {
		testing.expect_value(t, paragraphs[i], want)
	}
}

@(test)
silence_the_engine_covered_with_an_empty_cue_still_breaks_a_paragraph :: proc(t: ^testing.T) {
	shape := []Shaped_Cue {
		{duration_ms = 3_480, text = " That is the first thing I wanted to say."},
		{duration_ms = 30_000, text = ""},
		{duration_ms = 4_060, text = " And that is the second."},
	}
	cues := shaped_cues(shape, context.allocator)
	defer delete(cues, context.allocator)

	paragraphs := merge_paragraphs(cues, PINNED_MERGE, context.allocator)
	defer destroy_paragraphs(paragraphs, context.allocator)

	expected := []Paragraph {
		{0, 3_480, "That is the first thing I wanted to say."},
		{33_480, 37_540, "And that is the second."},
	}
	if !testing.expect_value(t, len(paragraphs), len(expected)) {
		return
	}
	for want, i in expected {
		testing.expect_value(t, paragraphs[i], want)
	}
}

@(private)
@(require_results)
paragraph_prose :: proc(paragraphs: []Paragraph, sep: string, allocator: mem.Allocator) -> string {
	assert(len(paragraphs) > 0, "no paragraphs to put back together")
	assert(allocator.procedure != nil, "the joined prose outlives this procedure")

	parts := make([]string, len(paragraphs), allocator)
	defer delete(parts, allocator)
	for paragraph, i in paragraphs {
		parts[i] = paragraph.text
	}
	return strings.join(parts, sep, allocator)
}

@(private)
@(require_results)
cue_speech :: proc(cues: []Cue, allocator: mem.Allocator) -> string {
	assert(len(cues) > 0, "no cues to put back together")
	assert(allocator.procedure != nil, "the joined speech outlives this procedure")

	parts := slice.mapper(cues, spoken_text, allocator)
	defer delete(parts, allocator)
	assert(len(parts) == len(cues), "a cue went missing on the way to its speech")
	return strings.join(parts, " ", allocator)
}

@(test)
a_paragraph_never_exceeds_the_character_cap :: proc(t: ^testing.T) {
	tight := Merge_Params {
		max_gap_ms     = 1_000,
		hard_gap_ms    = 3_000,
		max_para_chars = 120,
	}
	shape := []Shaped_Cue {
		{duration_ms = 4_000, text = " and we went on talking about it for a while,"},
		{duration_ms = 4_000, text = " with nobody stopping to finish a sentence anywhere,"},
		{duration_ms = 4_000, text = " which is the shape of speech this cap exists for,"},
		{duration_ms = 4_000, text = " and it runs on well past anything a reader can hold,"},
		{duration_ms = 4_000, text = " so the merger has to put a break in somewhere itself."},
	}
	cues := shaped_cues(shape, context.allocator)
	defer delete(cues, context.allocator)

	paragraphs := merge_paragraphs(cues, tight, context.allocator)
	defer destroy_paragraphs(paragraphs, context.allocator)

	testing.expect(t, len(paragraphs) > 1, "the cap broke nothing on speech four times its length")
	for paragraph, i in paragraphs {
		held := strings.rune_count(paragraph.text)
		testing.expectf(
			t,
			held <= tight.max_para_chars,
			"paragraph %d holds %d characters",
			i + 1,
			held,
		)
		testing.expectf(t, held > 0, "paragraph %d holds nothing at all", i + 1)
	}

	prose := paragraph_prose(paragraphs, " ", context.allocator)
	defer delete(prose, context.allocator)
	speech := cue_speech(cues, context.allocator)
	defer delete(speech, context.allocator)
	testing.expect_value(t, prose, speech)
}

@(test)
a_cue_longer_than_the_cap_is_carved_rather_than_looping :: proc(t: ^testing.T) {
	tight := Merge_Params {
		max_gap_ms     = 1_000,
		hard_gap_ms    = 3_000,
		max_para_chars = 10,
	}
	shape := []Shaped_Cue {
		{
			duration_ms = 4_000,
			text = " Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch",
		},
	}
	word := strings.trim_space(shape[0].text)
	cues := shaped_cues(shape, context.allocator)
	defer delete(cues, context.allocator)

	paragraphs := merge_paragraphs(cues, tight, context.allocator)
	defer destroy_paragraphs(paragraphs, context.allocator)

	if !testing.expect_value(t, len(paragraphs), 6) {
		return
	}
	for paragraph, i in paragraphs {
		held := strings.rune_count(paragraph.text)
		testing.expectf(
			t,
			held <= tight.max_para_chars,
			"piece %d holds %d characters",
			i + 1,
			held,
		)
		testing.expectf(t, held > 0, "piece %d holds nothing at all", i + 1)
		testing.expectf(t, paragraph.start == 0, "piece %d starts at %v", i + 1, paragraph.start)
		testing.expectf(t, paragraph.end == 4_000, "piece %d ends at %v", i + 1, paragraph.end)
	}

	prose := paragraph_prose(paragraphs, "", context.allocator)
	defer delete(prose, context.allocator)
	testing.expect_value(t, prose, word)
}

@(test)
carved_paragraphs_all_claim_their_cue_and_so_overlap_each_other :: proc(t: ^testing.T) {
	tight := Merge_Params {
		max_gap_ms     = 1_000,
		hard_gap_ms    = 3_000,
		max_para_chars = 20,
	}
	long := strings.repeat("x", 70, context.allocator)
	defer delete(long, context.allocator)
	shape := []Shaped_Cue {
		{duration_ms = 1_000, text = " hi there"},
		{duration_ms = 60_000, text = long},
		{duration_ms = 1_000, text = " done"},
	}
	cues := shaped_cues(shape, context.allocator)
	defer delete(cues, context.allocator)

	paragraphs := merge_paragraphs(cues, tight, context.allocator)
	defer destroy_paragraphs(paragraphs, context.allocator)

	expected := []Paragraph {
		{0, 1_000, "hi there"},
		{1_000, 61_000, "xxxxxxxxxxxxxxxxxxxx"},
		{1_000, 61_000, "xxxxxxxxxxxxxxxxxxxx"},
		{1_000, 61_000, "xxxxxxxxxxxxxxxxxxxx"},
		{1_000, 62_000, "xxxxxxxxxx done"},
	}
	if !testing.expect_value(t, len(paragraphs), len(expected)) {
		return
	}
	for want, i in expected {
		testing.expect_value(t, paragraphs[i], want)
	}

	overlapped := 0
	for paragraph, i in paragraphs[1:] {
		if paragraph.start < paragraphs[i].end {
			overlapped += 1
		}
	}
	testing.expect_value(t, overlapped, 3)
}

@(test)
the_character_cap_counts_characters_and_not_bytes :: proc(t: ^testing.T) {
	said := "Déjà vu, déjà vu, déjà vu"
	tight := Merge_Params {
		max_gap_ms     = 1_000,
		hard_gap_ms    = 3_000,
		max_para_chars = 25,
	}
	testing.expect_value(t, strings.rune_count(said), 25)
	testing.expect_value(t, len(said), 31)

	shape := []Shaped_Cue{{duration_ms = 2_000, text = " Déjà vu, déjà vu, déjà vu"}}
	cues := shaped_cues(shape, context.allocator)
	defer delete(cues, context.allocator)

	paragraphs := merge_paragraphs(cues, tight, context.allocator)
	defer destroy_paragraphs(paragraphs, context.allocator)

	if !testing.expect_value(t, len(paragraphs), 1) {
		return
	}
	testing.expect_value(t, paragraphs[0].text, said)
}

@(test)
merging_no_cues_yields_no_paragraphs :: proc(t: ^testing.T) {
	paragraphs := merge_paragraphs(nil, PINNED_MERGE, context.allocator)
	defer destroy_paragraphs(paragraphs, context.allocator)

	testing.expect_value(t, len(paragraphs), 0)
	testing.expect(
		t,
		paragraphs == nil,
		"an empty paragraph set came back with memory behind it to free",
	)
}

@(test)
merging_cues_that_say_nothing_yields_no_paragraphs :: proc(t: ^testing.T) {
	shape := []Shaped_Cue {
		{duration_ms = 10_000, text = ""},
		{duration_ms = 10_000, text = " "},
		{duration_ms = 10_000, text = "\t\r\n"},
	}
	cues := shaped_cues(shape, context.allocator)
	defer delete(cues, context.allocator)

	paragraphs := merge_paragraphs(cues, PINNED_MERGE, context.allocator)
	defer destroy_paragraphs(paragraphs, context.allocator)

	testing.expect_value(t, len(paragraphs), 0)
	testing.expect(
		t,
		paragraphs == nil,
		"an empty paragraph set came back with memory behind it to free",
	)
}

@(test)
real_engine_output_becomes_paragraphs :: proc(t: ^testing.T) {
	cues, err := parse_cues("engine-output.json", ENGINE_JSON, FIXTURE_DURATION, context.allocator)
	defer destroy_cues(cues, context.allocator)
	if !testing.expect_value(t, err.fault, Parse_Fault.None) {
		return
	}

	kept := collapse_repetition(cues, COLLAPSE_THRESHOLDS, context.allocator)
	defer destroy_cues(kept, context.allocator)
	if !testing.expect_value(t, len(kept), 7) {
		return
	}
	testing.expect_value(t, kept[6], Cue{30_000, 59_980, " Thank you."})

	merged := merge_paragraphs(kept, MONOLOGUE, context.allocator)
	defer destroy_paragraphs(merged, context.allocator)
	if !testing.expect_value(t, len(merged), 1) {
		return
	}
	testing.expect_value(t, merged[0].start, Millis(0))
	testing.expect_value(t, merged[0].end, Millis(59_980))
	testing.expect_value(
		t,
		merged[0].text,
		"This is a recording made to exercise the Q-Parser. The engine emits one time-stamped fragment of speech at a time. Each fragment carries a start offset, an end offset, and its text. The offsets arrive in miliscans, counted from the beginning of the recording. A parser that reads them as integers will find none, because the numbers are floating point. That is the whole point of this fixture. Thank you.",
	)

	broken := merge_paragraphs(kept, CONVERSATION, context.allocator)
	defer destroy_paragraphs(broken, context.allocator)
	testing.expect_value(t, len(broken), 7)
	testing.expect_value(t, broken[6], Paragraph{30_000, 59_980, "Thank you."})
}

@(test)
a_run_of_spaces_is_kept_whole_or_is_the_break :: proc(t: ^testing.T) {
	said := " one  two   three    four"
	shape := []Shaped_Cue{{duration_ms = 2_000, text = said}}
	cues := shaped_cues(shape, context.allocator)
	defer delete(cues, context.allocator)

	roomy := Merge_Params {
		max_gap_ms     = 1_000,
		hard_gap_ms    = 3_000,
		max_para_chars = 30,
	}
	whole := merge_paragraphs(cues, roomy, context.allocator)
	defer destroy_paragraphs(whole, context.allocator)
	if testing.expect_value(t, len(whole), 1) {
		testing.expect_value(t, whole[0].text, strings.trim_space(said))
	}

	tight := Merge_Params {
		max_gap_ms     = 1_000,
		hard_gap_ms    = 3_000,
		max_para_chars = 10,
	}
	broken := merge_paragraphs(cues, tight, context.allocator)
	defer destroy_paragraphs(broken, context.allocator)

	expected := []string{"one  two", "three", "four"}
	if !testing.expect_value(t, len(broken), len(expected)) {
		return
	}
	for want, i in expected {
		testing.expect_value(t, broken[i].text, want)
	}
}

@(test)
a_carve_at_a_word_boundary_leaves_no_padding_behind :: proc(t: ^testing.T) {
	tight := Merge_Params {
		max_gap_ms     = 1_000,
		hard_gap_ms    = 3_000,
		max_para_chars = 5,
	}
	shape := []Shaped_Cue{{duration_ms = 2_000, text = "  one  two   three  "}}
	cues := shaped_cues(shape, context.allocator)
	defer delete(cues, context.allocator)

	paragraphs := merge_paragraphs(cues, tight, context.allocator)
	defer destroy_paragraphs(paragraphs, context.allocator)

	expected := []string{"one", "two", "three"}
	if !testing.expect_value(t, len(paragraphs), len(expected)) {
		return
	}
	for want, i in expected {
		testing.expect_value(t, paragraphs[i].text, want)
	}
}

// One control byte mid-Cue is ordinary Engine output, and it takes a whole Batch down.
@(test)
a_carve_around_a_byte_nobody_said_never_makes_a_paragraph_of_it :: proc(t: ^testing.T) {
	tight := Merge_Params {
		max_gap_ms     = 1_000,
		hard_gap_ms    = 3_000,
		max_para_chars = 4,
	}
	for c in INTERIOR_SILENCE_CASES {
		shape := []Shaped_Cue{{duration_ms = 2_000, text = c.said}}
		cues := shaped_cues(shape, context.allocator)
		defer delete(cues, context.allocator)

		paragraphs := merge_paragraphs(cues, tight, context.allocator)
		defer destroy_paragraphs(paragraphs, context.allocator)

		if !testing.expectf(
			t,
			len(paragraphs) == len(c.becomes),
			"%q became %d paragraphs, want %d",
			c.said,
			len(paragraphs),
			len(c.becomes),
		) {
			continue
		}
		for want, i in c.becomes {
			testing.expectf(
				t,
				paragraphs[i].text == want,
				"%q: paragraph %d reads %q, want %q",
				c.said,
				i + 1,
				paragraphs[i].text,
				want,
			)
		}
	}
}

// Not rodata: the rows hold slices, and rodata takes only constant initialisation.
@(private)
Interior_Silence_Case :: struct {
	said:    string,
	becomes: []string,
}

@(private)
INTERIOR_SILENCE_CASES := []Interior_Silence_Case {
	{said = " aaaa \x01 bbbbbbbbbbbb", becomes = {"aaaa", "bbbb", "bbbb", "bbbb"}},
	{said = " ab\x01cd efgh", becomes = {"ab", "cd", "efgh"}},
}
