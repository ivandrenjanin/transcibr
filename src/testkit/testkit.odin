#+vet explicit-allocators
// Package testkit builds and tears down the fixtures a child-driving suite in
// this repository needs: a scratch cache under TEMP, and a `waitfor` signal
// name no other suite can collide on. It carries no dependency on
// transcibr:child on purpose -- src/child/child_test.odin is itself part of
// that package, and a testkit that imported child could not be imported back
// by child's own tests without a cycle. `open_group` is therefore kept local
// at each of its three call sites rather than moved here.
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
import "core:testing"

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
