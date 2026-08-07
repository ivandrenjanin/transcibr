#+vet explicit-allocators
package policy

import "core:mem"
import "core:strings"
import "core:testing"

// This file checks the verdicts check.odin computes from Source_Facts: the
// five things that, before issue #152's justfile migration, were computed by
// scripts\common.ps1's Assert-Odin* procedures from this program's own
// report -- now computed here directly.

@(require_results)
long_body :: proc(lines: int, allocator: mem.Allocator) -> string {
	assert(lines > 0, "asked for a body with no lines in it at all")
	into := strings.builder_make(allocator)
	strings.write_string(&into, PROBE)
	strings.write_string(&into, "held :: proc() {\n")
	for _ in 0 ..< lines {
		strings.write_string(&into, "\tx := 1\n")
	}
	strings.write_string(&into, "}\n")
	return strings.to_string(into)
}

@(test)
a_procedure_at_the_line_limit_is_not_a_violation :: proc(t: ^testing.T) {
	src := long_body(MAX_PROCEDURE_LINES - 2, context.allocator)
	defer delete(src, context.allocator)
	facts := facts_of(t, src)
	defer facts_destroy(facts, context.allocator)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_length_violations("probe.odin", facts, &violations)

	testing.expect_value(t, len(violations), 0)
}

@(test)
a_procedure_over_the_line_limit_is_a_violation :: proc(t: ^testing.T) {
	src := long_body(MAX_PROCEDURE_LINES, context.allocator)
	defer delete(src, context.allocator)
	facts := facts_of(t, src)
	defer facts_destroy(facts, context.allocator)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_length_violations("probe.odin", facts, &violations)

	testing.expect_value(t, len(violations), 1)
	testing.expect_value(t, violations[0].file, "probe.odin")
	testing.expect_value(t, violations[0].line, 3)
}

@(test)
a_body_comment_is_a_violation :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "held :: proc() {\n\t// banned\n}\n")
	defer facts_destroy(facts, context.allocator)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_comment_violations("probe.odin", facts, &violations)

	testing.expect_value(t, len(violations), 1)
	testing.expect_value(t, violations[0].line, 4)
}

@(test)
a_returning_procedure_with_no_attribute_is_a_violation :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "answers :: proc() -> bool {\n\treturn true\n}\n")
	defer facts_destroy(facts, context.allocator)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_result_violations("probe.odin", facts, &violations)

	testing.expect_value(t, len(violations), 1)
}

@(test)
an_annotated_returning_procedure_is_not_a_violation :: proc(t: ^testing.T) {
	facts := facts_of(
		t,
		PROBE + "@(require_results)\nanswers :: proc() -> bool {\n\treturn true\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_result_violations("probe.odin", facts, &violations)

	testing.expect_value(t, len(violations), 0)
}

@(test)
a_file_missing_a_required_vet_tag_is_a_violation :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "held :: proc() {\n}\n")
	defer facts_destroy(facts, context.allocator)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	required := required_vet_tags(vet_tag_roster, context.allocator)
	defer delete(required, context.allocator)
	collect_vet_tag_violations("probe.odin", facts, required, &violations)

	testing.expect_value(t, len(violations), 1)
}

@(test)
a_file_declaring_its_required_tags_is_not_a_violation :: proc(t: ^testing.T) {
	source := "#+vet explicit-allocators\npackage probe\n\nheld :: proc() {\n}\n"
	facts := facts_of(t, source)
	defer facts_destroy(facts, context.allocator)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	required := required_vet_tags(vet_tag_roster, context.allocator)
	defer delete(required, context.allocator)
	collect_vet_tag_violations("probe.odin", facts, required, &violations)

	testing.expect_value(t, len(violations), 0)
}

@(test)
a_remove_all_call_is_a_violation :: proc(t: ^testing.T) {
	source := PROBE + "import \"core:os\"\n\nheld :: proc() {\n\tos.remove_all(\"x\")\n}\n"
	facts := facts_of(t, source)
	defer facts_destroy(facts, context.allocator)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_remove_all_violations("probe.odin", facts, &violations)

	testing.expect_value(t, len(violations), 1)
}

@(test)
a_defer_order_issue_is_a_violation :: proc(t: ^testing.T) {
	source :=
		PROBE +
		"held :: proc() {\n\tviolations := check()\n\tdefer violations_destroy(violations, context.allocator)\n\tdefer delete(violations)\n}\n"
	facts := facts_of(t, source)
	defer facts_destroy(facts, context.allocator)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_defer_order_violations("probe.odin", facts, &violations)

	testing.expect_value(t, len(violations), 1)
	testing.expect_value(t, violations[0].line, 5)
}

@(test)
network_code_outside_the_one_allowed_file_is_a_violation :: proc(t: ^testing.T) {
	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_network_violations("src/child/child.odin", "WinHttpOpen()", &violations)

	testing.expect_value(t, len(violations), 1)
}

@(test)
network_code_in_the_one_allowed_file_is_not_a_violation :: proc(t: ^testing.T) {
	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_network_violations("src/net/winhttp.odin", "WinHttpOpen()", &violations)

	testing.expect_value(t, len(violations), 0)
}

@(test)
network_code_outside_src_is_not_a_violation :: proc(t: ^testing.T) {
	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	collect_network_violations(
		"docs/reference/winhttp-download.odin",
		"WinHttpOpen()",
		&violations,
	)

	testing.expect_value(t, len(violations), 0)
}
