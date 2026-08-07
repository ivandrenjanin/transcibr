#+vet explicit-allocators
package policy

import "core:testing"

// Every fault has words of its own, checked by walking the vocabulary rather than
// by asserting inside fault_says: an assertion there fires on the first report of
// that fault, which is a build already failing in front of somebody, and a test
// that trips an assertion takes the whole runner down (issue #22). This is the
// only guard on fault_says's switch.
//
// .Nested_Too_Deep and .Not_Odin are the two faults read_source actually
// produces -- an arm compiles clean whether it returns real words or an empty
// string, and an empty arm crashes at check.odin's `make_violation`, whose
// `assert(len(message) > 0, ...)` aborts the process before the violation is
// ever reported: a source file is external input (rule A8), so what stops that
// file crashing the build is this test staying red until every arm says
// something. Issue #169 deleted `.Unreadable`, the third member this test used
// to walk: it had no producer or constructor anywhere in the tree, so the
// vocabulary now names only the faults something can actually raise.
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
