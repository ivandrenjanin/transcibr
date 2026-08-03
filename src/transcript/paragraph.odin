package transcript

import "core:mem"
import "core:strings"

// A run of consecutive Cues merged into one piece of prose, and the unit a
// reader actually reads.
//
// The offsets are kept because an Anchor is placed off them later, and because
// a Paragraph that has lost its place in the Recording cannot be checked against
// it. `text` is prose: the Engine's padding is off every Cue and one space
// stands at each seam.
Paragraph :: struct {
	start: Millis,
	end:   Millis,
	text:  string,
}

// Where paragraph breaks fall.
//
// Two signals and no more (ADR-0007): the silence between consecutive Cues, and
// whether the Cue in front ended a sentence. There is nothing else to read --
// speaker diarization is out of scope, so this handles multi-speaker material
// temporally and will still merge two people who overlap without a gap.
//
// Passed as an argument rather than read from a constant because these are taste
// and not truth. They are the one part of this program tuned by reading real
// output, and tuning is cheap because the Engine's JSON is retained (ADR-0002,
// ADR-0003) -- change the profile, re-render, no GPU. A test pins its own.
Merge_Params :: struct {
	// The silence that ends a Paragraph once a sentence has ended with it.
	max_gap_ms:     Millis,
	// The silence that ends a Paragraph whatever was said, sentence or not.
	// Never below max_gap_ms: a hard threshold under the soft one would make
	// the soft one unreachable and delete the sentence signal entirely.
	hard_gap_ms:    Millis,
	// The longest a Paragraph may run, in characters and not bytes. A wall of
	// text is unreadable however few sentences ended inside it.
	max_para_chars: int,
}

// Continuous single-speaker material: merge generously.
//
// The measured population is bimodal -- 45.8% of Cues touch outright, and 19% of
// the gaps run over two and a half seconds while the speaker pauses (ADR-0007).
// So there is very little gap mass between the two modes for a threshold to sit
// in, and one placed at a second and a half breaks at the pauses and nowhere
// else. The generous cap follows from the same shape: fewer breaks means longer
// Paragraphs, and cutting them short again at a character count would put the
// breaks back in the arbitrary places the thresholds were chosen to avoid.
MONOLOGUE :: Merge_Params {
	max_gap_ms     = 1_500,
	hard_gap_ms    = 5_000,
	max_para_chars = 2_000,
}

// Interactive material: break aggressively.
//
// A dense continuous distribution of short turns, almost nothing touching, and
// a median gap of 520 ms -- rapid speaker turns leave sub-second gaps, and a
// threshold that ignored them would merge two people into one Paragraph. It
// still will where they overlap without a gap at all: diarization is out of
// scope, this handles multi-speaker material temporally, and that limitation is
// inherent rather than a defect to be fixed later (ADR-0007).
CONVERSATION :: Merge_Params {
	max_gap_ms     = 500,
	hard_gap_ms    = 1_500,
	max_para_chars = 700,
}

// What the shipped profiles have to be for merge_paragraphs to accept them at
// all, said in checked code beside them rather than discovered on the first
// Recording that uses one (CLAUDE.md A5). The compiler answers this; the
// assertions inside merge_paragraphs answer it again for a profile a caller
// built by hand (CLAUDE.md A4).
#assert(MONOLOGUE.max_gap_ms > 0)
#assert(MONOLOGUE.hard_gap_ms >= MONOLOGUE.max_gap_ms)
#assert(MONOLOGUE.max_para_chars > 0)
#assert(CONVERSATION.max_gap_ms > 0)
#assert(CONVERSATION.hard_gap_ms >= CONVERSATION.max_gap_ms)
#assert(CONVERSATION.max_para_chars > 0)

// And what makes them two profiles rather than two spellings of one. Every
// threshold in the aggressive profile sits below its counterpart in the generous
// one, so no tuning pass can leave the pair pointing the same way while the
// names still promise otherwise.
#assert(CONVERSATION.max_gap_ms < MONOLOGUE.max_gap_ms)
#assert(CONVERSATION.hard_gap_ms < MONOLOGUE.hard_gap_ms)
#assert(CONVERSATION.max_para_chars < MONOLOGUE.max_para_chars)

// Everything a half-built Paragraph is made of, in one place so the procedures
// that add to it and close it cannot disagree about what "open" means.
@(private)
Merge_State :: struct {
	out:   [dynamic]Paragraph,
	prose: strings.Builder,
	// Characters, matching Merge_Params.max_para_chars. Counted as prose is
	// written rather than measured off the builder at every comparison: the
	// builder holds BYTES, and a cap enforced on those cuts a Recording of
	// accented speech short of one written in ASCII.
	runes: int,
	start: Millis,
	end:   Millis,
	open:  bool,
}

// Merges a Cue set into Paragraphs.
//
// The allocator is explicit and never defaulted: the Paragraphs outlive this
// procedure and cross a worker boundary (ADR-0010). Free them with
// destroy_paragraphs, passing the same allocator.
merge_paragraphs :: proc(
	cues: []Cue,
	p: Merge_Params,
	allocator: mem.Allocator,
) -> (
	paragraphs: []Paragraph,
) {
	assert(p.max_gap_ms > 0, "a paragraph that breaks on no silence at all breaks at every cue")
	assert(p.hard_gap_ms >= p.max_gap_ms, "hard gap must not sit below max gap")
	assert(p.max_para_chars > 0, "a paragraph that may hold no characters can never be closed")
	assert(allocator.procedure != nil, "the paragraphs outlive this procedure and need a chosen allocator")
	// What every consumer in this package asserts on the way in (CLAUDE.md A4).
	// Gaps are read between neighbours, and a set whose starts go backwards
	// yields negative silence where the longest pause in the Recording was.
	assert(cues_are_ordered(cues), "merging a cue set parse_cues could not have returned")

	if len(cues) == 0 {
		return nil
	}

	state := Merge_State {
		out   = make([dynamic]Paragraph, 0, len(cues), allocator),
		prose = strings.builder_make(allocator),
	}
	defer strings.builder_destroy(&state.prose)

	// The last Cue that SAID something, which is not always the last Cue. The
	// Engine writes empty and space-only Cues over silence, and measuring the
	// gap to one of those reads the silence it covers as no silence at all --
	// the merger would run a Recording's two halves together across the four
	// minutes of nothing the Engine politely filled in.
	previous: Maybe(Cue)

	for cue in cues {
		said := spoken_text(cue)
		// Such a Cue holds its place in the Cue set -- repetition collapse counts
		// runs of them -- and contributes nothing to prose. The silence it covers
		// is still counted, because `previous` did not move.
		if len(said) == 0 {
			continue
		}

		before, spoke_before := previous.?
		if spoke_before && breaks_paragraph(before, cue, p) {
			paragraph_close(&state, allocator)
		}
		paragraph_admit(&state, cue, said, p, allocator)
		previous = cue
	}
	paragraph_close(&state, allocator)

	// destroy_paragraphs frees the returned SLICE, so the block behind it has to
	// be exactly as long as the slice says.
	shrink(&state.out)
	paragraphs = state.out[:]
	assert(cap(state.out) == len(paragraphs), "the returned slice does not own exactly the block it names")
	return
}

// Frees a Paragraph set merge_paragraphs returned, and the prose of every
// Paragraph in it.
//
// The allocator is an explicit parameter and is never defaulted: these values
// outlive the procedure that made them, and under ADR-0010 a defaulted allocator
// on such a value is a defect, because `context.temp_allocator` is thread-local
// and the Paragraph set crosses workers.
destroy_paragraphs :: proc(paragraphs: []Paragraph, allocator: mem.Allocator) {
	assert(allocator.procedure != nil, "paragraphs cannot be freed without the allocator that made them")
	// The negative space of merge_paragraphs' allocation (CLAUDE.md A3): a set
	// with no backing memory but a length in it was assembled by hand out of
	// parts, and the loop below walks prose that never existed.
	if paragraphs == nil {
		assert(len(paragraphs) == 0, "a paragraph set with a length and no memory behind it")
	}

	for paragraph in paragraphs {
		// The remove side of the add (CLAUDE.md A3, A4). merge_paragraphs never
		// emits a Paragraph with nothing in it, so one arriving here belongs to
		// somebody else and freeing its prose stays silent until an unrelated
		// allocation comes back corrupted.
		assert(len(paragraph.text) > 0, "freeing a paragraph merge_paragraphs could not have returned")
		delete(paragraph.text, allocator)
	}
	delete(paragraphs, allocator)
}

// Whether a Paragraph ends between two Cues that both said something.
//
// The whole of the rule, and it is two lines long on purpose: silence past the
// hard threshold ends a Paragraph whatever was being said, and silence past the
// soft one ends it only where a sentence ended with it. Nothing else is read.
//
// The gap is negative where the Cues overlap, which is ordinary Engine output
// (the parser accepts it), and a negative gap is no silence at all.
@(private)
breaks_paragraph :: proc(before, after: Cue, p: Merge_Params) -> bool {
	assert(p.max_gap_ms > 0, "a paragraph that breaks on no silence at all breaks at every cue")
	// The same relationship merge_paragraphs asserts, at the one place that
	// depends on it (CLAUDE.md A4): a hard threshold below the soft one is
	// reached first on every gap, and the sentence signal is never read at all.
	assert(p.hard_gap_ms >= p.max_gap_ms, "hard gap must not sit below max gap")

	gap := after.start - before.end
	if gap >= p.hard_gap_ms {
		return true
	}
	if gap < p.max_gap_ms {
		return false
	}
	return ends_a_sentence(spoken_text(before))
}

// What a sentence can end with, and what may sit after it and still leave it
// ended. `…` is the Engine's own spelling of a trailing-off, and a quote or a
// bracket after the stop closes something the sentence opened.
@(private)
SENTENCE_ENDS :: ".!?…"
@(private)
SENTENCE_CLOSERS :: `"')]}»”’`

// Whether a Cue's speech ended a sentence.
//
// Read off punctuation and nothing cleverer, which is only possible because VAD
// is off: with it on the Engine emits one unbroken lower-case run carrying no
// punctuation of any kind, and this signal -- along with the gap signal beside
// it -- goes to zero (ADR-0005).
//
// It says yes to an abbreviation, and that is the right trade. A false yes costs
// one paragraph break that a reader would not have made and which still falls at
// a real pause, because it is only ever read where the silence already cleared
// max_gap_ms.
@(private)
ends_a_sentence :: proc(said: string) -> bool {
	// Paired with spoken_text's assert on the other end of the same string
	// (CLAUDE.md A4): that one checks the padding is off the front, this one
	// checks the back, which is the end this procedure reads.
	if len(said) > 0 {
		assert(said[len(said) - 1] != ' ', "asked whether padded text ends a sentence")
	}

	bare := strings.trim_right(said, SENTENCE_CLOSERS)
	assert(len(bare) <= len(said), "trimming a sentence's closers added bytes to it")
	// Shorter after the stops come off means there were stops to come off. Asked
	// this way rather than by decoding the last rune, because the cutset is
	// rune-aware and `…` is three bytes: a byte comparison would answer no to
	// every trailing-off the Engine writes.
	return len(strings.trim_right(bare, SENTENCE_ENDS)) < len(bare)
}

// Adds one Cue's speech under the cap, closing Paragraphs as it fills them and
// carving speech no Paragraph could ever hold whole.
//
// THE LOOP THAT MUST TERMINATE. Three things keep it honest, and all three are
// asserted rather than argued: a close always hands the whole cap to the next
// Paragraph, the cap is positive, and every round either closes an open
// Paragraph or consumes at least one character of what is left.
@(private)
paragraph_admit :: proc(s: ^Merge_State, cue: Cue, said: string, p: Merge_Params, allocator: mem.Allocator) {
	assert(len(said) > 0, "empty speech opens a paragraph that can never be closed")
	assert(p.max_para_chars > 0, "a paragraph that may hold no characters can never be closed")

	rest := said
	for len(rest) > 0 {
		room := paragraph_room(s^, p)
		take, tail := word_split(rest, room)

		if len(take) == 0 && s.open {
			// Not enough room left for the next whole word. Closing offers the
			// whole cap instead, which is strictly more room than there was.
			paragraph_close(s, allocator)
			continue
		}
		if len(take) == 0 {
			// One word longer than the entire cap. It cannot be admitted whole,
			// must not be dropped, and has no boundary to prefer -- so the carve
			// falls inside the word, which is the last resort and looks like one.
			assert(room == p.max_para_chars, "carved a word into a paragraph that was not empty")
			take, tail = character_split(rest, room)
		}

		assert(len(take) > 0, "a split that took no speech at all")
		assert(len(tail) < len(rest), "a split that consumed no speech at all")
		paragraph_extend(s, cue, take)
		rest = tail
	}
}

// How many more characters the Paragraph being built can hold, counting the
// space that would stand at the seam. Zero or less where what is open is already
// full; the whole cap where nothing is open.
@(private)
paragraph_room :: proc(s: Merge_State, p: Merge_Params) -> int {
	assert(p.max_para_chars > 0, "a paragraph that may hold no characters can never be closed")

	if !s.open {
		return p.max_para_chars
	}
	return p.max_para_chars - s.runes - 1
}

// Splits speech at the last word boundary that fits in `room` characters.
//
// Reports that NOTHING fits rather than breaking a word, which is what makes the
// caller's two cases two cases: a Paragraph with a few characters left closes
// and offers the whole cap, and only one that has already offered the whole cap
// carves the word itself.
@(private)
word_split :: proc(said: string, room: int) -> (take, rest: string) {
	assert(len(said) > 0, "there is nothing here to split")

	if room <= 0 {
		return "", said
	}
	if strings.rune_count(said) <= room {
		return said, ""
	}

	// More characters than there is room for, so there is a character sitting at
	// the cut and it can be read.
	cut := character_offset(said, room)
	assert(cut < len(said), "speech longer than the room measured out no shorter than itself")
	if said[cut] == ' ' {
		return said[:cut], strings.trim_left_space(said[cut:])
	}

	at := strings.last_index_byte(said[:cut], ' ')
	if at <= 0 {
		return "", said
	}
	return said[:at], strings.trim_left_space(said[at:])
}

// Splits speech at exactly `room` characters, wherever that falls.
@(private)
character_split :: proc(said: string, room: int) -> (take, rest: string) {
	assert(len(said) > 0, "there is nothing here to carve")
	assert(room > 0, "a carve that may take no characters never finishes")

	cut := character_offset(said, room)
	// Characters and not bytes, which is the whole reason this walks the string
	// instead of slicing it: a cut taken at a byte offset lands inside an
	// accented character and puts a broken one into the deliverable.
	assert(cut > 0, "a positive room measured out no characters at all")
	return said[:cut], strings.trim_left_space(said[cut:])
}

// The byte offset one past the `count`th character, or the whole length where
// there are fewer than that many.
@(private)
character_offset :: proc(said: string, count: int) -> int {
	assert(count > 0, "the offset of no characters at all is not a position")

	seen := 0
	for _, at in said {
		if seen == count {
			return at
		}
		seen += 1
	}
	return len(said)
}

// Adds one Cue's speech to the Paragraph being built, opening one if none is.
@(private)
paragraph_extend :: proc(s: ^Merge_State, cue: Cue, said: string) {
	assert(len(said) > 0, "empty speech opens a paragraph that can never be closed")

	if s.open {
		strings.write_byte(&s.prose, ' ')
		s.runes += 1
	} else {
		// The negative space of paragraph_close resetting the builder (A3, A4).
		// Opening onto characters the last Paragraph left behind is how prose
		// from two ends of a Recording ends up in one block of text.
		assert(s.runes == 0, "opened a paragraph onto characters the last one left behind")
		s.start = cue.start
		s.end = cue.end
		s.open = true
	}

	strings.write_string(&s.prose, said)
	s.runes += strings.rune_count(said)
	// max, not assignment: consecutive Cues may overlap, which is ordinary
	// Engine output, so the last Cue in a Paragraph is not always the one that
	// ends latest.
	s.end = max(s.end, cue.end)
}

// Emits the Paragraph being built, if there is one, and readies the state for
// the next.
@(private)
paragraph_close :: proc(s: ^Merge_State, allocator: mem.Allocator) {
	assert(allocator.procedure != nil, "a paragraph's prose outlives this procedure")

	if !s.open {
		// The negative space of the reset below (CLAUDE.md A3). Nothing open
		// means nothing half-written is waiting to be inherited.
		assert(s.runes == 0, "a paragraph that is not open is still holding characters")
		return
	}

	said := strings.to_string(s.prose)
	assert(len(said) > 0, "an open paragraph with no prose in it")
	assert(s.end >= s.start, "a paragraph that ends before it starts")
	append(&s.out, Paragraph{start = s.start, end = s.end, text = strings.clone(said, allocator)})

	strings.builder_reset(&s.prose)
	s.runes = 0
	s.open = false
}
