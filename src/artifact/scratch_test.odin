package artifact

import "core:fmt"
import "core:os"
import "core:testing"

// The caller frees the path and removes the directory.
@(private)
@(require_results)
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

// Best effort: a case that failed half way should not fail a second time on the
// way out.
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

// The caller frees the path; remove_scratch takes the file.
@(private)
@(require_results)
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
