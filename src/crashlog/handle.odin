#+vet explicit-allocators
package crashlog

import "core:fmt"
import "core:mem"
import "core:os"
import win32 "core:sys/windows"

LOG_FILE_NAME :: "transcibr.log"

#assert(len(LOG_FILE_NAME) > 0)

// Opens `<dir>\transcibr.log` for append, creating `dir` if it is not there
// yet. `FILE_APPEND_DATA` rather than plain `GENERIC_WRITE` -- a write
// through it always lands at the file's current end, so no writer can
// truncate what another already wrote. Sharing both `FILE_SHARE_READ` and
// `FILE_SHARE_WRITE` is what actually lets a second concurrent transcibr-cli
// (or a future #16 GUI) open the same file at all -- issue #76 review round 2
// measured a `FILE_SHARE_READ`-only open here refuse a second opener outright
// with a sharing violation, leaving that second process's crash unlogged.
//
// `rotate_if_over` runs first, before this file's own handle exists at all
// (ADR-0039 D2): whichever file the `CreateFileW` call below opens is the one
// `install`'s later call into `register` points every crash hook at for the
// rest of the process's life. `rotation_refusal` reports the classified
// cause `install` has to act on -- see `Rotation_Refusal`'s own doc comment
// -- so `install` can log it once `register` has made `note` callable.
@(require_results)
open_log :: proc(
	dir: string,
	allocator: mem.Allocator,
) -> (
	h: Log_Handle,
	rotation_refusal: Rotation_Refusal,
	ok: bool,
) {
	assert(len(dir) > 0, "a crash log needs somewhere to be opened")
	assert(allocator.procedure != nil, "opening the crash log needs an allocator for its path")

	if os.make_directory_all(dir) != nil {
		return {}, .None, false
	}

	rotation_refusal = rotate_if_over(dir, allocator)

	path := fmt.aprintf("%s\\%s", dir, LOG_FILE_NAME, allocator = allocator)
	defer delete(path, allocator)

	wide := win32.utf8_to_utf16(path, allocator)
	defer delete(wide, allocator)
	if wide == nil {
		return {}, rotation_refusal, false
	}

	handle := win32.CreateFileW(
		win32.wstring(raw_data(wide)),
		win32.FILE_APPEND_DATA,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
		nil,
		win32.OPEN_ALWAYS,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE {
		return {}, rotation_refusal, false
	}
	return Log_Handle{file = handle}, rotation_refusal, true
}
