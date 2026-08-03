package transcript

import "core:mem"
import "core:strings"

// When a run of identical consecutive Cues stops being speech and starts being
// the Engine inventing over silence.
//
// ONE threshold, and it counts SAYINGS. Per-Cue confidence does not exist in
// Engine output and the only number that does -- per-token `p` -- is the wrong
// instrument, because a fabrication over silence is emitted with HIGH token
// probability (ADR-0001). So the shape of the run is all there is to read.
//
// What separates the two populations is HOW MANY, not how long (ADR-0016). The
// clock cannot do it in either direction: a call-hold announcement repeats more
// slowly than the Engine's measured invention of "you", and the Engine's classic
// loop of "Thank you for watching!" arrives faster than ordinary conversation.
// A threshold on elapsed time therefore deletes real speech at the slow end and
// waves the Engine through at the fast one, whichever way it is turned. The
// number of sayings does neither: both inventions ADR-0001 measured hold 16 and
// 17 of them, and the longest real repetition collected holds eleven.
Collapse_Params :: struct {
	// How many SAYINGS of an invented run survive it. Three rather than one: the
	// run is dropped where it is INVENTED, and a Transcript that reads "you. you.
	// you." tells a reader the Engine ran on over silence, where a single "you."
	// reads as something the speaker said.
	max_run:      int,
	// How many SAYINGS a run must hold before it is an Invention at all. Never at
	// or below max_run, which would condemn a run the moment it passed what
	// survives it -- a cap on length alone, and a cap on length alone deletes
	// real words: "no. no. no. no. no." is five sayings, and an over-eager filter
	// that took two of them away would not be noticed for weeks.
	invention_at: int,
}

// The one shipped set of these, and the reason there is one rather than one per
// Merge Profile: repetition is a property of the ENGINE, not of the material.
// The Engine loops over silence the same way whoever was recorded was talking to
// one person or to six. Not COLLAPSE_DEFAULT: there is no second set for a
// default to be chosen over, and a name promising one invites a caller to go
// looking for it.
//
// The evidence supports a BAND rather than a number -- above eleven, the longest
// real repetition collected, and at or below sixteen, the shorter of the two
// inventions ADR-0001 measured. Fourteen is the middle of it, which is the value
// furthest from both ways of being wrong. What the remaining false positives
// cost, and why they are paid rather than tuned away, is ADR-0016.
COLLAPSE_THRESHOLDS :: Collapse_Params {
	max_run      = 3,
	invention_at = 14,
}

// What collapse_repetition has to be handed to accept these at all, said in
// checked code beside them rather than discovered on the first Recording that
// uses one (CLAUDE.md A5). The compiler answers this; the assertions inside
// collapse_repetition answer it again for a set a caller built by hand (A4).
#assert(COLLAPSE_THRESHOLDS.max_run > 0)
#assert(COLLAPSE_THRESHOLDS.invention_at > COLLAPSE_THRESHOLDS.max_run)

// Collapses every invented repetition run in a Cue set, leaving everything else
// exactly as it was.
//
// The Cues come back CLONED, so what is returned is freed with destroy_cues and
// the Cue set that went in is freed separately with the allocator that made it.
// Under the arena a job runs on (ADR-0010) neither set is freed at all and the
// borrow would cost nothing; destroy_cues exists for the per-set freeing the
// tests do, and a borrowed slice makes one destroy_cues on each a double free
// with only one of the two orders even survivable.
//
// The allocator is explicit and never defaulted: the Cue set this returns
// outlives this procedure and crosses a worker boundary (ADR-0010).
collapse_repetition :: proc(cues: []Cue, p: Collapse_Params, allocator: mem.Allocator) -> (kept: []Cue) {
	assert(p.max_run > 0, "a run collapsed to nothing deletes the speech it was made of")
	assert(p.invention_at > p.max_run, "a run condemned at what survives it is a cap on length alone")
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

	kept = owned_slice(&built)
	assert(len(kept) > 0, "collapsed a cue set that had cues in it down to nothing")
	assert(len(kept) <= len(cues), "collapsing invented a cue")
	// The read side of the ordering asserted on the way in (CLAUDE.md A4).
	// Dropping the tail of a run preserves it; dropping the wrong end would not.
	assert(cues_are_ordered(kept), "collapsing left the cue set out of order")
	return
}

// Whether a run of identical consecutive Cues is invention rather than speech.
//
// The elapsed time of the run is deliberately not read, and that is the whole
// design (ADR-0016). It is not a weaker signal than the count, it is a signal
// pointing the wrong way at both ends: the slowest repetition in the collected
// material is real speech -- a hold announcement every half a minute -- and the
// fastest is the Engine looping once a second.
//
// The false positive that remains is a run of MORE than invention_at genuine
// sayings of one phrase: a chant, a drill, a guided meditation. It comes back
// with max_run sayings and the rest of the run dropped, which is real speech
// deleted, and ADR-0016 records it as the accepted cost rather than pretending
// it is cheap.
@(private)
is_invention :: proc(run: []Cue, p: Collapse_Params) -> bool {
	assert(len(run) > 0, "a run with no cues in it is not a run")
	assert(p.invention_at > p.max_run, "a run condemned at what survives it is a cap on length alone")

	// SAYINGS and not Cues, which is what keeps the Engine's own silence out of
	// this. Silence is identical to silence, so counting Cues makes eight minutes
	// of the Cues the Engine writes over a quiet stretch an invention and deletes
	// all but three of them -- taking the Recording's timeline with them, and
	// none of it was ever speech to strip.
	count := run_sayings(run)
	if count == 0 {
		return false
	}

	// A run with sayings in it BEGAN at one: silence carries a run on rather than
	// starting one, so a run that began at silence holds nothing else. The read
	// side of the run walk's own rule (CLAUDE.md A4).
	assert(len(spoken_text(run[0])) > 0, "a run of silence was counted as having said something")
	return count >= p.invention_at
}

// How many Cues of a run said something.
@(private)
run_sayings :: proc(run: []Cue) -> (count: int) {
	assert(len(run) > 0, "a run with no cues in it is not a run")
	defer assert(count <= len(run), "counted more sayings than there were cues to say them")
	// The negative space of that (CLAUDE.md A3): a count is a tally, and a
	// negative one would make every run speech and strip nothing at all.
	defer assert(count >= 0, "counted a negative number of sayings")

	for cue in run {
		if len(spoken_text(cue)) == 0 {
			continue
		}
		count += 1
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
