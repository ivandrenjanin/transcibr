#+vet explicit-allocators
package transcript

import "core:testing"

@(private)
Ordering_Probe :: struct {
	name: string,
	cues: []Cue,
}

// The ordering conditions are spelled twice: first_disordered_cue backs the
// assertions, cue_follows is the boundary that rejects Engine JSON through the
// error return. A sequence the boundary accepts and the assertion side refuses
// is an A8 crash on external input, so the two are probed against the same
// adversarial sequences, cue by cue as read_cues runs them.
@(private, rodata)
ORDERING_PROBES := []Ordering_Probe {
	{name = "empty set", cues = {}},
	{name = "single zero-length cue at zero", cues = {{0, 0, ""}}},
	{name = "equal starts", cues = {{0, 10, " a"}, {0, 5, " b"}}},
	{name = "overlapping spans", cues = {{0, 100, " a"}, {50, 150, " b"}}},
	{name = "zero-length run", cues = {{5, 5, ""}, {5, 5, ""}}},
	{name = "negative start", cues = {{-1, 0, " a"}}},
	{name = "end before start", cues = {{10, 5, " a"}}},
	{name = "second starts earlier", cues = {{100, 200, " a"}, {50, 60, " b"}}},
	{name = "third starts earlier", cues = {{10, 20, " a"}, {20, 30, " b"}, {15, 40, " c"}}},
	{name = "largest i64 offsets", cues = {{9223372036854775807, 9223372036854775807, " a"}}},
	{name = "smallest i64 start", cues = {{-9223372036854775808, 0, " a"}}},
	{name = "smallest i64 end", cues = {{0, -9223372036854775808, " a"}}},
	{name = "parse range ceiling", cues = {{READABLE_MS, READABLE_MS, " a"}}},
	{name = "negative after a valid cue", cues = {{0, 5, " a"}, {-1, 6, " b"}}},
	{name = "equal start then inverted", cues = {{7, 7, ""}, {7, 3, " x"}}},
}

@(private)
@(require_results)
first_cue_the_boundary_refuses :: proc(cues: []Cue) -> (ordinal: int) {
	defer assert(ordinal >= 0, "a cue ordinal is a position or zero, never negative")
	defer assert(ordinal <= len(cues), "named a cue position past the end of the set")

	for cue, i in cues {
		if cue_follows(cue, cues[:i]) != .None {
			return i + 1
		}
	}
	return 0
}

@(test)
boundary_and_assertion_agree_on_every_probe :: proc(t: ^testing.T) {
	for probe in ORDERING_PROBES {
		asserted := first_disordered_cue(probe.cues)
		refused := first_cue_the_boundary_refuses(probe.cues)
		testing.expectf(
			t,
			asserted == refused,
			"%s: the assertion names cue %d, the boundary names cue %d",
			probe.name,
			asserted,
			refused,
		)
	}
}
