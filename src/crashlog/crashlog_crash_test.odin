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
// walk). `just test-one crashlog <name>` rebuilds it too, as its own first
// dependency edge (issue #240's `drill-cli-exe` recipe) -- a bare
// `test-one`, with no prior `just test` and no hand-run build, always meets
// the current source.
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
import win32 "core:sys/windows"
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

// Fix round 1, issue #270 finding 1: `install`'s own `if refusal != .None {
// note(...) }` wiring was reachable from no red mutation -- deleting it left
// every crashlog test green, because `rotate_test.odin`'s own refusal test
// calls `note` directly rather than through `install`. This drives the real
// seam: the drill's own child process runs a real `crashlog.install` against
// a directory this test process holds an over-bound log open in (without
// `FILE_SHARE_DELETE`, the same fixture shape `rotate_test.odin` uses), so
// only the drill's OWN `install` call can put the WARN line in the log.
@(test)
installs_own_warn_line_reaches_the_log_when_rotation_is_refused :: proc(t: ^testing.T) {
	dir := testkit.scratch_cache(t, "crashlog", "rotation_warn_drill", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	holder, holder_refusal, holder_ok := open_log(dir, context.allocator)
	defer close_log(&holder)
	if !testing.expect(t, holder_ok, "could not open the holder handle this fixture needs") {
		return
	}
	testing.expect_value(t, holder_refusal, Rotation_Refusal.None)

	padding := make([]byte, LOG_CEILING_BYTES + 1, context.allocator)
	defer delete(padding, context.allocator)
	write_bytes(holder.file, padding)

	if !run_crash_drill(t, "rotation-warn", dir) {
		return
	}

	text := read_log(t, dir)
	defer delete(text, context.allocator)
	testing.expect(
		t,
		strings.contains(text, "WARN rotation refused: a second process holds transcibr.log open"),
		"the drill's own install call did not log the rotation refusal",
	)
}

// The fixture half of the test below, split out to hold F1's line limit: this
// plants an over-bound `transcibr.log`, a stale `.1` generation, and holds
// only the DESTINATION generation file open (no `FILE_SHARE_DELETE`, nothing
// at all holding the source) -- the same shape `rotate_test.odin`'s
// `open_log_reports_an_unknown_cause_when_only_the_destination_is_held` uses,
// which makes `rotate_if_over`'s `MoveFileExW` fail with `ERROR_ACCESS_DENIED`
// rather than `ERROR_SHARING_VIOLATION`.
@(private)
@(require_results)
hold_destination_generation_file :: proc(
	t: ^testing.T,
	dir: string,
) -> (
	dest_handle: win32.HANDLE,
	ok: bool,
) {
	assert(t != nil, "there is no test here to report a fixture failure through")
	assert(len(dir) > 0, "the fixture needs somewhere to plant its files")

	if os.make_directory_all(dir) != nil {
		testing.expect(t, false, "could not create the drill directory")
		return win32.INVALID_HANDLE_VALUE, false
	}

	path := strings.concatenate({dir, "\\", LOG_FILE_NAME}, context.allocator)
	defer delete(path, context.allocator)
	old := make([]byte, LOG_CEILING_BYTES + 1, context.allocator)
	defer delete(old, context.allocator)
	if os.write_entire_file(path, old) != nil {
		testing.expect(t, false, "could not plant an over-bound log fixture")
		return win32.INVALID_HANDLE_VALUE, false
	}

	generation_path := strings.concatenate({dir, "\\", LOG_FILE_NAME, ".1"}, context.allocator)
	defer delete(generation_path, context.allocator)
	if os.write_entire_file(generation_path, transmute([]byte)string("stale generation")) != nil {
		testing.expect(t, false, "could not plant a stale generation fixture")
		return win32.INVALID_HANDLE_VALUE, false
	}

	generation_wide := win32.utf8_to_utf16(generation_path, context.allocator)
	defer delete(generation_wide, context.allocator)
	if generation_wide == nil {
		testing.expect(t, false, "could not encode the generation path")
		return win32.INVALID_HANDLE_VALUE, false
	}
	handle := win32.CreateFileW(
		win32.wstring(raw_data(generation_wide)),
		win32.GENERIC_READ,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE {
		testing.expect(t, false, "could not hold the destination generation file for this fixture")
		return win32.INVALID_HANDLE_VALUE, false
	}
	return handle, true
}

// Fix round 2, issue #270 finding 1: `install`'s `.Unknown` arm was reachable
// from no red mutation -- deleting only `case .Unknown: note(...)` left every
// crashlog test green, because the existing rotation-warn drill test's
// fixture holds a live handle on the SOURCE file, which classifies as
// `.Second_Opener` and only ever exercises the sibling arm. `rotation-warn`
// is the same drill mode finding 1's first case already wired -- it calls
// `install` unconditionally and lets whatever `Rotation_Refusal` `open_log`
// returns pick the wording, so only the fixture needs to differ.
@(test)
installs_own_unknown_wording_reaches_the_log_when_only_the_destination_is_held :: proc(
	t: ^testing.T,
) {
	dir := testkit.scratch_cache(t, "crashlog", "rotation_warn_unknown_drill", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	dest_handle, planted := hold_destination_generation_file(t, dir)
	if !planted {
		return
	}
	defer win32.CloseHandle(dest_handle)

	if !run_crash_drill(t, "rotation-warn", dir) {
		return
	}

	text := read_log(t, dir)
	defer delete(text, context.allocator)
	testing.expect(
		t,
		strings.contains(
			text,
			"WARN rotation refused: the previous transcibr.log could not be rotated",
		),
		"the drill's own install call did not log the unknown-cause rotation refusal",
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
