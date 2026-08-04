package audio

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
MILLISECOND_NS :: SECOND_NS / 1000
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
a_clock_that_went_backwards_between_two_readings_cannot_tell :: proc(t: ^testing.T) {
	// An NTP step or a user setting the machine's time, which is outside this
	// program and may not crash it (A8). A Reading carries a wall clock rather
	// than a monotonic tick on purpose -- a Batch resumes across a reboot
	// (ADR-0003) and a tick from a previous boot compares against nothing -- so
	// this is a live path and not a hypothetical.
	first := first_reading()
	second := first
	second.taken_ns -= 60 * SECOND_NS

	testing.expect_value(
		t,
		settling(first, second, MINIMUM_SETTLING_GAP_NS),
		Settling.Too_Soon_To_Tell,
	)

	// And a clock that went backwards does not hide a file that MOVED, which
	// is the half that matters: the proof is the size and the timestamp, and
	// the gap only says how much weight to give their not having changed.
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
	// THE TWIN OF THE CASE ABOVE, and the one that cannot be fixed here. A step
	// forward is arithmetically indistinguishable from time passing: two
	// readings a millisecond apart with a minute of clock inserted between them
	// look exactly like two readings a minute apart, and there is no third fact
	// in a Reading to tell them apart. A monotonic tick would, and a Reading
	// carries a wall clock on purpose so a Batch can resume across a reboot
	// (ADR-0003).
	//
	// So it is pinned rather than fixed, and what is pinned is how far it
	// reaches: it can turn `Too_Soon_To_Tell` into `Settled`, and it can do
	// nothing else.
	first := first_reading()
	stepped := first
	stepped.taken_ns += 60 * SECOND_NS
	testing.expect_value(t, settling(first, stepped, MINIMUM_SETTLING_GAP_NS), Settling.Settled)

	// The half that holds, and it is the half carrying the weight: what proves a
	// file is moving is its SIZE and its TIMESTAMP, neither of which a clock step
	// touches. A Recording that is genuinely still being written is caught with
	// the clock in any state at all -- the gap only ever decides how much to make
	// of two readings that AGREE.
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

// ------------------------------------------- how long there is left to wait --
//
// The clamp that decides the one wait this package ever takes. It lived inline
// in run.odin, where nothing could reach it, and it is the same clock-step class
// every case above is about.

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
	// Every Recording but the first in a Batch: its planning reading is minutes
	// or hours old by the time its extraction starts, so there is nothing left
	// to wait for. A negative duration handed to a sleep is the shape this
	// stops.
	first := first_reading()
	long_after := first
	long_after.taken_ns += 60 * SECOND_NS
	testing.expect_value(t, remaining_gap_ns(first, long_after, MINIMUM_SETTLING_GAP_NS), 0)

	// The boundary itself: the gap exactly reached leaves nothing.
	exactly := first
	exactly.taken_ns += MINIMUM_SETTLING_GAP_NS
	testing.expect_value(t, remaining_gap_ns(first, exactly, MINIMUM_SETTLING_GAP_NS), 0)

	// And one nanosecond short of it leaves the smallest wait there is, which is
	// one MILLISECOND and not one nanosecond -- see the case below.
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
	// FOUND BY A RUNNING CASE, on the first run of the one in run_test.odin that
	// takes this wait for real. `time.sleep` on Windows is
	// `Sleep(DWORD(d / Millisecond))` -- integer division, so it TRUNCATES. A wait
	// of 1,999,700 microseconds sleeps 1,999 milliseconds and comes back three
	// tenths of a millisecond early; the reading taken then is still inside the
	// gap, `settling` answers `Too_Soon_To_Tell` a second time, and `settle`
	// refuses a Recording nothing was ever wrong with as `.Still_Unsettled`.
	//
	// That is the exact failure the second look exists to prevent, and it lands on
	// every Batch's FIRST Recording and no other -- the only one whose planning
	// reading is still inside the gap when its extraction starts.
	first := first_reading()
	second := first
	second.taken_ns += 300_000

	// Three tenths of a millisecond spent out of two seconds leaves
	// 1,999,700,000 nanoseconds, and the whole two seconds once it is rounded up
	// to something the sleep can express.
	testing.expect_value(t, remaining_gap_ns(first, second, 2 * SECOND_NS), 2 * SECOND_NS)

	// The property rather than the one worked example: no wait this answers can
	// be truncated to nothing.
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
	// The whole reason the clamp exists. `waited` reads negative, and
	// subtracting it would ask for the gap PLUS however far the clock jumped --
	// a minute of NTP correction turning a three-second wait into sixty-three.
	first := first_reading()
	backwards := first
	backwards.taken_ns -= 60 * SECOND_NS

	testing.expect_value(
		t,
		remaining_gap_ns(first, backwards, MINIMUM_SETTLING_GAP_NS),
		MINIMUM_SETTLING_GAP_NS,
	)
}

// ------------------- what one look settles, and whether another is worth it --
//
// The OUTCOME MAPPING, which lived inline in `settle` where no case could reach
// it. Mutated in place, all three of its decisions were invisible: a `settle`
// that answered SUCCESS for a Recording nothing was ever seen to stop writing
// passed every case in this package.

@(test)
a_recording_seen_to_have_settled_is_no_fault_and_no_second_look :: proc(t: ^testing.T) {
	fault, again := settling_fault(.Settled, 1)
	testing.expect_value(t, fault, Fault.None)
	testing.expect(t, !again, "a Recording that had settled was waited for anyway")
}

@(test)
a_recording_seen_to_move_is_refused_however_many_looks_are_left :: proc(t: ^testing.T) {
	// A change is PROOF, and the one outcome here that is proof of anything, so
	// there is nothing a later look could add to it.
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
	// The one wait this package ever takes, and the whole reason there are two
	// looks: every Batch's FIRST Recording is planned microseconds before its
	// extraction starts, so the first look is always too soon to tell.
	fault, again := settling_fault(.Too_Soon_To_Tell, 1)
	testing.expect(t, again, "the second look was never asked for")
	testing.expect_value(t, fault, Fault.None)
}

@(test)
too_soon_to_tell_with_no_look_left_is_refused_and_never_called_settled :: proc(t: ^testing.T) {
	// SPEC STORY 52's own failure if this answers `.None`: a Recording nothing was
	// ever seen to stop writing, reported as success and transcribed into a
	// Transcript that stops mid-sentence and is marked complete forever.
	fault, again := settling_fault(.Too_Soon_To_Tell, 0)
	testing.expect_value(t, fault, Fault.Still_Unsettled)
	testing.expect(t, !again, "a look was asked for that the caller does not have")
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
