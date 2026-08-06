#+vet explicit-allocators
package child

import "base:runtime"
import "core:mem"
import "core:os"
import "core:strings"
import "core:thread"

// Bounding `os.make_directory_all` and `os.read_all_directory_by_path` the
// same way `read_bounded` bounds a whole-file read: `--cache` is hand-typed
// input, the same class of risk `--from-json` already carries (issue #27),
// and `open_cache` -- `transcibr:audio`'s `run.odin` -- is the FIRST thing
// `--transcribe` does with it, before any bound this package's callers
// otherwise rely on. A stalled network share used as scratch wedges a
// directory creation or a directory listing exactly the way it wedges the
// reads this package already bounds (PR #64's third review, finding 6).

@(private)
Make_Directory_Job :: struct {
	path: string,
	err:  os.Error,
}

@(private)
make_directory_worker :: proc(data: rawptr) {
	job := (^Make_Directory_Job)(data)
	assert(job != nil, "a directory-creation thread was started with no job to run")
	assert(len(job.path) > 0, "a directory-creation thread was started with no path to create")

	job.err = os.make_directory_all(job.path)
}

// `ok` collapses a bound reached, a thread that could not start, and a
// directory that exists already into the identical answer a caller already
// treats the same way: `open_cache` accepts either `err == nil` or the
// directory already being there, and cannot and does not need to tell "the
// share stopped answering" apart from "something else is wrong with it".
@(require_results)
make_directory_bounded :: proc(path: string, bound_ms: i64) -> (ok: bool) {
	assert(len(path) > 0, "there is no directory here to create")
	assert(bound_ms > 0, "a directory creation given no time at all cannot do anything")

	job := new(Make_Directory_Job, runtime.heap_allocator())
	job.path = strings.clone(path, runtime.heap_allocator())

	context.allocator = runtime.heap_allocator()
	t := thread.create_and_start_with_data(job, make_directory_worker)
	if t == nil {
		delete(job.path, runtime.heap_allocator())
		free(job, runtime.heap_allocator())
		return false
	}

	finished, reclaim := await_and_reclaim(t, bound_ms)
	if finished {
		err := job.err
		release_make_directory_job(t, job)
		return err == nil || os.exists(path)
	}
	if reclaim {
		release_make_directory_job(t, job)
	}
	return false
}

@(private)
release_make_directory_job :: proc(t: ^thread.Thread, job: ^Make_Directory_Job) {
	assert(t != nil, "there is no thread here to release")
	assert(job != nil, "there is no job here to release")

	delete(job.path, runtime.heap_allocator())
	free(job, runtime.heap_allocator())
	thread.destroy(t)
}

@(private)
Directory_Listing_Job :: struct {
	path:    string,
	listing: []os.File_Info,
	err:     os.Error,
}

@(private)
directory_listing_worker :: proc(data: rawptr) {
	job := (^Directory_Listing_Job)(data)
	assert(job != nil, "a directory-listing thread was started with no job to read")
	assert(len(job.path) > 0, "a directory-listing thread was started with no path to read")

	job.listing, job.err = os.read_all_directory_by_path(job.path, runtime.heap_allocator())
}

// The mirror of `transcibr:planning`'s own `directory_listing_bounded`, one
// package over: the same bound, the same collapse of every failure into
// `ok == false`, because a scratch-cache sweep already treats an unreadable
// cache as `.Unusable` whatever the reason.
@(require_results)
list_directory_bounded :: proc(
	path: string,
	bound_ms: i64,
	allocator: mem.Allocator,
) -> (
	listing: []os.File_Info,
	ok: bool,
) {
	assert(len(path) > 0, "there is no directory here to list")
	assert(bound_ms > 0, "a listing given no time at all cannot do anything")
	assert(allocator.procedure != nil, "a listing outliving this procedure needs an allocator")

	job := new(Directory_Listing_Job, runtime.heap_allocator())
	job.path = strings.clone(path, runtime.heap_allocator())

	context.allocator = runtime.heap_allocator()
	t := thread.create_and_start_with_data(job, directory_listing_worker)
	if t == nil {
		delete(job.path, runtime.heap_allocator())
		free(job, runtime.heap_allocator())
		return nil, false
	}

	finished, reclaim := await_and_reclaim(t, bound_ms)
	if finished {
		return directory_listing_finished(t, job, allocator)
	}
	if reclaim {
		release_directory_listing_job(t, job)
	}
	return nil, false
}

@(private)
release_directory_listing_job :: proc(t: ^thread.Thread, job: ^Directory_Listing_Job) {
	assert(t != nil, "there is no thread here to release")
	assert(job != nil, "there is no job here to release")

	if job.err == nil {
		os.file_info_slice_delete(job.listing, runtime.heap_allocator())
	}
	delete(job.path, runtime.heap_allocator())
	free(job, runtime.heap_allocator())
	thread.destroy(t)
}

@(private)
@(require_results)
directory_listing_finished :: proc(
	t: ^thread.Thread,
	job: ^Directory_Listing_Job,
	allocator: mem.Allocator,
) -> (
	listing: []os.File_Info,
	ok: bool,
) {
	assert(t != nil, "there is no thread here to close out")
	assert(job != nil, "a finished listing has no job to read its answer from")

	err := job.err
	if err == nil {
		listing, ok = clone_directory_listing(job.listing, allocator)
	}
	release_directory_listing_job(t, job)
	return
}

// Frees `cloned[:i]` through `os.file_info_slice_delete` alone on the error
// path, and never `cloned` again after it -- `file_info_slice_delete` ends
// with `delete(infos, allocator)`, which already frees the pointer `cloned`
// itself holds. A second `delete` there is the exact double free PR #64's
// second review found in `planning`'s own `clone_listing`
// (`a_directory_listing_that_cannot_be_cloned_under_memory_pressure_frees_-`
// `what_it_cloned_exactly_once` is this file's copy of the regression test
// that pins it).
@(private)
@(require_results)
clone_directory_listing :: proc(
	listing: []os.File_Info,
	allocator: mem.Allocator,
) -> (
	cloned: []os.File_Info,
	ok: bool,
) {
	assert(allocator.procedure != nil, "a listing outliving this procedure needs an allocator")

	cloned = make([]os.File_Info, len(listing), allocator)
	for info, i in listing {
		one, err := os.file_info_clone(info, allocator)
		if err != nil {
			os.file_info_slice_delete(cloned[:i], allocator)
			return nil, false
		}
		cloned[i] = one
	}
	return cloned, true
}
