#+vet explicit-allocators
// Package testkit builds and tears down the fixtures a child-driving suite in
// this repository needs: a scratch cache under TEMP, a `waitfor` signal name
// no other suite can collide on, and the flood file two of those suites write
// to force a diagnostic pipe past what one poll can drain in one pass.
//
// It carries no dependency on transcibr:child on purpose, but the constraint
// is one-way and not three-way: src/child/child_test.odin is part of package
// child, and a testkit that imported child could not be imported back by
// child's own tests without a cycle. src/audio and src/engine's test files are
// not package child and import transcibr:child directly already, so nothing
// stops a helper that needs it -- such as `open_group` -- from living in a
// second, child-importing package shared between just those two. It stays out
// of THIS package because child_test.odin also imports testkit (for
// `lonely_signal`), and importing child here would put that one file back in
// the cycle it is the actual reason for. `open_group` is kept local at each of
// its three call sites for that reason, spelled the same way at all three so
// the copies do not drift the way `scratch_cache` once did between audio and
// engine.
//
// What each procedure here does is checked directly, in testkit_test.odin,
// rather than only through the suites that call it: the drift this package
// exists to close (issue #33) was exactly the kind of small, easy-to-miss
// difference that only shows up when nobody wrote a test for the helper
// itself.
package testkit

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// Names a place under TEMP and does not create it -- a caller testing
// directory creation needs a path nothing has made yet. `scope` keeps two
// packages' caches apart and `tag` keeps two cases in one package apart. The
// caller frees the path and removes the directory.
@(require_results)
scratch_cache :: proc(
	t: ^testing.T,
	scope: string,
	tag: string,
	allocator: mem.Allocator,
) -> string {
	assert(t != nil, "there is no test here to report a refusal through")
	assert(len(scope) > 0, "a scratch cache with no package to name is a cache nobody can find")
	assert(len(tag) > 0, "a scratch cache shared by two cases is a cache one of them cannot claim")
	assert(allocator.procedure != nil, "the path outlives this procedure and needs an allocator")

	directory := os.get_env("TEMP", allocator)
	defer delete(directory, allocator)
	testing.expect(t, len(directory) > 0, "TEMP names nowhere to put a scratch cache")

	return fmt.aprintf(
		"%s\\transcibr-%s-%d-%s",
		directory,
		scope,
		os.get_pid(),
		tag,
		allocator = allocator,
	)
}

// As scratch_cache, and creates the directory: a caller that writes into the
// cache directly, rather than through the code under test, needs it there
// already. `src/audio`'s cases want the bare path instead, because several of
// them are testing directory creation itself -- that drift is why the two
// shapes are two procedures with two names rather than one flag.
@(require_results)
made_scratch_cache :: proc(
	t: ^testing.T,
	scope: string,
	tag: string,
	allocator: mem.Allocator,
) -> string {
	assert(t != nil, "there is no test here to report a refusal through")

	cache := scratch_cache(t, scope, tag, allocator)
	assert(len(cache) > 0, "scratch_cache produced no path to create")
	testing.expect(t, os.make_directory_all(cache) == nil, "could not make a scratch cache")
	return cache
}

// Best effort: a case that failed half-way should not fail a second time on
// the way out.
remove_cache :: proc(cache: string, allocator: mem.Allocator) {
	assert(len(cache) > 0, "there is no scratch cache here to remove")
	assert(allocator.procedure != nil, "a listing needs an allocator to be read into")

	listing, unreadable := os.read_all_directory_by_path(cache, allocator)
	if unreadable == nil {
		defer os.file_info_slice_delete(listing, allocator)
		for info in listing {
			os.remove(info.fullpath)
		}
	}
	os.remove(cache)
}

// `waitfor` registers its signal name machine-wide, and a second instance
// asking for a name already registered fails at once -- so cases that share
// one name make a different one red on each run. The process id keeps two
// suites apart, `scope` keeps two packages apart, and `tag` keeps two cases in
// one package apart.
@(require_results)
lonely_signal :: proc(scope: string, tag: string, allocator: mem.Allocator) -> string {
	assert(len(scope) > 0, "a signal name with no package to name is a signal nobody can trace")
	assert(len(tag) > 0, "a signal name shared by two cases is a signal one of them cannot have")
	assert(allocator.procedure != nil, "the name outlives this procedure and needs an allocator")

	return fmt.aprintf("transcibr%sNoSignal%d%s", scope, os.get_pid(), tag, allocator = allocator)
}

// Generous against the few seconds ADR-0020 measured for a real stop, so this
// only fires if a caller's own bound was never reached at all.
FLOOD_STOP_SLACK :: 5 * time.Second

// Writes at least `minimum_bytes` to `path` by repeating `filler_line`, so a
// child told to `type` it back out keeps a diagnostic pipe fed for longer than
// one poll takes to drain it. The line is the caller's own, so a file that
// wound up open in an editor still says which suite wrote it.
@(require_results)
write_flood :: proc(
	t: ^testing.T,
	path: string,
	minimum_bytes: int,
	filler_line: string,
	allocator: mem.Allocator,
) -> bool {
	assert(t != nil, "there is no test here to report a refusal through")
	assert(minimum_bytes > 0, "a flood of nothing at all floods nothing")
	assert(len(filler_line) > 0, "a flood built from an empty line floods nothing per line")

	written := strings.builder_make(allocator)
	defer strings.builder_destroy(&written)
	for strings.builder_len(written) < minimum_bytes {
		strings.write_string(&written, filler_line)
	}
	return testing.expect(
		t,
		os.write_entire_file(path, written.buf[:]) == nil,
		"could not write the flood this case types",
	)
}

// `cmd.exe`'s own way of typing a file to standard error before waiting on a
// signal nobody sends, so the child outlives whatever the flood alone takes to
// drain. The caller frees the command.
@(require_results)
flood_type_command :: proc(
	path: string,
	longer_seconds: int,
	signal: string,
	allocator: mem.Allocator,
) -> string {
	assert(len(path) > 0, "there is no flood file here for a child to type")
	assert(longer_seconds > 0, "a child told to wait no time at all was never told to wait")
	assert(len(signal) > 0, "a command with no signal to wait for never ends on its own")

	return fmt.aprintf(
		"type %s 1>&2 & waitfor /t %d %s",
		path,
		longer_seconds,
		signal,
		allocator = allocator,
	)
}
