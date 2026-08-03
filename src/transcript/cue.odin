// Package transcript turns what the Engine emitted into a Transcript: it parses
// Engine JSON into Cues, collapses repetition runs, merges Cues into Paragraphs
// under a Merge Profile, and renders Markdown.
//
// Pure core (ADR-0009): no clock, no environment, no I/O. The Engine's JSON
// arrives as text and the Recording's length arrives as a number, both settled
// by the shell before anything here runs, so every decision this package makes
// is reproducible from its arguments alone.
package transcript

import "core:mem"
import "core:strings"

// Milliseconds counted from the start of a Recording.
//
// `distinct` because two units are in play and nothing else keeps them apart:
// the Engine's JSON carries `timestamps` as `hh:mm:ss,mmm` text beside
// `offsets` in whole milliseconds, and whisper.cpp counts internally in
// centiseconds. A bare integer lets one pass for the other, and the mistake
// renders as a Transcript that is merely wrong rather than one that fails.
//
// `i64` and not `int` because an offset is written into a Sidecar and compared
// against one an earlier build wrote (CLAUDE.md T1); a width that changes with
// the target is not a quantity you can persist.
Millis :: distinct i64

// One timestamped fragment of speech, exactly as the Engine emitted it.
//
// `text` is verbatim -- the Engine's leading space kept, the empty string kept.
// This parser is lossless on purpose: deciding what is worth keeping belongs to
// repetition collapse and paragraph merging downstream, and a parser that
// quietly trims has already destroyed the evidence they work from.
Cue :: struct {
	start: Millis,
	end:   Millis,
	text:  string,
}

// Whether a character is one nobody said: whitespace, or a control byte a text
// editor renders as nothing at all.
//
// The two are one question here, and CONTEXT.md is why: a Saying is "one cue
// that said something", and the Engine's empty and space-only Cues over silence
// are not Sayings. A Cue of control characters is that same statement written in
// bytes -- nothing a reader could see, and nothing a speaker said.
@(private)
says_nothing :: proc(r: rune) -> bool {
	return strings.is_space(r) || r < 0x20 || r == 0x7F
}

// What was actually said in a Cue: its text with everything nobody said taken
// off either end.
//
// The Engine writes a leading space on every Cue it emits, and writes an empty
// or space-only Cue over silence, and neither of those is content. The parser
// keeps them because it is lossless on purpose; every stage after it has to take
// them off, and doing that in one place is what stops the two stages disagreeing
// about what a Cue says.
//
// Control characters come off the ENDS for the same reason the padding does, and
// leaving them there costs more than a stray byte: prose opening on one reaches
// Markdown as prose opening on a space, which is that renderer's own indentation
// (see write_prose). Inside the speech they stay, and the renderer writes them
// out as spaces -- there, what they separated is still separated.
//
// Repetition collapse compares Cues by this and not by the raw text: " you" and
// "you " are one phrase said twice, and a comparison that could not tell would
// leave a run uncollapsed over a stray byte the Engine chose. Paragraph merging
// joins by this for the mirror-image reason -- prose that kept the padding
// carries a double space at every Cue seam.
//
// Private, unlike cues_are_ordered beneath it. That one is public because it is
// the promise parse_cues makes about what it hands back, and a caller holding a
// Cue set can check it. This is how the stages inside this package read a Cue,
// which is nobody else's business: what the package offers outward is Cues,
// Paragraphs, and the procedures that make them.
@(private)
spoken_text :: proc(cue: Cue) -> (said: string) {
	said = strings.trim_left_proc(strings.trim_right_proc(cue.text, says_nothing), says_nothing)
	// Both sides of what trimming is allowed to do (CLAUDE.md A3): it only ever
	// takes bytes away, and what it leaves no longer starts with the one byte it
	// exists to take away. The second is the claim every caller relies on and the
	// only one a reader cannot check by looking (A6).
	assert(len(said) <= len(cue.text), "trimming a cue's text added bytes to it")
	if len(said) > 0 {
		assert(said[0] != ' ', "a trimmed cue still carries the engine's padding")
		assert(!says_nothing(rune(said[0])), "a trimmed cue still opens on a byte nobody said")
	}
	return
}

// The 1-based position of the first Cue that breaks the ordering this package
// promises, or 0 when the whole set is ordered. That ordering is:
//
//   - no offset is negative, because an offset is a count from the start;
//   - no Cue ends before it starts;
//   - no Cue starts before the one in front of it.
//
// Overlap is NOT a violation. Consecutive Cues whose spans overlap are ordinary
// Engine output, and a check demanding a strictly increasing, disjoint sequence
// would reject real Recordings while looking stricter.
//
// Nothing about the Cues themselves is asserted here. parse_cues runs this
// across Engine output *before* that output is trusted, so an assertion on what
// it finds would be an assertion on external input (CLAUDE.md A8). What is
// asserted is the answer this procedure gives about them.
first_disordered_cue :: proc(cues: []Cue) -> (ordinal: int) {
	// The ordinal convention checked where it is PRODUCED; fault_at checks the
	// ordinal against the fault's scope where one is written into a Parse_Error
	// (CLAUDE.md A4). Off by one on either side reports a fault against a Cue
	// that is not in the set.
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

// Whether a Cue set satisfies the ordering above.
//
// The property is enforced twice by two routes (CLAUDE.md A4): read_cues
// rejects the Engine's output as an operating error, per Cue, as it builds and
// then asserts the answer on what it built; check_cue_set asserts it again on
// the way in, because the implication it draws is sound only on an ordered set.
// Every consumer asserts it on the way in too, which is why this is public
// rather than an internal detail of the parser.
cues_are_ordered :: proc(cues: []Cue) -> bool {
	ordinal := first_disordered_cue(cues)
	// The negative space of the same fact (CLAUDE.md A3), checked at the one
	// place both answers are in hand. A set with nothing in it has nothing to
	// disorder, and a disagreement here would make every assertion built on
	// this predicate vacuous rather than wrong -- which is worse, because a
	// vacuous assertion still passes.
	if len(cues) == 0 {
		assert(ordinal == 0, "an empty cue set was reported disordered")
	}
	return ordinal == 0
}

// Frees a Cue set parse_cues returned, and the text of every Cue in it.
//
// The allocator is an explicit parameter and is never defaulted: these values
// outlive the procedure that made them, and under ADR-0010 a defaulted
// allocator on such a value is a defect, because `context.temp_allocator` is
// thread-local and the Cue set crosses workers.
destroy_cues :: proc(cues: []Cue, allocator: mem.Allocator) {
	assert(allocator.procedure != nil, "cues cannot be freed without the allocator that made them")
	// The remove side of parse_cues' add (CLAUDE.md A3). A set this package
	// could not have produced is a set whose text pointers belong to someone
	// else, and freeing those stays silent until an unrelated allocation comes
	// back corrupted.
	assert(cues_are_ordered(cues), "freeing a cue set parse_cues could not have returned")
	// The negative space of that (CLAUDE.md A3): a set with no backing memory
	// but a length in it was assembled by hand out of parts rather than
	// returned from here, and the loop below walks pointers that never existed.
	if cues == nil {
		assert(len(cues) == 0, "a cue set with a length and no memory behind it")
	}

	for cue in cues {
		delete(cue.text, allocator)
	}
	delete(cues, allocator)
}

// The slice a builder owns, shrunk to exactly what was put in it.
//
// Every destroy_ procedure in this package frees the returned SLICE, so the
// block behind it has to be exactly as long as the slice says -- and both
// builders here reserve for the whole input and then deliberately do not fill
// it. Said once, because it was the same three lines and the same comment in
// two files, and a claim maintained in two places is a claim that drifts.
@(private)
owned_slice :: proc(built: ^[dynamic]$T) -> (owned: []T) {
	assert(built != nil, "there is no builder here to take a slice of")

	shrink(built)
	owned = built[:]
	assert(cap(built^) == len(owned), "the returned slice does not own exactly the block it names")
	return
}
