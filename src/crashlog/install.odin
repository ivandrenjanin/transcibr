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
//
// A refused rotation (ADR-0039 D2) is logged here, immediately after
// `register`, rather than inside `open_log` itself: `note` writes through
// `g_log`, and `g_log` is not set until `register` runs, so `open_log`
// cannot call it -- the refusal fact leaves `open_log` as a second result
// instead, and this is the one place downstream of `register` that can
// finally report it. The wording per cause is `Rotation_Refusal`'s own
// concern (see `rotate.odin`); this switch only decides whether to warn.
@(require_results)
install :: proc(dir: string, allocator: mem.Allocator) -> (ok: bool) {
	assert(len(dir) > 0, "crashlog cannot be installed with nowhere to write")
	assert(allocator.procedure != nil, "opening the crash log needs an allocator for its path")

	h, refusal, opened := open_log(dir, allocator)
	if !opened {
		return false
	}
	register(h)
	switch refusal {
	case .None:
	case .Second_Opener:
		note(.Warn, "rotation refused", "a second process holds transcibr.log open")
	case .Unknown:
		note(.Warn, "rotation refused", "the previous transcibr.log could not be rotated")
	}
	return true
}
