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
