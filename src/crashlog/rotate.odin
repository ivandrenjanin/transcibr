#+vet explicit-allocators
package crashlog

import "core:fmt"
import "core:mem"
import win32 "core:sys/windows"

// ADR-0039 D2: sized from the measured growth rates in the 176-B review's
// residuals comment (~61 B per healthy run, ~106-167 B per refusing run) and
// D2's own worked example -- a 56-Recording Batch's trail runs near 72 KB,
// two orders of magnitude under this ceiling, so 8 MiB leaves headroom no
// plausible single-process run reaches while still bounding the file against
// the unbounded case (a crash loop, a very long-lived process).
LOG_CEILING_BYTES :: 8 << 20

#assert(LOG_CEILING_BYTES > 0)

// The handleless size read D2 requires: `GetFileAttributesExW`, never
// `GetFileSizeEx`, because a sizing handle opened under `handle.odin`'s own
// flags (`FILE_APPEND_DATA`, no `FILE_SHARE_DELETE`) would block the very
// rename this file exists to perform, in the same process that opened it
// (measured, ADR-0039 D2). No handle is opened here at all.
@(private)
@(require_results)
log_file_size :: proc(path: win32.wstring) -> (size: i64, ok: bool) {
	assert(path != nil, "cannot stat a log path with no wide string")

	data: win32.WIN32_FILE_ATTRIBUTE_DATA
	if !bool(win32.GetFileAttributesExW(path, win32.GetFileExInfoStandard, &data)) {
		return 0, false
	}
	return i64(data.nFileSizeHigh) << 32 | i64(data.nFileSizeLow), true
}

// ADR-0039 D2: runs once, before `open_log`'s own `CreateFileW`, so
// whichever file `register` later gets a handle to is the one every crash
// hook writes for the rest of the process's life. A missing or under-bound
// log is not rotated at all -- `rotation_refused` answers `false` for both,
// the same as a rotation that ran and succeeded, because "refused" names
// only the one case `open_log`'s caller has to report: an oversize log that
// stayed oversize because a second live transcibr already held it open
// without `FILE_SHARE_DELETE` (D2's "honest part"). The rename's own
// `MOVEFILE_REPLACE_EXISTING` flag is what lets a second rotation overwrite
// a stale `.1` generation from a previous rotation, so no separate
// `DeleteFileW` call is needed here.
@(private)
@(require_results)
rotate_if_over :: proc(dir: string, allocator: mem.Allocator) -> (rotation_refused: bool) {
	assert(len(dir) > 0, "rotation needs somewhere to look for a log")
	assert(allocator.procedure != nil, "rotation needs an allocator for its paths")

	path := fmt.aprintf("%s\\%s", dir, LOG_FILE_NAME, allocator = allocator)
	defer delete(path, allocator)
	wide := win32.utf8_to_utf16(path, allocator)
	defer delete(wide, allocator)
	if wide == nil {
		return false
	}

	size, sized := log_file_size(win32.wstring(raw_data(wide)))
	if !sized || size < LOG_CEILING_BYTES {
		return false
	}

	generation_path := fmt.aprintf("%s\\%s.1", dir, LOG_FILE_NAME, allocator = allocator)
	defer delete(generation_path, allocator)
	generation_wide := win32.utf8_to_utf16(generation_path, allocator)
	defer delete(generation_wide, allocator)
	if generation_wide == nil {
		return true
	}

	moved := win32.MoveFileExW(
		win32.wstring(raw_data(wide)),
		win32.wstring(raw_data(generation_wide)),
		win32.MOVEFILE_REPLACE_EXISTING,
	)
	return !bool(moved)
}
