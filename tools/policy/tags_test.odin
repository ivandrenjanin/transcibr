#+vet explicit-allocators
package policy

import "core:mem"
import "core:strings"
import "core:testing"

// This file checks CLAUDE.md rule M2: the `#+vet` names a file declares for
// itself, above its `package` clause.
//
// ABSENCE is the whole subject. A misspelled name is `Syntax Error: Invalid vet
// flag name` and a tag below the package clause is refused by the compiler, so
// both stop a build on their own. A tag nobody wrote stops nothing: the file
// compiles, and the check the tag turns on is never applied to it.

@(require_results)
tags_of :: proc(t: ^testing.T, src: string, allocator: mem.Allocator) -> string {
	facts := read_source("probe.odin", src, allocator)
	defer facts_destroy(facts, allocator)
	testing.expect_value(t, facts.fault, Fault.None)
	return strings.join(facts.vet_tags, " ", allocator)
}

@(test)
a_vet_tag_is_read_off_the_line_above_the_package_clause :: proc(t: ^testing.T) {
	read := tags_of(t, "#+vet explicit-allocators\npackage probe\n", context.allocator)
	defer delete(read, context.allocator)
	testing.expect_value(t, read, "explicit-allocators")
}

@(test)
a_file_with_no_vet_tag_declares_nothing :: proc(t: ^testing.T) {
	read := tags_of(t, "package probe\n", context.allocator)
	defer delete(read, context.allocator)
	testing.expect_value(t, read, "")
}

// Several names on one line, which the compiler accepts and fires all of, and
// which is the shape this line takes the moment a second name is declared.
@(test)
several_vet_names_on_one_line_are_all_read :: proc(t: ^testing.T) {
	read := tags_of(
		t,
		"#+vet explicit-allocators unused-imports\npackage probe\n",
		context.allocator,
	)
	defer delete(read, context.allocator)
	testing.expect_value(t, read, "explicit-allocators unused-imports")
}

// Stacked with a tag of another kind and below the doc comment docs\ opens with.
// Both placements compile, and a reader that only looked at line 1 would refuse
// one of them.
@(test)
a_vet_tag_under_a_comment_and_above_another_tag_is_read :: proc(t: ^testing.T) {
	read := tags_of(
		t,
		"// why this file exists\n#+vet explicit-allocators\n#+private\npackage probe\n",
		context.allocator,
	)
	defer delete(read, context.allocator)
	testing.expect_value(t, read, "explicit-allocators")
}

// One QUOTED in the doc comment above the clause, which is what a file explaining
// this rule to a reader would carry.
@(test)
a_vet_tag_quoted_in_a_block_comment_is_not_a_tag :: proc(t: ^testing.T) {
	read := tags_of(t, "/*\n#+vet explicit-allocators\n*/\npackage probe\n", context.allocator)
	defer delete(read, context.allocator)
	testing.expect_value(t, read, "")
}

// BELOW the package clause is `Lines starting with #+ (file tags) are only
// allowed before the package line`. The reader this replaced credited nothing and
// carried on; the parser refuses the whole file, which is the stronger answer --
// a file the compiler will not build is not a file the checks may pass.
@(test)
a_vet_tag_below_the_package_clause_refuses_the_file :: proc(t: ^testing.T) {
	facts := read_source(
		"probe.odin",
		"package probe\n\n#+vet explicit-allocators\n",
		context.allocator,
	)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, facts.fault, Fault.Not_Odin)
	testing.expect_value(t, len(facts.vet_tags), 0)
}

// Case-SENSITIVELY, the way the compiler reads the name: it answers `Invalid vet
// flag name: Explicit-Allocators`. A reader that folded case would report a
// spelling the compiler refuses as the spelling it wants.
@(test)
vet_names_are_read_exactly_as_they_are_spelled :: proc(t: ^testing.T) {
	read := tags_of(t, "#+vet Explicit-Allocators\npackage probe\n", context.allocator)
	defer delete(read, context.allocator)
	testing.expect_value(t, read, "Explicit-Allocators")
}

// A tag that merely begins with the prefix is a different tag, and reading its
// remainder as a list of vet names would credit a file with names nobody wrote.
@(test)
a_tag_that_merely_begins_with_the_prefix_is_not_a_vet_tag :: proc(t: ^testing.T) {
	names, is_vet := vet_tag_names("#+vetted explicit-allocators")
	testing.expect_value(t, is_vet, false)
	testing.expect_value(t, names, "")
}

@(test)
a_vet_tag_with_no_names_after_it_declares_nothing :: proc(t: ^testing.T) {
	read := tags_of(t, "#+vet\npackage probe\n", context.allocator)
	defer delete(read, context.allocator)
	testing.expect_value(t, read, "")
}
