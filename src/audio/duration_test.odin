package audio

import "core:testing"

// Whether the audio ffmpeg produced is the whole Recording, decided against the
// only independent claim there is: the container's own duration.
//
// EVERY NUMBER BELOW WAS MEASURED, on this machine, with the ffmpeg build this
// repository bundles (ADR-0013) and the argument list extract_arguments builds.
// Five containers of a 300-second sine, probed and then extracted:
//
//   container                     probe said   extracted audio   difference
//   AAC in MP4                    300.000000   300000 ms              0 ms
//   MP3 with its Xing header      300.000000   300000 ms              0 ms
//   PCM in WAV                    300.000000   300000 ms              0 ms
//   AC3 in Matroska               300.006000   300000 ms              6 ms
//   the same MP3, cut in half     300.000000   149918 ms        150082 ms
//
// The last row is the failure this whole check exists for, and the gap between
// it and the row above is what a tolerance has to fit inside. Two more, both
// legitimate files and both far outside any tolerance worth having, are in
// durations_of_a_container_that_estimates_its_own_length_disagree.
@(test)
audio_that_came_back_the_length_the_container_promised_agrees :: proc(t: ^testing.T) {
	testing.expect(t, durations_agree(300_000, 300_000, DEFAULT_TOLERANCE))
	// AC3 in Matroska, measured. Frame quantisation, and the largest
	// difference any well-formed container here produced.
	testing.expect(t, durations_agree(300_006, 300_000, DEFAULT_TOLERANCE))
}

@(test)
audio_that_stopped_half_way_through_the_recording_disagrees :: proc(t: ^testing.T) {
	// The measured half-truncated MP3. A Recording that produced this and was
	// transcribed anyway is a Transcript that stops mid-sentence and is marked
	// complete forever, which is the sentence the issue opens with.
	testing.expect(t, !durations_agree(300_000, 149_918, DEFAULT_TOLERANCE))
}

@(test)
audio_longer_than_the_container_claims_disagrees_too :: proc(t: ^testing.T) {
	// The negative space (A3), and not a formality: a check written as
	// `container - audio > allowed` passes every case above and waves through
	// a probe that read a different file from the one ffmpeg extracted.
	testing.expect(t, !durations_agree(300_000, 450_000, DEFAULT_TOLERANCE))
}

// ------------------------------------------------ the tolerance, both sides --
//
// A threshold nothing constrains in the dangerous direction is a threshold that
// gets loosened by whoever meets it next. Each case below pins one bound one
// millisecond either side of it, so a change to DEFAULT_TOLERANCE has to be a
// change to these cases too.

@(test)
the_floor_governs_a_short_recording_and_is_one_second :: proc(t: ^testing.T) {
	// A ten-minute Recording: a thousandth of it is 600 ms, so the floor is
	// what applies.
	testing.expect_value(t, allowed_difference_ms(600_000, DEFAULT_TOLERANCE), i64(1000))
	testing.expect(t, durations_agree(600_000, 599_000, DEFAULT_TOLERANCE))
	testing.expect(t, !durations_agree(600_000, 598_999, DEFAULT_TOLERANCE))
}

@(test)
the_relative_term_governs_a_long_recording_and_is_a_thousandth :: proc(t: ^testing.T) {
	// 168 minutes, the longest Recording in the reference corpus. A thousandth
	// of it is 10,080 ms, which is past the floor.
	longest :: i64(168 * 60 * 1000)
	testing.expect_value(t, allowed_difference_ms(longest, DEFAULT_TOLERANCE), i64(10_080))
	testing.expect(t, durations_agree(longest, longest - 10_080, DEFAULT_TOLERANCE))
	testing.expect(t, !durations_agree(longest, longest - 10_081, DEFAULT_TOLERANCE))
}

@(test)
the_two_terms_cross_over_at_one_thousand_seconds :: proc(t: ^testing.T) {
	// Below this the floor is the larger and above it the relative term is, and
	// a tolerance that took only one of them would be wrong on one side of it.
	testing.expect_value(t, allowed_difference_ms(1_000_000, DEFAULT_TOLERANCE), i64(1000))
	testing.expect_value(t, allowed_difference_ms(999_000, DEFAULT_TOLERANCE), i64(1000))
	testing.expect_value(t, allowed_difference_ms(2_000_000, DEFAULT_TOLERANCE), i64(2000))
}

@(test)
the_default_tolerance_is_the_one_that_was_measured_for :: proc(t: ^testing.T) {
	// The constants themselves, so that loosening either is an edit to a case
	// rather than a number nobody is holding. The floor covers every
	// quantisation effect there is with room to spare -- AAC encoder priming
	// and padding is at most 2,112 samples, 48 ms at 44.1 kHz, and one video
	// frame of container rounding at 23.976 fps is 42 ms -- and the measured
	// worst case among well-formed containers was 6 ms.
	testing.expect_value(t, DEFAULT_TOLERANCE.floor_ms, i64(1000))
	testing.expect_value(t, DEFAULT_TOLERANCE.per_mille, i64(1))
}

@(test)
a_tolerance_is_an_argument_so_a_batch_can_be_told_to_be_stricter :: proc(t: ^testing.T) {
	// The default is a default and not the rule. A caller handing in a tighter
	// one gets a tighter answer for the same two durations, which is what makes
	// the cases above claims about the constants rather than about arithmetic
	// nothing can vary.
	exact :: Tolerance {
		floor_ms  = 0,
		per_mille = 0,
	}
	testing.expect(t, durations_agree(300_000, 300_000, exact))
	testing.expect(t, !durations_agree(300_006, 300_000, exact))
}

@(test)
durations_of_a_container_that_estimates_its_own_length_disagree :: proc(t: ^testing.T) {
	// TWO MEASURED FALSE FAILURES, recorded here rather than left to be
	// discovered. Where a container carries no duration and ffprobe estimates
	// one from the average bitrate, the estimate is nowhere near:
	//
	//   an MP3 written with -write_xing 0   probe 287,765 ms, audio 300,042 ms
	//   a raw ADTS AAC stream               probe 587,005 ms, audio 300,025 ms
	//
	// Both files are complete and both fail this check. That is the honest
	// outcome and not a defect to route around: a container that cannot say how
	// long it is cannot be used to tell a complete extraction from a truncated
	// one, and ADR-0002's answer to anything arriving from outside is to report
	// it against the Recording and carry on with the Batch. What the user gets
	// is a line naming the file and both durations, which is actionable; what
	// the alternative gives is four hours of half a Recording marked complete.
	testing.expect(t, !durations_agree(287_765, 300_042, DEFAULT_TOLERANCE))
	testing.expect(t, !durations_agree(587_005, 300_025, DEFAULT_TOLERANCE))
}
