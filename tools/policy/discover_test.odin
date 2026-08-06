#+vet explicit-allocators
package policy

import "core:testing"

@(test)
excluded_directories_are_named_exactly :: proc(t: ^testing.T) {
	testing.expect_value(t, is_excluded_directory(".git"), true)
	testing.expect_value(t, is_excluded_directory("build"), true)
	testing.expect_value(t, is_excluded_directory(".scratch"), true)
	testing.expect_value(t, is_excluded_directory(".tools"), true)
	testing.expect_value(t, is_excluded_directory("src"), false)
	testing.expect_value(t, is_excluded_directory(".gitignore"), false)
}

@(test)
relative_slashed_trims_the_root_and_flips_separators :: proc(t: ^testing.T) {
	relative := relative_slashed(`C:\repo\src\version\version.odin`, `C:\repo`, context.allocator)
	defer delete(relative, context.allocator)

	testing.expect_value(t, relative, "src/version/version.odin")
}

@(test)
discover_odin_files_refuses_a_root_that_is_not_there :: proc(t: ^testing.T) {
	files, ok := discover_odin_files(`C:\this-path-does-not-exist-at-all-152`, context.allocator)
	defer delete(files, context.allocator)
	defer for file in files {
		delete(file, context.allocator)
	}

	testing.expect_value(t, ok, false)
}
