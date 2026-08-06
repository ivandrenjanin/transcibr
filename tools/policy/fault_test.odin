#+vet explicit-allocators
package policy

import "core:testing"

// Every fault has words of its own, checked by walking the vocabulary rather than
// by asserting inside fault_says: an assertion there fires on the first report of
// that fault, which is a build already failing in front of somebody, and a test
// that trips an assertion takes the whole runner down (issue #22). This is the
// only guard on fault_says's switch.
//
// For .Nested_Too_Deep and .Not_Odin -- the two faults read_source actually
// produces -- an arm compiles clean whether it returns real words or an empty
// string, and an empty arm crashes at check.odin's `make_violation`, whose
// `assert(len(message) > 0, ...)` aborts the process before the violation is
// ever reported: a source file is external input (rule A8), so what stops that
// file crashing the build is this test staying red until every arm says
// something. .Unreadable has no producer anywhere in this package today --
// nothing calls fault_says with it -- so for that member this test is a guard
// against a caller that reaches it in the future, not against a reachable
// crash now.
@(test)
every_fault_says_something_of_its_own :: proc(t: ^testing.T) {
	seen: [dynamic]string
	defer delete(seen)

	for fault in Fault {
		if fault == .None {
			continue
		}
		says := fault_says(fault)
		testing.expect(t, len(says) > 0, "a fault with no words for it")
		for already in seen {
			testing.expect(t, already != says, "two faults say exactly the same thing")
		}
		append(&seen, says)
	}
	testing.expect_value(t, len(seen), len(Fault) - 1)
}
