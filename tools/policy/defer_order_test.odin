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

// A `switch` case clause holds its statements directly in `body: []^Stmt`
// (core/odin/ast/ast.odin's Case_Clause), with no intervening Block_Stmt --
// so a walk/free pair registered directly under a case clause, never inside
// a nested block of its own, must still be read as a scope.
@(test)
a_walk_defer_registered_before_a_free_defer_inside_a_switch_case_is_a_violation :: proc(
	t: ^testing.T,
) {
	facts := facts_of(
		t,
		PROBE +
		"held :: proc(n: int) {\n\tviolations := check()\n\tswitch n {\n\tcase 1:\n\t\tdefer violations_destroy(violations, context.allocator)\n\t\tdefer delete(violations)\n\t}\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.defer_order), 1)
	if len(facts.defer_order) == 1 {
		testing.expect_value(t, facts.defer_order[0].line, 7)
		testing.expect_value(t, facts.defer_order[0].walk_proc, "violations_destroy")
		testing.expect_value(t, facts.defer_order[0].free_proc, "delete")
		testing.expect_value(t, facts.defer_order[0].arg, "violations")
	}
}

// Issue #246's probed-live residual: a walk defer in the OUTER scope beside a
// free defer in a NESTED block on the same identifier. Odin's defers are
// scoped to the block that registers them, so the nested block's `defer
// delete(violations)` fires when that block exits -- strictly before the
// enclosing procedure exits and runs the outer `defer walk(violations)` on
// what is by then freed memory. collect_defer_order_issues pairs a scope's
// own direct statements only (note_stmt_list_defers reads one []^ast.Stmt at
// a time), so the outer defer and the nested block's defer are never read as
// one scope and this real inversion goes unreported. This test PINS that gap
// rather than closing it -- see collect_defer_order_issues's own doc comment
// for why (issue #246 recorded the residual rather than extending the
// check): the day this starts reporting an issue, this test goes red and
// the doc comment must move with it.
@(test)
a_walk_defer_in_an_outer_scope_beside_a_free_defer_in_a_nested_block_is_not_caught :: proc(
	t: ^testing.T,
) {
	facts := facts_of(
		t,
		PROBE +
		"held :: proc(n: int) {\n\tviolations := check()\n\tdefer walk(violations)\n\tif n > 0 {\n\t\tdefer delete(violations)\n\t}\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.defer_order), 0)
}

// A second silent category, distinct from the cross-scope one above: a free
// registered through anything other than the two builtins is_freeing_call
// matches by name, `delete` and `free`. A wrapper that itself frees its
// argument -- `violations_release`, say -- reads as just another WALK to
// this check, so a walk defer registered ahead of it is never paired at all
// and the same LIFO inversion goes unreported. Naming every project's own
// free-like wrapper would need resolving what a call actually does, the
// second model of the code ADR-0028 keeps this program from building, so
// this is recorded rather than chased.
@(test)
a_free_registered_through_a_procedure_not_named_delete_or_free_is_not_caught :: proc(
	t: ^testing.T,
) {
	facts := facts_of(
		t,
		PROBE +
		"held :: proc() {\n\tviolations := check()\n\tdefer walk(violations)\n\tdefer violations_release(violations)\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.defer_order), 0)
}

// Issue #281 item 1: two `defer delete(x)` on the same identifier, in the
// same scope. This is a genuine double free -- LIFO runs both, and the
// second one frees memory the first already freed -- but is_freeing_call
// short-circuited the outer loop before this fix, so a free was never
// considered as the EARLIER half of a pair (the #281 review's PROBE-F
// measured 0 issues for exactly this shape).
@(test)
two_defer_deletes_on_the_same_identifier_in_one_scope_is_a_violation :: proc(t: ^testing.T) {
	facts := facts_of(
		t,
		PROBE +
		"held :: proc() {\n\tviolations := check()\n\tdefer delete(violations)\n\tdefer delete(violations)\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.defer_order), 1)
	if len(facts.defer_order) == 1 {
		testing.expect_value(t, facts.defer_order[0].line, 5)
		testing.expect_value(t, facts.defer_order[0].walk_proc, "delete")
		testing.expect_value(t, facts.defer_order[0].free_proc, "delete")
		testing.expect_value(t, facts.defer_order[0].arg, "violations")
	}
}

// Issue #281 item 2: the #246 review's PROBE-A shape, committed. Both
// halves of a walk/free pair sitting inside one nested non-case Block_Stmt
// (an `if` body here) is already read as its own scope by
// note_defer_order_node -- descent carries on into a nested Block_Stmt the
// same way it does into a Case_Clause -- but no committed test exercised the
// positive before this one.
@(test)
a_walk_defer_and_a_free_defer_both_inside_a_nested_if_block_is_a_violation :: proc(t: ^testing.T) {
	facts := facts_of(
		t,
		PROBE +
		"held :: proc(n: int) {\n\tif n > 0 {\n\t\tviolations := check()\n\t\tdefer violations_destroy(violations, context.allocator)\n\t\tdefer delete(violations)\n\t}\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.defer_order), 1)
	if len(facts.defer_order) == 1 {
		testing.expect_value(t, facts.defer_order[0].line, 6)
		testing.expect_value(t, facts.defer_order[0].walk_proc, "violations_destroy")
		testing.expect_value(t, facts.defer_order[0].free_proc, "delete")
		testing.expect_value(t, facts.defer_order[0].arg, "violations")
	}
}
