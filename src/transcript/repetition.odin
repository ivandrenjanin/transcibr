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
	// How many SAYINGS of an invented run survive it. Three rather than one: the
	// run is dropped where it is INVENTED, and a Transcript that reads "you. you.
	// you." tells a reader the Engine ran on over silence, where a single "you."
	// reads as something the speaker said.
	max_run:    int,
	// How much of the Recording the sayings must cover before their number is
	// held against them at all. This is the threshold that protects real speech.
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
// The Cues come back CLONED, so what is returned is freed with destroy_cues and
// the Cue set that went in is freed separately with the allocator that made it.
// Handing back a slice that borrowed the other one's text would be cheaper and
// would make the two sets impossible to free independently -- one destroy_cues
// on each is a double free, and only one of the two orders of the two calls is
// even survivable.
//
// The allocator is explicit and never defaulted: the Cue set this returns
// outlives this procedure and crosses a worker boundary (ADR-0010).
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
		run := cues[start:end]

		take := len(run)
		if is_invention(run, p) {
			take = through_sayings(run, p.max_run)
		}
		assert(take > 0, "kept no part of a run that had cues in it")
		assert(take <= len(run), "kept more of a run than was ever in it")

		for cue in run[:take] {
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

	count, ended := run_sayings(run)
	// SAYINGS and not Cues, which is what keeps the Engine's own silence out of
	// this. Silence is identical to silence, so counting Cues makes eight minutes
	// of the Cues the Engine writes over a quiet stretch an invention and deletes
	// all but three of them -- taking the Recording's timeline with them, and
	// none of it was ever speech to strip.
	if count <= p.max_run {
		return false
	}

	// A run with sayings in it BEGAN at one: silence carries a run on rather than
	// starting one, so a run that began at silence holds nothing else.
	assert(len(spoken_text(run[0])) > 0, "a run of silence was counted as having said something")
	span := ended - run[0].start
	// The ordering collapse_repetition asserted, read back as the one thing this
	// measurement needs from it (CLAUDE.md A4). A negative span would make every
	// long run speech and strip nothing at all.
	assert(span >= 0, "a run of an ordered set ends before it starts")
	return span >= p.min_run_ms
}

// How many Cues of a run said something, and where the last of those ended.
@(private)
run_sayings :: proc(run: []Cue) -> (count: int, ended: Millis) {
	assert(len(run) > 0, "a run with no cues in it is not a run")

	for cue in run {
		if len(spoken_text(cue)) == 0 {
			continue
		}
		count += 1
		// max, not assignment: consecutive Cues may overlap, which is ordinary
		// Engine output, so the last saying is not always the one ending latest.
		ended = max(ended, cue.end)
	}

	assert(count <= len(run), "counted more sayings than there were cues to say them")
	// The negative space of that (CLAUDE.md A3): a run that said nothing has no
	// last saying, so the zero here is the absence of one and not an offset.
	if count == 0 {
		assert(ended == 0, "a run that said nothing has a saying ending somewhere")
	}
	return
}

// One past the Cue carrying the `count`th saying of a run.
//
// Everything before it comes through, silence included: the Cues the Engine
// wrote over the silence between two sayings are the Recording's own timeline,
// and only the tail of an invention is anything to drop.
@(private)
through_sayings :: proc(run: []Cue, count: int) -> (end: int) {
	assert(len(run) > 0, "a run with no cues in it is not a run")
	assert(count > 0, "a run cut short of its first saying keeps no speech at all")
	defer assert(end > 0, "kept no part of a run that had sayings in it")
	defer assert(end <= len(run), "kept more of a run than was ever in it")

	said := 0
	for cue, i in run {
		if len(spoken_text(cue)) == 0 {
			continue
		}
		said += 1
		if said == count {
			return i + 1
		}
	}
	return len(run)
}

// One past the last Cue carrying on the run that begins at `start`.
@(private)
repetition_run_end :: proc(cues: []Cue, start: int) -> (end: int) {
	assert(start >= 0, "a run cannot begin before the cue set does")
	assert(start < len(cues), "a run cannot begin past the end of the cue set")
	// The run holds the Cue it began at, whatever else it holds. A run of nothing
	// would leave collapse_repetition's loop standing still on it forever.
	defer assert(end > start, "a run that does not hold the cue it began at")

	said := spoken_text(cues[start])
	end = start + 1
	for end < len(cues) && carries_on_run(cues[end], said) {
		end += 1
	}
	return
}

// Whether a Cue carries on the run of `said`.
//
// A Cue that says nothing is silence the Engine wrote a Cue over. It neither
// starts a run nor breaks one, so it carries on whatever is in progress: an
// invention with the Engine's own silence written through it is still ONE
// invention, and a walk demanding strictly adjacent sayings sees sixteen runs of
// one there and strips nothing at all.
//
// A run that began at silence is a run OF silence -- `said` is empty, so the
// first Cue that says anything ends it -- and a run that said nothing is never
// an invention.
@(private)
carries_on_run :: proc(cue: Cue, said: string) -> bool {
	next := spoken_text(cue)
	if len(next) == 0 {
		return true
	}
	return next == said
}
