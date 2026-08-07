#+vet explicit-allocators
package crashlog

import "core:mem"

// The one call a binary's own `main` makes, once, before anything else in
// the process can assert or fault: opens the log and installs the exception
// filter (`register`). Returns `false` on an operating error (the directory
// could not be made, the file could not be opened); a caller that cannot get
// a crash log still has to decide whether to run without one, which is why
// this hands back `ok` rather than asserting.
//
// This does NOT set `context.assertion_failure_proc` -- Odin's implicit
// `context` does not propagate back out through a returning call (see
// `hooks.odin`'s `assertion_hook` doc comment), so a caller that wants
// assertion coverage writes `context.assertion_failure_proc =
// crashlog.assertion_hook` itself, immediately after this returns `true`,
// and again at the top of every worker thread it spawns.
@(require_results)
install :: proc(dir: string, allocator: mem.Allocator) -> (ok: bool) {
	assert(len(dir) > 0, "crashlog cannot be installed with nowhere to write")
	assert(allocator.procedure != nil, "opening the crash log needs an allocator for its path")

	h, opened := open_log(dir, allocator)
	if !opened {
		return false
	}
	register(h)
	return true
}
