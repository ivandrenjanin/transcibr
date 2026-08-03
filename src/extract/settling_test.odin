package extract

import "core:testing"

// Whether a Recording has stopped being written to, decided from two readings
// of it rather than from one.
//
// THE QUESTION IS INHERENTLY RACY and these cases are where that is faced. A
// file that has not changed between two readings may simply not have been
// written to in that moment; the answer is a probability and never a proof. What
// the decision below can do is refuse to answer where it has no basis, which is
// what the third outcome is for.

// A reading of a settled 100 MB Recording, and the same reading three seconds
// later. Nanoseconds throughout, which is what Windows keeps and what
// core:time counts in.
@(private)
SECOND_NS :: i64(1_000_000_000)
@(private)
first_reading :: proc() -> Reading {
	return Reading{bytes = 104_857_600, modified_ns = 500 * SECOND_NS, taken_ns = 900 * SECOND_NS}
}

@(test)
a_source_that_did_not_change_between_two_readings_has_settled :: proc(t: ^testing.T) {
	first := first_reading()
	second := first
	second.taken_ns += 3 * SECOND_NS

	testing.expect_value(t, settling(first, second, MINIMUM_SETTLING_GAP_NS), Settling.Settled)
}

@(test)
a_source_that_grew_between_two_readings_is_still_being_written :: proc(t: ^testing.T) {
	first := first_reading()
	second := first
	second.taken_ns += 3 * SECOND_NS
	second.bytes += 4096
	// The modification time deliberately left ALONE, which is the case that
	// makes the size check worth having: FAT, exFAT and many SMB servers keep
	// modification times to a two-second granularity, so two writes inside one
	// bucket carry the same timestamp.
	testing.expect_value(
		t,
		settling(first, second, MINIMUM_SETTLING_GAP_NS),
		Settling.Still_Being_Written,
	)
}

@(test)
a_source_touched_in_place_between_two_readings_is_still_being_written :: proc(t: ^testing.T) {
	first := first_reading()
	second := first
	second.taken_ns += 3 * SECOND_NS
	second.modified_ns += SECOND_NS
	// The SIZE deliberately left alone, which is the case that makes the
	// modification-time check worth having: a container being finalised
	// rewrites its index in place, and a recorder writing into a preallocated
	// file does not change its length at all.
	testing.expect_value(
		t,
		settling(first, second, MINIMUM_SETTLING_GAP_NS),
		Settling.Still_Being_Written,
	)
}

@(test)
a_source_that_shrank_between_two_readings_is_still_being_written :: proc(t: ^testing.T) {
	first := first_reading()
	second := first
	second.taken_ns += 3 * SECOND_NS
	second.bytes -= 4096
	testing.expect_value(
		t,
		settling(first, second, MINIMUM_SETTLING_GAP_NS),
		Settling.Still_Being_Written,
	)
}

@(test)
two_readings_taken_too_close_together_cannot_tell :: proc(t: ^testing.T) {
	// The honest answer, and the reason there are three outcomes rather than
	// two. A pair of readings five milliseconds apart says nothing about a
	// recorder that flushes once a second, and reporting that as "settled" is
	// how a file still being written gets transcribed anyway.
	first := first_reading()
	second := first
	second.taken_ns += 5 * SECOND_NS / 1000

	testing.expect_value(
		t,
		settling(first, second, MINIMUM_SETTLING_GAP_NS),
		Settling.Too_Soon_To_Tell,
	)
}

@(test)
the_gap_is_pinned_one_nanosecond_either_side :: proc(t: ^testing.T) {
	// A bound nothing holds in the dangerous direction is a bound that gets
	// shortened by whoever meets it next.
	first := first_reading()
	just_enough := first
	just_enough.taken_ns += MINIMUM_SETTLING_GAP_NS
	testing.expect_value(
		t,
		settling(first, just_enough, MINIMUM_SETTLING_GAP_NS),
		Settling.Settled,
	)

	one_short := first
	one_short.taken_ns += MINIMUM_SETTLING_GAP_NS - 1
	testing.expect_value(
		t,
		settling(first, one_short, MINIMUM_SETTLING_GAP_NS),
		Settling.Too_Soon_To_Tell,
	)
}

@(test)
a_source_that_changed_is_still_being_written_however_soon_it_was_read :: proc(t: ^testing.T) {
	// Order matters, and this is what pins it. A change is PROOF that
	// something is writing; too short a gap is only an absence of evidence. A
	// decision that checked the gap first would answer "cannot tell" for a file
	// it had just watched grow.
	first := first_reading()
	second := first
	second.taken_ns += 1
	second.bytes += 1

	testing.expect_value(
		t,
		settling(first, second, MINIMUM_SETTLING_GAP_NS),
		Settling.Still_Being_Written,
	)
}

@(test)
the_minimum_gap_outlasts_the_coarsest_timestamp_a_recording_can_carry :: proc(t: ^testing.T) {
	// FAT and exFAT store a modification time to a two-second granularity, and
	// SMB servers commonly round to the same. A gap shorter than that can fall
	// entirely inside one bucket, so a file being appended to shows the same
	// timestamp twice and only the size gives it away.
	testing.expect_value(t, MINIMUM_SETTLING_GAP_NS, 3 * SECOND_NS)
	testing.expect(
		t,
		MINIMUM_SETTLING_GAP_NS > 2 * SECOND_NS,
		"the gap does not outlast a FAT timestamp bucket",
	)
}
