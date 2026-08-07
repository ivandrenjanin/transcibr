#+vet explicit-allocators
package crashlog

import "core:fmt"
import "core:mem"
import "core:os"

// The directory this program's log and crash artifacts sit under, when a
// caller has not already got one from elsewhere: local application data
// (spec story 50's "on disk", never network -- story 57), one level below
// %LOCALAPPDATA% named for this program. `directory_under` is the pure half
// of this so a test can check the join without touching the real environment
// or the real filesystem.
@(require_results)
directory_under :: proc(base: string, allocator: mem.Allocator) -> string {
	assert(len(base) > 0, "a diagnostics directory needs a base to sit under")
	assert(allocator.procedure != nil, "the joined path needs an allocator")

	return fmt.aprintf("%s\\transcibr", base, allocator = allocator)
}

// Reads %LOCALAPPDATA% and creates `<LOCALAPPDATA>\transcibr` if it is not
// already there. An unset or empty %LOCALAPPDATA% is an operating error, not
// a programmer error -- it is external input this process does not
// control -- so it is rejected through `ok`, never asserted (CLAUDE.md A8).
@(require_results)
default_directory :: proc(allocator: mem.Allocator) -> (dir: string, ok: bool) {
	assert(allocator.procedure != nil, "the diagnostics directory needs an allocator for its path")

	base, found := os.lookup_env("LOCALAPPDATA", allocator)
	defer delete(base, allocator)
	if !found || len(base) == 0 {
		return "", false
	}

	dir = directory_under(base, allocator)
	if os.make_directory_all(dir) != nil {
		delete(dir, allocator)
		return "", false
	}
	return dir, true
}
