#+vet explicit-allocators
package crashlog

import "base:runtime"
import "core:debug/trace"
import win32 "core:sys/windows"

// Initialized once, by `register`, and read only from `assertion_hook` on
// whichever thread is failing -- `core:debug/trace`'s own doc example shares
// one `Context` the same way. Never destroyed: nothing here runs after the
// process this was installed in has exited.
@(private)
g_trace: trace.Context

// `context.assertion_failure_proc`'s replacement. Odin's implicit `context`
// does not propagate back out of a call that returns -- only forward, into
// what a scope calls next -- so `context.assertion_failure_proc =
// crashlog.assertion_hook` has to be written at every site that needs it
// (process start, and every S3 context rebuild) rather than folded into
// `install` or `register`; a helper that set it on the caller's behalf would
// set it on its OWN, now-discarded copy of the context and nothing would
// change for the caller once that helper returned. `assert`, `ensure`,
// `panic`, `unimplemented` and a context-carrying failed type assert all
// reach here once it is; `assert_contextless`/`panic_contextless` and a
// bounds or slice check do not (they raise SEH `0xC000008C` directly, which
// `exception_filter` below is what catches). The stderr lines mirror
// `runtime.default_assertion_contextless_failure_proc` so a console still
// reads the same thing it always did; the log line is the one story 51 asks
// for. Stack symbolization follows `core:debug/trace`'s own doc example
// exactly -- it degrades to nothing on a non-`-debug` build rather than
// failing, per that package's own doc comment.
assertion_hook :: proc(prefix, message: string, loc: runtime.Source_Code_Location) -> ! {
	record_assert_line(g_log.file, prefix, message, loc)

	runtime.print_caller_location(loc)
	runtime.print_string(" ")
	runtime.print_string(prefix)
	if len(message) > 0 {
		runtime.print_string(": ")
		runtime.print_string(message)
	}
	runtime.print_byte('\n')

	if !trace.in_resolve(&g_trace) {
		buf: [64]trace.Frame
		frames := trace.frames(&g_trace, 1, buf[:])
		for f in frames {
			fl := trace.resolve(&g_trace, f, context.temp_allocator)
			if fl.loc.file_path == "" && fl.loc.line == 0 {
				continue
			}
			record_assert_line(g_log.file, "stack frame", "", fl.loc)
		}
	}
	runtime.trap()
}

// The bounds/slice-check path: `base:runtime`'s own `bounds_check_error` and
// `slice_handle_error` print contextlessly to stderr and then call
// `RaiseException(EXCEPTION_ARRAY_BOUNDS_EXCEEDED, ...)` directly, never
// touching `context.assertion_failure_proc`. `SetUnhandledExceptionFilter`
// is the only hook that ever sees that. `"system"`, no context, and every
// call inside `record_exception_line` is `"contextless"` (rule S3).
@(private)
@(require_results)
exception_filter :: proc "system" (info: ^win32.EXCEPTION_POINTERS) -> win32.LONG {
	record_exception_line(g_log.file, info)
	return win32.EXCEPTION_CONTINUE_SEARCH
}

// Points `assertion_hook`/`exception_filter` at `h` and installs the one hook
// that IS process-wide rather than per-context: `SetUnhandledExceptionFilter`
// is real global OS state, so a helper setting it on the caller's behalf works
// fine, unlike `context.assertion_failure_proc` above. `h` must already be
// open -- `install` is the caller that opens one and hands it here -- because
// this procedure itself must not allocate: opening a file is exactly the
// kind of call the maintainer ruling keeps out of the hooks' own path.
register :: proc(h: Log_Handle) {
	assert(handle_is_open(h), "cannot register crash hooks with no open log handle")

	g_log = h
	_ = trace.init(&g_trace)
	win32.SetUnhandledExceptionFilter(exception_filter)
}
