// Package version holds transcibr's own version and renders it for display.
//
// Pure core (ADR-0009): no clock, no environment, no I/O. The version a build
// reports is a compiled-in constant rather than something read from the world,
// so a transcript's recorded provenance (ADR-0003) cannot disagree with the
// binary that produced it.
package version

import "core:fmt"
import "core:mem"
import "core:strings"

// A semantic version. The components are `u32` because a version component is
// a small non-negative count that means the same thing on every target, which
// `int` -- signed, and as wide as the target -- does not say.
Version :: struct {
	major: u32,
	minor: u32,
	patch: u32,
}

// The version this build reports. Bumped by hand.
CURRENT :: Version{major = 0, minor = 1, patch = 0}

// Renders the line a binary prints to identify itself, e.g. `transcibr-cli 0.1.0`.
//
// The allocator is an explicit parameter, never defaulted: the result outlives
// this procedure, and a defaulted allocator on such a value is a defect under
// ADR-0010 because `context.temp_allocator` is thread-local.
banner :: proc(program: string, v: Version, allocator: mem.Allocator) -> string {
	assert(len(program) > 0, "program name must not be empty")
	assert(v != Version{}, "version must be set; an all-zero version is uninitialised state")

	out := fmt.aprintf("%s %d.%d.%d", program, v.major, v.minor, v.patch, allocator = allocator)

	// The shape a caller reads back off this line, asserted on the side that
	// writes it. main asserts the same four facts on the way in (CLAUDE.md
	// A4), and this is the side that can be wrong: a program name carrying a
	// newline renders a banner no reader can split, and only this end sees it.
	assert(strings.has_prefix(out, program), "banner does not name the program it was given")
	assert(len(out) > len(program), "banner carries no version after the program name")
	assert(out[len(program)] == ' ', "banner does not separate the program name from the version")
	assert(strings.index_byte(out, '\n') == -1, "banner rendered more than one line")
	return out
}
