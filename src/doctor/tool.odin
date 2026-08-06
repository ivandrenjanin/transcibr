#+vet explicit-allocators
package doctor

// What "actually spawns it rather than stat-ing it" (ADR-0011) is built from:
// one bounded run of an executable, its whole diagnostic stream captured
// rather than watched line by line, because a doctor probe cares about
// everything a short-lived process said and never about a progress reading.

import "core:mem"
import "core:strings"
import "transcibr:child"

// A `--help`/`-version` probe exits almost immediately once its own
// executable is even runnable; five seconds is generous against a cold page
// cache and nowhere close to what a wedged or hostile executable could stall
// this for (issue #27's bound family).
PROBE_BOUND_MS :: i64(5_000)

#assert(PROBE_BOUND_MS > 0)

// `child.MAX_DRAIN_BYTES` bounds one drain of the pipe, but a probe's own
// wall-clock bound still gives a flooding tool many drains to grow this
// builder across -- twenty at PROBE_BOUND_MS's five seconds, sixty at the
// model load probe's fifteen (POLL_MS's own 250 ms apart). Four times
// MAX_DRAIN_BYTES (4 MiB) sits an order of magnitude over any legitimate
// `--help`/`-version`/`--no-prints` transcript this package has ever
// captured, while still refusing a flood loudly well short of what a doctor
// run should ever hold in memory for one probe.
MAX_PROBE_CAPTURE_BYTES :: 4 * child.MAX_DRAIN_BYTES

#assert(MAX_PROBE_CAPTURE_BYTES > child.MAX_DRAIN_BYTES)

// What one bounded probe of an executable came to: whether it could be
// spawned and stopped cleanly at all, everything it wrote to its diagnostic
// stream while it ran, and -- only where `run` is `.Finished` -- the status it
// chose to exit with. `exited` is what tells a status of zero from no status
// at all, since a halted child's code is this program's own kill.
Probe :: struct {
	run:        child.Run,
	captured:   string,
	exit_code:  u32,
	exited:     bool,
	child:      child.Error,
	// Set when the capture hit MAX_PROBE_CAPTURE_BYTES before the child ended
	// on its own; `captured` holds only what arrived before the ceiling, and
	// a caller must refuse the probe on this rather than judge that partial
	// text -- a marker that happens to sit inside the kept prefix would
	// otherwise pass a flooding tool by accident.
	overflowed: bool,
}

@(private)
Capture_State :: struct {
	builder:    strings.Builder,
	exit_code:  u32,
	exited:     bool,
	overflowed: bool,
}

@(private)
captured_chunk :: proc(chunk: string, elapsed_ns: i64, user: rawptr) {
	assert(user != nil, "there is no capture here to append a chunk to")
	assert(len(chunk) > 0, "a read that took nothing was reported as a chunk")

	state := (^Capture_State)(user)
	if state.overflowed {
		return
	}
	if strings.builder_len(state.builder) + len(chunk) > MAX_PROBE_CAPTURE_BYTES {
		state.overflowed = true
		return
	}
	strings.write_string(&state.builder, chunk)
}

@(private)
captured_exit :: proc(code: u32, user: rawptr) {
	assert(user != nil, "there is no capture here to record an exit status against")

	state := (^Capture_State)(user)
	state.exit_code = code
	state.exited = true
}

// The only way this package asks `run_bounded` to stop a child early: once
// the capture has overflowed, reading more from the pipe cannot change the
// verdict, so there is nothing left for the rest of the wall-clock bound to
// buy.
@(private)
@(require_results)
capture_overflow_poll :: proc(elapsed_ns: i64, user: rawptr) -> bool {
	assert(user != nil, "there is no capture here to poll for overflow")

	state := (^Capture_State)(user)
	return state.overflowed
}

// The caller owns `probe.captured` and frees it with `delete` and the
// allocator handed in, whichever way the probe ended -- a probe that never
// started captured nothing and frees an empty string safely.
@(require_results)
probe_executable :: proc(
	group: ^child.Job_Object,
	executable: string,
	arguments: []string,
	allocator: mem.Allocator,
	bound_ms := PROBE_BOUND_MS,
) -> (
	probe: Probe,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(executable) > 0, "there is no executable here to probe")
	assert(bound_ms > 0, "a probe given no time at all cannot do anything")
	assert(
		allocator.procedure != nil,
		"the capture outlives this procedure and needs an allocator",
	)

	state := Capture_State {
		builder = strings.builder_make(allocator),
	}

	run, _, err := child.run_bounded(
		group,
		executable,
		arguments,
		bound_ms,
		allocator,
		child.Run_Callbacks {
			user = &state,
			on_chunk = captured_chunk,
			on_exit = captured_exit,
			on_poll = capture_overflow_poll,
		},
	)
	if run == .Finished {
		assert(state.exited, "a finished run reported no exit status at all")
	}
	return Probe {
		run = run,
		captured = strings.to_string(state.builder),
		exit_code = state.exit_code,
		exited = state.exited,
		child = err,
		overflowed = state.overflowed,
	}
}

// The one refusal message every probe caller in this package reports the
// same way: `combined_message` needs a subject that already has a check
// name attached to it (`checks.odin`, `engine.odin` and `model_probe.odin`
// each know their own), so this only carries the wording all three share.
@(require_results)
probe_overflow_message :: proc(executable: string, allocator: mem.Allocator) -> string {
	assert(len(executable) > 0, "a refusal must name what it is reported against")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs an allocator",
	)

	return combined_message(
		executable,
		"reported more diagnostic output than a probe will capture and was refused",
		"MAX_PROBE_CAPTURE_BYTES exceeded",
		allocator,
	)
}
