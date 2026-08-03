package transcript

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// A run of consecutive Cues merged into one piece of prose, and the unit a
// reader actually reads.
//
// The offsets are kept because an Anchor is placed off them later, and because
// a Paragraph that has lost its place in the Recording cannot be checked against
// it. `text` is prose: the Engine's padding is off every Cue and one space
// stands at each seam.
//
// Consecutive Paragraphs MAY OVERLAP, and one carved out of a long Cue overlaps
// its neighbours by that Cue's whole length. Nothing in the Engine's output says
// where inside a Cue a carve landed, so every piece of one carries the Cue's own
// start and end rather than an offset interpolated from nothing -- which would
// put an Anchor at a time nobody spoke. Placing Anchors off these is therefore
// not simply reading `start`: see
// carved_paragraphs_all_claim_their_cue_and_so_overlap_each_other.
Paragraph :: struct {
	start: Millis,
	end:   Millis,
	text:  string,
}

// Where paragraph breaks fall, and how long a Paragraph may get.
//
// Two SIGNALS and no more (ADR-0007): the silence between consecutive Cues, and
// whether the Cue in front ended a sentence. There is nothing else to read --
// speaker diarization is out of scope, so this handles multi-speaker material
// temporally and will still merge two people who overlap without a gap.
//
// The character cap is not a third signal and reading it as one is the mistake
// this paragraph exists to prevent. A signal says where a reader would break; the
// cap says where a Paragraph has to stop whatever the signals said, and it fires
// only where NEITHER did. It puts breaks in arbitrary places on purpose, because
// a wall of text is worse.
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

// And what makes them two profiles rather than two spellings of one: both
// SIGNALS in the aggressive profile fire sooner than their counterparts in the
// generous one, so no tuning pass can leave the pair pointing the same way while
// the names still promise otherwise.
//
// The caps are deliberately not held apart the same way. A cap is a bound and
// not a signal, two profiles sharing one would still break in different places,
// and an #assert here would be pinning how the pair happens to be tuned as
// though it were the rule that makes them a pair.
#assert(CONVERSATION.max_gap_ms < MONOLOGUE.max_gap_ms)
#assert(CONVERSATION.hard_gap_ms < MONOLOGUE.hard_gap_ms)

// The two Merge Profiles by name -- what a person picks, and what a Transcript
// records having been merged under.
//
// The thresholds above are the profile; this is its NAME, and a Merge Profile is
// "a named set of thresholds" (CONTEXT.md) rather than the thresholds alone. The
// name existed only in prose until a front matter block had to record it and a
// command line had to accept one, and prose is not something either can read.
Merge_Profile :: enum u8 {
	Monologue = 0,
	Conversation,
}

// The profile a caller who chose none is merged under.
//
// Named once, here, because BOTH binaries need it and they must not disagree:
// the window ADR-0004 promises and the command line have to produce the same
// bytes from the same input (spec story 44), and a default spelled as a bare
// enum member at each of them is two answers to one question that nothing keeps
// in step. Monologue because it is the generous one: merging too little leaves
// the subtitle-fragment wall this program exists to avoid, and a reader who
// wanted the aggressive profile can re-render in seconds (spec story 43).
DEFAULT_PROFILE :: Merge_Profile.Monologue

// A profile's name beside the thresholds it stands for, so a row cannot name one
// profile and point at the other's constants.
@(private)
Named_Profile :: struct {
	name:   string,
	params: Merge_Params,
}

// An enumerated array rather than a switch, the way FAULT is: a profile added to
// Merge_Profile without an entry here still HAS an entry, made of zeroes, and
// profile_name's assertion on an empty name is what catches it on the first
// Transcript rather than after one ships recording no profile at all.
@(private, rodata)
PROFILES := [Merge_Profile]Named_Profile {
	.Monologue = {name = "monologue", params = MONOLOGUE},
	.Conversation = {name = "conversation", params = CONVERSATION},
}

// One profile's row, checked.
//
// THE ONE PLACE THE TABLE IS READ, and the one place the missing row is caught.
// The claim was made at three call sites in two different wordings, all three
// running on every render and all three about the same defect: a Merge_Profile
// added without a row here still HAS a row, made of zeroes, and a zeroed row
// carries no name for the front matter and thresholds merge_paragraphs would
// refuse. Said once, where both halves of a row are in hand.
@(private)
profile_row :: proc(profile: Merge_Profile) -> (row: Named_Profile) {
	row = PROFILES[profile]
	assert(len(row.name) > 0, "a profile was added to Merge_Profile without a row in PROFILES")
	// The negative space of the same missing row (CLAUDE.md A3): a row could
	// carry a name and no thresholds, and the merger would then break at every
	// Cue while naming the merger rather than the profile nobody filled in.
	assert(row.params.max_gap_ms > 0, "a named profile carries no thresholds")
	assert(
		row.params.hard_gap_ms >= row.params.max_gap_ms,
		"a named profile's hard gap sits below its soft",
	)
	return
}

// What a Transcript records having been merged under.
//
// Borrowed from the table above and never owned: it is a compiled-in constant
// that outlives every caller, so nothing frees it.
profile_name :: proc(profile: Merge_Profile) -> string {
	return profile_row(profile).name
}

// The thresholds behind a name, for merge_paragraphs to be handed.
profile_params :: proc(profile: Merge_Profile) -> Merge_Params {
	return profile_row(profile).params
}

// Every profile a caller may pick, joined the way a usage line offers a choice:
// `monologue|conversation`.
//
// Read out of the table rather than spelled again wherever a usage line is
// written. That copy lived in another package, where no compiler could compare
// the two -- so a third profile would go unmentioned and a renamed one would be
// offered under a spelling profile_named refuses.
//
// The allocator is explicit and never defaulted: the line outlives this
// procedure. Free it with `delete`, passing the same allocator.
profile_names :: proc(allocator: mem.Allocator) -> (offered: string) {
	assert(allocator.procedure != nil, "the line outlives this procedure")
	// What every caller depends on: there is always a choice to offer, because
	// an enumeration with no members is not something this program has.
	defer assert(len(offered) > 0, "offered a choice between no profiles at all")

	out := strings.builder_make(allocator)
	defer strings.builder_destroy(&out)

	for profile in Merge_Profile {
		if strings.builder_len(out) > 0 {
			strings.write_byte(&out, '|')
		}
		strings.write_string(&out, profile_row(profile).name)
	}
	return strings.clone(strings.to_string(out), allocator)
}

// The profile a name stands for, or nothing where no profile carries it.
//
// Compared EXACTLY, case included. A lookup folding case would accept a spelling
// the front matter never writes, and a Transcript recording `Monologue` while
// planning looks for `monologue` is a Recording re-done on every run (ADR-0003).
profile_named :: proc(name: string) -> (profile: Merge_Profile, known: bool) {
	// Never asserted against the empty string: the name comes off a command line,
	// which is outside this program, and nothing outside it may crash it
	// (CLAUDE.md A8). It is refused through the return like any other spelling.
	//
	// Compared through profile_row rather than against the range value, so every
	// row is checked as the walk passes it -- including the zeroed one, which
	// answers to the empty name and would otherwise hand a caller passing "" a
	// profile whose thresholds merge_paragraphs refuses.
	for candidate in Merge_Profile {
		if profile_row(candidate).name == name {
			return candidate, true
		}
	}
	return {}, false
}

// Everything a half-built Paragraph is made of, in one place so the procedures
// that add to it and close it cannot disagree about what "open" means.
//
// There is no `open` flag. Nothing ever opens a Paragraph on empty speech --
// paragraph_extend asserts that on the way in -- so "open" IS `runes > 0`, and
// a flag beside the count would be a second answer to one question kept in step
// by assertions. Derived, the two cannot disagree at all.
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
}

// Whether there is a Paragraph half-built.
@(private)
paragraph_is_open :: proc(s: Merge_State) -> bool {
	assert(s.runes >= 0, "a paragraph holding a negative number of characters")
	return s.runes > 0
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
	assert(
		allocator.procedure != nil,
		"the paragraphs outlive this procedure and need a chosen allocator",
	)
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
			paragraph_close(&state, p, allocator)
		}
		paragraph_admit(&state, cue, said, p, allocator)
		previous = cue
	}
	paragraph_close(&state, p, allocator)

	paragraphs = owned_slice(&state.out)
	// The cap is NOT re-counted over the set here. paragraph_close checks it on
	// each Paragraph as it is emitted, and the cases that observe it count the
	// characters that actually arrived -- a sweep on the same predicate would
	// pre-empt those, leaving one of them with no reachable expectation at all
	// and turning a named failure into several tests asserting at once, which is
	// the runner hang CLAUDE.md documents.
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
	assert(
		allocator.procedure != nil,
		"paragraphs cannot be freed without the allocator that made them",
	)
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
		assert(
			len(paragraph.text) > 0,
			"freeing a paragraph merge_paragraphs could not have returned",
		)
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
paragraph_admit :: proc(
	s: ^Merge_State,
	cue: Cue,
	said: string,
	p: Merge_Params,
	allocator: mem.Allocator,
) {
	assert(len(said) > 0, "empty speech opens a paragraph that can never be closed")
	assert(p.max_para_chars > 0, "a paragraph that may hold no characters can never be closed")

	rest := said
	for len(rest) > 0 {
		room := paragraph_room(s^, p)
		take, tail := word_split(rest, room)

		if len(take) == 0 && paragraph_is_open(s^) {
			// Not enough room left for the next whole word. Closing offers the
			// whole cap instead, which is strictly more room than there was.
			paragraph_close(s, p, allocator)
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

		// Speech left behind means the split happened because the rest did not
		// fit, and whatever stood between the two sides -- one space or four --
		// went with it. Carrying on inside this Paragraph would put ONE space
		// back in its place, which rewrites what the Engine wrote and spends
		// fewer characters against the cap than the speech was made of. So the
		// Paragraph ends at the split, which is what a split means anyway.
		//
		// On single-spaced speech this changes nothing, and the arithmetic is
		// why: the split takes the LAST word boundary inside the room, so the
		// next word ends at or past the cut and cannot fit in what is left.
		// Only a run of spaces frees enough room to make the question live.
		if len(rest) > 0 {
			paragraph_close(s, p, allocator)
		}
	}
}

// How many more characters the Paragraph being built can hold, counting the
// space that would stand at the seam. Zero or less where what is open is already
// full; the whole cap where nothing is open.
@(private)
paragraph_room :: proc(s: Merge_State, p: Merge_Params) -> int {
	assert(p.max_para_chars > 0, "a paragraph that may hold no characters can never be closed")

	if !paragraph_is_open(s) {
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
//
// Both ends of what it hands back are trimmed. The space the split broke at is
// not speech and must not survive into either side of it: on the left it reaches
// the deliverable as a Paragraph ending in whitespace and is spent against the
// cap, and on the right it opens the next Paragraph with padding the Engine's
// own leading space was already taken off for.
@(private)
word_split :: proc(said: string, room: int) -> (take, rest: string) {
	assert(len(said) > 0, "there is nothing here to split")
	// The one thing the trims below rely on: speech starts with speech, so
	// nothing they take off the left can empty what is left of it.
	assert(!strings.is_space(rune(said[0])), "speech still carrying the engine's padding")
	defer if len(take) > 0 {
		assert(take == strings.trim_space(take), "a split left padding on the prose")
	}

	if room <= 0 {
		return "", said
	}
	if strings.rune_count(said) <= room {
		return said, ""
	}

	// More characters than there is room for, so there is a character sitting at
	// the cut and it can be read.
	cut := utf8.rune_offset(said, room)
	// rune_offset answers -1 where the string ran out, and the guard above is why
	// it cannot here. Asserted rather than argued, because -1 passes the bound
	// below and `said[cut:]` panics on it (CLAUDE.md A6).
	assert(cut >= 0, "speech longer than the room ran out of characters inside it")
	assert(cut < len(said), "speech longer than the room measured out no shorter than itself")

	// A boundary sitting exactly AT the cut fills the room to the character
	// without breaking anything, which the search below cannot see because it
	// only looks inside the window.
	at_cut, _ := utf8.decode_rune_in_string(said[cut:])
	if strings.is_space(at_cut) {
		return strings.trim_right_space(said[:cut]), strings.trim_left_space(said[cut:])
	}

	// `strings.is_space` and never a comparison against the space byte: it is the
	// predicate trim_left_space and trim_right_space use, and a boundary search
	// that knew about fewer characters than the trims do carves a tab as though
	// it were a letter.
	at := strings.last_index_proc(said[:cut], strings.is_space)
	if at <= 0 {
		return "", said
	}
	return strings.trim_right_space(said[:at]), strings.trim_left_space(said[at:])
}

// Splits speech at exactly `room` characters, wherever that falls.
@(private)
character_split :: proc(said: string, room: int) -> (take, rest: string) {
	assert(len(said) > 0, "there is nothing here to carve")
	assert(room > 0, "a carve that may take no characters never finishes")
	defer assert(len(take) > 0, "a carve that took no speech at all")

	// Characters and not bytes, which is the whole reason this asks utf8 instead
	// of slicing: a cut taken at a byte offset lands inside an accented character
	// and puts a broken one into the deliverable. The same guard as above, and
	// this one rejects rune_offset's -1 with it: only reached where word_split
	// has already found more characters here than there is room for.
	cut := utf8.rune_offset(said, room)
	assert(cut > 0, "a positive room measured out no characters at all")
	return strings.trim_right_space(said[:cut]), strings.trim_left_space(said[cut:])
}

// Adds one Cue's speech to the Paragraph being built, opening one if none is.
@(private)
paragraph_extend :: proc(s: ^Merge_State, cue: Cue, said: string) {
	assert(len(said) > 0, "empty speech opens a paragraph that can never be closed")

	if paragraph_is_open(s^) {
		strings.write_byte(&s.prose, ' ')
		s.runes += 1
	} else {
		// The negative space of paragraph_close resetting the builder (A3, A4).
		// Opening onto characters the last Paragraph left behind is how speech
		// from two ends of a Recording ends up inside one Paragraph -- and with
		// "open" derived from the count, those characters would also make this
		// look like a Paragraph already in progress.
		assert(
			strings.builder_len(s.prose) == 0,
			"opened a paragraph onto prose the last one left behind",
		)
		s.start = cue.start
		s.end = cue.end
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
paragraph_close :: proc(s: ^Merge_State, p: Merge_Params, allocator: mem.Allocator) {
	assert(p.max_para_chars > 0, "a paragraph that may hold no characters can never be closed")
	assert(allocator.procedure != nil, "a paragraph's prose outlives this procedure")

	if !paragraph_is_open(s^) {
		// The negative space of the reset below (CLAUDE.md A3). Nothing counted
		// means nothing half-written is waiting to be inherited, and the builder
		// is the other half of that claim.
		assert(
			strings.builder_len(s.prose) == 0,
			"nothing is open but there is prose half-written",
		)
		return
	}

	said := strings.to_string(s.prose)
	assert(len(said) > 0, "an open paragraph with no prose in it")
	assert(s.end >= s.start, "a paragraph that ends before it starts")

	// The read side of the cap paragraph_admit maintains by arithmetic on the way
	// in (CLAUDE.md A4), and the one Merge_State invariant that had no check
	// facing it. Counted off the prose that actually arrived rather than read off
	// the running total, so a counter that drifted from the builder is caught by
	// the first of these and an arithmetic error by the second. Per Paragraph and
	// never over the set: an assert sweeping every Paragraph is the expectation
	// no_shipped_profile_exceeds_its_own_character_cap already holds, and
	// pre-empting it would turn a named failure into several tests asserting at
	// once, which is the runner hang CLAUDE.md documents.
	held := strings.rune_count(said)
	assert(held == s.runes, "the character count and the prose behind it disagree")
	assert(held <= p.max_para_chars, "a paragraph longer than the cap reached the deliverable")
	append(&s.out, Paragraph{start = s.start, end = s.end, text = strings.clone(said, allocator)})

	strings.builder_reset(&s.prose)
	s.runes = 0
}
