#+vet explicit-allocators
// Issue #222 work item 2: the double-token justfile guard #184 added
// (formerly `packages_test.odin`'s
// `the_real_justfiles_test_recipe_reports_policy_missing_once_its_test_line_is_gone`)
// covered `tools/policy` alone. The right altitude, the ticket's own words,
// is a guard that loops over EVERY tested package the real justfile names,
// stripping each one's own test line in turn and asserting
// `missing_from_test_recipe` reds for it -- so the same hole for any OTHER
// package (a `test` line that builds instead of testing, silently disabling
// the accounting guard) is caught too, not just `tools/policy`'s own
// historical case. Runs entirely in-process, over the real `tested_packages`
// walk and the real justfile text read once: measured against spawning one
// `policy-cli.exe` child per package instead, this whole loop -- both roots,
// every real package this repository holds -- finishes in single-digit
// milliseconds, where one child spawn alone (`policy_exit_code`'s own tests)
// costs tens of milliseconds each; N children would make this the slowest
// test in the suite for a question `missing_from_test_recipe` itself never
// needs a live process to answer.
package policy

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

// One package's own `test <prefix>/<name> ` token, stripped out of every
// line of `justfile_text` that carries it -- the mutation the #184 review
// applied by hand to `tools/policy` alone, generalized to any package. The
// trailing space in the needle is the token boundary: without it, stripping
// `src/plan`'s line would also strip `src/planning`'s.
@(require_results)
strip_package_test_line :: proc(
	justfile_text: string,
	prefix: string,
	name: string,
	allocator: mem.Allocator,
) -> string {
	assert(len(prefix) > 0, "asked to strip a test line under a root with no name")
	assert(len(name) > 0, "asked to strip a test line for no package at all")

	needle := fmt.aprintf("test %s/%s ", prefix, name, allocator = allocator)
	defer delete(needle, allocator)

	lines := strings.split_lines(justfile_text, allocator)
	defer delete(lines, allocator)

	kept := make([dynamic]string, 0, len(lines), allocator)
	defer delete(kept)
	for line in lines {
		if strings.contains(line, needle) {
			continue
		}
		append(&kept, line)
	}
	return strings.join(kept[:], "\n", allocator)
}

// How many lines of `text` contain `needle` at all -- used both to count a
// package's own token before any strip, and (with an empty needle, which
// every line contains) to count `text`'s lines outright.
@(require_results)
count_lines_containing :: proc(text: string, needle: string, allocator: mem.Allocator) -> int {
	lines := strings.split_lines(text, allocator)
	defer delete(lines, allocator)
	count := 0
	for line in lines {
		if strings.contains(line, needle) {
			count += 1
		}
	}
	return count
}

// Strips `name`'s own line and asserts the strip removed EXACTLY as many
// lines as its own needle matches in the UNSTRIPPED text -- no fewer (a
// strip that only widens a substring match would remove more) and no more
// (a strip broad enough to empty the whole justfile still removes every
// line, not just the needle's). A package's own token can legitimately
// appear on more than one line (`src/child` names its own recipe line and
// `test-single`'s, both containing "test src/child "), so the expected
// count is measured from the real text rather than assumed to be one.
// Returns the mutated text (caller frees) and whether both checks passed.
@(require_results)
assert_strip_removed_expected_lines :: proc(
	t: ^testing.T,
	prefix: string,
	name: string,
	justfile_text: string,
) -> (
	mutated: string,
	ok: bool,
) {
	needle := fmt.aprintf("test %s/%s ", prefix, name, allocator = context.allocator)
	defer delete(needle, context.allocator)

	expected_removed := count_lines_containing(justfile_text, needle, context.allocator)
	if !testing.expectf(
		t,
		expected_removed > 0,
		"%s/%s's own needle matched no line in the real justfile at all",
		prefix,
		name,
	) {
		return "", false
	}

	mutated = strip_package_test_line(justfile_text, prefix, name, context.allocator)

	before := count_lines_containing(justfile_text, "", context.allocator)
	after := count_lines_containing(mutated, "", context.allocator)
	removed := before - after
	if !testing.expectf(
		t,
		removed == expected_removed,
		"%s/%s's own line strip removed %d lines, not the %d its needle matches",
		prefix,
		name,
		removed,
		expected_removed,
	) {
		delete(mutated, context.allocator)
		return "", false
	}
	return mutated, true
}

// Strips `name`'s own line and requires `missing_from_test_recipe` to report
// exactly `name` and nothing else. Returns 1 when it did, 0 when any
// expectation failed -- the caller sums this across every package it walks,
// so a walk that checked nothing at all is visible too.
//
// Two checks bracket the strip so a broad or vacuous strip cannot pass
// silently: BEFORE stripping, `name` must already be accounted for (a
// baseline of "already missing" would let the post-strip check pass having
// tested nothing) -- `assert_strip_removed_expected_lines` above is the
// second bracket, on the strip itself.
@(require_results)
assert_stripping_reddens_one_package :: proc(
	t: ^testing.T,
	prefix: string,
	name: string,
	exempt: []string,
	justfile_text: string,
) -> int {
	assert(t != nil, "there is no test here to report a stripped line's result through")
	assert(len(name) > 0, "asked to strip the test line of no package at all")

	baseline := missing_from_test_recipe(
		[]string{name},
		justfile_text,
		prefix,
		exempt,
		context.allocator,
	)
	defer {
		for missed in baseline {
			delete(missed, context.allocator)
		}
		delete(baseline, context.allocator)
	}
	if !testing.expectf(
		t,
		len(baseline) == 0,
		"%s/%s was already missing from the test recipe before any line was stripped",
		prefix,
		name,
	) {
		return 0
	}

	mutated, stripped_ok := assert_strip_removed_expected_lines(t, prefix, name, justfile_text)
	if !stripped_ok {
		return 0
	}
	defer delete(mutated, context.allocator)

	missing := missing_from_test_recipe([]string{name}, mutated, prefix, exempt, context.allocator)
	defer {
		for missed in missing {
			delete(missed, context.allocator)
		}
		delete(missing, context.allocator)
	}

	if !testing.expectf(
		t,
		len(missing) == 1,
		"%s/%s stayed accounted for after its own test line was stripped",
		prefix,
		name,
	) {
		return 0
	}
	testing.expect_value(t, missing[0], name)
	return 1
}

// Every real, non-exempt package under `root`/`prefix`: stripping ITS OWN
// line must make `missing_from_test_recipe` report it. Returns how many
// packages this actually checked, so the caller can require the walk found
// at least one -- an empty or all-exempt walk would otherwise pass having
// asked nothing, the same silent-green shape issue #152 exists to end.
@(require_results)
assert_every_tested_package_reddens_when_its_line_is_stripped :: proc(
	t: ^testing.T,
	root: string,
	prefix: string,
	exempt: []string,
	justfile_text: string,
) -> int {
	assert(t != nil, "there is no test here to report this walk's result through")
	assert(len(root) > 0, "asked to walk no repository root at all")
	assert(len(prefix) > 0, "asked to walk a root with no name at all")

	package_root := strings.concatenate({root, "/", prefix}, context.allocator)
	defer delete(package_root, context.allocator)

	tested, strays, discovered := tested_packages(package_root, context.allocator)
	defer delete(tested, context.allocator)
	defer for name in tested {
		delete(name, context.allocator)
	}
	defer delete(strays, context.allocator)
	defer for stray in strays {
		delete(stray, context.allocator)
	}
	if !testing.expectf(t, discovered, "could not walk %s\\ of the real repository", prefix) {
		return 0
	}

	checked := 0
	for name in tested {
		if is_test_less_package(name, exempt) {
			continue
		}
		checked += assert_stripping_reddens_one_package(t, prefix, name, exempt, justfile_text)
	}
	return checked
}

// The whole loop, over both real roots this repository holds packages under
// -- generalizing #184's single `tools/policy` case into the guard issue
// #222 asked for. Reads THIS REPOSITORY'S OWN justfile once: the test
// process's working directory is the repository root, the same convention
// `repo_root` in main.odin relies on.
@(test)
every_tested_packages_own_test_line_reddens_the_accounting_check_when_stripped :: proc(
	t: ^testing.T,
) {
	root, root_err := os.get_working_directory(context.allocator)
	testing.expect_value(t, root_err, nil)
	defer delete(root, context.allocator)

	justfile_path := strings.concatenate({root, "/justfile"}, context.allocator)
	defer delete(justfile_path, context.allocator)
	justfile_bytes, read_err := os.read_entire_file(justfile_path, context.allocator)
	testing.expect_value(t, read_err, os.Error(nil))
	defer delete(justfile_bytes, context.allocator)
	justfile_text := string(justfile_bytes)

	checked := assert_every_tested_package_reddens_when_its_line_is_stripped(
		t,
		root,
		"src",
		TEST_LESS_SRC_PACKAGES,
		justfile_text,
	)
	checked += assert_every_tested_package_reddens_when_its_line_is_stripped(
		t,
		root,
		"tools",
		NO_TEST_LESS_PACKAGES,
		justfile_text,
	)
	testing.expectf(
		t,
		checked > 0,
		"found no real tested, non-exempt package to strip a line from at all",
	)
}
