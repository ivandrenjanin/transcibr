// Package transcript parses Engine JSON into Cues, collapses repetition runs,
// merges Cues into Paragraphs under a Merge Profile, and renders Markdown.
package transcript

import "core:mem"
import "core:strings"

// `distinct` because the Engine writes `hh:mm:ss,mmm` text beside whole
// milliseconds and counts internally in centiseconds; a bare integer lets one
// unit pass for another, and the mistake renders as a Transcript merely wrong.
Millis :: distinct i64

// `text` is verbatim -- the Engine's leading space kept, the empty string kept.
// Deciding what is worth keeping belongs to collapse and merging downstream, and
// a parser that quietly trims destroys the evidence they work from.
Cue :: struct {
	start: Millis,
	end:   Millis,
	text:  string,
}

// Every byte of a multi-byte character is at or above 0x80, so a caller walking
// BYTES and casting each one to a rune gets the answer decoding would give it.
@(private)
@(require_results)
renders_as_nothing :: proc(r: rune) -> bool {
	return r < 0x20 || r == 0x7F
}

@(private)
@(require_results)
says_nothing :: proc(r: rune) -> bool {
	return strings.is_space(r) || renders_as_nothing(r)
}

@(private)
@(require_results)
opens_on_silence :: proc(said: string) -> bool {
	return len(said) > 0 && says_nothing(rune(said[0]))
}

@(private)
@(require_results)
ends_on_silence :: proc(said: string) -> bool {
	return len(said) > 0 && says_nothing(rune(said[len(said) - 1]))
}

// Control characters come off the ENDS as well as the padding: prose opening on
// one reaches Markdown as prose opening on a space, which is that renderer's own
// indentation. Inside the speech they stay, and render as spaces.
@(private)
@(require_results)
spoken_text :: proc(cue: Cue) -> (said: string) {
	said = strings.trim_left_proc(strings.trim_right_proc(cue.text, says_nothing), says_nothing)
	assert(len(said) <= len(cue.text), "trimming a cue's text added bytes to it")
	assert(!opens_on_silence(said), "a trimmed cue still opens on a byte nobody said")
	assert(!ends_on_silence(said), "a trimmed cue still ends on a byte nobody said")
	return
}

// The 1-based position of the first Cue that breaks the ordering, or 0 when the
// whole set is ordered. Overlap is not a violation: consecutive Cues whose spans
// overlap are ordinary Engine output, and demanding a disjoint sequence would
// reject real Recordings while looking stricter.
@(require_results)
first_disordered_cue :: proc(cues: []Cue) -> (ordinal: int) {
	defer assert(ordinal >= 0, "a cue ordinal is a position or zero, never negative")
	defer assert(ordinal <= len(cues), "named a cue position past the end of the set")

	for cue, i in cues {
		if cue.start < 0 {
			return i + 1
		}
		if cue.end < cue.start {
			return i + 1
		}
		if i > 0 && cue.start < cues[i - 1].start {
			return i + 1
		}
	}
	return 0
}

@(require_results)
cues_are_ordered :: proc(cues: []Cue) -> bool {
	ordinal := first_disordered_cue(cues)
	if len(cues) == 0 {
		assert(ordinal == 0, "an empty cue set was reported disordered")
	}
	return ordinal == 0
}

// Frees a Cue set parse_cues returned, and the text of every Cue in it.
destroy_cues :: proc(cues: []Cue, allocator: mem.Allocator) {
	assert(allocator.procedure != nil, "cues cannot be freed without the allocator that made them")
	assert(cues_are_ordered(cues), "freeing a cue set parse_cues could not have returned")
	if cues == nil {
		assert(len(cues) == 0, "a cue set with a length and no memory behind it")
	}

	for cue in cues {
		delete(cue.text, allocator)
	}
	delete(cues, allocator)
}

// Every destroy_ procedure in this package frees the returned SLICE, so the block
// behind it has to be exactly as long as the slice says -- and both builders here
// reserve for the whole input and then deliberately do not fill it.
@(private)
@(require_results)
owned_slice :: proc(built: ^[dynamic]$T) -> (owned: []T) {
	assert(built != nil, "there is no builder here to take a slice of")

	shrink(built)
	owned = built[:]
	assert(cap(built^) == len(owned), "the returned slice does not own exactly the block it names")
	return
}
