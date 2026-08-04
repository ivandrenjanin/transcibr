#+vet explicit-allocators
package audio

import "core:testing"

@(private)
SECOND_NS :: i64(1_000_000_000)
@(private)
MILLISECOND_NS :: SECOND_NS / 1000
@(private)
@(require_results)
first_reading :: proc() -> Reading {
	return Reading{bytes = 104_857_600, modified_ns = 500 * SECOND_NS, taken_ns = 900 * SECOND_NS}
}

@(test)
a_source_that_grew_between_two_readings_is_still_being_written :: proc(t: ^testing.T) {
	first := first_reading()
	second := first
	second.taken_ns += 3 * SECOND_NS
	second.bytes += 4096
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
a_clock_that_went_backwards_between_two_readings_cannot_tell :: proc(t: ^testing.T) {
	first := first_reading()
	second := first
	second.taken_ns -= 60 * SECOND_NS

	testing.expect_value(
		t,
		settling(first, second, MINIMUM_SETTLING_GAP_NS),
		Settling.Too_Soon_To_Tell,
	)

	grew := second
	grew.bytes += 4096
	testing.expect_value(
		t,
		settling(first, grew, MINIMUM_SETTLING_GAP_NS),
		Settling.Still_Being_Written,
	)
}

@(test)
a_clock_that_stepped_forward_makes_a_gap_look_satisfied_and_the_proof_still_holds :: proc(
	t: ^testing.T,
) {
	first := first_reading()
	stepped := first
	stepped.taken_ns += 60 * SECOND_NS
	testing.expect_value(t, settling(first, stepped, MINIMUM_SETTLING_GAP_NS), Settling.Settled)

	moved := stepped
	moved.bytes += 4096
	testing.expect_value(
		t,
		settling(first, moved, MINIMUM_SETTLING_GAP_NS),
		Settling.Still_Being_Written,
	)

	touched := stepped
	touched.modified_ns += SECOND_NS
	testing.expect_value(
		t,
		settling(first, touched, MINIMUM_SETTLING_GAP_NS),
		Settling.Still_Being_Written,
	)
}

@(test)
the_wait_is_what_is_left_of_the_gap :: proc(t: ^testing.T) {
	first := first_reading()
	second := first
	second.taken_ns += SECOND_NS

	testing.expect_value(
		t,
		remaining_gap_ns(first, second, MINIMUM_SETTLING_GAP_NS),
		2 * SECOND_NS,
	)
}

@(test)
a_gap_already_outlasted_is_no_wait_at_all_rather_than_a_negative_one :: proc(t: ^testing.T) {
	first := first_reading()
	long_after := first
	long_after.taken_ns += 60 * SECOND_NS
	testing.expect_value(t, remaining_gap_ns(first, long_after, MINIMUM_SETTLING_GAP_NS), 0)

	exactly := first
	exactly.taken_ns += MINIMUM_SETTLING_GAP_NS
	testing.expect_value(t, remaining_gap_ns(first, exactly, MINIMUM_SETTLING_GAP_NS), 0)

	one_short := first
	one_short.taken_ns += MINIMUM_SETTLING_GAP_NS - 1
	testing.expect_value(
		t,
		remaining_gap_ns(first, one_short, MINIMUM_SETTLING_GAP_NS),
		MILLISECOND_NS,
	)
}

@(test)
a_wait_is_a_whole_number_of_milliseconds_because_the_sleep_it_feeds_truncates :: proc(
	t: ^testing.T,
) {
	first := first_reading()
	second := first
	second.taken_ns += 300_000

	testing.expect_value(t, remaining_gap_ns(first, second, 2 * SECOND_NS), 2 * SECOND_NS)

	for spent in ([]i64{1, 300_000, MILLISECOND_NS, MILLISECOND_NS + 1, SECOND_NS - 1}) {
		spent_at := first
		spent_at.taken_ns += spent
		left := remaining_gap_ns(first, spent_at, MINIMUM_SETTLING_GAP_NS)
		testing.expectf(
			t,
			left % MILLISECOND_NS == 0,
			"%d nanoseconds in, the wait is %d, which a millisecond sleep cannot express",
			spent,
			left,
		)
		testing.expectf(
			t,
			left + spent >= MINIMUM_SETTLING_GAP_NS,
			"%d nanoseconds in, waiting %d more still lands inside the gap",
			spent,
			left,
		)
	}
}

@(test)
a_clock_that_went_backwards_does_not_ask_for_a_longer_wait_than_the_gap :: proc(t: ^testing.T) {
	first := first_reading()
	backwards := first
	backwards.taken_ns -= 60 * SECOND_NS

	testing.expect_value(
		t,
		remaining_gap_ns(first, backwards, MINIMUM_SETTLING_GAP_NS),
		MINIMUM_SETTLING_GAP_NS,
	)
}

@(test)
a_recording_seen_to_have_settled_is_no_fault_and_no_second_look :: proc(t: ^testing.T) {
	fault, again := settling_fault(.Settled, 1)
	testing.expect_value(t, fault, Fault.None)
	testing.expect(t, !again, "a Recording that had settled was waited for anyway")
}

@(test)
a_recording_seen_to_move_is_refused_however_many_looks_are_left :: proc(t: ^testing.T) {
	for left in 0 ..= SETTLING_ATTEMPTS {
		fault, again := settling_fault(.Still_Being_Written, left)
		testing.expect_value(t, fault, Fault.Still_Being_Written)
		testing.expectf(
			t,
			!again,
			"a Recording caught moving was looked at again, with %d left",
			left,
		)
	}
}

@(test)
too_soon_to_tell_asks_for_another_look_while_there_is_one_to_ask_for :: proc(t: ^testing.T) {
	fault, again := settling_fault(.Too_Soon_To_Tell, 1)
	testing.expect(t, again, "the second look was never asked for")
	testing.expect_value(t, fault, Fault.None)
}

@(test)
too_soon_to_tell_with_no_look_left_is_refused_and_never_called_settled :: proc(t: ^testing.T) {
	fault, again := settling_fault(.Too_Soon_To_Tell, 0)
	testing.expect_value(t, fault, Fault.Still_Unsettled)
	testing.expect(t, !again, "a look was asked for that the caller does not have")
}

@(test)
the_minimum_gap_outlasts_the_coarsest_timestamp_a_recording_can_carry :: proc(t: ^testing.T) {
	testing.expect_value(t, MINIMUM_SETTLING_GAP_NS, 3 * SECOND_NS)
}
