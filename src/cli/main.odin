// transcibr-cli — the console-subsystem binary (ADR-0004).
//
// The command-line front end exists so a batch can be planned or re-rendered
// from a script. Today it is a walking skeleton: it reports its version and
// exits zero, which is enough to prove the build produces a running binary.
package main

import "core:fmt"
import "transcibr:version"

PROGRAM :: "transcibr-cli"

main :: proc() {
	line := version.banner(PROGRAM, version.CURRENT, context.allocator)
	defer delete(line, context.allocator)
	// Read-side half of the pair `banner` asserts on the way out (A4).
	assert(len(line) > len(PROGRAM), "banner carries no version after the program name")
	fmt.println(line)
}
