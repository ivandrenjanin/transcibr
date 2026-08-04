package audio

// Carries its own timestamp rather than the decision reading a clock: a gap
// exactly reached and one a nanosecond short are the two values that matter, and
// the two a clock will not produce on request.
Reading :: struct {
	bytes:       i64,
	modified_ns: i64,
	taken_ns:    i64,
}

Settling :: enum u8 {
	Settled = 0,
	Still_Being_Written,
	Too_Soon_To_Tell,
}

// Why three seconds: ADR-0023.
MINIMUM_SETTLING_GAP_NS :: i64(3_000_000_000)

// Two, because every Batch's first Recording is planned microseconds before its
// extraction starts, so its first look is always too soon to tell.
SETTLING_ATTEMPTS :: 2

#assert(SETTLING_ATTEMPTS >= 2)

settling_fault :: proc(outcome: Settling, attempts_left: int) -> (fault: Fault, again: bool) {
	assert(attempts_left >= 0, "a look cannot be followed by a negative number of looks")

	switch outcome {
	case .Settled:
		return .None, false
	case .Still_Being_Written:
		return .Still_Being_Written, false
	case .Too_Soon_To_Tell:
		if attempts_left > 0 {
			return .None, true
		}
		return .Still_Unsettled, false
	}
	unreachable()
}

@(private)
SLEEP_GRANULARITY_NS :: i64(1_000_000)

// Never more than the whole gap, because a clock that stepped backwards makes
// `waited` negative; never a fraction of a millisecond, because the sleep it
// feeds truncates. Why the truncation costs a Recording: ADR-0023.
remaining_gap_ns :: proc(first: Reading, second: Reading, minimum_gap_ns: i64) -> i64 {
	assert(minimum_gap_ns > 0, "a gap of no time at all says nothing about anything")

	waited := second.taken_ns - first.taken_ns
	left := minimum_gap_ns
	if waited >= 0 {
		left = max(0, minimum_gap_ns - waited)
	}
	return (left + SLEEP_GRANULARITY_NS - 1) / SLEEP_GRANULARITY_NS * SLEEP_GRANULARITY_NS
}

// Deliberately does not assert "taken in order": the readings belong to this
// package, but the clock they carry belongs to the machine. Why a forward step
// is not detectable here and what bounds it: ADR-0023.
settling :: proc(first: Reading, second: Reading, minimum_gap_ns: i64) -> Settling {
	assert(minimum_gap_ns > 0, "a gap of no time at all says nothing about anything")

	if second.bytes != first.bytes {
		return .Still_Being_Written
	}
	if second.modified_ns != first.modified_ns {
		return .Still_Being_Written
	}

	if second.taken_ns - first.taken_ns < minimum_gap_ns {
		return .Too_Soon_To_Tell
	}
	return .Settled
}
