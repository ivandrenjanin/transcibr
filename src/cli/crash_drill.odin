#+vet explicit-allocators
package main

import "core:thread"
import "transcibr:crashlog"

// An undocumented mode, named in no USAGE block and reachable only by
// spelling `--crash-drill` on the command line: what issue #76's acceptance
// criteria call "measured, not assumed" needs a process that actually
// crashes with the two hooks installed, and that process cannot be the
// `odin test` runner itself (CLAUDE.md's Windows notes on the concurrent-
// assert hang, issue #22). `crashlog_crash_test.odin` in `transcibr:crashlog`
// spawns this binary with this flag and reads back what it left in the log.
// Named "drill" rather than "probe" -- CONTEXT.md's `Probe` entry already
// means what a container is asked about itself, and this is a deliberate
// self-inflicted crash, not an inspection.
CRASH_DRILL :: "--crash-drill"

CRASH_DRILL_ASSERT :: "assert"
CRASH_DRILL_ASSERT_THREAD :: "assert-thread"
CRASH_DRILL_BOUNDS :: "bounds"

// Exercises `main`'s OWN crash-capture wiring rather than duplicating it:
// every other mode below calls `crashlog.install` and sets
// `context.assertion_failure_proc` itself, at this procedure's own scope,
// which is exactly what masked fix round 5's issue #76 finding -- `main`'s
// install had the same bug (the assignment lived inside an `if` block and
// reverted at the closing brace) and every crash-drill test still passed,
// because this procedure's own duplicate assignment covered for it. This
// mode installs nothing and assigns nothing; it relies entirely on whatever
// `main` already did before dispatching here, so a regression of that bug
// shows up as a log with no "runtime assertion" line rather than a green
// test. `dir` is unused by this mode -- the log it should reach is
// %LOCALAPPDATA%\transcibr\transcibr.log, wherever `main`'s own
// `crashlog.default_directory` call resolved that to.
CRASH_DRILL_WIRING_ASSERT :: "wiring-assert"

// `arguments` is `<mode> <directory>`, both required: a drill that does not
// know where to write leaves nothing for the spawning test to read. An empty
// directory or an unknown mode is an operating error, not a programmer error
// -- both are refused through the same USAGE_ERROR path every other CLI flag
// uses, before `crashlog.install` ever runs, since its own
// `assert(len(dir) > 0, ...)` guards an internal invariant of the crashlog
// package, not the CLI's own argument boundary (CLAUDE.md A8).
@(require_results)
run_crash_drill :: proc(arguments: []string) -> int {
	if len(arguments) < 2 {
		_ = refuse("--crash-drill needs a mode and a directory.")
		return USAGE_ERROR
	}
	mode := arguments[0]
	dir := arguments[1]

	switch mode {
	case CRASH_DRILL_ASSERT,
	     CRASH_DRILL_ASSERT_THREAD,
	     CRASH_DRILL_BOUNDS,
	     CRASH_DRILL_WIRING_ASSERT:
	case:
		_ = refuse("--crash-drill does not know the mode %q.", mode)
		return USAGE_ERROR
	}
	if len(dir) == 0 {
		_ = refuse("--crash-drill needs a directory to write to.")
		return USAGE_ERROR
	}

	if mode != CRASH_DRILL_WIRING_ASSERT {
		if !crashlog.install(dir, context.allocator) {
			return OPERATING_ERROR
		}
		context.assertion_failure_proc = crashlog.assertion_hook
	}

	switch mode {
	case CRASH_DRILL_ASSERT:
		assert(false, "crashlog drill: deliberate assertion for issue #76 measurement")
	case CRASH_DRILL_ASSERT_THREAD:
		crash_in_a_worker_thread()
	case CRASH_DRILL_BOUNDS:
		crash_out_of_bounds(len(arguments))
	case CRASH_DRILL_WIRING_ASSERT:
		assert(
			false,
			"crashlog drill: deliberate assertion relying on main's own wiring for issue #76 measurement",
		)
	case:
		assert(false, "mode was already validated above")
	}
	return 0
}

// A fresh `core:thread` gets a fresh context, so `context.assertion_failure_proc`
// is back to Odin's own default here until this thread's own body sets it
// again -- exactly the S3 rebuild point the maintainer ruling names, and the
// same reason `run_crash_drill` sets it directly rather than through a call.
@(private)
crash_in_a_worker_thread :: proc() {
	worker :: proc() {
		context.assertion_failure_proc = crashlog.assertion_hook
		assert(
			false,
			"crashlog drill: deliberate assertion on a worker thread for issue #76 measurement",
		)
	}

	t := thread.create_and_start(worker)
	assert(t != nil, "the crash drill's own worker thread would not start")
	thread.join(t)
	thread.destroy(t)
}

// `index` is derived from argv's own length, never a literal, so the
// compiler cannot fold this to a compile-time-known out-of-range access and
// refuse to build it -- it has to reach `base:runtime`'s real, contextless
// bounds-check path at run time.
@(private)
crash_out_of_bounds :: proc(argument_count: int) {
	assert(argument_count >= 0, "argv cannot report a negative length")

	values := []int{1, 2, 3}
	index := argument_count + len(values) + 1
	_ = values[index]
}
