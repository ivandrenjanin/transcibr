#+vet explicit-allocators
package child

import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"

// Finding 6 of PR #64's third review: `--cache` is hand-typed, the same
// class of input `--from-json` is, and `open_cache` is the first thing
// `--transcribe` does with it. This case proves `make_directory_bounded`
// actually creates the directory within its bound, and not merely that it
// compiles against `await_or_abandon` -- the bound-enforcement mechanism
// itself is `read_test.odin`'s to prove, against a pipe nobody writes to.
// Three missing levels, matching `directory.odin`'s `make_directory_worker`
// call to `os.make_directory_all` rather than `os.make_directory`: this is the only
// test in the repository whose target proves the recursive create is really
// what runs. Issue #97 measured (fix round 1, against
// `dev-2026-07-nightly:819fdc7`) that the `-define:ODIN_TEST_THREADS=1`
// crash was a second `os.remove_all` on a NON-EMPTY directory on a
// `core:testing` runner thread, not depth -- so teardown here is four
// stacked `os.remove` calls, innermost first, and never `os.remove_all`.
@(test)
a_scratch_cache_directory_is_created_within_its_bound :: proc(t: ^testing.T) {
	root := scratch_path(t, "cachedir", context.allocator)
	defer delete(root, context.allocator)
	nested := fmt.aprintf("%s\\a\\b\\c", root, allocator = context.allocator)
	defer delete(nested, context.allocator)
	level_b := fmt.aprintf("%s\\a\\b", root, allocator = context.allocator)
	defer delete(level_b, context.allocator)
	level_a := fmt.aprintf("%s\\a", root, allocator = context.allocator)
	defer delete(level_a, context.allocator)

	defer os.remove(root)
	defer os.remove(level_a)
	defer os.remove(level_b)
	defer os.remove(nested)

	testing.expect(
		t,
		make_directory_bounded(nested, READ_TEST_RUN_BOUND_MS),
		"a scratch cache directory within its bound was reported as not made",
	)
	testing.expect(
		t,
		os.exists(nested),
		"make_directory_bounded reported success but made nothing",
	)
}

@(test)
a_scratch_cache_directory_that_already_exists_is_still_reported_made :: proc(t: ^testing.T) {
	root := scratch_path(t, "cachedirexists", context.allocator)
	defer delete(root, context.allocator)
	defer os.remove(root)
	testing.expect(
		t,
		os.make_directory_all(root) == nil,
		"could not make the directory this case needs",
	)

	testing.expect(
		t,
		make_directory_bounded(root, READ_TEST_RUN_BOUND_MS),
		"a directory already there was reported as not made",
	)
}

@(test)
a_directory_listing_within_its_bound_returns_every_entry_through_child :: proc(t: ^testing.T) {
	root := scratch_path(t, "listdirok", context.allocator)
	defer delete(root, context.allocator)
	testing.expect(
		t,
		os.make_directory_all(root) == nil,
		"could not make the directory this case needs",
	)
	defer os.remove(root)

	a := fmt.aprintf("%s\\a.wav", root, allocator = context.allocator)
	defer delete(a, context.allocator)
	defer os.remove(a)
	testing.expect(
		t,
		os.write_entire_file(a, transmute([]u8)string("a")) == nil,
		"could not write a.wav",
	)
	b := fmt.aprintf("%s\\b.wav", root, allocator = context.allocator)
	defer delete(b, context.allocator)
	defer os.remove(b)
	testing.expect(
		t,
		os.write_entire_file(b, transmute([]u8)string("b")) == nil,
		"could not write b.wav",
	)

	listing, ok := list_directory_bounded(root, READ_TEST_RUN_BOUND_MS, context.allocator)
	defer if ok {
		os.file_info_slice_delete(listing, context.allocator)
	}

	testing.expect(t, ok, "a directory listing within its bound was reported as unreadable")
	testing.expect_value(t, len(listing), 2)
}

// A dedicated stress case proving the bound itself fires (thousands of
// directory entries against a 1 ms bound, mirroring `transcibr:planning`'s
// own bound-reached case) is deliberately NOT here: this package's own
// concurrent suite already runs a hundred abandoned reads and an 8 MiB
// flood side by side, and adding a third heavy, thread-and-disk-bound case
// to that mix reproducibly tripped `odin test`'s documented concurrent-
// signal fragility (CLAUDE.md's Odin notes, issue #22) rather than proving
// anything new -- `list_directory_bounded` calls the identical
// `await_or_abandon` this file already discriminates directly, at the pipe,
// in `a_read_that_cannot_finish_is_abandoned_at_its_bound` and in
// `abandoning_a_read_repeatedly_does_not_accumulate_threads_when_the_thread_probe_succeeds`, and
// `planning.a_directory_listing_that_cannot_finish_within_its_bound_is_-`
// `reported_rather_than_awaited_forever` already proves the identical
// listing-specific wiring one package over.

// The double free PR #64's second review found in `planning`'s own
// `clone_listing`, mirrored here because `clone_directory_listing` is the
// identical shape: `os.file_info_slice_delete(cloned[:i], allocator)` already
// frees `cloned`'s backing block, and a second `delete(cloned, allocator)`
// after it frees the same block twice. `fails_after` answers `.Out_Of_Memory`
// on the third allocation, landing the failure mid-listing.
@(private)
Directory_Failing_Allocator :: struct {
	backing:   mem.Allocator,
	remaining: int,
}

@(private)
@(require_results)
directory_fails_after_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	loc := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	fa := (^Directory_Failing_Allocator)(allocator_data)
	assert(fa != nil, "a probe allocator call arrived with no state behind it")

	if mode == .Alloc || mode == .Alloc_Non_Zeroed {
		if fa.remaining == 0 {
			return nil, .Out_Of_Memory
		}
		fa.remaining -= 1
	}
	return fa.backing.procedure(fa.backing.data, mode, size, alignment, old_memory, old_size, loc)
}

@(private)
@(require_results)
directory_fails_after :: proc(
	fa: ^Directory_Failing_Allocator,
	remaining: int,
	backing: mem.Allocator,
) -> mem.Allocator {
	assert(fa != nil, "there is no state here to run a probe allocator through")
	assert(remaining >= 0, "a probe cannot fail before it has done anything")

	fa.backing = backing
	fa.remaining = remaining
	return mem.Allocator{procedure = directory_fails_after_proc, data = fa}
}

@(test)
a_directory_listing_that_cannot_be_cloned_under_memory_pressure_frees_what_it_cloned_exactly_once :: proc(
	t: ^testing.T,
) {
	listing := []os.File_Info {
		{fullpath = "C:\\cache\\a.wav"},
		{fullpath = "C:\\cache\\b.wav"},
		{fullpath = "C:\\cache\\c.wav"},
	}

	fa: Directory_Failing_Allocator
	probe := directory_fails_after(&fa, 2, context.allocator)

	cloned, ok := clone_directory_listing(listing, probe)

	testing.expect(t, !ok, "cloning under memory pressure was reported as succeeding")
	testing.expect(t, cloned == nil, "a failed clone still handed back a partial listing")
}
