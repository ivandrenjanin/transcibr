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
	// same range where one is written into a Parse_Error (CLAUDE.md A4). Off by
	// one on either side reports a fault against a Cue that is not in the set.
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
// The property is enforced twice (CLAUDE.md A4): parse_cues rejects the
// Engine's output as an operating error, per Cue, as it builds -- and then
// asserts this on the slice it hands back. Every consumer asserts it on the way
// in, which is why this is public rather than an internal detail of the parser.
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
