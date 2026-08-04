#+vet explicit-allocators
package audio

import "core:testing"

// Measured; see ADR-0022.
@(test)
audio_that_came_back_the_length_the_container_promised_agrees :: proc(t: ^testing.T) {
	testing.expect(t, durations_agree(300_000, 300_000, DEFAULT_TOLERANCE))
	testing.expect(t, durations_agree(300_006, 300_000, DEFAULT_TOLERANCE))
}

@(test)
audio_that_stopped_half_way_through_the_recording_disagrees :: proc(t: ^testing.T) {
	testing.expect(t, !durations_agree(300_000, 149_918, DEFAULT_TOLERANCE))
}

@(test)
audio_longer_than_the_container_claims_disagrees_too :: proc(t: ^testing.T) {
	testing.expect(t, !durations_agree(300_000, 450_000, DEFAULT_TOLERANCE))
}

@(test)
the_floor_governs_a_short_recording_and_is_one_second :: proc(t: ^testing.T) {
	testing.expect_value(t, allowed_difference_ms(600_000, DEFAULT_TOLERANCE), i64(1000))
	testing.expect(t, durations_agree(600_000, 599_000, DEFAULT_TOLERANCE))
	testing.expect(t, !durations_agree(600_000, 598_999, DEFAULT_TOLERANCE))
}

@(test)
the_relative_term_governs_a_long_recording_and_is_a_thousandth :: proc(t: ^testing.T) {
	longest :: i64(168 * 60 * 1000)
	testing.expect_value(t, allowed_difference_ms(longest, DEFAULT_TOLERANCE), i64(10_080))
	testing.expect(t, durations_agree(longest, longest - 10_080, DEFAULT_TOLERANCE))
	testing.expect(t, !durations_agree(longest, longest - 10_081, DEFAULT_TOLERANCE))
}

@(test)
the_two_terms_cross_over_at_one_thousand_seconds :: proc(t: ^testing.T) {
	testing.expect_value(t, allowed_difference_ms(1_000_000, DEFAULT_TOLERANCE), i64(1000))
	testing.expect_value(t, allowed_difference_ms(999_000, DEFAULT_TOLERANCE), i64(1000))
	testing.expect_value(t, allowed_difference_ms(2_000_000, DEFAULT_TOLERANCE), i64(2000))
}

@(test)
the_default_tolerance_is_the_one_that_was_measured_for :: proc(t: ^testing.T) {
	testing.expect_value(t, DEFAULT_TOLERANCE.floor_ms, i64(1000))
	testing.expect_value(t, DEFAULT_TOLERANCE.per_mille, i64(1))
}

@(test)
a_tolerance_is_an_argument_so_a_batch_can_be_told_to_be_stricter :: proc(t: ^testing.T) {
	exact :: Tolerance {
		floor_ms  = 0,
		per_mille = 0,
	}
	testing.expect(t, durations_agree(300_000, 300_000, exact))
	testing.expect(t, !durations_agree(300_006, 300_000, exact))
}

// Two measured false failures, accepted; see ADR-0022.
@(test)
durations_of_a_container_that_estimates_its_own_length_disagree :: proc(t: ^testing.T) {
	testing.expect(t, !durations_agree(287_765, 300_042, DEFAULT_TOLERANCE))
	testing.expect(t, !durations_agree(587_005, 300_025, DEFAULT_TOLERANCE))
}
