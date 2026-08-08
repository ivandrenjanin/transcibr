#+vet explicit-allocators
package policy

import "core:strings"
import "core:testing"

// Issue #235: an in-repo comment cite of an `.odin` file pins itself to a
// line number, and the very next edit to that file moves the line without
// touching the cite -- #228 measured ten stale at once, #266 measured a
// cite going stale from its OWN insertion. CLAUDE.md's Odin-notes section
// already prefers identifier cites over line numbers for `core`; this check
// carries the same rule to in-repo comments and refuses the form outright
// rather than trying to keep a line number honest.

@(test)
a_comment_citing_a_file_and_line_is_a_violation :: proc(t: ^testing.T) {
	facts := facts_of(
		t,
		PROBE + "// see other.odin:42 for the real story\nheld :: proc() {\n\treturn\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_line_number_cite_violations("probe.odin", facts, &violations)

	testing.expect_value(t, len(violations), 1)
	testing.expect_value(t, violations[0].line, 3)
}

@(test)
a_comment_with_no_odin_file_cite_is_not_a_violation :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "// nothing to see here\nheld :: proc() {\n\treturn\n}\n")
	defer facts_destroy(facts, context.allocator)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_line_number_cite_violations("probe.odin", facts, &violations)

	testing.expect_value(t, len(violations), 0)
}

// A timestamp or a version string carries digits after a colon too, and
// neither is a cite: the pattern this check refuses is specifically an
// `.odin` filename immediately followed by `:` and digits.
@(test)
a_timestamp_or_version_string_is_not_a_violation :: proc(t: ^testing.T) {
	facts := facts_of(
		t,
		PROBE +
		"// measured at 12:34:56 against release-1.2.3, dev-2026-07-nightly:819fdc7\nheld :: proc() {\n\treturn\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_line_number_cite_violations("probe.odin", facts, &violations)

	testing.expect_value(t, len(violations), 0)
}

// An identifier cite -- the form this check pushes every in-repo comment
// toward -- names the construct rather than a line, and must not itself
// trip the check.
@(test)
an_identifier_cite_is_not_a_violation :: proc(t: ^testing.T) {
	facts := facts_of(
		t,
		PROBE + "// see other.odin's `held` for the real story\nheld :: proc() {\n\treturn\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_line_number_cite_violations("probe.odin", facts, &violations)

	testing.expect_value(t, len(violations), 0)
}

// The mandated identifier form can still read `<name>.odin:` followed by
// prose rather than digits (a colon reads naturally before a clause). Fix
// round 2 finding 2: without the "at least one digit follows the colon"
// half of the guard, this exact mandated form false-reds.
@(test)
an_odin_file_colon_with_no_digits_is_not_a_violation :: proc(t: ^testing.T) {
	facts := facts_of(
		t,
		PROBE + "// see run.odin: its `held` loop bound\nheld :: proc() {\n\treturn\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_line_number_cite_violations("probe.odin", facts, &violations)

	testing.expect_value(t, len(violations), 0)
}

// A comment ABOVE a procedure is not inside a body, but a line-number cite
// there is banned exactly the same way -- this check reads every comment in
// the file, not only the ones section 0 already flags.
@(test)
a_cite_above_a_procedure_is_still_a_violation :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "// see run.odin:10\nheld :: proc() {\n\treturn\n}\n")
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.comments), 0)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_line_number_cite_violations("probe.odin", facts, &violations)

	testing.expect_value(t, len(violations), 1)
}

// #219's precedent (`collect_violations_wires_in_the_defer_order_check` in
// check_test.odin): a collector proven correct in isolation is not proven
// wired in. This asserts through `collect_violations` itself, and checks the
// message text, so unwiring this check -- or wiring in a different collector
// that happens to also report one violation -- cannot satisfy it.
@(test)
collect_violations_wires_in_the_line_number_cite_check :: proc(t: ^testing.T) {
	source := PROBE + "// see other.odin:42 for the real story\nheld :: proc() {\n\treturn\n}\n"
	facts := facts_of(t, source)
	defer facts_destroy(facts, context.allocator)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_violations("probe.odin", facts, []string{}, &violations)

	testing.expect_value(t, len(violations), 1)
	if len(violations) == 1 {
		testing.expect_value(t, violations[0].line, 3)
		testing.expect(
			t,
			strings.contains(violations[0].message, "issue #235"),
			"collect_violations must surface the line-number-cite verdict, not just some other one",
		)
	}
}
