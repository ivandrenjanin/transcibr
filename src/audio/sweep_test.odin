#+vet explicit-allocators
package audio

import "core:testing"

@(private)
HOUR_NS :: i64(60 * 60) * 1_000_000_000
@(private)
DAY_NS :: 24 * HOUR_NS
@(private)
GIB :: i64(1024 * 1024 * 1024)

@(private)
@(require_results)
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
	entries := []Cache_Entry {
		entry("newest.wav", 8 * GIB, 2 * HOUR_NS),
		entry("oldest.wav", 8 * GIB, 5 * DAY_NS),
		entry("new.wav", 8 * GIB, 3 * HOUR_NS),
		entry("old.wav", 8 * GIB, 4 * DAY_NS),
	}

	taken := sweep_choice(entries, DEFAULT_SWEEP_LIMITS, context.allocator)
	defer delete(taken, context.allocator)
	testing.expect_value(t, len(taken), 2)
	testing.expect_value(t, taken[0], 1)
	testing.expect_value(t, taken[1], 3)
}

@(test)
a_part_file_a_run_still_in_progress_is_writing_is_never_taken :: proc(t: ^testing.T) {
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
	entries := []Cache_Entry{entry("1.wav.part", GIB, 9 * DAY_NS)}

	taken := sweep_choice(entries, DEFAULT_SWEEP_LIMITS, context.allocator)
	defer delete(taken, context.allocator)
	testing.expect_value(t, len(taken), 1)
	testing.expect_value(t, taken[0], 0)
}

@(test)
the_size_ceiling_stops_at_the_spare_floor_rather_than_emptying_the_cache :: proc(t: ^testing.T) {
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

@(test)
a_file_exactly_at_the_age_ceiling_is_kept_and_one_nanosecond_older_is_taken :: proc(
	t: ^testing.T,
) {
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
	testing.expect_value(t, len(taken), 1)
	testing.expect_value(t, taken[0], 1)
}

@(test)
an_empty_cache_gives_the_sweep_nothing_to_do :: proc(t: ^testing.T) {
	taken := sweep_choice(nil, DEFAULT_SWEEP_LIMITS, context.allocator)
	defer delete(taken, context.allocator)
	testing.expect_value(t, len(taken), 0)
}

// Why each of the three is the number it is: ADR-0023.
@(test)
the_sweep_ceilings_are_the_ones_that_were_reasoned_about :: proc(t: ^testing.T) {
	testing.expect_value(t, DEFAULT_SWEEP_LIMITS.max_bytes, 20 * GIB)
	testing.expect_value(t, DEFAULT_SWEEP_LIMITS.max_age_ns, 7 * DAY_NS)
	testing.expect_value(t, DEFAULT_SWEEP_LIMITS.spare_age_ns, HOUR_NS)
}
