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

// Whether `trace.init` actually succeeded -- its own doc comment marks the
// result required-checking, and issue #76 review round 1 measured it
// silently discarded and false on a machine where `register` runs twice in
// one process (`--crash-drill` installs a second time over `main`'s own
// install, per `src/cli/main.odin`'s comment on that call site; SymInitialize
// fails when called again for a process already initialized). `assertion_hook`
// reads this instead of attempting a stack walk against a DbgHelp session
// that never opened.
@(private)
g_trace_ok: bool

// Set by `enter_assertion_hook`, read by nothing else -- `assertion_hook`'s
// own re-entrancy guard. `resolve_frame`'s two asserts route back through
// `context.assertion_failure_proc`, which is `assertion_hook` itself; issue
// #76 review round 2 measured a fired one recurse into 408 log lines and
// exit 127 with no guard here. Plain assignment rather than an atomic is
// enough: the hazard this closes is one thread calling back into its own
// still-running hook, not two threads racing each other into it.
@(private)
g_in_assertion_hook: bool

// Returns true the first time it is called and false on every call after
// that until the flag is reset -- extracted from `assertion_hook` so the
// guard itself can be exercised directly. Tripping the real hook crashes the
// process by design (`runtime.trap()`), so a test can reach this but not
// `assertion_hook` as a whole.
@(private)
@(require_results)
enter_assertion_hook :: proc() -> bool {
	if g_in_assertion_hook {
		return false
	}
	g_in_assertion_hook = true
	return true
}

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
	if !enter_assertion_hook() {
		runtime.trap()
	}

	record_assert_line(g_log.file, prefix, message, loc)

	runtime.print_caller_location(loc)
	runtime.print_string(" ")
	runtime.print_string(prefix)
	if len(message) > 0 {
		runtime.print_string(": ")
		runtime.print_string(message)
	}
	runtime.print_byte('\n')

	if g_trace_ok {
		buf: [64]trace.Frame
		frames := trace.frames(&g_trace, 1, buf[:])
		hProcess := win32.GetCurrentProcess()
		for f in frames {
			resolve_frame(hProcess, f)
		}
	}
	runtime.trap()
}

// Resolves one captured frame and writes it, without ever reaching an
// allocator: issue #76 review round 1 measured `core:debug/trace`'s own
// `resolve` making eight allocator calls through `context.temp_allocator` in
// this exact path (its `Frame_Location.procedure`/`.file_path` are copied out
// with `win32.wstring_to_utf8_alloc`, one `make` per string), which the
// maintainer ruling and AC4 hold this path to zero of. `SymFromAddrW`/
// `SymGetLineFromAddrW64` write into caller-owned buffers already --
// `win32.wstring_to_utf8_buf` (the buffer overload, never the allocating one)
// is what copies their UTF-16 output into `name_buf`/`file_buf` below.
@(private)
resolve_frame :: proc(hProcess: win32.HANDLE, frame: trace.Frame) {
	assert(hProcess != nil, "cannot resolve a stack frame with no process handle")
	assert(frame != 0, "cannot resolve a nil stack frame")

	data: [size_of(win32.SYMBOL_INFOW) + size_of([256]win32.WCHAR)]byte
	symbol := (^win32.SYMBOL_INFOW)(&data[0])
	symbol.SizeOfStruct = size_of(symbol^)
	symbol.MaxNameLen = 255

	procedure := ""
	name_buf: [256]byte
	if win32.SymFromAddrW(hProcess, win32.DWORD64(frame), &{}, symbol) {
		procedure = win32.wstring_to_utf8_buf(name_buf[:], cstring16(&symbol.Name[0]), -1)
	}

	line: win32.IMAGEHLP_LINE64
	line.SizeOfStruct = size_of(line)
	file_path := ""
	file_buf: [512]byte
	line_number: i32
	if win32.SymGetLineFromAddrW64(hProcess, win32.DWORD64(frame), &{}, &line) {
		file_path = win32.wstring_to_utf8_buf(file_buf[:], line.FileName, -1)
		line_number = i32(line.LineNumber)
	}

	if len(file_path) == 0 && line_number == 0 {
		return
	}
	record_stack_frame_line(g_log.file, procedure, file_path, line_number)
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
	if g_trace_ok {
		_ = trace.destroy(&g_trace)
	}
	g_trace_ok = trace.init(&g_trace)
	win32.SetUnhandledExceptionFilter(exception_filter)
}
