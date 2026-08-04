#+vet explicit-allocators
package policy

import "core:mem"
import "core:strings"
import "core:testing"

// This file checks the report scripts\common.ps1 reads back: one record per line,
// tab-separated, a `file` record opening the block every record after it belongs
// to. What is pinned here is the SHAPE, because the reader on the other side of
// it is in another language and cannot be type-checked against this one.

@(require_results)
rendered :: proc(name: string, facts: Source_Facts, allocator: mem.Allocator) -> string {
	into := strings.builder_make(allocator)
	render_file(name, &into)
	render_facts(facts, &into)
	return strings.to_string(into)
}

@(test)
a_report_opens_a_block_with_the_file_its_records_belong_to :: proc(t: ^testing.T) {
	facts := facts_of(
		t,
		PROBE + "@(require_results)\nanswers :: proc() -> bool {\n\treturn true\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	report := rendered("src/probe.odin", facts, context.allocator)
	defer delete(report, context.allocator)

	testing.expect(
		t,
		strings.has_prefix(report, "file\tsrc/probe.odin\n"),
		"the report does not open with the file its records belong to",
	)
	testing.expect(
		t,
		strings.contains(report, "proc\tanswers\t4\t6\t1\t1\t1\n"),
		"the report does not carry the procedure it read",
	)
}

@(test)
a_report_carries_every_body_comment_and_every_vet_tag :: proc(t: ^testing.T) {
	source := "#+vet explicit-allocators\npackage probe\n\nheld :: proc() {\n\t// banned\n}\n"
	facts := facts_of(t, source)
	defer facts_destroy(facts, context.allocator)

	report := rendered("src/probe.odin", facts, context.allocator)
	defer delete(report, context.allocator)

	testing.expect(
		t,
		strings.contains(report, "comment\t5\theld\t// banned\n"),
		"the report does not carry the body comment it read",
	)
	testing.expect(
		t,
		strings.contains(report, "tag\texplicit-allocators\n"),
		"the report does not carry the vet tag it read",
	)
}

// A refused file renders its fault and NOTHING else. A reader meeting a `file`
// record with no records after it and no fault between them would read a refusal
// as a file with nothing in it, which is the silence this program exists to end.
@(test)
a_refused_file_reports_its_fault_and_no_facts :: proc(t: ^testing.T) {
	report := rendered("src/probe.odin", Source_Facts{fault = .Unreadable}, context.allocator)
	defer delete(report, context.allocator)

	testing.expect_value(
		t,
		report,
		"file\tsrc/probe.odin\nfault\tUnreadable\tcannot be read at all\n",
	)
}

// Every fault has words of its own, checked by walking the vocabulary rather than
// by asserting inside the renderer: an assertion there fires on the first report
// of that fault, which is a build already failing in front of somebody, and a
// test that trips an assertion takes the whole runner down (issue #22).
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
