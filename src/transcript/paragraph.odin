package transcript

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// Consecutive Paragraphs MAY OVERLAP -- one carved out of a long Cue overlaps its
// neighbours by that Cue's whole length -- so an Anchor cannot be placed by naively
// reading `start`. See carved_paragraphs_all_claim_their_cue_and_so_overlap_each_other.
Paragraph :: struct {
	start: Millis,
	end:   Millis,
	text:  string,
}

Merge_Params :: struct {
	max_gap_ms:     Millis,
	hard_gap_ms:    Millis,
	max_para_chars: int,
}

// Measured; see ADR-0007.
MONOLOGUE :: Merge_Params {
	max_gap_ms     = 1_500,
	hard_gap_ms    = 5_000,
	max_para_chars = 2_000,
}

// Measured; see ADR-0007.
CONVERSATION :: Merge_Params {
	max_gap_ms     = 500,
	hard_gap_ms    = 1_500,
	max_para_chars = 700,
}

#assert(MONOLOGUE.max_gap_ms > 0)
#assert(MONOLOGUE.hard_gap_ms >= MONOLOGUE.max_gap_ms)
#assert(MONOLOGUE.max_para_chars > 0)
#assert(CONVERSATION.max_gap_ms > 0)
#assert(CONVERSATION.hard_gap_ms >= CONVERSATION.max_gap_ms)
#assert(CONVERSATION.max_para_chars > 0)

#assert(CONVERSATION.max_gap_ms < MONOLOGUE.max_gap_ms)
#assert(CONVERSATION.hard_gap_ms < MONOLOGUE.hard_gap_ms)

Merge_Profile :: enum u8 {
	Monologue = 0,
	Conversation,
}

// Named once because both binaries must default to the same profile, and a bare
// enum member at each of them is two answers to one question.
DEFAULT_PROFILE :: Merge_Profile.Monologue

@(private)
Named_Profile :: struct {
	name:   string,
	params: Merge_Params,
}

@(private, rodata)
PROFILES := [Merge_Profile]Named_Profile {
	.Monologue = {name = MONOLOGUE_NAME, params = MONOLOGUE},
	.Conversation = {name = CONVERSATION_NAME, params = CONVERSATION},
}

@(private)
MONOLOGUE_NAME :: "monologue"
@(private)
CONVERSATION_NAME :: "conversation"

// A constant and not a procedure that builds it: a usage block assembled at run
// time is a format string, and the first `%` a line of prose carries reaches a
// caller as a bad verb.
PROFILE_CHOICE :: MONOLOGUE_NAME + "|" + CONVERSATION_NAME

#assert(len(Merge_Profile) == 2)

@(private)
@(require_results)
profile_row :: proc(profile: Merge_Profile) -> (row: Named_Profile) {
	row = PROFILES[profile]
	assert(len(row.name) > 0, "a profile was added to Merge_Profile without a row in PROFILES")
	assert(row.params.max_gap_ms > 0, "a named profile carries no thresholds")
	assert(
		row.params.hard_gap_ms >= row.params.max_gap_ms,
		"a named profile's hard gap sits below its soft",
	)
	return
}

// Borrowed from a compiled-in constant and never owned; nothing frees it.
@(require_results)
profile_name :: proc(profile: Merge_Profile) -> string {
	return profile_row(profile).name
}

@(require_results)
profile_params :: proc(profile: Merge_Profile) -> Merge_Params {
	return profile_row(profile).params
}

@(require_results)
profile_named :: proc(name: string) -> (profile: Merge_Profile, known: bool) {
	for candidate in Merge_Profile {
		if profile_row(candidate).name == name {
			return candidate, true
		}
	}
	return {}, false
}

@(private)
Merge_State :: struct {
	out:   [dynamic]Paragraph,
	prose: strings.Builder,
	runes: int,
	start: Millis,
	end:   Millis,
}

@(private)
@(require_results)
paragraph_is_open :: proc(s: Merge_State) -> bool {
	assert(s.runes >= 0, "a paragraph holding a negative number of characters")
	return s.runes > 0
}

// Free the returned Paragraphs with destroy_paragraphs, passing the same allocator.
@(require_results)
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
	assert(cues_are_ordered(cues), "merging a cue set parse_cues could not have returned")

	if len(cues) == 0 {
		return nil
	}

	state := Merge_State {
		out   = make([dynamic]Paragraph, 0, len(cues), allocator),
		prose = strings.builder_make(allocator),
	}
	defer strings.builder_destroy(&state.prose)

	previous: Maybe(Cue)

	for cue in cues {
		said := spoken_text(cue)
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
	return
}

destroy_paragraphs :: proc(paragraphs: []Paragraph, allocator: mem.Allocator) {
	assert(
		allocator.procedure != nil,
		"paragraphs cannot be freed without the allocator that made them",
	)
	if paragraphs == nil {
		assert(len(paragraphs) == 0, "a paragraph set with a length and no memory behind it")
	}

	for paragraph in paragraphs {
		assert(
			len(paragraph.text) > 0,
			"freeing a paragraph merge_paragraphs could not have returned",
		)
		delete(paragraph.text, allocator)
	}
	delete(paragraphs, allocator)
}

@(private)
@(require_results)
breaks_paragraph :: proc(before, after: Cue, p: Merge_Params) -> bool {
	assert(p.max_gap_ms > 0, "a paragraph that breaks on no silence at all breaks at every cue")
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

@(private)
SENTENCE_ENDS :: ".!?…"
@(private)
SENTENCE_CLOSERS :: `"')]}»”’`

// Says yes to an abbreviation, and that is the right trade: the false break falls
// at a pause that had already cleared max_gap_ms.
@(private)
@(require_results)
ends_a_sentence :: proc(said: string) -> bool {
	assert(
		!ends_on_silence(said),
		"asked whether text still ending on what nobody said ends a sentence",
	)

	bare := strings.trim_right(said, SENTENCE_CLOSERS)
	assert(len(bare) <= len(said), "trimming a sentence's closers added bytes to it")
	return len(strings.trim_right(bare, SENTENCE_ENDS)) < len(bare)
}

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
			paragraph_close(s, p, allocator)
			continue
		}
		if len(take) == 0 {
			assert(room == p.max_para_chars, "carved a word into a paragraph that was not empty")
			take, tail = character_split(rest, room)
		}

		assert(len(take) > 0, "a split that took no speech at all")
		assert(len(tail) < len(rest), "a split that consumed no speech at all")
		paragraph_extend(s, cue, take)
		rest = tail

		if len(rest) > 0 {
			paragraph_close(s, p, allocator)
		}
	}
}

@(private)
@(require_results)
paragraph_room :: proc(s: Merge_State, p: Merge_Params) -> int {
	assert(p.max_para_chars > 0, "a paragraph that may hold no characters can never be closed")

	if !paragraph_is_open(s) {
		return p.max_para_chars
	}
	return p.max_para_chars - s.runes - 1
}

@(private)
@(require_results)
split_trimmed :: proc(said: string, at: int) -> (take, rest: string) {
	assert(at > 0, "a split that takes nothing is not a split into two sides")
	assert(at < len(said), "a split at or past the end of the speech behind it")
	assert(!opens_on_silence(said), "speech still opening on something nobody said")
	defer assert(len(take) > 0, "trimming a split emptied the side that opened on speech")

	take = strings.trim_right_proc(said[:at], says_nothing)
	rest = strings.trim_left_proc(said[at:], says_nothing)
	return
}

@(private)
@(require_results)
word_split :: proc(said: string, room: int) -> (take, rest: string) {
	assert(len(said) > 0, "there is nothing here to split")
	assert(!opens_on_silence(said), "speech still opening on something nobody said")
	assert(!ends_on_silence(said), "speech still ending on something nobody said")
	defer assert(!opens_on_silence(take), "a split opened prose on something nobody said")
	defer assert(!ends_on_silence(take), "a split left something nobody said on the prose")

	if room <= 0 {
		return "", said
	}
	if strings.rune_count(said) <= room {
		return said, ""
	}

	cut := utf8.rune_offset(said, room)
	assert(cut >= 0, "speech longer than the room ran out of characters inside it")
	assert(cut < len(said), "speech longer than the room measured out no shorter than itself")

	at_cut, _ := utf8.decode_rune_in_string(said[cut:])
	if says_nothing(at_cut) {
		return split_trimmed(said, cut)
	}

	at := strings.last_index_proc(said[:cut], says_nothing)
	if at <= 0 {
		return "", said
	}
	return split_trimmed(said, at)
}

@(private)
@(require_results)
character_split :: proc(said: string, room: int) -> (take, rest: string) {
	assert(len(said) > 0, "there is nothing here to carve")
	assert(room > 0, "a carve that may take no characters never finishes")
	assert(!opens_on_silence(said), "speech still opening on something nobody said")
	defer assert(len(take) > 0, "a carve that took no speech at all")

	cut := utf8.rune_offset(said, room)
	assert(cut > 0, "a positive room measured out no characters at all")
	return split_trimmed(said, cut)
}

@(private)
paragraph_extend :: proc(s: ^Merge_State, cue: Cue, said: string) {
	assert(len(said) > 0, "empty speech opens a paragraph that can never be closed")

	if paragraph_is_open(s^) {
		strings.write_byte(&s.prose, ' ')
		s.runes += 1
	} else {
		assert(
			strings.builder_len(s.prose) == 0,
			"opened a paragraph onto prose the last one left behind",
		)
		s.start = cue.start
		s.end = cue.end
	}

	strings.write_string(&s.prose, said)
	s.runes += strings.rune_count(said)
	s.end = max(s.end, cue.end)
}

@(private)
paragraph_close :: proc(s: ^Merge_State, p: Merge_Params, allocator: mem.Allocator) {
	assert(p.max_para_chars > 0, "a paragraph that may hold no characters can never be closed")
	assert(allocator.procedure != nil, "a paragraph's prose outlives this procedure")

	if !paragraph_is_open(s^) {
		assert(
			strings.builder_len(s.prose) == 0,
			"nothing is open but there is prose half-written",
		)
		return
	}

	said := strings.to_string(s.prose)
	assert(len(said) > 0, "an open paragraph with no prose in it")
	assert(s.end >= s.start, "a paragraph that ends before it starts")

	held := strings.rune_count(said)
	assert(held == s.runes, "the character count and the prose behind it disagree")
	assert(held <= p.max_para_chars, "a paragraph longer than the cap reached the deliverable")
	append(&s.out, Paragraph{start = s.start, end = s.end, text = strings.clone(said, allocator)})

	strings.builder_reset(&s.prose)
	s.runes = 0
}
