package audio

import "core:testing"

// What the sweep at Batch start may take out of the scratch cache, and -- the
// half that matters more -- what it may not.
//
// THIS DECISION DELETES FILES. Every case below is about a file surviving or not
// surviving, and the ones about survival are load-bearing: the cache is where an
// extraction's `.part` and the Engine's output live while they are being written
// (ADR-0002), so a sweep that took a file another worker was using would destroy
// the run it belongs to.

@(private)
HOUR_NS :: i64(60 * 60) * 1_000_000_000
@(private)
DAY_NS :: 24 * HOUR_NS
@(private)
GIB :: i64(1024 * 1024 * 1024)

@(private)
entry :: proc(name: string, bytes: i64, age_ns: i64) -> Cache_Entry {
	return Cache_Entry{name = name, bytes = bytes, age_ns = age_ns}
}

@(test)
a_cache_inside_both_ceilings_is_left_alone :: proc(t: ^testing.T) {
	entries := []Cache_Entry{entry("1.wav", GIB, DAY_NS), entry("2.wav", GIB, 2 * DAY_NS)}

	taken := sweep_choice(entries, DEFAULT_SWEEP_LIMITS, context.allocator)
	defer delete(taken, context.allocator)
	testing.expect_value(t, len(taken), 0)
}

@(test)
audio_left_behind_by_a_run_that_failed_every_recording_is_swept_on_age :: proc(t: ^testing.T) {
	// The spec's own sentence: a run that fails every Recording must not
	// accumulate audio indefinitely. Nothing about these is over the size
	// ceiling; they are simply old.
	entries := []Cache_Entry {
		entry("old.wav", GIB, 8 * DAY_NS),
		entry("older.wav", GIB, 30 * DAY_NS),
		entry("recent.wav", GIB, 2 * DAY_NS),
	}

	taken := sweep_choice(entries, DEFAULT_SWEEP_LIMITS, context.allocator)
	defer delete(taken, context.allocator)
	testing.expect_value(t, len(taken), 2)
	testing.expect_value(t, taken[0], 0)
	testing.expect_value(t, taken[1], 1)
}

@(test)
a_cache_over_the_size_ceiling_loses_its_oldest_first :: proc(t: ^testing.T) {
	// Four entries of 8 GiB each against a 20 GiB ceiling: 32 GiB is 12 over,
	// so the two oldest go and the two newest stay.
	entries := []Cache_Entry {
		entry("newest.wav", 8 * GIB, 2 * HOUR_NS),
		entry("oldest.wav", 8 * GIB, 5 * DAY_NS),
		entry("new.wav", 8 * GIB, 3 * HOUR_NS),
		entry("old.wav", 8 * GIB, 4 * DAY_NS),
	}

	taken := sweep_choice(entries, DEFAULT_SWEEP_LIMITS, context.allocator)
	defer delete(taken, context.allocator)
	testing.expect_value(t, len(taken), 2)
	// Indices into what it was given, ascending: `oldest.wav` and `old.wav`.
	testing.expect_value(t, taken[0], 1)
	testing.expect_value(t, taken[1], 3)
}

// ------------------------------------------------------ what it will not do --

@(test)
a_part_file_a_run_still_in_progress_is_writing_is_never_taken :: proc(t: ^testing.T) {
	// Far over the size ceiling and every entry minutes old, which is what a
	// second transcibr window mid-Batch looks like. The ceiling is not enforced
	// against files that young, and that is the decision rather than an
	// oversight: the alternative is a sweep that deletes the audio another
	// worker is at that moment writing.
	entries := []Cache_Entry {
		entry("1.wav.part", 40 * GIB, 5 * 60 * 1_000_000_000),
		entry("2.wav", 40 * GIB, 10 * 60 * 1_000_000_000),
	}

	taken := sweep_choice(entries, DEFAULT_SWEEP_LIMITS, context.allocator)
	defer delete(taken, context.allocator)
	testing.expect_value(t, len(taken), 0)
}

@(test)
a_part_file_from_a_run_that_died_days_ago_is_taken :: proc(t: ^testing.T) {
	// The negative space of the case above (A3), and not a formality: a floor
	// that protected everything would protect the leak the sweep exists for.
	// A `.part` is stale intermediate audio like any other file here.
	entries := []Cache_Entry{entry("1.wav.part", GIB, 9 * DAY_NS)}

	taken := sweep_choice(entries, DEFAULT_SWEEP_LIMITS, context.allocator)
	defer delete(taken, context.allocator)
	testing.expect_value(t, len(taken), 1)
	testing.expect_value(t, taken[0], 0)
}

@(test)
the_size_ceiling_stops_at_the_spare_floor_rather_than_emptying_the_cache :: proc(t: ^testing.T) {
	// Three old entries and one an hour too young. Even after the three are
	// gone the cache would be over its ceiling, and the young one stays anyway.
	entries := []Cache_Entry {
		entry("in-flight.wav.part", 30 * GIB, 30 * 60 * 1_000_000_000),
		entry("a.wav", 8 * GIB, 3 * DAY_NS),
		entry("b.wav", 8 * GIB, 4 * DAY_NS),
		entry("c.wav", 8 * GIB, 5 * DAY_NS),
	}

	taken := sweep_choice(entries, DEFAULT_SWEEP_LIMITS, context.allocator)
	defer delete(taken, context.allocator)
	testing.expect_value(t, len(taken), 3)
	for index in taken {
		testing.expect(t, index != 0, "the sweep took a file a run still in progress is writing")
	}
}

// ------------------------------------------------- where each line falls --
//
// Three thresholds, six cases, and none of them had one. This is the decision
// in this package that DELETES FILES, and "roughly a week" and "roughly an
// hour" are not what it does -- a file is kept or it is gone, and the whole
// difference is one nanosecond either side of a number nobody had pinned.
//
// Each pair fixes the limits it is about and puts the other two out of reach,
// so a case that moves is a case about the threshold it names.

@(test)
a_file_exactly_at_the_age_ceiling_is_kept_and_one_nanosecond_older_is_taken :: proc(
	t: ^testing.T,
) {
	// The size ceiling is a hundred gibibytes against one, so nothing here is
	// taken for being over it.
	limits := Sweep_Limits {
		max_bytes    = 100 * GIB,
		max_age_ns   = 7 * DAY_NS,
		spare_age_ns = HOUR_NS,
	}

	at := []Cache_Entry{entry("at.wav", GIB, 7 * DAY_NS)}
	kept := sweep_choice(at, limits, context.allocator)
	defer delete(kept, context.allocator)
	testing.expect_value(t, len(kept), 0)

	past := []Cache_Entry{entry("past.wav", GIB, 7 * DAY_NS + 1)}
	taken := sweep_choice(past, limits, context.allocator)
	defer delete(taken, context.allocator)
	testing.expect_value(t, len(taken), 1)
	testing.expect_value(t, taken[0], 0)
}

@(test)
a_file_exactly_at_the_spare_floor_is_taken_and_one_nanosecond_younger_is_kept :: proc(
	t: ^testing.T,
) {
	// A size ceiling of nothing at all, so the ceiling always says take it and
	// the only thing deciding is the floor. This is the side that matters: the
	// floor is what stands between the sweep and a file another worker is at
	// that moment writing.
	limits := Sweep_Limits {
		max_bytes    = 0,
		max_age_ns   = 7 * DAY_NS,
		spare_age_ns = HOUR_NS,
	}

	at := []Cache_Entry{entry("at.wav", GIB, HOUR_NS)}
	taken := sweep_choice(at, limits, context.allocator)
	defer delete(taken, context.allocator)
	testing.expect_value(t, len(taken), 1)
	testing.expect_value(t, taken[0], 0)

	under := []Cache_Entry{entry("under.wav", GIB, HOUR_NS - 1)}
	kept := sweep_choice(under, limits, context.allocator)
	defer delete(kept, context.allocator)
	testing.expect_value(t, len(kept), 0)
}

@(test)
a_cache_exactly_at_the_size_ceiling_is_kept_and_one_byte_over_loses_its_oldest :: proc(
	t: ^testing.T,
) {
	// Every age here is days old and the ceiling is a week, so nothing is taken
	// for being old and nothing is protected for being young.
	limits := Sweep_Limits {
		max_bytes    = 2 * GIB,
		max_age_ns   = 7 * DAY_NS,
		spare_age_ns = HOUR_NS,
	}

	at := []Cache_Entry{entry("new.wav", GIB, DAY_NS), entry("old.wav", GIB, 2 * DAY_NS)}
	kept := sweep_choice(at, limits, context.allocator)
	defer delete(kept, context.allocator)
	testing.expect_value(t, len(kept), 0)

	over := []Cache_Entry{entry("new.wav", GIB, DAY_NS), entry("old.wav", GIB + 1, 2 * DAY_NS)}
	taken := sweep_choice(over, limits, context.allocator)
	defer delete(taken, context.allocator)
	// The oldest goes, and taking it brings the total back inside the ceiling,
	// so the newer one stays: one byte over is one file gone and not two.
	testing.expect_value(t, len(taken), 1)
	testing.expect_value(t, taken[0], 1)
}

@(test)
an_empty_cache_gives_the_sweep_nothing_to_do :: proc(t: ^testing.T) {
	taken := sweep_choice(nil, DEFAULT_SWEEP_LIMITS, context.allocator)
	defer delete(taken, context.allocator)
	testing.expect_value(t, len(taken), 0)
}

@(test)
the_sweep_ceilings_are_the_ones_that_were_reasoned_about :: proc(t: ^testing.T) {
	// Pinned outright, because all three are the kind of number that gets
	// nudged by whoever meets it next -- and two of them nudge towards deleting
	// more. WHY each is the number it is lives beside the constant in sweep.odin
	// and is deliberately not restated here: two copies of a justification are
	// two things to keep in step, and only one of them is next to the number.
	//
	// That the floor sits under the age ceiling is NOT checked here. It was, and
	// the check could not report: the three lines above already fix all three
	// numbers, so it compared two constants it had just pinned and could never
	// disagree with them. It is a `#assert` beside the constants now (A5), which
	// holds it before a test runs -- and sweep_choice asserts the same of
	// whatever limits it is handed, which every case in this file exercises.
	testing.expect_value(t, DEFAULT_SWEEP_LIMITS.max_bytes, 20 * GIB)
	testing.expect_value(t, DEFAULT_SWEEP_LIMITS.max_age_ns, 7 * DAY_NS)
	testing.expect_value(t, DEFAULT_SWEEP_LIMITS.spare_age_ns, HOUR_NS)
}
