package transcript

import "core:mem"
import "core:strings"
import "core:testing"

// The thresholds every case below pins for itself, so that tuning MONOLOGUE and
// CONVERSATION -- which ADR-0007 says is expected, and is the one part of this
// program tuned by reading real output -- moves no test's meaning. The profiles
// get their own cases, which are about the difference between them rather than
// about any number in either.
@(private)
PINNED_MERGE :: Merge_Params {
	max_gap_ms     = 1_000,
	hard_gap_ms    = 3_000,
	max_para_chars = 2_000,
}

// The Engine cuts a Cue every few seconds and mid-sentence, so the silence
// between two Cues is usually nothing at all. A Paragraph that broke on those
// would be the subtitle dump this program exists not to produce.
@(test)
a_short_gap_does_not_break_a_paragraph :: proc(t: ^testing.T) {
	shape := []Shaped_Cue {
		{duration_ms = 3_480, text = " This is a recording made to exercise the merger."},
		{gap_ms = 400, duration_ms = 4_060, text = " The engine emits one fragment of speech at a time,"},
		{gap_ms = 120, duration_ms = 4_620, text = " and the merger puts them back together."},
	}
	cues := shaped_cues(shape, context.allocator)
	defer delete(cues, context.allocator)

	paragraphs := merge_paragraphs(cues, PINNED_MERGE, context.allocator)
	defer destroy_paragraphs(paragraphs, context.allocator)

	if !testing.expect_value(t, len(paragraphs), 1) {
		return
	}
	// Offsets copied off the shape by hand: 3480 + 400 + 4060 + 120 + 4620.
	testing.expect_value(t, paragraphs[0].start, Millis(0))
	testing.expect_value(t, paragraphs[0].end, Millis(12_680))
	// The Engine's leading space is gone from every Cue and one space stands at
	// each seam. Prose, not a subtitle dump with the padding still in it.
	testing.expect_value(
		t,
		paragraphs[0].text,
		"This is a recording made to exercise the merger. The engine emits one fragment of speech at a time, and the merger puts them back together.",
	)
}

// The two signals together, which is the only place either one decides anything
// (ADR-0007). This is silence past max_gap_ms landing where a sentence just
// ended.
@(test)
a_long_gap_after_a_sentence_breaks_a_paragraph :: proc(t: ^testing.T) {
	shape := []Shaped_Cue {
		{duration_ms = 3_480, text = " That is the first thing I wanted to say."},
		{gap_ms = 2_400, duration_ms = 4_060, text = " The second one needs a paragraph of its own."},
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

// The negative space of the case above (CLAUDE.md A3), and the reason the
// sentence signal is read at all. The SAME silence, in the middle of a sentence:
// a speaker drawing breath after a comma is not starting a new paragraph, and a
// merger that broke here would cut prose in half at the one place a reader
// notices.
@(test)
the_same_gap_in_the_middle_of_a_sentence_does_not :: proc(t: ^testing.T) {
	shape := []Shaped_Cue {
		{duration_ms = 3_480, text = " That is the first thing I wanted to say,"},
		{gap_ms = 2_400, duration_ms = 4_060, text = " and the second follows straight on from it."},
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

// And the silence that ends a Paragraph whatever was being said. Without this,
// a speaker who trails off mid-clause and comes back a minute later leaves one
// Paragraph with a minute of nothing inside it and no punctuation to break on.
@(test)
a_gap_past_the_hard_threshold_breaks_a_paragraph_mid_sentence :: proc(t: ^testing.T) {
	shape := []Shaped_Cue {
		{duration_ms = 3_480, text = " That is the first thing I wanted to say,"},
		{gap_ms = 5_000, duration_ms = 4_060, text = " and this is what came after a very long pause."},
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

// The Engine writes an empty Cue over silence, and it covers the silence: the
// gap in FRONT of it is nothing and the gap BEHIND it is nothing, so a merger
// reading the Cue in front of each Cue sees no pause at all where half a minute
// of it went by. Both signals are gone at once and the two halves of the
// Recording run together.
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

// ---------------------------------------------------------------------------
// The character cap.
//
// It is the only thing standing between a Recording with no pauses in it and one
// unbroken wall of text, and it is the acceptance criterion stated absolutely: a
// Paragraph NEVER exceeds it. That absolute is what forces the carve -- a Cue
// whose own speech is longer than the cap cannot be admitted whole, cannot be
// dropped, and must not send the loop that admits it round for ever.
// ---------------------------------------------------------------------------

// The Paragraphs' prose put back together, so a case can say "nothing was lost"
// rather than listing every break the cap happened to make.
@(private)
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

// The same, off the Cues that went in.
@(private)
cue_speech :: proc(cues: []Cue, allocator: mem.Allocator) -> string {
	assert(len(cues) > 0, "no cues to put back together")
	assert(allocator.procedure != nil, "the joined speech outlives this procedure")

	parts := make([]string, len(cues), allocator)
	defer delete(parts, allocator)
	for cue, i in cues {
		parts[i] = spoken_text(cue)
	}
	return strings.join(parts, " ", allocator)
}

// Speech with no pause and no full stop in it: neither signal fires, so the cap
// is the only thing that can break this and every break it makes falls at a word
// boundary. Putting the Paragraphs back together has to give back exactly what
// went in.
@(test)
a_paragraph_never_exceeds_the_character_cap :: proc(t: ^testing.T) {
	tight := Merge_Params{max_gap_ms = 1_000, hard_gap_ms = 3_000, max_para_chars = 120}
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
		testing.expectf(t, held <= tight.max_para_chars, "paragraph %d holds %d characters", i + 1, held)
		testing.expectf(t, held > 0, "paragraph %d holds nothing at all", i + 1)
	}

	prose := paragraph_prose(paragraphs, " ", context.allocator)
	defer delete(prose, context.allocator)
	speech := cue_speech(cues, context.allocator)
	defer delete(speech, context.allocator)
	testing.expect_value(t, prose, speech)
}

// One word longer than the cap, with no space anywhere in it to break at. There
// is no word boundary, so the carve falls inside the word -- and every piece of
// it still has to arrive, in order, with nothing invented between them.
@(test)
a_cue_longer_than_the_cap_is_carved_rather_than_looping :: proc(t: ^testing.T) {
	tight := Merge_Params{max_gap_ms = 1_000, hard_gap_ms = 3_000, max_para_chars = 10}
	word := "Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch"
	shape := []Shaped_Cue{{duration_ms = 4_000, text = " Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch"}}
	cues := shaped_cues(shape, context.allocator)
	defer delete(cues, context.allocator)

	paragraphs := merge_paragraphs(cues, tight, context.allocator)
	defer destroy_paragraphs(paragraphs, context.allocator)

	// 58 characters carved ten at a time, so six pieces and the last one short.
	if !testing.expect_value(t, len(paragraphs), 6) {
		return
	}
	for paragraph, i in paragraphs {
		held := strings.rune_count(paragraph.text)
		testing.expectf(t, held <= tight.max_para_chars, "piece %d holds %d characters", i + 1, held)
		testing.expectf(t, held > 0, "piece %d holds nothing at all", i + 1)
		// Every piece carries the Cue's own offsets. Nothing in the Engine's
		// output says where inside a Cue a carve landed, and inventing an
		// offset for it would put an Anchor at a time nobody spoke.
		testing.expectf(t, paragraph.start == 0, "piece %d starts at %v", i + 1, paragraph.start)
		testing.expectf(t, paragraph.end == 4_000, "piece %d ends at %v", i + 1, paragraph.end)
	}

	// Concatenated with NOTHING between them: a carve inside a word must not
	// leave a space behind where the word had none.
	prose := paragraph_prose(paragraphs, "", context.allocator)
	defer delete(prose, context.allocator)
	testing.expect_value(t, prose, word)
}

// The cap counts CHARACTERS. Every accented character the Engine writes is two
// bytes or more, so a cap enforced on bytes cuts a Recording of French short of
// one recorded in English -- silently, and only on the material where it is
// hardest to notice.
@(test)
the_character_cap_counts_characters_and_not_bytes :: proc(t: ^testing.T) {
	said := "Déjà vu, déjà vu, déjà vu"
	// Twenty-five characters and thirty-one bytes, so a cap of twenty-five holds
	// it whole by one measure and breaks it three times by the other.
	tight := Merge_Params{max_gap_ms = 1_000, hard_gap_ms = 3_000, max_para_chars = 25}
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

// ---------------------------------------------------------------------------
// Nothing in, nothing out.
// ---------------------------------------------------------------------------

@(test)
merging_no_cues_yields_no_paragraphs :: proc(t: ^testing.T) {
	paragraphs := merge_paragraphs(nil, PINNED_MERGE, context.allocator)
	defer destroy_paragraphs(paragraphs, context.allocator)

	testing.expect_value(t, len(paragraphs), 0)
	testing.expect(t, paragraphs == nil, "an empty paragraph set came back with memory behind it to free")
}

// The other way a Cue set can hold no prose. The Engine writes these over
// silence and the parser keeps them, so a Recording of nothing but silence
// arrives here as a set full of Cues that say nothing -- and a Paragraph with no
// prose in it is a blank line in the deliverable, not a paragraph.
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
}
