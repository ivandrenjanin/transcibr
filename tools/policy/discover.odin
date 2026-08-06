#+vet explicit-allocators
// This file finds .odin files on disk, the way scripts\common.ps1's
// Get-OdinSource and Get-OdinPackage did before issue #152 retired them. It
// is the one part of this program's job that genuinely needs the filesystem
// rather than a string in memory, which is why it is apart from check.odin
// and untouched by policy_test.odin's fixture-as-string-literal style.
package policy

import "core:mem"
import "core:os"
import "core:strings"

// Directories no walk here ever descends into: git's own object store, this
// program's own build output, the throwaway prototypes .gitignore already
// keeps out of the repository, and `.tools`, where `just install-tools`
// extracts the pinned Odin distribution -- 1,330 `.odin` files of core
// library source that are not this repository's own and must never be read
// against its policies (measured: 19,965 violations before this exclusion
// existed). None of these directories holds authored Odin.
EXCLUDED_DIRECTORY_NAMES :: []string{".git", "build", ".scratch", ".tools"}

@(require_results)
is_excluded_directory :: proc(name: string) -> bool {
	assert(len(name) > 0, "asked whether a nameless directory is excluded")
	for excluded in EXCLUDED_DIRECTORY_NAMES {
		if name == excluded {
			return true
		}
	}
	return false
}

// Every `.odin` file under `root`, repository-relative and forward-slashed,
// skipping the directories above wherever they appear. Refuses a root that is
// not there rather than returning an empty list: a walk that silently covers
// nothing reports the same green as one that covered everything.
@(require_results)
discover_odin_files :: proc(
	root: string,
	allocator: mem.Allocator,
) -> (
	files: []string,
	ok: bool,
) {
	assert(len(root) > 0, "asked to discover Odin files under no root at all")
	assert(
		allocator.procedure != nil,
		"the discovered paths outlive this call and need a chosen allocator",
	)

	if !os.exists(root) {
		return nil, false
	}

	found := make([dynamic]string, 0, allocator)
	walker := os.walker_create(root)
	defer os.walker_destroy(&walker)

	for entry in os.walker_walk(&walker) {
		if entry.type == .Directory {
			if is_excluded_directory(entry.name) {
				os.walker_skip_dir(&walker)
			}
			continue
		}
		if entry.type != .Regular || !strings.has_suffix(entry.name, ".odin") {
			continue
		}
		relative := relative_slashed(entry.fullpath, root, allocator)
		append(&found, relative)
	}

	if _, walk_error := os.walker_error(&walker); walk_error != nil {
		return found[:], false
	}
	return found[:], true
}

// `path`, spelled relative to `root` and forward-slashed: `src/version/version.odin`
// rather than a machine-specific absolute path with backslashes in it.
@(require_results)
relative_slashed :: proc(path: string, root: string, allocator: mem.Allocator) -> string {
	assert(len(path) > 0, "asked to relativise a path with no name")
	assert(len(root) > 0, "asked to relativise a path against no root at all")

	forward, _ := strings.replace_all(path, "\\", "/", allocator)
	defer delete(forward, allocator)
	forward_root, _ := strings.replace_all(root, "\\", "/", allocator)
	defer delete(forward_root, allocator)

	trimmed := strings.trim_prefix(forward, forward_root)
	trimmed = strings.trim_prefix(trimmed, "/")
	return strings.clone(trimmed, allocator)
}
