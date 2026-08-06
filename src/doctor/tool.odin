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

// What one bounded probe of an executable came to: whether it could be
// spawned and stopped cleanly at all, and everything it wrote to its
// diagnostic stream while it ran.
Probe :: struct {
	run:      child.Run,
	captured: string,
	child:    child.Error,
}

@(private)
Capture_State :: struct {
	builder: strings.Builder,
}

@(private)
captured_chunk :: proc(chunk: string, elapsed_ns: i64, user: rawptr) {
	assert(user != nil, "there is no capture here to append a chunk to")
	assert(len(chunk) > 0, "a read that took nothing was reported as a chunk")

	state := (^Capture_State)(user)
	strings.write_string(&state.builder, chunk)
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

	run, err := child.run_bounded(
		group,
		executable,
		arguments,
		bound_ms,
		allocator,
		child.Run_Callbacks{user = &state, on_chunk = captured_chunk},
	)
	return Probe{run = run, captured = strings.to_string(state.builder), child = err}
}
