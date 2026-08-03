package transcript

import "core:mem"
import "core:strings"

// When a run of identical consecutive Cues stops being speech and starts being
// the Engine inventing over silence.
//
// TWO thresholds, and the second one is why this is not simply a cap. Per-Cue
// confidence does not exist in Engine output and the only number that does --
// per-token `p` -- is the wrong instrument, because a fabrication over silence is
// emitted with HIGH token probability (ADR-0001). So the shape of the run is all
// there is to read, and a cap read off length alone deletes real words: "no. no.
// no. no. no." is five sayings, and an over-eager filter that took two of them
// away would not be noticed for weeks.
//
// What separates the two populations is TIME, not count. The measured inventions
// were 17 identical Cues of one short phrase and 16 of the single word "you"
// spanning four and a half minutes of silence -- one saying every seventeen
// seconds, over a stretch where nothing was said at all. Real repetition is
// fast: a stutter, a name repeated, "yeah, yeah, yeah" in a conversation, a
// chorus, a count-off. Those are over in seconds, and every one of them survives
// a filter that asks for both.
Collapse_Params :: struct {
	// How many sayings of an invented run survive it. Three rather than one: the
	// run is dropped where it is INVENTED, and a Transcript that reads "you. you.
	// you." tells a reader the Engine ran on over silence, where a single "you."
	// reads as something the speaker said.
	max_run:    int,
	// How much of the Recording a run must cover before its length is held
	// against it at all. This is the threshold that protects real speech.
	min_run_ms: Millis,
}

// The one shipped set of these, and the reason there is one rather than one per
// Merge Profile: repetition is a property of the ENGINE, not of the material.
// The Engine loops over silence the same way whoever was recorded was talking to
// one person or to six.
//
// Twenty seconds is far above anything a person says identically -- the longest
// real run in the measured material was over in a few -- and far below the four
// and a half minutes the Engine spent on "you" (ADR-0001).
COLLAPSE_DEFAULT :: Collapse_Params {
	max_run    = 3,
	min_run_ms = 20_000,
}

// Collapses every invented repetition run in a Cue set, leaving everything else
// exactly as it was.
//
// The Cues come back CLONED, so the result is freed with destroy_cues and the
// input is freed separately with the allocator that made it. Handing back a
// slice that borrowed the input's text would be cheaper and would make the two
// sets impossible to free independently -- one destroy_cues on each is a double
// free, and only one of the two orders of the two calls is even survivable.
//
// The allocator is explicit and never defaulted: the result outlives this
// procedure and crosses a worker boundary (ADR-0010).
collapse_repetition :: proc(cues: []Cue, p: Collapse_Params, allocator: mem.Allocator) -> (kept: []Cue) {
	assert(p.max_run > 0, "a run collapsed to nothing deletes the speech it was made of")
	assert(p.min_run_ms > 0, "a run that need span no time at all makes every repetition an invention")
	assert(allocator.procedure != nil, "the cue set outlives this procedure and needs a chosen allocator")
	// What every consumer in this package asserts on the way in (CLAUDE.md A4).
	// A set whose starts go backwards would have runs split across the reordering
	// and the spans below measured off the wrong end.
	assert(cues_are_ordered(cues), "collapsing a cue set parse_cues could not have returned")

	// Distinguished from a set that collapsed to nothing, which cannot happen and
	// is asserted below. Nothing in, nothing out, and no allocation for a caller
	// to free.
	if len(cues) == 0 {
		return nil
	}

	built := make([dynamic]Cue, 0, len(cues), allocator)
	for start := 0; start < len(cues); {
		end := repetition_run_end(cues, start)
		take := end - start
		if is_invention(cues[start:end], p) {
			take = p.max_run
		}
		assert(take > 0, "kept no part of a run that had cues in it")
		assert(take <= end - start, "kept more sayings of a run than were ever said")

		for cue in cues[start:][:take] {
			append(&built, Cue{cue.start, cue.end, strings.clone(cue.text, allocator)})
		}
		start = end
	}

	// destroy_cues frees the returned SLICE, so the block behind it has to be
	// exactly as long as the slice says -- and unlike the parser's, this array is
	// reserved for the whole input and deliberately not filled.
	shrink(&built)
	kept = built[:]
	assert(cap(built) == len(kept), "the returned slice does not own exactly the block it names")
	assert(len(kept) > 0, "collapsed a cue set that had cues in it down to nothing")
	assert(len(kept) <= len(cues), "collapsing invented a cue")
	// The read side of the ordering asserted on the way in (CLAUDE.md A4).
	// Dropping the tail of a run preserves it; dropping the wrong end would not.
	assert(cues_are_ordered(kept), "collapsing left the cue set out of order")
	return
}

// Whether a run of identical consecutive Cues is invention rather than speech.
//
// BOTH thresholds, and the conjunction is the whole design. Length alone
// condemns real emphasis; span alone condemns a phrase said twice across a long
// pause. A run is invention only when it is longer than anything said out loud
// AND spread over more of the Recording than saying it would take.
//
// The false positive this can still make is cheap and the false negative is not.
// A slow, deliberate repetition -- "breathe. breathe. breathe." over half a
// minute -- comes back with max_run sayings of it, which still reads as a
// repetition; a missed invention is four minutes of "you" in the deliverable.
@(private)
is_invention :: proc(run: []Cue, p: Collapse_Params) -> bool {
	assert(len(run) > 0, "a run with no cues in it is not a run")
	assert(p.max_run > 0, "a run collapsed to nothing deletes the speech it was made of")

	if len(run) <= p.max_run {
		return false
	}

	span := run[len(run) - 1].end - run[0].start
	// The ordering collapse_repetition asserted, read back as the one thing this
	// measurement needs from it (CLAUDE.md A4). A negative span would make every
	// long run speech and strip nothing at all.
	assert(span >= 0, "a run of an ordered set ends before it starts")
	return span >= p.min_run_ms
}

// One past the last Cue saying the same thing as the one at `start`.
@(private)
repetition_run_end :: proc(cues: []Cue, start: int) -> (end: int) {
	assert(start >= 0, "a run cannot begin before the cue set does")
	assert(start < len(cues), "a run cannot begin past the end of the cue set")
	// The run holds the Cue it began at, whatever else it holds. A run of nothing
	// would leave collapse_repetition's loop standing still on it forever.
	defer assert(end > start, "a run that does not hold the cue it began at")

	said := spoken_text(cues[start])
	end = start + 1
	for end < len(cues) && spoken_text(cues[end]) == said {
		end += 1
	}
	return
}
