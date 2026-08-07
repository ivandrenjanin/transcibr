#+vet explicit-allocators
// Package crashlog is the on-disk crash log and the two Windows crash hooks
// spec stories 50 and 51 ask for, and no more than they ask for: no network
// path exists anywhere in this package (story 57), and no procedure here
// writes a non-crash line -- nothing in this package rotates or bounds the
// file either, since nothing here grows it outside a crash (docs/adr/0036's
// "What this build deliberately does not do"). Issue #76's maintainer
// ruling is the design: `context.assertion_failure_proc`, reinstalled at
// every S3 context rebuild, for `assert`/`ensure`/`panic`; a process-wide
// `SetUnhandledExceptionFilter` for the bounds/slice-check path that bypasses
// it (`base:runtime`'s `bounds_check_error` prints contextlessly and raises
// SEH `0xC000008C` directly, never touching `assertion_failure_proc` at
// all). See `docs/adr/0036-...md` for why this package writes its own thin,
// non-allocating line writer instead of putting `core:log.create_file_logger`
// on `context.logger`.
//
// `install` is the one entry point a binary's own `main` calls, once, before
// anything else can assert or fault. There is no reinstall procedure to call
// from a freshly spawned worker thread: `core:thread` hands a new thread a
// context built from scratch, and `context.assertion_failure_proc` is a
// field of that context rather than a process-wide setting the way the
// exception filter is, so a worker thread instead writes
// `context.assertion_failure_proc = crashlog.assertion_hook` itself, inline,
// the same one line `install`'s own caller writes (see `hooks.odin`'s
// `assertion_hook` doc comment for why this cannot be folded into a helper).
//
// `open_log`/`close_log` and the format helpers are split out from
// `install`/`register` on purpose: they touch no global state and can be
// exercised directly from a test running inside `odin test`'s own process,
// where calling `register` would leave that process's
// `SetUnhandledExceptionFilter` pointed at a handle the test then closes.
// Measuring the two hooks themselves needs a process this package's own
// tests do not run inside -- `crashlog_crash_test.odin` spawns one
// (`transcibr:child`), a debug build of `transcibr-cli` carrying a hidden
// `--crash-drill` mode, and reads back what it left in the log.
package crashlog

import win32 "core:sys/windows"

Log_Handle :: struct {
	file: win32.HANDLE,
}

// Set once, by `register`, and read by the two hooks below -- neither of
// which can be handed a handle as an argument, because their signatures are
// fixed by `context.assertion_failure_proc` and `SetUnhandledExceptionFilter`
// respectively.
@(private)
g_log: Log_Handle

@(require_results)
handle_is_open :: proc(h: Log_Handle) -> bool {
	return h.file != nil && h.file != win32.INVALID_HANDLE_VALUE
}

close_log :: proc(h: ^Log_Handle) {
	assert(h != nil, "there is no log handle here to close")

	if handle_is_open(h^) {
		win32.CloseHandle(h.file)
	}
	h.file = nil
}
