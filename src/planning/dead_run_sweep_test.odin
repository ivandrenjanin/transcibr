#+vet explicit-allocators
package planning

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"
import "core:testing"
import "transcibr:testkit"

// Issue #217: a planning suite that is killed (the issue #22 runner class)
// before its own tests' `defer testkit.remove_tree(...)` runs leaves the
// whole per-pid scratch tree behind under %TEMP% --
// `transcibr-planning-<pid>-<name>`, one set per dead run, forever, since
// nothing else ever revisits it.
//
// `sweep_dead_runs_once` is the startup self-sweep: called from the first
// test the alphabetically-first file in this package declares
// (access_test.odin), guarded by `sweep_once` so a later edit that adds a
// second call site stays free rather than re-sweeping. It enumerates %TEMP%
// for exactly this package's prefix -- never a wildcard delete, enumerate
// then delete exact paths -- skips its own pid and any pid still alive, and
// removes the rest through `testkit.remove_tree`, planning's own existing
// tree-remover and already junction-safe: `os.File_Info.type` reads a
// reparse point as `.Symlink` rather than `.Directory` (walk.odin, ADR-0026),
// so `remove_tree`'s `info.type == .Directory` check never recurses into
// one -- it falls to a bare `os.remove` on the link itself, which Windows
// answers by deleting the reparse point and never the target it points at.
//
// Bounded and quiet, like every consumer of `testkit.remove_tree`: a locked
// or otherwise undeletable tree is left for the next run to find, never
// retried into a storm, and never turns into a suite failure -- there is no
// `testing.T` here for it to report through, on purpose, since a stray dead
// run belongs to hygiene and not to the case that happens to run first.
@(private)
DEAD_RUN_PREFIX :: "transcibr-planning-"

// The exit-code sentinel GetExitCodeProcess reports while a process is still
// running (winbase.h's STILL_ACTIVE) -- core:sys/windows does not carry the
// constant itself, only the calls that need it.
@(private)
STILL_ACTIVE :: 259

@(private)
sweep_once: sync.Once

@(private)
sweep_dead_runs_once :: proc() {
	sync.once_do(&sweep_once, sweep_dead_runs)
}

// Ungated, so tests can call it directly and observe one deterministic pass
// rather than racing the once-guard's "did the suite already run this"
// state.
@(private)
sweep_dead_runs :: proc() {
	directory := os.get_env("TEMP", context.allocator)
	defer delete(directory, context.allocator)
	if len(directory) == 0 {
		return
	}

	listing, unreadable := os.read_all_directory_by_path(directory, context.allocator)
	if unreadable != nil {
		return
	}
	defer os.file_info_slice_delete(listing, context.allocator)

	own := os.get_pid()
	for info in listing {
		if info.type != .Directory {
			continue
		}
		if !strings.has_prefix(info.name, DEAD_RUN_PREFIX) {
			continue
		}
		pid, named := dead_run_pid(info.name)
		if !named {
			continue
		}
		if int(pid) == own {
			continue
		}
		if pid_is_live(pid) {
			continue
		}
		testkit.remove_tree(info.fullpath, context.allocator)
	}
}

// `transcibr-planning-<pid>-<name>` -- the pid is the digit run between the
// prefix and the next '-'. Digits only, no sign, no separator, the same
// discipline `read_natural` (src/process/engine.odin) holds a boundary
// number to: the name comes from whatever is sitting in %TEMP%, external
// input this package did not write, so a malformed one is refused rather
// than trusted.
@(private)
@(require_results)
dead_run_pid :: proc(name: string) -> (pid: u32, ok: bool) {
	assert(
		len(name) >= len(DEAD_RUN_PREFIX),
		"dead_run_pid was handed a name shorter than its own prefix",
	)

	rest := name[len(DEAD_RUN_PREFIX):]
	at := strings.index_byte(rest, '-')
	if at <= 0 {
		return 0, false
	}
	return parse_pid(rest[:at])
}

@(private)
@(require_results)
parse_pid :: proc(digits: string) -> (pid: u32, ok: bool) {
	if len(digits) == 0 || len(digits) > 10 {
		return 0, false
	}

	value: i64 = 0
	for r in digits {
		if r < '0' || r > '9' {
			return 0, false
		}
		value = value * 10 + i64(r - '0')
		if value > i64(max(u32)) {
			return 0, false
		}
	}
	return u32(value), true
}

// Never touches a pid still running -- the sole invariant this whole sweep
// exists to hold. Failing to OPEN the process at all is read two ways:
// ERROR_ACCESS_DENIED means the process exists and this account may just not
// query it, so treated as alive; anything else, including the plain "no such
// process" a pid nothing ever held answers with, means it does not resolve,
// which is the only shape a dead-run pid is allowed to take. A handle that
// opens but will not report its exit code is read the same cautious way.
@(private)
@(require_results)
pid_is_live :: proc(pid: u32) -> bool {
	handle := win32.OpenProcess(win32.PROCESS_QUERY_LIMITED_INFORMATION, false, win32.DWORD(pid))
	if handle == nil {
		return win32.GetLastError() == win32.ERROR_ACCESS_DENIED
	}
	defer win32.CloseHandle(handle)

	exit_code: win32.DWORD
	if !win32.GetExitCodeProcess(handle, &exit_code) {
		return true
	}
	return exit_code == STILL_ACTIVE
}

// Every case below builds its dead-run tree by hand rather than through
// `testkit.made_scratch_cache`, which always stamps the CALLING process's own
// pid -- the one pid a sweep must never touch.
@(private)
@(require_results)
dead_run_tree :: proc(t: ^testing.T, pid: u32, tag: string) -> string {
	assert(t != nil, "there is no test here to report a refusal through")
	assert(len(tag) > 0, "a dead-run tree with no tag is a tree two cases collide on")

	directory := os.get_env("TEMP", context.allocator)
	defer delete(directory, context.allocator)
	testing.expect(t, len(directory) > 0, "TEMP names nowhere to plant a dead-run tree")

	tree := fmt.aprintf(
		"%s\\transcibr-planning-%d-%s",
		directory,
		pid,
		tag,
		allocator = context.allocator,
	)
	testing.expectf(
		t,
		os.make_directory_all(tree) == nil,
		"could not make the dead-run tree %s",
		tree,
	)
	return tree
}

// Chosen far above any pid Windows hands out in practice, and read as "does
// not resolve" by `pid_is_live` itself: OpenProcess answers
// ERROR_INVALID_PARAMETER rather than ERROR_ACCESS_DENIED for a pid nothing
// ever held, which is exactly what a dead run's pid looks like once the
// process is gone.
@(private)
NEVER_ALIVE_PID :: 0xEFFFFFF0

@(test)
a_dead_run_tree_is_swept_on_the_next_suite_run :: proc(t: ^testing.T) {
	tree := dead_run_tree(t, NEVER_ALIVE_PID, "planted")
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree, context.allocator)

	left := testkit.fixture_file(t, tree, "left-behind.mp4", "video", context.allocator)
	defer delete(left, context.allocator)

	sweep_dead_runs()

	testing.expectf(t, !os.exists(tree), "a dead run's tree at %s was not swept", tree)
}

// The junction-safety proof: a dead-run tree holding a junction that points
// at a SEPARATE sentinel directory (outside this package's prefix, so the
// sweep never reaches it any other way) must lose the tree without the
// sentinel's own contents being touched at all.
@(test)
a_junction_inside_a_dead_run_tree_is_removed_without_touching_its_target :: proc(t: ^testing.T) {
	sentinel := testkit.made_scratch_cache(t, "planningsentinel", "junction", context.allocator)
	defer delete(sentinel, context.allocator)
	defer testkit.remove_tree(sentinel, context.allocator)

	guarded := testkit.fixture_file(t, sentinel, "guarded.mp4", "video", context.allocator)
	defer delete(guarded, context.allocator)

	tree := dead_run_tree(t, NEVER_ALIVE_PID, "junctioned")
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree, context.allocator)

	link := fmt.aprintf("%s\\link", tree, allocator = context.allocator)
	defer delete(link, context.allocator)
	if !junction(t, link, sentinel) {
		return
	}

	sweep_dead_runs()

	testing.expectf(t, !os.exists(tree), "a dead run's tree at %s was not swept", tree)
	content, unreadable := os.read_entire_file(guarded, context.allocator)
	defer delete(content, context.allocator)
	testing.expect(
		t,
		unreadable == nil,
		"the sweep followed the junction and took the sentinel's own file with it",
	)
	testing.expect_value(t, string(content), "video")
}

// The current pid is exactly the pid `os.get_pid()` reports for this very
// suite -- the tree it names is a tree still in use, not a dead run at all,
// and a sweep that touched it would delete out from under a test running in
// the same process.
@(test)
a_tree_named_with_the_current_pid_is_never_touched :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "planning", "current-pid", context.allocator)
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree, context.allocator)

	sweep_dead_runs()

	testing.expect(t, os.exists(tree), "the sweep removed a tree stamped with its own running pid")
}

// A locked, undeletable dead-run tree is exactly what `testkit.remove_tree`
// is already built to survive: best effort, no retry storm, no error return
// to fail a caller on. This proves the sweep inherits that rather than
// wrapping the call in anything that could turn a locked file into a suite
// failure (issue #22: nothing here may trip an assert).
@(test)
a_locked_dead_run_tree_does_not_fail_the_suite :: proc(t: ^testing.T) {
	tree := dead_run_tree(t, NEVER_ALIVE_PID, "locked")
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree, context.allocator)

	held := fmt.aprintf("%s\\held.bin", tree, allocator = context.allocator)
	defer delete(held, context.allocator)
	if !testing.expect(
		t,
		os.write_entire_file(held, []u8{0}) == nil,
		"could not write the file this case holds open",
	) {
		return
	}

	wide := win32.utf8_to_wstring(held, context.allocator)
	defer delete(wide, context.allocator)
	handle := win32.CreateFileW(
		wide,
		win32.GENERIC_READ,
		win32.FILE_SHARE_READ,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if !testing.expect(t, handle != win32.INVALID_HANDLE_VALUE, "could not open the held handle") {
		return
	}

	sweep_dead_runs()
	win32.CloseHandle(handle)

	testing.expect(
		t,
		os.exists(held),
		"the held file vanished, so this case proved nothing about a lock surviving",
	)
}
