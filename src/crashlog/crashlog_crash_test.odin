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
//
// The drill is spawned through `core:os`'s own `process_start`/`process_wait`
// and NOT through `transcibr:child`, which is what this file used to use.
// Issue #76 review round 6 wires `crashlog.assertion_hook` into
// `transcibr:child`'s own worker entry points, so `child` now imports
// `crashlog` -- and Odin refuses a cyclic package import outright
// (`Error: Cyclic importation of 'child'`, measured at the pin; a `_test.odin`
// file is part of its package for import resolution even under `odin build`).
// `core:os`'s spawn is enough for a drill: nothing here needs
// `CREATE_NO_WINDOW` (the test runner is a console-subsystem build) and
// nothing here terminates a child (every drill mode traps on its own), so
// neither CLAUDE.md note against `core:os` process handling applies. What is
// given up is the Job Object `transcibr:child` put each drill in; a drill that
// wedges past its bound now leaks its own process handle rather than dying
// with the runner, on a path where the test has already failed.
package crashlog

import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "transcibr:testkit"

@(private)
DRILL_CLI :: "build\\odin-test\\transcibr-cli-drill.exe"

@(private)
DRILL_BOUND :: 30 * time.Second

// Starts `transcibr-cli --crash-drill <mode> <dir>`, waits for it to end, and
// hands back the code it ended with. The drill is EXPECTED to crash -- a
// crash signals exactly as fast as a clean exit, so `exited` says nothing yet
// about HOW it ended, only that it did.
@(private)
@(require_results)
drill_exit_code :: proc(t: ^testing.T, mode: string, dir: string) -> (code: int, exited: bool) {
	assert(t != nil, "there is no test here to report a drill failure through")
	assert(len(mode) > 0, "a crash drill with no mode tells the CLI nothing to do")

	p, start_err := os.process_start({command = {DRILL_CLI, "--crash-drill", mode, dir}})
	if !testing.expectf(t, start_err == nil, "the crash drill did not start: %v", start_err) {
		return 0, false
	}

	state, wait_err := os.process_wait(p, DRILL_BOUND)
	if !testing.expectf(
		t,
		wait_err == nil,
		"the crash drill did not exit within the bound: %v",
		wait_err,
	) {
		_ = os.process_kill(p)
		return 0, false
	}
	return state.exit_code, state.exited
}

@(private)
@(require_results)
run_crash_drill :: proc(t: ^testing.T, mode: string, dir: string) -> (ok: bool) {
	assert(t != nil, "there is no test here to report a drill failure through")
	assert(len(mode) > 0, "a crash drill with no mode tells the CLI nothing to do")

	_, exited := drill_exit_code(t, mode, dir)
	return exited
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
	code, exited := drill_exit_code(t, "assert", "")
	testing.expect(t, exited, "the crash drill's exit code was not available after it signalled")
	testing.expect_value(t, code, 2)
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

// Issue #76 review round 6: `context.assertion_failure_proc` is per-context,
// and until that round only `main` and the drill's OWN synthetic thread
// installed it -- so every real production worker crashed mute, leaving the
// bare `CRASH exception=` line and nothing else. The test above passes on a
// thread `src/cli/crash_drill.odin` created and wired itself, which is why it
// stayed green throughout. This one drives `transcibr:child`'s `read_worker`,
// the production entry point `transcibr-cli --from-json` reads through, and
// the drill installs nothing on that thread: the message and the frame naming
// `read_worker` can only arrive through `read_worker`'s own install. Deleting
// that one line turns this red while every other test in this file stays
// green.
@(test)
an_assertion_in_a_real_production_worker_reaches_the_log :: proc(t: ^testing.T) {
	dir := testkit.scratch_cache(t, "crashlog", "worker_assert_drill", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	if !run_crash_drill(t, "worker-assert", dir) {
		return
	}

	text := read_log(t, dir)
	defer delete(text, context.allocator)
	testing.expect(
		t,
		strings.contains(text, "a read thread was asked to fail on purpose, and did"),
		"the production read worker's assertion never reached the log",
	)
	testing.expect(
		t,
		strings.contains(text, "read.odin"),
		"the production read worker's location never reached the log",
	)
	testing.expect(
		t,
		strings.contains(text, "stack frame: child::[read.odin]::read_worker"),
		"no symbolized frame naming the production read worker reached the log",
	)
}

// Fix round 5, issue #76's PR #166: `main` used to write
// `context.assertion_failure_proc = crashlog.assertion_hook` inside the `if`
// that decides whether the log opened -- a block-scoped assignment that
// reverted the instant the block closed, so `main`'s own copy of the
// context never actually carried the hook. Every other test in this file
// runs `--crash-drill`'s own modes, which set the hook a second time at
// `run_crash_drill`'s own proc scope and so passed regardless of whether
// `main`'s install worked. `wiring-assert` sets nothing itself (see
// `src/cli/crash_drill.odin`'s `CRASH_DRILL_WIRING_ASSERT` doc comment), so
// this test is red against the pre-fix `main` and green only once the
// assignment sits at `main`'s own top level. `main` reads its crash
// directory from %LOCALAPPDATA%, not from an argument, so this test points
// that variable at a scratch base for the duration of the drill and restores
// it afterward; `main` opens its log one level below that base, under
// `<base>\transcibr`, so cleanup removes that subdirectory before the base
// itself -- `defer`'s reverse-of-registration order is what sequences the
// two removals correctly.
@(test)
mains_own_wiring_installs_the_assertion_hook_without_the_drills_help :: proc(t: ^testing.T) {
	base := testkit.scratch_cache(t, "crashlog", "wiring_drill", context.allocator)
	defer delete(base, context.allocator)
	dir := strings.concatenate({base, "\\transcibr"}, context.allocator)
	defer delete(dir, context.allocator)
	defer os.remove(base)
	defer testkit.remove_cache(dir, context.allocator)

	previous, had_previous := os.lookup_env("LOCALAPPDATA", context.allocator)
	defer if had_previous {
		delete(previous, context.allocator)
	}
	if !testing.expect(
		t,
		os.set_env("LOCALAPPDATA", base) == nil,
		"could not point LOCALAPPDATA at the scratch base for this test",
	) {
		return
	}
	defer if had_previous {
		_ = os.set_env("LOCALAPPDATA", previous)
	} else {
		_ = os.unset_env("LOCALAPPDATA")
	}

	if !run_crash_drill(t, "wiring-assert", base) {
		return
	}

	text := read_log(t, dir)
	defer delete(text, context.allocator)
	testing.expect(
		t,
		strings.contains(text, "relying on main's own wiring"),
		"main's own crash-capture wiring never reached the log -- context.assertion_failure_proc was not set at main's own scope",
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
