// transcibr-cli — the console-subsystem binary (ADR-0004).
//
// The command-line front end exists so a batch can be planned or re-rendered
// from a script. Today it is a walking skeleton: it reports its version and
// exits zero, which is enough to prove the build produces a running binary.
package main

import "core:fmt"
import "core:strings"
import "transcibr:version"

PROGRAM :: "transcibr-cli"

// Half of the banner's contract, and it never varies at runtime -- so the
// claim belongs in the compiled output rather than in a check main would have
// to reach to execute (CLAUDE.md rule A5).
#assert(len(PROGRAM) > 0)

main :: proc() {
	line := version.banner(PROGRAM, version.CURRENT, context.allocator)
	defer delete(line, context.allocator)

	// The read side of what `banner` asserts on the way out (A4). A script
	// reading this binary's output splits the first line on its first space,
	// so the shape is the contract, not merely the length: a line naming a
	// different program, joined by something other than a space, or carrying a
	// second line, is wrong in a way a length check cannot see.
	assert(strings.has_prefix(line, PROGRAM), "banner does not name this program")
	assert(len(line) > len(PROGRAM), "banner carries no version after the program name")
	assert(line[len(PROGRAM)] == ' ', "banner does not separate the program name from the version")
	assert(strings.index_byte(line, '\n') == -1, "banner rendered more than one line")

	fmt.println(line)
}
