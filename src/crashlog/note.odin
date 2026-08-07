#+vet explicit-allocators
package crashlog

import win32 "core:sys/windows"

// The three severities a routine trail line can carry (ADR-0039 D1). `enum
// u8`, not the bare `int` a first draft would reach for: this value crosses
// into `record_note_line`'s own caller-owned stack buffer the same way a
// `Job_ID` crosses a storage edge, and a fixed one-byte width is what T1
// asks for anywhere a value's shape is part of its contract rather than an
// implementation detail.
Level :: enum u8 {
	Info,
	Warn,
	Error,
}

// Maps a `Level` to the word `record_note_line` writes. An exhaustive
// `switch` over three members, not a `[Level]string` table -- CLAUDE.md's
// enumerated-array note: a fourth severity added to `Level` fails this
// build outright until this switch names its own word, where a table would
// silently grow a blank row instead.
@(private)
@(require_results)
level_name :: proc "contextless" (level: Level) -> string {
	switch level {
	case .Info:
		return "INFO"
	case .Warn:
		return "WARN"
	case .Error:
		return "ERROR"
	}
	return ""
}

// `crashlog`'s one entry point for the non-crash operational trail
// (ADR-0039 D1): a fourth caller of the writer the two crash hooks already
// use, `"contextless"` and allocation-free like every other call into it so
// it stays safely callable from anywhere in the process that already
// reaches `g_log` -- though every real caller today (`src/cli`) has a
// context of its own. Best-effort, like the crash path's own writes: called
// before `install` has run, or once a log could not be opened, it is a
// silent no-op rather than an assertion -- an unopened log is an operating
// error `main` already decided how to tolerate at startup (ADR-0036), not a
// programmer error at every one of `note`'s call sites downstream of it.
note :: proc "contextless" (level: Level, subject, detail: string) {
	if g_log.file == nil || g_log.file == win32.INVALID_HANDLE_VALUE {
		return
	}

	ft: win32.FILETIME
	win32.GetSystemTimeAsFileTime(&ft)
	buf: [20]byte
	stamp := format_timestamp(buf[:], ft)

	record_note_line(g_log.file, stamp, level, subject, detail)
}
