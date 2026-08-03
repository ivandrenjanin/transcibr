package extract

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

// What two readings of one Recording say.
//
// A8: both readings are of a file another program may be writing, so nothing
// here is an assertion about the file. The assertions are about the readings
// being this package's own -- taken in order, by the caller, from the same
// path.
settling :: proc(first: Reading, second: Reading, minimum_gap_ns: i64) -> Settling {
	assert(second.taken_ns >= first.taken_ns, "two readings of a source were taken out of order")
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

	if second.taken_ns - first.taken_ns < minimum_gap_ns {
		return .Too_Soon_To_Tell
	}
	return .Settled
}
