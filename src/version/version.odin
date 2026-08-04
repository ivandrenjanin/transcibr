package version

import "core:fmt"
import "core:mem"
import "core:strings"

Version :: struct {
	major: u32,
	minor: u32,
	patch: u32,
}

CURRENT :: Version {
	major = 0,
	minor = 1,
	patch = 0,
}

@(require_results)
banner :: proc(program: string, v: Version, allocator: mem.Allocator) -> string {
	assert(len(program) > 0, "program name must not be empty")
	assert(strings.index_byte(program, '\n') == -1, "program name must not contain a newline")
	assert(v != Version{}, "version must be set; an all-zero version is uninitialised state")

	out := fmt.aprintf("%s %d.%d.%d", program, v.major, v.minor, v.patch, allocator = allocator)

	assert(strings.has_prefix(out, program), "banner does not name the program it was given")
	assert(len(out) > len(program), "banner carries no version after the program name")
	assert(out[len(program)] == ' ', "banner does not separate the program name from the version")
	assert(strings.index_byte(out, '\n') == -1, "banner rendered more than one line")
	return out
}
