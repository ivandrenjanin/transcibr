#+vet explicit-allocators
package policy

import "core:testing"

// This file checks CLAUDE.md section 0: a comment inside a procedure body, and
// every shape that is not one. The negative space is most of it -- a checker that
// reports a URL inside a string as a comment refuses a Recording for what
// somebody said, and this repository transcribes whatever somebody said.

@(require_results)
one_comment :: proc(t: ^testing.T, facts: Source_Facts) -> Body_Comment {
	testing.expect_value(t, len(facts.comments), 1)
	if len(facts.comments) != 1 {
		return {}
	}
	return facts.comments[0]
}

@(test)
a_comment_inside_a_body_is_found_with_its_line_and_its_procedure :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "held :: proc() {\n\t// this one is banned\n\treturn\n}\n")
	defer facts_destroy(facts, context.allocator)

	found := one_comment(t, facts)
	testing.expect_value(t, found.inside, "held")
	testing.expect_value(t, found.line, 4)
	testing.expect_value(t, found.text, "// this one is banned")
}

// The comment a procedure is ALLOWED: the one above it, saying why it exists.
// Reading that as a body comment would fail every well-documented file in this
// repository and make the check the first thing anybody turned off.
@(test)
a_comment_above_a_procedure_is_not_a_comment_inside_it :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "// why this procedure exists\nheld :: proc() {\n\treturn\n}\n")
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.comments), 0)
}

// The gap a reader anchored to the first token on a line leaves open: `x := 1 //
// why` passed a check whose refusal reads "N comment(s) inside a procedure body",
// which is a complete-sounding guarantee over a partial scan.
@(test)
a_comment_following_code_on_its_line_is_still_a_comment_in_the_body :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "held :: proc() {\n\tx := 1 // why\n\t_ = x\n}\n")
	defer facts_destroy(facts, context.allocator)

	found := one_comment(t, facts)
	testing.expect_value(t, found.line, 4)
	testing.expect_value(t, found.inside, "held")
}

@(test)
a_block_comment_following_code_is_still_a_comment_in_the_body :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "held :: proc() {\n\tx := 1 /* why */\n\t_ = x\n}\n")
	defer facts_destroy(facts, context.allocator)

	found := one_comment(t, facts)
	testing.expect_value(t, found.line, 4)
}

// A block comment spanning ten lines is ONE finding and not ten, reported at the
// line it opens on, and flattened to one line so the report stays one record per
// line.
@(test)
a_block_comment_over_several_lines_is_one_finding_at_the_line_it_opens :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "held :: proc() {\n\t/* why\n\t   and why\n\t*/\n\treturn\n}\n")
	defer facts_destroy(facts, context.allocator)

	found := one_comment(t, facts)
	testing.expect_value(t, found.line, 4)
	testing.expect_value(t, found.text, "/* why")
}

// Two slashes inside a string are not a comment, and this repository writes
// strings holding whatever somebody said.
@(test)
two_slashes_inside_a_string_are_not_a_comment :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "held :: proc() {\n\ts := \"https://example.com\"\n\t_ = s\n}\n")
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.comments), 0)
}

// Nor is a rune literal spelled '/' half of one, and the escaped-quote rune
// beside it is what stops a reader running off the end of the literal and reading
// the rest of the line as text inside a string.
@(test)
a_rune_literal_holding_a_slash_is_not_a_comment :: proc(t: ^testing.T) {
	runes :=
		PROBE + "held :: proc() {\n\tslash := '/'\n\tquote := '\\''\n\t_, _ = slash, quote\n}\n"
	facts := facts_of(t, runes)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.comments), 0)
}

// A raw string spans lines and takes no escapes, so a line beginning `//` inside
// one is transcribed speech. This is the case that separates the reader from a
// grep.
@(test)
a_raw_string_holding_two_slashes_is_not_a_comment :: proc(t: ^testing.T) {
	quoted := PROBE + "held :: proc() {\n\ttext := `\n// inside a raw string\n`\n\t_ = text\n}\n"
	facts := facts_of(t, quoted)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.comments), 0)
}

// A comment in a top-level table is not inside a procedure body, and the scan
// this replaced reported one as though it were -- the same defect that invented
// a phantom procedure above it.
@(test)
a_comment_in_a_top_level_table_is_not_inside_a_body :: proc(t: ^testing.T) {
	shape :=
		PROBE +
		"Fault_Says :: proc(fault: int) -> string\n\n" +
		"FAULT := [2]string {\n\t// the success value\n\t\"a\",\n\t\"b\",\n}\n"
	facts := facts_of(t, shape)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.comments), 0)
}

// A comment inside a procedure declared where no column-zero scan could look.
// Section 0's verdict is a claim about EVERY procedure, and this is the one the
// guard that replaced it could only refuse rather than read.
@(test)
a_comment_inside_an_indented_procedure_is_found :: proc(t: ^testing.T) {
	hidden :=
		PROBE +
		"when ODIN_OS == .Windows {\n\thelper :: proc() {\n\t\t// invisible to a column-zero scan\n\t}\n}\n"
	facts := facts_of(t, hidden)
	defer facts_destroy(facts, context.allocator)

	found := one_comment(t, facts)
	testing.expect_value(t, found.inside, "helper")
	testing.expect_value(t, found.line, 5)
}

// Innermost, so a nested body's comment is reported against the procedure it is
// actually in rather than against the one that happens to enclose it.
@(test)
a_comment_is_reported_against_the_innermost_procedure_holding_it :: proc(t: ^testing.T) {
	nested := PROBE + "outer :: proc() {\n\tinner :: proc() {\n\t\t// in here\n\t}\n\tinner()\n}\n"
	facts := facts_of(t, nested)
	defer facts_destroy(facts, context.allocator)

	found := one_comment(t, facts)
	testing.expect_value(t, found.inside, "inner")
	testing.expect_value(t, found.line, 5)
}

// Issue #52's shape again, from section 0's side: the procedure whose body never
// closes at column 0 carries a comment that no check could see.
@(test)
a_comment_in_a_body_that_never_closes_at_column_zero_is_found :: proc(t: ^testing.T) {
	escaping :=
		PROBE + "escapes :: proc() -> bool {\n\t// a comment section 0 bans\n\treturn true}\n"
	facts := facts_of(t, escaping)
	defer facts_destroy(facts, context.allocator)

	found := one_comment(t, facts)
	testing.expect_value(t, found.inside, "escapes")
	testing.expect_value(t, found.line, 4)
}
