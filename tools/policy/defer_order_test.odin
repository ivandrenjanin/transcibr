#+vet explicit-allocators
package policy

import "core:testing"

// This file checks issue #219's class: a `defer` that frees a container
// (delete/free of X) registered AFTER a `defer` that walks or derefs the
// same X in the same scope. Odin's defer runs LIFO, so the later-registered
// free fires FIRST and the walk then reads freed memory -- silently, since
// ODIN_TEST_FAIL_ON_BAD_MEMORY did not catch it on main (the #184 review).
//
// The shape below is main.odin's own #184 pair before that fix: `defer
// violations_destroy(violations, ...)` registered ahead of `defer
// delete(violations)`.

@(test)
a_walk_defer_registered_before_a_free_defer_on_the_same_identifier_is_a_violation :: proc(
	t: ^testing.T,
) {
	facts := facts_of(
		t,
		PROBE +
		"held :: proc() {\n\tviolations := check()\n\tdefer violations_destroy(violations, context.allocator)\n\tdefer delete(violations)\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.defer_order), 1)
	if len(facts.defer_order) == 1 {
		testing.expect_value(t, facts.defer_order[0].line, 5)
		testing.expect_value(t, facts.defer_order[0].walk_proc, "violations_destroy")
		testing.expect_value(t, facts.defer_order[0].free_proc, "delete")
		testing.expect_value(t, facts.defer_order[0].arg, "violations")
	}
}

// The fixed order: the free registered first, so LIFO runs the walk before
// the free -- exactly what #184's fix landed.
@(test)
a_free_defer_registered_before_a_walk_defer_is_not_a_violation :: proc(t: ^testing.T) {
	facts := facts_of(
		t,
		PROBE +
		"held :: proc() {\n\tviolations := check()\n\tdefer delete(violations)\n\tdefer violations_destroy(violations, context.allocator)\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.defer_order), 0)
}

// CLAUDE.md rule F2 mandates `defer _ = f(x)`, not `defer f(x)`, for any
// call whose procedure returns something -- so a result-carrying walk_proc
// (like remove_cache, once it gains a return value) is written in exactly
// this discard form. The check must see through it the same way it sees a
// bare call.
@(test)
a_walk_defer_written_in_the_discard_form_is_still_a_violation :: proc(t: ^testing.T) {
	facts := facts_of(
		t,
		PROBE +
		"held :: proc() {\n\tviolations := check()\n\tdefer _ = violations_destroy(violations, context.allocator)\n\tdefer delete(violations)\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.defer_order), 1)
	if len(facts.defer_order) == 1 {
		testing.expect_value(t, facts.defer_order[0].line, 5)
		testing.expect_value(t, facts.defer_order[0].walk_proc, "violations_destroy")
		testing.expect_value(t, facts.defer_order[0].free_proc, "delete")
		testing.expect_value(t, facts.defer_order[0].arg, "violations")
	}
}
