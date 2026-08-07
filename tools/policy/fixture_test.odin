#+vet explicit-allocators
// Issue #202's consolidation item: this package's fixture planters used to be
// three near-verbatim copies -- `plant_accounting_fixture`/
// `remove_accounting_fixture`, `plant_e2e_fixture`/`remove_e2e_fixture`, and
// #184's `plant_exit_fixture`/`remove_exit_fixture` -- each walking the same
// "directories, then files, then a justfile" shape and tearing it back down
// in reverse. `Fixture_File`, `plant_fixture` and `remove_fixture` below are
// that one shape, written once; `fixture_root` and `fixture_path` name where
// a fixture lives and what its entries are called, and every planter in this
// package now calls through them instead of carrying its own copy.
package policy

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:testing"

Fixture_File :: struct {
	path:    string,
	content: string,
}

@(require_results)
fixture_path :: proc(base: string, name: string, allocator: mem.Allocator) -> string {
	assert(len(base) > 0, "asked to name a fixture file under no root at all")
	assert(len(name) > 0, "asked to name a fixture file with no name at all")
	return fmt.aprintf("%s/%s", base, name, allocator = allocator)
}

// A fresh, pid-suffixed fixture root under `os.get_env("TEMP")` -- joined
// with `core:path/filepath`'s `join`, never built by concatenating the
// directory's result straight onto a name (that concatenation lands the
// fixture as a SIBLING of the temp directory rather than a child of it,
// #185; `join` inserts the separator every platform needs). Reads
// `os.get_env("TEMP")` directly, the call `testkit.scratch_cache` uses, and
// not `os.temp_dir()`: the 2026-08-06 review's refuted list records
// `os.temp_directory` silently falling back to the user profile with
// TMP/TEMP both unset (err=nil), and reading TMP before TEMP when only one
// is set -- neither failure mode is one `fixture_root`'s caller can see
// through `os.temp_dir()`'s own `Error`, since it reports success either
// way. A single `defer` right after the read covers every return path, so
// the error branch never needs its own hand-rolled `delete` -- there is only
// one place `root` is freed.
@(require_results)
fixture_root :: proc(
	t: ^testing.T,
	name: string,
	allocator: mem.Allocator,
) -> (
	path: string,
	ok: bool,
) {
	assert(t != nil, "there is no test here to report a refusal through")
	assert(len(name) > 0, "asked to build a fixture root with no name at all")
	assert(
		allocator.procedure != nil,
		"the fixture root outlives this call and needs a chosen allocator",
	)

	root := os.get_env("TEMP", allocator)
	defer delete(root, allocator)
	if !testing.expect(t, len(root) > 0, "TEMP names nowhere to put a fixture root") {
		return "", false
	}

	dir_name := fmt.aprintf("%s-%d", name, os.get_pid(), allocator = allocator)
	defer delete(dir_name, allocator)

	joined, join_err := filepath.join([]string{root, dir_name}, allocator)
	if join_err != nil {
		return "", false
	}
	return joined, true
}

// Tolerates a leftover from a prior red run: an EMPTY directory already
// sitting at `base` is removed and recreated rather than refused, so one
// crashed test does not permanently arm a recycled pid against every fixture
// that reuses this name -- the exact failure mode the ticket named,
// `make_directory(base) -> Exist` in the very tests #185 fixed. A non-empty
// leftover is still refused: that shape means something else planted real
// files there, and silently absorbing it would hide a genuine collision
// rather than a stale one.
@(require_results)
ensure_fixture_root :: proc(base: string) -> os.Error {
	assert(len(base) > 0, "asked to create a fixture root at no path at all")

	err := os.make_directory(base)
	if err == nil {
		return nil
	}
	if err != os.General_Error.Exist {
		return err
	}

	entries, read_err := os.read_all_directory_by_path(base, context.allocator)
	if read_err != nil {
		return read_err
	}
	defer os.file_info_slice_delete(entries, context.allocator)
	if len(entries) != 0 {
		return err
	}

	remove_err := os.remove(base)
	if remove_err != nil {
		return remove_err
	}
	return os.make_directory(base)
}

// Plants a fixture, per-entry -- no `os.remove_all` counterpart is needed
// here since planting never removes anything, but the same hand-rolled
// per-path shape is used for both halves so the pairing (CLAUDE.md rule A4)
// reads the same way at both ends. `dirs` is created parent before child,
// the order `remove_fixture` walks in reverse.
plant_fixture :: proc(
	t: ^testing.T,
	base: string,
	dirs: []string,
	files: []Fixture_File,
	justfile: string,
) {
	assert(t != nil, "asked to plant a fixture for no test at all")
	assert(len(base) > 0, "asked to plant a fixture at no path at all")

	testing.expect_value(t, ensure_fixture_root(base), os.Error(nil))
	for name in dirs {
		path := fixture_path(base, name, context.allocator)
		defer delete(path, context.allocator)
		testing.expect_value(t, os.make_directory(path), os.Error(nil))
	}

	for file in files {
		path := fixture_path(base, file.path, context.allocator)
		defer delete(path, context.allocator)
		testing.expect_value(
			t,
			os.write_entire_file(path, transmute([]byte)file.content),
			os.Error(nil),
		)
	}

	justfile_path := fixture_path(base, "justfile", context.allocator)
	defer delete(justfile_path, context.allocator)
	testing.expect_value(
		t,
		os.write_entire_file(justfile_path, transmute([]byte)justfile),
		os.Error(nil),
	)
}

// Removes the fixture, per-entry: the #97/#105 rule (CLAUDE.md's Odin notes)
// bans `os.remove_all` anywhere in this tree, build-enforced by
// `collect_remove_all_violations` itself. Files first, then directories in
// reverse (child before parent), then `base` -- and `base`'s own removal is
// the return value every caller checks, closing the #202 residual where
// three of five fixture families discarded it.
@(require_results)
remove_fixture :: proc(base: string, dirs: []string, files: []Fixture_File) -> os.Error {
	assert(len(base) > 0, "asked to remove a fixture at no path at all")

	justfile_path := fixture_path(base, "justfile", context.allocator)
	defer delete(justfile_path, context.allocator)
	os.remove(justfile_path)

	for file in files {
		path := fixture_path(base, file.path, context.allocator)
		defer delete(path, context.allocator)
		os.remove(path)
	}
	#reverse for name in dirs {
		path := fixture_path(base, name, context.allocator)
		defer delete(path, context.allocator)
		os.remove(path)
	}
	return os.remove(base)
}
