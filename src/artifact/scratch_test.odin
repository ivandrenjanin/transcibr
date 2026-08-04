package artifact

import "core:fmt"
import "core:os"
import "core:testing"

// The directory helpers every shell case in this package uses, declared ONCE
// here rather than at the top of each file that wants one.
//
// A FOURTH COPY OF `scratch_cache` AND `remove_cache` IN THIS REPOSITORY, and
// issue #33 is where that debt lives: `src/child`, `src/audio` and `src/engine`
// each carry a pair, and the three have already drifted -- `src/audio`'s builds
// a path and stops where `src/engine`'s makes the directory. Odin has no
// test-only shared package, so the fix is either a `transcibr:testkit` built for
// the purpose or a decision to keep the copies and say so at every site, and
// both are decisions rather than a pass on this ticket. What is declined here is
// the copy WITHIN a package: one declaration for every case file, so the drift
// cannot start again inside these four files.

// A directory of this case's own, made. The caller frees the path and removes
// the directory.
//
// It stands in for two different places depending on the case: the scratch
// cache the Engine wrote into, and the directory a Recording lives in. They are
// deliberately separate directories in the cases that use both, because that is
// the arrangement the cross-volume question is really about.
@(private)
scratch :: proc(t: ^testing.T, tag: string) -> string {
	directory := os.get_env("TEMP", context.allocator)
	defer delete(directory, context.allocator)
	testing.expect(t, len(directory) > 0, "TEMP names nowhere to put a scratch directory")

	made := fmt.aprintf(
		"%s\\transcibr-artifact-%d-%s",
		directory,
		os.get_pid(),
		tag,
		allocator = context.allocator,
	)
	testing.expect(t, os.make_directory_all(made) == nil, "could not make a scratch directory")
	return made
}

// Everything a case left in a directory, and then the directory. Best effort: a
// case that failed half way should not fail a second time on the way out.
@(private)
remove_scratch :: proc(directory: string) {
	listing, unreadable := os.read_all_directory_by_path(directory, context.allocator)
	if unreadable == nil {
		defer os.file_info_slice_delete(listing, context.allocator)
		for info in listing {
			os.remove(info.fullpath)
		}
	}
	os.remove(directory)
}

// One file, written. The caller frees the path; remove_scratch takes the file.
@(private)
file_in :: proc(t: ^testing.T, directory: string, name: string, content: string) -> string {
	path := fmt.aprintf("%s\\%s", directory, name, allocator = context.allocator)
	testing.expectf(
		t,
		os.write_entire_file(path, transmute([]u8)content) == nil,
		"could not write %s",
		path,
	)
	return path
}
