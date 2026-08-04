package audio

// This file holds one decision: whether something is still writing a Recording.
//
// Spec story 52 asks for a Recording that is still being written to be detected
// rather than silently producing a Transcript that stops mid-sentence, and the
// only handle there is on that from outside the writing process is to look at
// the file twice and see whether it moved.
//
// THE ANSWER IS A PROBABILITY AND NEVER A PROOF, and the shape below is what
// says so. A file that did not change between two readings may simply not have
// been written to in that moment; two readings five milliseconds apart say
// nothing at all about a recorder that flushes once a second. So there are three
// outcomes rather than two, and the third -- "not far enough apart to say" -- is
// the one that stops an absence of evidence being reported as evidence of
// absence.
//
// THIS FILE IS PURE LEAF MATH, which is CLAUDE.md rule A1's own exemption: it
// carries fewer than two assertions a procedure because its caller carries more.
// Every refusal that could be made about a Reading -- a source that will not
// stat, a planning reading with no timestamp on it at all -- is `settle`'s, one
// file over, where the reading is taken and where the value came from outside.
//
// WHAT IT COSTS. The second reading is one call to the filesystem and is free;
// the GAP is the cost, and on a Batch of several hundred Recordings a gap taken
// per Recording would be minutes of pure waiting. It is not paid that way: the
// first reading is the one taken when the Batch was planned, which for every
// Recording but the first is already minutes or hours old by the time its
// extraction starts. Only a Recording whose extraction begins within the gap of
// its own planning ever waits, and it waits once.

// One look at a Recording: what it was, and when it was looked at.
//
// The reading carries its own timestamp rather than the decision reading a
// clock, which is what makes the decision checkable: a gap exactly reached and
// one a nanosecond short are the two values that matter and the two a clock will
// not produce on request. `remaining_ms` in `transcibr:child` is the same shape
// for the same reason.
//
// i64 nanoseconds throughout. Windows keeps a file's modification time to 100
// nanoseconds and `core:time` counts in nanoseconds, so nothing here rounds.
Reading :: struct {
	bytes:       i64,
	modified_ns: i64,
	taken_ns:    i64,
}

// What two readings of a Recording say about whether anything is still writing
// it.
Settling :: enum u8 {
	// Nothing moved, over a gap long enough to mean something.
	Settled = 0,
	// It moved. PROOF, and the one outcome here that is proof of anything.
	Still_Being_Written,
	// Nothing moved, but the two readings are too close together for that to
	// mean anything. The caller reads again later rather than deciding.
	Too_Soon_To_Tell,
}

// How far apart two readings have to be before "nothing changed" means
// anything, in nanoseconds.
//
// THREE SECONDS, and the number comes from the coarsest timestamp a Recording
// can carry rather than from taste. FAT and exFAT store a modification time to a
// two-second granularity and SMB servers commonly round to the same, so a gap
// shorter than two seconds can fall entirely inside one bucket -- a file being
// appended to then shows the SAME timestamp twice, and only its size gives it
// away. Two seconds is the floor that guarantees the bucket moves; three leaves
// a second over for the writer's own flush interval, since what is timestamped
// is the last write before the reading and not the reading.
//
// It is a gap and not a wait. See the file comment for what it costs and who
// pays it.
MINIMUM_SETTLING_GAP_NS :: i64(3_000_000_000)

// How many times a Recording is looked at before the question is given up on.
//
// TWO, and the second is the whole of it. Every Batch's FIRST Recording is
// planned microseconds before its extraction starts, so its first look is always
// too soon to tell -- at one look, every Batch's first Recording fails as
// `.Still_Unsettled`. A third buys nothing the second did not: both compare
// against the PLANNED reading rather than the last one, so the gap the second
// look waits out is already the whole of it.
//
// It is HERE and not a local constant in `settle`, for ADR-0018's reason: a
// decision that turns up in run.odin belongs in one of the files beside it,
// where a case can reach it.
SETTLING_ATTEMPTS :: 2

// The claim the number rests on, held by the COMPILER (A5) rather than left to
// the prose above: a Recording looked at once and found too soon to tell can
// never answer anything else, because there is no second reading to compare
// against.
#assert(SETTLING_ATTEMPTS >= 2)

// What one look at a Recording settles, and whether another one is worth taking.
//
// THE OUTCOME MAPPING, and the reason it is a procedure rather than three arms
// inside `settle`: it is a decision, nothing in run.odin can be reached by a
// case, and all three of its answers were invisible there. Mutated in place, a
// `settle` that reported SUCCESS for a Recording nothing was ever seen to stop
// writing passed every case in this package -- which is spec story 52's exact
// failure, shipped green.
//
// `attempts_left` is how many looks the caller has AFTER this one. It is the
// only thing separating "too soon to tell, so look again" from "too soon to
// tell, and there is no later look" -- and the second of those is a REFUSAL and
// never a success. Nothing was seen to move, and nothing could be made of that;
// the caller is told so rather than told the file is fine.
settling_fault :: proc(outcome: Settling, attempts_left: int) -> (fault: Fault, again: bool) {
	assert(attempts_left >= 0, "a look cannot be followed by a negative number of looks")

	switch outcome {
	case .Settled:
		return .None, false
	case .Still_Being_Written:
		// PROOF, and the one outcome here that is proof of anything, so no later
		// look could add to it.
		return .Still_Being_Written, false
	case .Too_Soon_To_Tell:
		if attempts_left > 0 {
			return .None, true
		}
		return .Still_Unsettled, false
	}
	unreachable()
}

// The granularity every wait here is rounded up to, in nanoseconds.
//
// A MILLISECOND, and it is the sleep on the other end of this rather than a
// taste. See remaining_gap_ns.
@(private)
SLEEP_GRANULARITY_NS :: i64(1_000_000)

// How long is left of the gap before a Recording is worth reading again, in
// nanoseconds, as a whole number of milliseconds.
//
// The other side of the same clock-step guard `settling` carries, and it is HERE
// rather than inline in run.odin for the reason ADR-0018 gives: a decision that
// turns up in run.odin belongs in one of the files beside it, because nothing in
// run.odin can be reached by a case. This is the exact class settling_test.odin
// already exercises nine ways, and it had no case at all.
//
// Never more than the whole gap: a clock that stepped BACKWARDS between the two
// readings makes `waited` negative, and subtracting it would ask for a longer
// wait than the gap ever was. Never less than nothing: a gap already outlasted
// is a wait of zero and not a negative duration to hand to a sleep.
//
// AND NEVER A FRACTION OF A MILLISECOND, which is a fix and not a tidiness.
// `time.sleep` on Windows is `Sleep(DWORD(d / Millisecond))` -- integer
// division, so it TRUNCATES, and a wait of 1,999,700 microseconds sleeps 1,999
// milliseconds and comes back three tenths of a millisecond early. The reading
// taken then is still inside the gap, `settling` answers `Too_Soon_To_Tell` a
// second time, and `settle` refuses a Recording nothing was ever wrong with as
// `.Still_Unsettled` -- the exact failure the second look exists to prevent,
// landing on every Batch's FIRST Recording and no other, since it is the only
// one whose planning reading is still inside the gap when its extraction starts.
//
// Found by a running case rather than reasoned about: the case in run_test.odin
// that takes this wait for real came back red the first time it ran.
remaining_gap_ns :: proc(first: Reading, second: Reading, minimum_gap_ns: i64) -> i64 {
	assert(minimum_gap_ns > 0, "a gap of no time at all says nothing about anything")

	waited := second.taken_ns - first.taken_ns
	left := minimum_gap_ns
	if waited >= 0 {
		left = max(0, minimum_gap_ns - waited)
	}
	// Rounded UP, so that a wait the sleep would truncate to nothing is a whole
	// millisecond instead. Waiting a fraction of a millisecond longer than the
	// gap costs nothing; waiting a fraction less costs the Recording.
	return (left + SLEEP_GRANULARITY_NS - 1) / SLEEP_GRANULARITY_NS * SLEEP_GRANULARITY_NS
}

// What two readings of one Recording say.
//
// A8: both readings are of a file another program may be writing, so nothing
// here is an assertion about the file. THE ONE ASSERTION is about the gap, which
// is the caller's own choice and this package's own state.
//
// "Taken in order" is what it deliberately does NOT assert, and that is the
// whole of the backwards-clock answer twenty lines down: the readings belong to
// this package, but the CLOCK they carry belongs to the machine, and a second
// reading timestamped before the first is an NTP step rather than corrupt
// internal state.
settling :: proc(first: Reading, second: Reading, minimum_gap_ns: i64) -> Settling {
	assert(minimum_gap_ns > 0, "a gap of no time at all says nothing about anything")

	// CHECKED FIRST, and the order is the decision rather than a detail. A
	// change is proof that something is writing; too short a gap is only an
	// absence of evidence. Asking about the gap first would answer "cannot
	// tell" about a file it had just watched grow.
	if second.bytes != first.bytes {
		return .Still_Being_Written
	}
	// Both halves (A3), because the two catch different writers: a size that
	// moves is anything appending, and a modification time that moves with the
	// size unchanged is a container being finalised in place or a recorder
	// writing into a file it preallocated.
	if second.modified_ns != first.modified_ns {
		return .Still_Being_Written
	}

	// A gap that reads as NEGATIVE is a clock that went backwards between the
	// two readings, and it answers the same way an unmeasurably short one does.
	// NOT an assertion, though "a reading taken before the one before it" looks
	// like corrupt internal state: the readings are this package's, but the
	// clock they carry is the machine's, and an NTP step or a user setting the
	// time is outside this program (A8). It held one, and a clock step during a
	// Batch would have crashed it.
	//
	// A STEP FORWARD IS NOT DETECTABLE HERE, and that is stated rather than
	// worked around. It is arithmetically identical to time passing -- a minute
	// of clock inserted between two readings a millisecond apart looks exactly
	// like two readings a minute apart, and a Reading holds no third fact that
	// could tell them apart. A monotonic tick would, and one is deliberately not
	// carried: a Batch resumes across a reboot (ADR-0003) and a tick from a
	// previous boot compares against nothing.
	//
	// What bounds the damage is which half of the answer the clock reaches. The
	// gap decides only how much to make of two readings that AGREE; the proof
	// that a file is moving is its size and its modification time, and a step in
	// either direction leaves both of those alone. So the worst a forward step
	// can do is turn `Too_Soon_To_Tell` into `Settled` on a file nothing was
	// seen to touch. settling_test.odin pins exactly that reach.
	if second.taken_ns - first.taken_ns < minimum_gap_ns {
		return .Too_Soon_To_Tell
	}
	return .Settled
}
