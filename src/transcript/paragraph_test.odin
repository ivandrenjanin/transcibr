package transcript

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
