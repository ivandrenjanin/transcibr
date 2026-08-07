#+vet explicit-allocators
package crashlog

import "base:runtime"
import win32 "core:sys/windows"

// One line: "<file>(<line>) <prefix>: <message>\n", matching the order
// `runtime.default_assertion_contextless_failure_proc` already prints to
// stderr, so a line in this log and a line on a console read the same way.
// Contextless and allocation-free like everything else in this file --
// `raw_write.odin`'s explanation is why.
@(private)
record_assert_line :: proc "contextless" (
	h: win32.HANDLE,
	prefix, message: string,
	loc: runtime.Source_Code_Location,
) {
	write_str(h, loc.file_path)
	write_str(h, "(")
	buf: [20]byte
	write_str(h, format_int(buf[:], i64(loc.line)))
	write_str(h, ") ")
	write_str(h, prefix)
	if len(message) > 0 {
		write_str(h, ": ")
		write_str(h, message)
	}
	write_str(h, "\n")
}

// One line: "stack frame: <procedure> <file>(<line>)\n" for a symbolized
// frame `hooks.odin`'s `resolve_frame` resolved without allocating. Empty
// `procedure`/`file_path` print as empty spans rather than being special-
// cased -- `resolve_frame` already refuses to call this at all when both
// `file_path` and `line` came back empty.
@(private)
record_stack_frame_line :: proc "contextless" (
	h: win32.HANDLE,
	procedure, file_path: string,
	line: i32,
) {
	write_str(h, "stack frame: ")
	write_str(h, procedure)
	write_str(h, " ")
	write_str(h, file_path)
	write_str(h, "(")
	buf: [20]byte
	write_str(h, format_int(buf[:], i64(line)))
	write_str(h, ")\n")
}

// One line: "CRASH exception=0x.. address=0x..\n" -- the exception code and
// faulting address are the two fields `EXCEPTION_POINTERS` carries that
// identify what happened without symbolizing anything, which the exception
// filter must not attempt (CLAUDE.md's Windows notes: DbgHelp is
// single-threaded and the filter runs with no promise the heap is intact).
@(private)
record_exception_line :: proc "contextless" (h: win32.HANDLE, info: ^win32.EXCEPTION_POINTERS) {
	runtime.assert_contextless(
		info != nil,
		"windows delivered an unhandled exception with no info block",
	)
	runtime.assert_contextless(
		info.ExceptionRecord != nil,
		"an exception with no exception record reached the filter",
	)

	write_str(h, "CRASH exception=")
	code_buf: [20]byte
	write_str(h, format_hex(code_buf[:], u64(info.ExceptionRecord.ExceptionCode)))
	write_str(h, " address=")
	addr_buf: [20]byte
	write_str(h, format_hex(addr_buf[:], u64(uintptr(info.ExceptionRecord.ExceptionAddress))))
	write_str(h, "\n")
}

// One line: "<timestamp> <LEVEL> <subject>: <detail>\n", or with no
// trailing ": <detail>" at all when `detail` is empty -- the fourth line
// shape (ADR-0039 D1), reached only from `crashlog.note` (`note.odin`)
// rather than either crash hook. Built from the same `write_str`/
// `format_int`/`format_hex`-family, multi-write, contextless discipline as
// the three shapes above; `stamp` arrives pre-formatted because
// `format_timestamp` (`raw_write.odin`) needs its own caller-owned buffer,
// which is `note`'s stack and not this procedure's. A4: asserts the same
// non-empty-`subject` precondition `note` asserts on entry, again here on
// the write side -- `record_note_line` is `@(private)` but not unreachable
// from a caller inside this package that skips `note`.
@(private)
record_note_line :: proc "contextless" (
	h: win32.HANDLE,
	stamp: string,
	level: Level,
	subject, detail: string,
) {
	runtime.assert_contextless(len(subject) > 0, "a routine trail line must name a subject")

	write_str(h, stamp)
	write_str(h, " ")
	write_str(h, level_name(level))
	write_str(h, " ")
	write_str(h, subject)
	if len(detail) > 0 {
		write_str(h, ": ")
		write_str(h, detail)
	}
	write_str(h, "\n")
}
