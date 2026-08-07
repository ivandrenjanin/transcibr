#+vet explicit-allocators
// Issue #76's two hooks can only be measured from OUTSIDE the process they
// are installed in: `assertion_hook` calls `runtime.trap()` and
// `exception_filter` sits behind a real SEH exception, and tripping either
// one inside `odin test`'s own process is exactly the #22 failure class
// (the runner hangs or dies with no report on a concurrent assert). Every
// test in this file spawns a debug build of `transcibr-cli` with its hidden
// `--crash-drill` mode (`src/cli/crash_drill.odin`) as a CHILD process, waits
// for it to end, and reads back what it left in the log -- never asserts or
// crashes in this process itself.
//
// `just test`'s own first line builds the drill binary at the path below
// before any package's tests run, so it is already there by the time these
// run under `just test` or `just ci`. It is NOT `build\transcibr-cli.exe` --
// that path is shared by `build` and `release`, and issue #76 review round 3
// measured `test` failing depending on which of those last wrote it (a
// release binary carries no usable line info for `assertion_hook`'s stack
// walk). Running `just test-one crashlog <name>` for one of these in
// isolation needs the same drill-build line run first, by hand:
// `odin build src/cli -collection:transcibr=src -out:build/odin-test/transcibr-cli-drill.exe -subsystem:console -debug <vet set>`.
package crashlog

import "core:strings"
import "core:testing"
import "transcibr:child"
import "transcibr:testkit"

@(private)
DRILL_CLI :: "build\\odin-test\\transcibr-cli-drill.exe"

@(private)
DRILL_BOUND_MS :: u32(30_000)

@(private)
@(require_results)
open_drill_group :: proc(t: ^testing.T) -> (group: child.Job_Object, ok: bool) {
	opened, err := child.job_object_open()
	if !testing.expectf(t, err.fault == .None, "no job object: %v", err.fault) {
		return {}, false
	}
	return opened, true
}

// Starts `transcibr-cli --crash-drill <mode> <dir>` and waits for it to end.
// The drill is EXPECTED to crash -- `child.wait` only reports whether the
// process signalled within the bound, which a crash does exactly as fast as
// a clean exit, so this says nothing yet about how it ended.
@(private)
@(require_results)
run_crash_drill :: proc(t: ^testing.T, mode: string, dir: string) -> (ok: bool) {
	assert(t != nil, "there is no test here to report a drill failure through")
	assert(len(mode) > 0, "a crash drill with no mode tells the CLI nothing to do")

	group, opened := open_drill_group(t)
	defer child.job_object_close(&group)
	if !opened {
		return false
	}

	c, err := child.start(&group, DRILL_CLI, {"--crash-drill", mode, dir}, context.allocator)
	defer child.close(&c)
	if !testing.expectf(t, err.fault == .None, "the crash drill did not start: %v", err.fault) {
		return false
	}

	return testing.expect(
		t,
		child.wait(&c, DRILL_BOUND_MS),
		"the crash drill did not exit within the bound",
	)
}

// Issue #76 review round 3: an empty directory argument used to reach
// `crashlog.install`'s own `assert(len(dir) > 0, ...)` before the mode was
// even validated -- an A8 violation, since a CLI argument is an external
// boundary and every sibling flag refuses an empty value cleanly instead of
// crashing. This spawns the drill directly (rather than through
// `run_crash_drill`, which only reports whether the process signalled) so it
// can read back the exit code and tell USAGE_ERROR apart from a crash.
@(test)
an_empty_directory_argument_is_refused_rather_than_crashing :: proc(t: ^testing.T) {
	group, opened := open_drill_group(t)
	defer child.job_object_close(&group)
	if !opened {
		return
	}

	c, err := child.start(&group, DRILL_CLI, {"--crash-drill", "assert", ""}, context.allocator)
	defer child.close(&c)
	if !testing.expectf(t, err.fault == .None, "the crash drill did not start: %v", err.fault) {
		return
	}
	if !testing.expect(
		t,
		child.wait(&c, DRILL_BOUND_MS),
		"the crash drill did not exit within the bound",
	) {
		return
	}

	code, exited := child.exit_code(&c)
	testing.expect(t, exited, "the crash drill's exit code was not available after it signalled")
	testing.expect_value(t, code, u32(2))
}

@(test)
an_assertion_failure_leaves_its_message_and_location_in_the_log :: proc(t: ^testing.T) {
	dir := testkit.scratch_cache(t, "crashlog", "assert_drill", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	if !run_crash_drill(t, "assert", dir) {
		return
	}

	text := read_log(t, dir)
	defer delete(text, context.allocator)
	testing.expect(t, strings.contains(text, "crash_drill.odin"), "no location reached the log")
	testing.expect(
		t,
		strings.contains(
			text,
			"runtime assertion: crashlog drill: deliberate assertion for issue #76 measurement",
		),
		"no message reached the log",
	)
}

// Issue #76 review round 1: a `-debug` build with a real PDB produced zero
// `"stack frame"` lines for an assertion crash, because `trace.init`'s result
// was discarded and `assertion_hook`'s stack walk allocated through
// `context.temp_allocator` on top of that. This is the weaker-but-real
// assertion the implementer's own report flagged as missing: at least one
// symbolized frame, naming this test file, reaches the log.
@(test)
an_assertion_failure_leaves_a_symbolized_stack_frame_in_the_log :: proc(t: ^testing.T) {
	dir := testkit.scratch_cache(t, "crashlog", "assert_drill_stack", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	if !run_crash_drill(t, "assert", dir) {
		return
	}

	text := read_log(t, dir)
	defer delete(text, context.allocator)
	testing.expect(
		t,
		strings.contains(text, "stack frame: "),
		"no symbolized stack frame reached the log",
	)
	testing.expect(
		t,
		strings.contains(text, "stack frame: main::run_crash_drill"),
		"the symbolized stack frame did not name the drill's own call site",
	)
}

@(test)
an_assertion_failure_on_a_worker_thread_leaves_its_message_in_the_log :: proc(t: ^testing.T) {
	dir := testkit.scratch_cache(t, "crashlog", "assert_thread_drill", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	if !run_crash_drill(t, "assert-thread", dir) {
		return
	}

	text := read_log(t, dir)
	defer delete(text, context.allocator)
	testing.expect(
		t,
		strings.contains(text, "deliberate assertion on a worker thread"),
		"the worker thread's assertion never reached the log",
	)
}

// The bounds-check path is the one `assertion_hook` never sees at all
// (`base:runtime`'s own `bounds_check_error` raises SEH directly) -- the
// negated check is what actually distinguishes this from the assert tests
// above rather than merely duplicating one of them.
@(test)
a_bounds_check_crash_leaves_an_artifact_via_the_exception_filter_only :: proc(t: ^testing.T) {
	dir := testkit.scratch_cache(t, "crashlog", "bounds_drill", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	if !run_crash_drill(t, "bounds", dir) {
		return
	}

	text := read_log(t, dir)
	defer delete(text, context.allocator)
	testing.expect(
		t,
		strings.contains(text, "CRASH exception=0xc000008c"),
		"the bounds-check exception never reached the log",
	)
	testing.expect(
		t,
		!strings.contains(text, "runtime assertion"),
		"a bounds check reached assertion_failure_proc, which the two-hook design says it must not",
	)
}
