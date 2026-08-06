#+vet explicit-allocators
package policy

import "core:testing"

// This file checks the #97 ban: an `os.remove_all(...)` call expression
// anywhere in the tree. Issue #97 measured that a second `os.remove_all` on a
// non-empty directory faults on a `core:testing` runner thread; issue #105 is
// what makes staying away from it mechanical rather than prose in CLAUDE.md.
//
// Both directions matter equally here. A check that trips on the statement and
// nothing else is half the acceptance criteria; directory_test.odin's two
// comment lines naming `os.remove_all` are what the other half protects.

@(test)
an_os_remove_all_call_is_found_with_its_line :: proc(t: ^testing.T) {
	facts := facts_of(
		t,
		PROBE + `import "core:os"` + "\n\nheld :: proc() {\n\tos.remove_all(\"x\")\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.remove_all_lines), 1)
	if len(facts.remove_all_lines) == 1 {
		testing.expect_value(t, facts.remove_all_lines[0], 6)
	}
}

// The exact shape directory_test.odin carries today: two explanatory comment
// lines naming `os.remove_all`, and no statement anywhere. A parser reading a
// comment as a comment is the whole of what keeps this from refusing that
// file's own review notes about the ban it is enforcing.
@(test)
a_comment_naming_os_remove_all_is_not_a_call :: proc(t: ^testing.T) {
	facts := facts_of(
		t,
		PROBE +
		`import "core:os"` +
		"\n\n// never call os.remove_all here\nheld :: proc() {\n\t_ = os.remove\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.remove_all_lines), 0)
}

@(test)
a_file_that_never_imports_core_os_reports_no_remove_all_calls :: proc(t: ^testing.T) {
	facts := facts_of(t, PROBE + "held :: proc() {\n\treturn\n}\n")
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.remove_all_lines), 0)
}

// A file that imports `core:os` under a different local name is matched under
// THAT name, not under the convention every other file in the tree follows --
// the residual policy.odin's own comment on REMOVE_ALL_PACKAGE names.
@(test)
a_renamed_os_import_is_matched_under_its_own_local_name :: proc(t: ^testing.T) {
	facts := facts_of(
		t,
		PROBE + `import myos "core:os"` + "\n\nheld :: proc() {\n\tmyos.remove_all(\"x\")\n}\n",
	)
	defer facts_destroy(facts, context.allocator)

	testing.expect_value(t, len(facts.remove_all_lines), 1)
}
