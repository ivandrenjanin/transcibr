#+vet explicit-allocators
package crashlog

import "core:testing"

// Issue #76 review round 2: `assertion_hook` called `resolve_frame`, which
// used a plain `assert` -- routed through `context.assertion_failure_proc`,
// which IS `assertion_hook` -- with no guard against re-entering itself.
// Mutating one of `resolve_frame`'s asserts to fire produced 408 recursive
// log lines and an exit code of 127 instead of the one located line AC2
// asks for. `enter_assertion_hook` is the guard `assertion_hook` now checks
// before doing anything else; this exercises the guard directly, since
// tripping the real hook crashes the process by design (`runtime.trap()`)
// and cannot run inside `odin test`'s own process.
@(test)
enter_assertion_hook_blocks_a_re_entrant_call :: proc(t: ^testing.T) {
	g_in_assertion_hook = false
	defer g_in_assertion_hook = false

	first := enter_assertion_hook()
	testing.expect(t, first, "the first entry into the assertion hook should be allowed")

	second := enter_assertion_hook()
	testing.expect(t, !second, "a re-entrant call into the assertion hook should be blocked")
}
