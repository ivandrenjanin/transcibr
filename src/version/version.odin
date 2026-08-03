// Package version holds transcibr's own version and renders it for display.
//
// Pure core (ADR-0009): no clock, no environment, no I/O. The version a build
// reports is a compiled-in constant rather than something read from the world,
// so a transcript's recorded provenance (ADR-0003) cannot disagree with the
// binary that produced it.
package version

import "core:fmt"
import "core:mem"

// A semantic version.
//
// The widths are explicit but T1 does not compel them here: nothing serializes
// a Version yet, and the sidecar ADR-0003 specifies records the ENGINE's
// version, not transcibr's. They stay because a version component is a small
// non-negative number that means the same thing on every target -- which `int`,
// signed and target-width, does not say -- and because a build identifier is
// the kind of value that ends up written down. Should it ever be, T1 will
// require exactly this and the byte image will already be pinned.
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
	assert(len(out) > len(program), "banner carries no version after the program name")
	return out
}
