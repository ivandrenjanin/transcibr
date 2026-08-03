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
//
// Rejoining with ONE space is honest here because the speech is single-spaced:
// every break the cap makes falls at exactly the one space this puts back. It
// would not be honest on speech carrying runs of them, and that is a different
// case with a different expectation.
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
	// Derived rather than written twice: the same 58 characters spelled out in
	// two literals is two things to keep in step, and the case that puts them
	// back together would pass a drift between them straight through.
	shape := []Shaped_Cue{{duration_ms = 4_000, text = " Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch"}}
	word := strings.trim_space(shape[0].text)
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

// The consequence of that, on a Cue set rather than on one Cue, RECORDED rather
// than fixed.
//
// Nothing in the Engine's output says where inside a Cue a carve landed, so the
// alternative is inventing an offset by interpolation and putting an Anchor at a
// time nobody spoke. That trade is deliberate. What it costs is not visible on a
// single-Cue set, and this is it: every piece carved out of one long Cue claims
// that Cue's whole span, so a Paragraph ENDS a minute after the next one STARTS,
// and four of them sit within one second of each other across a minute of
// speech.
//
// CONTEXT.md defines an Anchor as what lets a reader find their place. Four
// Anchors a second apart over a minute of speech does not, so the Anchor ticket
// has to decide what to do here -- place Anchors off Paragraph starts and it
// emits four identical ones, take the first per stretch and three Paragraphs go
// unanchored. This case exists so that ticket finds the problem stated rather
// than discovers it.
@(test)
carved_paragraphs_all_claim_their_cue_and_so_overlap_each_other :: proc(t: ^testing.T) {
	tight := Merge_Params{max_gap_ms = 1_000, hard_gap_ms = 3_000, max_para_chars = 20}
	// One Cue holding a minute of Recording and one unbroken 70-character word,
	// between two ordinary short ones.
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

	// Offsets copied off the shape by hand. Everything carved out of the middle
	// Cue carries that Cue's own start and end, the last piece picking up the
	// short Cue that follows it.
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

	// The part that bites, said as its own claim rather than left to be read off
	// the table above: consecutive Paragraphs overlap, and by a minute.
	overlapped := 0
	for paragraph, i in paragraphs[1:] {
		if paragraph.start < paragraphs[i].end {
			overlapped += 1
		}
	}
	testing.expect_value(t, overlapped, 3)
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
	// The same claim the no-Cues case makes, by the other route into it: this one
	// reaches the end with an array reserved and never filled, and a reservation
	// handed back unshrunk is a block destroy_paragraphs frees at the wrong size.
	testing.expect(t, paragraphs == nil, "an empty paragraph set came back with memory behind it to free")
}

// ---------------------------------------------------------------------------
// Both stages over the one real Engine output in this repository.
//
// The fixtures above are shapes chosen to isolate one threshold at a time, which
// is what makes them readable and what makes them not proof. This is the whole
// of the ticket's work -- parse, collapse, merge -- run over 30 seconds of
// speech a real Engine really transcribed, hallucination and mishearing intact.
// ---------------------------------------------------------------------------

// The fixture's gaps are 900, 920, 980, 1040, 660 and 520 ms, every Cue ends a
// sentence, and the whole thing is 397 characters. So the generous profile
// merges all of it and the aggressive one breaks at every seam -- the two
// profiles at their furthest apart, on material neither was tuned against.
@(test)
real_engine_output_becomes_paragraphs :: proc(t: ^testing.T) {
	cues, err := parse_cues("engine-output.json", ENGINE_JSON, FIXTURE_DURATION, context.allocator)
	defer destroy_cues(cues, context.allocator)
	if !testing.expect_value(t, err.fault, Parse_Fault.None) {
		return
	}

	// Nothing here repeats, so nothing collapses. The Engine's invention over the
	// trailing silence -- " Thank you.", dated past the end of a Recording that
	// runs 30356 ms -- is a SINGLE Cue and not a run, and repetition detection is
	// the only handle there is (ADR-0001). It survives, un-clamped, because a
	// stage that clamped it would be hiding the evidence rather than reading it.
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

// What the Engine wrote between two words is the Engine's, and a run of spaces
// is never quietly rewritten into one. A run has exactly two fates: it stays
// inside a Paragraph byte for byte, or the cap breaks at it and it is the break.
//
// There was a third, and it was silent. The carve loop split at the run, dropped
// it, and then carried on filling the SAME Paragraph -- where the seam space
// that stands between two Cues went in instead. Four spaces came back as one,
// inside one Paragraph, and the character cap counted the Paragraph three
// characters shorter than the speech it was made of.
@(test)
a_run_of_spaces_is_kept_whole_or_is_the_break :: proc(t: ^testing.T) {
	said := " one  two   three    four"
	shape := []Shaped_Cue{{duration_ms = 2_000, text = said}}
	cues := shaped_cues(shape, context.allocator)
	defer delete(cues, context.allocator)

	// Room for all of it: nothing breaks, so every run is left exactly alone.
	roomy := Merge_Params{max_gap_ms = 1_000, hard_gap_ms = 3_000, max_para_chars = 30}
	whole := merge_paragraphs(cues, roomy, context.allocator)
	defer destroy_paragraphs(whole, context.allocator)
	if testing.expect_value(t, len(whole), 1) {
		testing.expect_value(t, whole[0].text, strings.trim_space(said))
	}

	// Room for eight characters at a time: each run the cap reaches is a break,
	// and no run survives as a single space on either side of one.
	tight := Merge_Params{max_gap_ms = 1_000, hard_gap_ms = 3_000, max_para_chars = 10}
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

// A Paragraph's prose is prose: the Engine's padding is off it and it does not
// end in the space the carve happened to break at. A trailing space reaches the
// deliverable and is spent against the cap -- at a cap of five, "one  two" would
// come back holding four characters of speech and one of nothing.
//
// Every run of spaces here is one the cap breaks at, so every one of them is a
// break and none survives. The case above is the one that says what happens to
// a run the cap does NOT reach.
@(test)
a_carve_at_a_word_boundary_leaves_no_padding_behind :: proc(t: ^testing.T) {
	tight := Merge_Params{max_gap_ms = 1_000, hard_gap_ms = 3_000, max_para_chars = 5}
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
