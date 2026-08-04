package transcript

import "core:mem"
import "core:strings"

Collapse_Params :: struct {
	max_run:      int,
	invention_at: int,
}

// Why these values, and why one set rather than one per Merge Profile: ADR-0016.
COLLAPSE_THRESHOLDS :: Collapse_Params {
	max_run      = 3,
	invention_at = 14,
}

#assert(COLLAPSE_THRESHOLDS.max_run > 0)
#assert(COLLAPSE_THRESHOLDS.invention_at > COLLAPSE_THRESHOLDS.max_run)

// The Cues come back CLONED: what is returned is freed with destroy_cues, and the
// set that went in is freed separately with the allocator that made it. Borrowing
// instead would make one destroy_cues on each a double free.
collapse_repetition :: proc(
	cues: []Cue,
	p: Collapse_Params,
	allocator: mem.Allocator,
) -> (
	kept: []Cue,
) {
	assert(p.max_run > 0, "a run collapsed to nothing deletes the speech it was made of")
	assert(
		p.invention_at > p.max_run,
		"a run condemned at what survives it is a cap on length alone",
	)
	assert(
		allocator.procedure != nil,
		"the cue set outlives this procedure and needs a chosen allocator",
	)
	assert(cues_are_ordered(cues), "collapsing a cue set parse_cues could not have returned")

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
	assert(cues_are_ordered(kept), "collapsing left the cue set out of order")
	return
}

// Why the elapsed time of a run is not read, and what the remaining false
// positive costs: ADR-0016.
@(private)
is_invention :: proc(run: []Cue, p: Collapse_Params) -> bool {
	assert(len(run) > 0, "a run with no cues in it is not a run")
	assert(
		p.invention_at > p.max_run,
		"a run condemned at what survives it is a cap on length alone",
	)

	count := run_sayings(run)
	if count == 0 {
		return false
	}

	assert(len(spoken_text(run[0])) > 0, "a run of silence was counted as having said something")
	return count >= p.invention_at
}

@(private)
run_sayings :: proc(run: []Cue) -> (count: int) {
	assert(len(run) > 0, "a run with no cues in it is not a run")
	defer assert(count <= len(run), "counted more sayings than there were cues to say them")
	defer assert(count >= 0, "counted a negative number of sayings")

	for cue in run {
		if len(spoken_text(cue)) == 0 {
			continue
		}
		count += 1
	}
	return
}

// One past the Cue carrying the `count`th saying. The silence between sayings
// comes through with them: the Cues the Engine wrote over it are the Recording's
// own timeline, and only the tail of an invention is anything to drop.
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

@(private)
repetition_run_end :: proc(cues: []Cue, start: int) -> (end: int) {
	assert(start >= 0, "a run cannot begin before the cue set does")
	assert(start < len(cues), "a run cannot begin past the end of the cue set")
	defer assert(end > start, "a run that does not hold the cue it began at")

	said := spoken_text(cues[start])
	end = start + 1
	for end < len(cues) && carries_on_run(cues[end], said) {
		end += 1
	}
	return
}

// A Cue that says nothing is silence the Engine wrote a Cue over: it carries a
// run ON rather than breaking it, because an invention with the Engine's own
// silence written through it is still ONE invention.
@(private)
carries_on_run :: proc(cue: Cue, said: string) -> bool {
	next := spoken_text(cue)
	if len(next) == 0 {
		return true
	}
	return next == said
}
