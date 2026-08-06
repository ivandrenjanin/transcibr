#+vet explicit-allocators
package policy

import "core:strings"
import "core:testing"

// Every fault has words of its own, checked by walking the vocabulary rather than
// by asserting inside fault_says: an assertion there fires on the first report of
// that fault, which is a build already failing in front of somebody, and a test
// that trips an assertion takes the whole runner down (issue #22). This is the
// only guard on fault_says's switch: an arm compiles clean whether it returns real
// words or an empty string, and an empty arm crashes at check.odin's
// `make_violation`, whose `assert(len(message) > 0, ...)` aborts the process
// before the violation is ever reported -- a source file is external input (rule
// A8), so what stops that file crashing the build is this test staying red until
// every arm says something.
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

// This file checks what a procedure is: where one begins and ends, whether it
// hands anything back, and whether the attribute rule F2 demands sits above it.
// comments_test.odin covers section 0 and tags_test.odin covers rule M2.
//
// Every fixture is a string literal rather than a file on a disk, which is the
// whole point of reading Odin with Odin: the shapes these rules turn on --
// a procedure type, a `where` clause, a raw string holding a `}` at column 0,
// an attribute quoted inside one -- were probes in a PowerShell suite that had
// to plant a repository to ask about each of them.

// What every fixture opens with, so a declaration below it starts on line 3.
PROBE :: "package probe\n\n"

@(require_results)
facts_of :: proc(t: ^testing.T, src: string) -> Source_Facts {
	facts := read_source("probe.odin", src, context.allocator)
	testing.expect_value(t, facts.fault, Fault.None)
	return facts
}

@(require_results)
one_procedure :: proc(t: ^testing.T, facts: Source_Facts) -> Procedure {
	testing.expect_value(t, len(facts.procedures), 1)
	if len(facts.procedures) != 1 {
		return {}
	}
	return facts.procedures[0]
}

@(require_results)
procedure_named :: proc(facts: Source_Facts, name: string) -> (found: Procedure, is_there: bool) {
	for procedure in facts.procedures {
		if procedure.name == name {
			return procedure, true
		}
	}
	return {}, false
}

@(test)
a_returning_procedure_is_read_with_its_span :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "answers :: proc(x: int) -> bool {\n\treturn x > 0\n}\n")
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.name, "answers")
	testing.expect_value(t, found.declared_at, 3)
	testing.expect_value(t, found.body_ends, 5)
	testing.expect_value(t, found.returns, true)
	testing.expect_value(t, found.annotated, false)
	testing.expect_value(t, found.attributable, true)
}

// A procedure TYPE has no body, so every question the policies ask about one is
// unanswerable: no length for rule F1, no lines for section 0, and the compiler
// REFUSES @(require_results) on it -- `Unknown attribute element name` -- so a
// demand for the attribute there is a build nobody can make pass.
@(test)
a_procedure_type_is_not_a_procedure_with_a_body :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "Fault_Says :: proc(fault: int) -> string\n")
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.procedures), 0)
}

// The shape src\process\command_line.odin and src\transcript\engine_json.odin
// carry: a fault-facts signature above a `:=` table. The column-zero scan walked
// past the table's own `:=` looking for a closing brace and stopped at the
// table's, handing all three checks a procedure eight lines long that never
// existed.
@(test)
a_procedure_type_above_a_table_leaves_the_table_alone :: proc(t: ^testing.T) {
	shape :=
		PROBE +
		"Fault_Says :: proc(fault: int) -> string\n\n" +
		"FAULT := [2]string {\n\t\"a\",\n\t\"b\",\n}\n"
	facts := facts_of(t, shape)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.procedures), 0)
}

// A `where` clause is what odinfmt puts between a complete signature and its
// brace, and it needed a special case in the header reader that replaced this.
// Here there is no header reader to teach.
@(test)
a_where_clause_needs_no_special_case :: proc(t: ^testing.T) {
	clause :=
		PROBE +
		"adds :: proc(a: $T, b: T) -> T\n" +
		"\twhere intrinsics.type_is_numeric(T) {\n" +
		"\treturn a + b\n}\n"
	facts := facts_of(t, clause)
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.name, "adds")
	testing.expect_value(t, found.declared_at, 3)
	testing.expect_value(t, found.body_ends, 6)
	testing.expect_value(t, found.returns, true)
}

@(test)
a_where_clause_over_two_lines_is_still_one_procedure :: proc(t: ^testing.T) {
	listed :=
		PROBE +
		"adds :: proc(a: $T, b: T) -> T\n" +
		"\twhere intrinsics.type_is_numeric(T),\n" +
		"\t\tintrinsics.type_is_ordered(T) {\n" +
		"\treturn a + b\n}\n"
	facts := facts_of(t, listed)
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.name, "adds")
	testing.expect_value(t, found.returns, true)
}

// What odinfmt writes for anything wide, which is most of this repository's
// returning procedures.
@(test)
a_wrapped_header_is_one_procedure :: proc(t: ^testing.T) {
	wrapped :=
		PROBE +
		"wide :: proc(\n\ta: int,\n\tb: int,\n) -> (\n\tsum: int,\n\tok: bool,\n) {\n" +
		"\treturn a + b, true\n}\n"
	facts := facts_of(t, wrapped)
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.name, "wide")
	testing.expect_value(t, found.declared_at, 3)
	testing.expect_value(t, found.body_ends, 11)
	testing.expect_value(t, found.returns, true)
}

// The only `->` here belongs to a PARAMETER that is itself a procedure, one level
// in, and the procedure declared hands back nothing at all.
@(test)
a_procedure_typed_parameter_does_not_make_its_owner_return :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "takes :: proc(cb: proc(x: int) -> int) {\n\t_ = cb\n}\n")
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.name, "takes")
	testing.expect_value(t, found.returns, false)
}

@(test)
the_parenthesised_attribute_is_read :: proc(t: ^testing.T) {
	stacked :=
		PROBE + "@(private)\n@(require_results)\nanswers :: proc() -> bool {\n\treturn true\n}\n"
	facts := facts_of(t, stacked)
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.annotated, true)
	testing.expect_value(t, found.declared_at, 5)
}

// The spelling the compiler's own core\odin\parser\file_tags.odin writes. odinfmt
// rewrites it to the parenthesised form and runs first, so a reader that knew one
// spelling would be right only about files that had been formatted.
@(test)
the_bare_attribute_spelling_is_read :: proc(t: ^testing.T) {
	facts := facts_of(
		t,
		PROBE + "@require_results\nanswers :: proc() -> bool {\n\treturn true\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.annotated, true)
}

// The comment a procedure is ALLOWED, sitting where this repository puts it:
// between the attribute and the declaration. A reader that stopped at the first
// non-attribute line reported this as bare, in a message telling somebody to put
// the attribute where it already was.
@(test)
an_attribute_above_a_comment_above_the_declaration_is_read :: proc(t: ^testing.T) {
	explained :=
		PROBE +
		"@(require_results)\n// why this exists\nanswers :: proc() -> bool {\n\treturn true\n}\n"
	facts := facts_of(t, explained)
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.annotated, true)
}

@(test)
an_attribute_above_a_block_comment_is_read :: proc(t: ^testing.T) {
	explained :=
		PROBE +
		"@(require_results)\n/* why this exists\n   over two lines */\n" +
		"answers :: proc() -> bool {\n\treturn true\n}\n"
	facts := facts_of(t, explained)
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.annotated, true)
}

// An attribute that is really text inside a raw string. This repository writes
// raw strings holding whatever somebody said, and a reader fooled by one credits
// an attribute nobody wrote.
@(test)
an_attribute_inside_a_raw_string_is_not_an_attribute :: proc(t: ^testing.T) {
	quoted :=
		PROBE +
		"TEXT :: `\n@(require_results)\n`\n" +
		"answers :: proc() -> bool {\n\treturn true\n}\n"
	facts := facts_of(t, quoted)
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.name, "answers")
	testing.expect_value(t, found.annotated, false)
}

// A comment with no attribute anywhere above it is still bare.
@(test)
a_comment_with_no_attribute_above_it_leaves_a_procedure_bare :: proc(t: ^testing.T) {
	facts := facts_of(
		t,
		PROBE + "// why this exists\nanswers :: proc() -> bool {\n\treturn true\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.annotated, false)
	testing.expect_value(t, found.returns, true)
}

// A procedure with no results, which rule F2 must never name: the compiler
// refuses the attribute there outright, so a false positive is a demand the
// toolchain will not let anybody satisfy.
@(test)
a_procedure_that_hands_back_nothing_does_not_return :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "shouts :: proc(x: int) {\n\t_ = x\n}\n")
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.returns, false)
	testing.expect_value(t, found.attributable, true)
}

// The row the column-zero scan could not reach at all: a procedure declared
// inside a `when` block was refused outright by a guard, because neither its
// length nor its comments could be seen. Issue #53.
@(test)
a_procedure_declared_indented_is_measured_rather_than_refused :: proc(t: ^testing.T) {
	hidden :=
		PROBE +
		"when ODIN_OS == .Windows {\n" +
		"\t@(require_results)\n\thelper :: proc() -> bool {\n\t\treturn true\n\t}\n}\n"
	facts := facts_of(t, hidden)
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.name, "helper")
	testing.expect_value(t, found.declared_at, 5)
	testing.expect_value(t, found.body_ends, 7)
	testing.expect_value(t, found.returns, true)
	testing.expect_value(t, found.annotated, true)
	testing.expect_value(t, found.attributable, true)
}

@(test)
a_procedure_nested_in_another_body_is_measured :: proc(t: ^testing.T) {
	nested := PROBE + "outer :: proc() {\n\tinner :: proc() {\n\t\treturn\n\t}\n\tinner()\n}\n"
	facts := facts_of(t, nested)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.procedures), 2)
	inner, is_there := procedure_named(facts, "inner")
	testing.expect(t, is_there, "a procedure declared inside another body was not measured")
	testing.expect_value(t, inner.declared_at, 4)
	testing.expect_value(t, inner.body_ends, 6)
}

// Issue #52: a body that opens and whose column-0 `}` never arrives was DROPPED
// by the scan that read this before, and a dropped procedure is the same green as
// a file that never had one. The file below is an odinfmt fixed point and `odin
// check` exits 0 over it, so nothing but this stood between the tree and a
// procedure invisible to every check.
@(test)
a_body_that_never_closes_at_column_zero_is_read :: proc(t: ^testing.T) {
	escaping := PROBE + "escapes :: proc() -> bool {\n\treturn true}\n"
	facts := facts_of(t, escaping)
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.name, "escapes")
	testing.expect_value(t, found.declared_at, 3)
	testing.expect_value(t, found.body_ends, 4)
	testing.expect_value(t, found.returns, true)
	testing.expect_value(t, found.annotated, false)
	testing.expect_value(t, found.attributable, true)
}

// A `}` at column 0 inside a raw string, which ended a procedure early for the
// reader that looked for one. Odin's raw strings span lines and take no escapes,
// so this is transcribed text and not the end of anything.
@(test)
a_closing_brace_inside_a_raw_string_does_not_end_a_procedure :: proc(t: ^testing.T) {
	quoted := PROBE + "held :: proc() {\n\ttext := `\n}\n`\n\t_ = text\n}\n"
	facts := facts_of(t, quoted)
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.name, "held")
	testing.expect_value(t, found.declared_at, 3)
	testing.expect_value(t, found.body_ends, 8)
}

// A procedure literal has a body, so section 0 covers it, and no declaration for
// an attribute to sit above, so rule F2 must not.
@(test)
a_procedure_literal_has_a_body_but_nothing_to_annotate :: proc(t: ^testing.T) {
	literal :=
		PROBE + "held :: proc() {\n\tcb := proc(x: int) -> int {\n\t\treturn x\n\t}\n\t_ = cb\n}\n"
	facts := facts_of(t, literal)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.procedures), 2)
	bound, is_there := procedure_named(facts, "cb")
	testing.expect(t, is_there, "a procedure bound with := was not measured")
	testing.expect_value(t, bound.returns, true)
	testing.expect_value(t, bound.attributable, false)
}

// `_ :: proc()` is a declaration an attribute can sit above: measured at the pin,
// `@(require_results)` on one compiles clean under the full vet set. So rules F1
// and F2 have every question about it that they have about any other procedure,
// and reading it as unattributable exempts it from both -- a hole the column-zero
// scan this replaced did not have, since its regex matched `_` like any name.
@(test)
a_discarded_declaration_is_something_an_attribute_can_sit_on :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "_ :: proc() -> bool {\n\treturn true\n}\n")
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.name, "_")
	testing.expect_value(t, found.declared_at, 3)
	testing.expect_value(t, found.body_ends, 5)
	testing.expect_value(t, found.returns, true)
	testing.expect_value(t, found.annotated, false)
	testing.expect_value(t, found.attributable, true)
}

// The negative space (rule A3), and the property the line above turns on: what
// makes a body unattributable is the `:=`, which the compiler refuses an
// attribute on, and never the spelling of the name in front of it.
@(test)
a_discarded_binding_is_not_something_an_attribute_can_sit_on :: proc(t: ^testing.T) {
	bound := PROBE + "held :: proc() {\n\t_ := proc() -> int {\n\t\treturn 1\n\t}\n}\n"
	facts := facts_of(t, bound)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.procedures), 2)
	inner, is_there := procedure_named(facts, "_")
	testing.expect(t, is_there, "a procedure bound to _ with := was not measured")
	testing.expect_value(t, inner.returns, true)
	testing.expect_value(t, inner.attributable, false)
}

// A foreign block's entries carry no body at all, so they are procedures in name
// only and none of the four policies has a question about one.
@(test)
a_foreign_block_entry_is_not_a_procedure_with_a_body :: proc(t: ^testing.T) {
	block :=
		PROBE +
		"foreign import kernel32 \"system:Kernel32.lib\"\n\n" +
		"@(default_calling_convention = \"std\")\nforeign kernel32 {\n" +
		"\tGetTickCount64 :: proc() -> u64 ---\n}\n"
	facts := facts_of(t, block)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.procedures), 0)
}

// Rule F1 counts from the line carrying `::` through the closing brace, comments
// and blanks included. The span is what this reports, so the arithmetic is one
// subtraction and cannot be done two ways.
@(test)
the_span_a_line_limit_counts_runs_from_the_declaration_to_the_brace :: proc(t: ^testing.T) {
	filler := strings.repeat("\tx := 1\n", 69, context.allocator)
	defer delete(filler, context.allocator)
	built := strings.concatenate({PROBE, "over :: proc() {\n", filler, "}\n"}, context.allocator)
	defer delete(built, context.allocator)

	facts := facts_of(t, built)
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.body_ends - found.declared_at + 1, 71)
}

// CLAUDE.md rule A8: a source file is external input, and one that is not Odin at
// all must be refused rather than half read. Refused whole: a file with a fault
// carries no facts, so nothing downstream can read a partial answer as a complete
// one.
@(test)
a_source_that_does_not_parse_is_refused_rather_than_half_read :: proc(t: ^testing.T) {
	facts := read_source("probe.odin", PROBE + "held :: proc( {\n", context.allocator)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, facts.fault, Fault.Not_Odin)
	testing.expect_value(t, len(facts.procedures), 0)
	testing.expect_value(t, len(facts.comments), 0)
	testing.expect_value(t, len(facts.vet_tags), 0)
}

// `core:odin/parser` is a recursive descent with no depth limit, so a file nested
// deeply enough runs the thread off its stack with no error return to catch. The
// bound is checked BEFORE the parse, with the tokenizer, which recurses not at
// all. The fixture is one past the limit and is never handed to the parser.
@(test)
a_source_nested_deeper_than_the_parser_survives_is_refused_unread :: proc(t: ^testing.T) {
	opening := strings.repeat("(", MAX_SOURCE_DEPTH + 1, context.allocator)
	defer delete(opening, context.allocator)
	closing := strings.repeat(")", MAX_SOURCE_DEPTH + 1, context.allocator)
	defer delete(closing, context.allocator)
	built := strings.concatenate({PROBE, "x := ", opening, "1", closing, "\n"}, context.allocator)
	defer delete(built, context.allocator)

	facts := read_source("probe.odin", built, context.allocator)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, facts.fault, Fault.Nested_Too_Deep)
	testing.expect_value(t, len(facts.procedures), 0)
}

// A closer with nothing open closes nothing, so the count has a floor at zero.
//
// Without one, a run of stray closers DEFLATES it: the shallowest overflow
// measured, preceded by just enough of them to bring the peak back under the
// bound, is counted as MAX_SOURCE_DEPTH and handed to the parser -- which is the
// exact shape the bound exists to keep away from it, and this program does not
// survive it. Any truncated or badly merged source is that file.
@(test)
stray_closing_brackets_do_not_deflate_the_count :: proc(t: ^testing.T) {
	stray := strings.repeat(")", SHALLOWEST_OVERFLOW - MAX_SOURCE_DEPTH, context.allocator)
	defer delete(stray, context.allocator)
	opening := strings.repeat("(", SHALLOWEST_OVERFLOW, context.allocator)
	defer delete(opening, context.allocator)
	closing := strings.repeat(")", SHALLOWEST_OVERFLOW, context.allocator)
	defer delete(closing, context.allocator)
	built := strings.concatenate(
		{PROBE, stray, "\nx := ", opening, "1", closing, "\n"},
		context.allocator,
	)
	defer delete(built, context.allocator)

	testing.expect_value(t, nesting_depth("probe.odin", built), SHALLOWEST_OVERFLOW)

	facts := read_source("probe.odin", built, context.allocator)
	defer facts_destroy(facts, context.allocator)
	testing.expect_value(t, facts.fault, Fault.Nested_Too_Deep)
}

// The negative space of the bound (rule A3): ordinary Odin nests brackets, and a
// reader that refused everything would satisfy the case above on its own.
@(test)
a_source_nested_as_deeply_as_this_repository_gets_is_read :: proc(t: ^testing.T) {
	opening := strings.repeat("(", DEEPEST_IN_TREE, context.allocator)
	defer delete(opening, context.allocator)
	closing := strings.repeat(")", DEEPEST_IN_TREE, context.allocator)
	defer delete(closing, context.allocator)
	built := strings.concatenate(
		{PROBE, "held :: proc() {\n\tx := ", opening, "1", closing, "\n\t_ = x\n}\n"},
		context.allocator,
	)
	defer delete(built, context.allocator)

	facts := facts_of(t, built)
	defer facts_destroy(facts, context.allocator)

	found := one_procedure(t, facts)
	testing.expect_value(t, found.name, "held")
}
