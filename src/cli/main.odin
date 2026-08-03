// transcibr-cli — the console-subsystem binary (ADR-0004).
//
// The command-line front end exists so a batch can be planned or re-rendered
// from a script. Today it is a walking skeleton: it reports its version and
// exits zero, which is enough to prove the build produces a running binary.
package main

import "core:fmt"
import "transcibr:version"

PROGRAM :: "transcibr-cli"

// `banner` requires it, and it cannot vary at runtime (CLAUDE.md rule A5).
#assert(len(PROGRAM) > 0)

main :: proc() {
	line := version.banner(PROGRAM, version.CURRENT, context.allocator)
	defer delete(line, context.allocator)

	// The line's shape is deliberately NOT re-asserted here. `banner` asserts
	// all four facts on the way out, and nothing between its return and this
	// call can change the string -- so a copy here fires only where the copy
	// there already did, and assertions are enabled in every configuration
	// this repository builds (CLAUDE.md rule A1).
	//
	// A4's read side is a process away, where a real reader is: scripts\
	// build.ps1 runs this binary and matches what it actually printed, and
	// src\version\version_test.odin pins the rendered line by exact equality.
	fmt.println(line)
}
