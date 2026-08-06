#+vet explicit-allocators
package child

import "core:mem"
import "core:time"

// This file runs one child under a wall-clock bound, draining its diagnostic
// pipe as it goes. What one chunk of that pipe means -- a tracker's progress
// reading, a settling reading, or nothing at all -- belongs entirely to the
// caller; this file knows only bytes, a bound and how one run ended.

// A quarter of a second stays well under DIAGNOSTIC_PIPE_BYTES filling, and
// paints far more often than a hundred-position bar can show.
POLL_MS :: u32(250)

@(private)
DRAIN_BYTES :: 4096

// Why one drain has a ceiling at all, and why a megabyte: ADR-0020.
MAX_DRAIN_BYTES :: 1 << 20

#assert(MAX_DRAIN_BYTES > DRAIN_BYTES)

Run :: enum u8 {
	Not_Started = 0,
	Finished,
	Stopped,
	// It may still be running and may still hold its output file open, which is
	// why nothing may delete that file.
	Unstoppable,
}

// What this run observed that made it halt -- mechanical facts about the
// child and its pipe, never a caller's reading of them. `.None` for
// `.Not_Started` and `.Finished`, where nothing halted the run early.
Stop_Reason :: enum u8 {
	None = 0,
	Bound_Expired,
	Poll_Asked,
	Drain_Failed,
}

// What a chunk means is the caller's alone. `elapsed_ns` is time since the
// child started and is always positive.
Run_Callbacks :: struct {
	user:     rawptr,
	on_chunk: proc(chunk: string, elapsed_ns: i64, user: rawptr),
	// Called once per drain that reaches end of stream, so a caller holding an
	// unterminated trailing chunk can finalize it.
	on_end:   proc(elapsed_ns: i64, user: rawptr),
	// Called once per poll, and once more after the child finishes. What a
	// bound expiry is CALLED -- an Engine gone silent, a settling reading that
	// never arrives -- is the caller's own vocabulary, carried in its own
	// state through `user`; returning true only asks this run to stop before
	// its wall-clock bound.
	on_poll:  proc(elapsed_ns: i64, user: rawptr) -> bool,
}

// The drain after `wait` succeeds is not optional for a caller with
// callbacks: it is what lets `on_end` see a trailing, unterminated line
// before this reports Finished -- an Engine's last percentage arrives this
// way. A caller with none, such as audio's silent extraction, pays one extra
// pipe check for the same guarantee rather than a second shape.
//
// The bound check below reads the clock fresh after `wait` rather than
// reusing the value `on_poll` read before it: a stale value lets a stop
// overshoot by a whole extra POLL_MS -- one drain plus two polls, the shape
// main's engine loop had -- where a fresh read caps both callers at one
// drain plus one poll, the shape main's audio loop had. One extra
// QueryPerformanceCounter call every 250 ms buys the tighter bound for both;
// see ADR-0020.
@(require_results)
run_bounded :: proc(
	group: ^Job_Object,
	executable: string,
	arguments: []string,
	bound_ms: i64,
	allocator: mem.Allocator,
	callbacks: Run_Callbacks = {},
) -> (
	run: Run,
	reason: Stop_Reason,
	err: Error,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(bound_ms > 0, "a child given no time at all cannot do anything")
	assert(len(executable) > 0, "there is no executable here to start")
	assert(allocator.procedure != nil, "starting a child needs an allocator for its command line")

	c, refusal := start(group, executable, arguments, allocator)
	if refusal.fault != .None {
		return .Not_Started, .None, refusal
	}
	defer close(&c)

	started := time.tick_now()
	for {
		if !drain_bounded(&c, started, callbacks) {
			return halt(&c), .Drain_Failed, Error{}
		}
		if callbacks.on_poll != nil && callbacks.on_poll(elapsed_ns(started), callbacks.user) {
			return halt(&c), .Poll_Asked, Error{}
		}
		if wait(&c, POLL_MS) {
			_ = drain_bounded(&c, started, callbacks)
			if callbacks.on_poll != nil {
				_ = callbacks.on_poll(elapsed_ns(started), callbacks.user)
			}
			return .Finished, .None, Error{}
		}
		if i64(time.duration_milliseconds(time.tick_since(started))) > bound_ms {
			return halt(&c), .Bound_Expired, Error{}
		}
	}
}

// Bounded so a flood on the pipe still lets the caller back in to look at its
// bound: ADR-0020.
@(private)
@(require_results)
drain_bounded :: proc(
	c: ^Child,
	started: time.Tick,
	callbacks: Run_Callbacks,
) -> (
	readable: bool,
) {
	assert(c != nil, "there is no child here to read")

	buffer: [DRAIN_BYTES]u8 = ---
	taken := 0
	for taken < MAX_DRAIN_BYTES {
		read, at_end, reading := read_diagnostics(c, buffer[:])
		if reading.fault != .None {
			return false
		}
		if read > 0 {
			assert(read <= len(buffer), "the pipe wrote past the end of the buffer it was given")
			if callbacks.on_chunk != nil {
				callbacks.on_chunk(string(buffer[:read]), elapsed_ns(started), callbacks.user)
			}
			taken += read
		}
		if at_end {
			if callbacks.on_end != nil {
				callbacks.on_end(elapsed_ns(started), callbacks.user)
			}
			return true
		}
		if read == 0 {
			return true
		}
	}
	assert(taken >= MAX_DRAIN_BYTES, "a drain left its loop with room to spare")
	return true
}

@(private)
@(require_results)
halt :: proc(c: ^Child) -> Run {
	assert(c != nil, "there is no child here to stop")

	if stop(c) {
		return .Stopped
	}
	return .Unstoppable
}

// Offset by one because the first tick since a start reads zero, and a
// tracker's opening reading refuses that.
@(private)
@(require_results)
elapsed_ns :: proc(started: time.Tick) -> i64 {
	reading := 1 + i64(time.duration_nanoseconds(time.tick_since(started)))
	assert(reading > 0, "a monotonic counter that went backwards or has not started")
	return reading
}
