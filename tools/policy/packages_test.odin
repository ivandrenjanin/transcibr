#+vet explicit-allocators
package policy

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
cli_is_the_one_exempt_package :: proc(t: ^testing.T) {
	testing.expect_value(t, is_test_less_package("cli", TEST_LESS_SRC_PACKAGES), true)
	testing.expect_value(t, is_test_less_package("child", TEST_LESS_SRC_PACKAGES), false)
}

// The exemption roster belongs to `src/` alone: under `tools/` there is no
// roster at all, so even the one exempt `src/` name is exempt from nothing
// there.
@(test)
no_name_is_exempt_under_the_tools_root :: proc(t: ^testing.T) {
	testing.expect_value(t, is_test_less_package("cli", NO_TEST_LESS_PACKAGES), false)
	testing.expect_value(t, is_test_less_package("policy", NO_TEST_LESS_PACKAGES), false)
}

@(test)
a_package_named_in_the_justfile_is_not_missing :: proc(t: ^testing.T) {
	justfile := "test:\n\todin test src/child {{vet}}\n\todin test tools/policy {{vet}}\n"
	missing := missing_from_test_recipe(
		[]string{"child"},
		justfile,
		"src",
		TEST_LESS_SRC_PACKAGES,
		context.allocator,
	)
	defer delete(missing, context.allocator)

	testing.expect_value(t, len(missing), 0)
}

@(test)
a_tools_package_named_in_the_justfile_is_not_missing :: proc(t: ^testing.T) {
	justfile := "test:\n\todin test src/child {{vet}}\n\todin test tools/policy {{vet}}\n"
	missing := missing_from_test_recipe(
		[]string{"policy"},
		justfile,
		"tools",
		NO_TEST_LESS_PACKAGES,
		context.allocator,
	)
	defer delete(missing, context.allocator)

	testing.expect_value(t, len(missing), 0)
}

@(test)
a_package_absent_from_the_justfile_is_missing :: proc(t: ^testing.T) {
	justfile := "test:\n\todin test src/child {{vet}}\n"
	missing := missing_from_test_recipe(
		[]string{"child", "audio"},
		justfile,
		"src",
		TEST_LESS_SRC_PACKAGES,
		context.allocator,
	)
	defer {
		for name in missing {
			delete(name, context.allocator)
		}
		delete(missing, context.allocator)
	}

	testing.expect_value(t, len(missing), 1)
	testing.expect_value(t, missing[0], "audio")
}

// A `tools/` package holding tests and absent from the test recipe is the
// exact silence the reviewer measured: on the branch before this round it was
// compiled and run by no recipe at all, and `just check` stayed green.
@(test)
a_tools_package_absent_from_the_justfile_is_missing :: proc(t: ^testing.T) {
	justfile := "test:\n\todin test tools/policy {{vet}}\n"
	missing := missing_from_test_recipe(
		[]string{"policy", "newtool"},
		justfile,
		"tools",
		NO_TEST_LESS_PACKAGES,
		context.allocator,
	)
	defer {
		for name in missing {
			delete(name, context.allocator)
		}
		delete(missing, context.allocator)
	}

	testing.expect_value(t, len(missing), 1)
	testing.expect_value(t, missing[0], "newtool")
}

@(test)
the_test_less_package_is_never_reported_missing :: proc(t: ^testing.T) {
	missing := missing_from_test_recipe(
		[]string{"cli"},
		"test:\n",
		"src",
		TEST_LESS_SRC_PACKAGES,
		context.allocator,
	)
	defer delete(missing, context.allocator)

	testing.expect_value(t, len(missing), 0)
}

// A package mentioned only in ANOTHER recipe -- test-single, exactly the way
// this repository's own justfile mentions src/child a second time -- must
// still be reported missing from the test recipe. A whole-file search would
// call it present and never notice the test recipe's own line was deleted.
@(test)
a_package_named_only_in_another_recipe_is_still_missing :: proc(t: ^testing.T) {
	justfile := "test:\n\todin test src/audio {{vet}}\n\ntest-single:\n\todin test src/child {{vet}}\n"
	missing := missing_from_test_recipe(
		[]string{"child"},
		justfile,
		"src",
		TEST_LESS_SRC_PACKAGES,
		context.allocator,
	)
	defer {
		for name in missing {
			delete(name, context.allocator)
		}
		delete(missing, context.allocator)
	}

	testing.expect_value(t, len(missing), 1)
	testing.expect_value(t, missing[0], "child")
}

// A tested package whose name is a prefix of another package already named
// in the test recipe (`plan` inside `planning`) must still be reported
// missing -- an unbounded substring match would let `src/planning`'s line
// silently satisfy `src/plan` too.
@(test)
a_package_that_is_a_prefix_of_another_named_package_is_still_missing :: proc(t: ^testing.T) {
	justfile := "test:\n\todin test src/planning {{vet}}\n"
	missing := missing_from_test_recipe(
		[]string{"plan"},
		justfile,
		"src",
		TEST_LESS_SRC_PACKAGES,
		context.allocator,
	)
	defer {
		for name in missing {
			delete(name, context.allocator)
		}
		delete(missing, context.allocator)
	}

	testing.expect_value(t, len(missing), 1)
	testing.expect_value(t, missing[0], "plan")
}

// The same token bounding, under the `tools/` prefix: `tools/plan` must not
// match inside `tools/planning` either.
@(test)
a_tools_package_that_is_a_prefix_of_another_named_package_is_still_missing :: proc(t: ^testing.T) {
	justfile := "test:\n\todin test tools/planning {{vet}}\n"
	missing := missing_from_test_recipe(
		[]string{"plan"},
		justfile,
		"tools",
		NO_TEST_LESS_PACKAGES,
		context.allocator,
	)
	defer {
		for name in missing {
			delete(name, context.allocator)
		}
		delete(missing, context.allocator)
	}

	testing.expect_value(t, len(missing), 1)
	testing.expect_value(t, missing[0], "plan")
}

// An exempt package (`cli`) that itself holds a `*_test.odin` file must be
// reported -- the exemption is for a package with no tests at all, not a
// package whose tests are silently never run by any recipe.
@(test)
an_exempt_package_holding_tests_is_reported :: proc(t: ^testing.T) {
	offending := exempt_packages_holding_tests(
		[]string{"cli", "child"},
		TEST_LESS_SRC_PACKAGES,
		context.allocator,
	)
	defer {
		for name in offending {
			delete(name, context.allocator)
		}
		delete(offending, context.allocator)
	}

	testing.expect_value(t, len(offending), 1)
	testing.expect_value(t, offending[0], "cli")
}

@(test)
no_exempt_package_holding_tests_reports_nothing :: proc(t: ^testing.T) {
	offending := exempt_packages_holding_tests(
		[]string{"child", "audio"},
		TEST_LESS_SRC_PACKAGES,
		context.allocator,
	)
	defer {
		for name in offending {
			delete(name, context.allocator)
		}
		delete(offending, context.allocator)
	}

	testing.expect_value(t, len(offending), 0)
}

@(test)
every_tested_package_is_missing_when_the_test_recipe_cannot_be_found :: proc(t: ^testing.T) {
	missing := missing_from_test_recipe(
		[]string{"child", "cli"},
		"build:\n\todin build src/cli\n",
		"src",
		TEST_LESS_SRC_PACKAGES,
		context.allocator,
	)
	defer {
		for name in missing {
			delete(name, context.allocator)
		}
		delete(missing, context.allocator)
	}

	testing.expect_value(t, len(missing), 1)
	testing.expect_value(t, missing[0], "child")
}

// A small fixture on disk: two packages under one throwaway root, one holding
// a `_test.odin` file and one holding only production source, torn down by
// hand -- CLAUDE.md forbids `os.remove_all` anywhere in this tree, this test
// included.
@(test)
tested_packages_finds_only_directories_holding_a_test_file :: proc(t: ^testing.T) {
	base, base_ok := fixture_root("transcibr-policy-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}
	tested_dir := fmt.aprintf("%s/tested", base, allocator = context.allocator)
	defer delete(tested_dir, context.allocator)
	plain_dir := fmt.aprintf("%s/plain", base, allocator = context.allocator)
	defer delete(plain_dir, context.allocator)

	testing.expect_value(t, os.make_directory(base), os.Error(nil))
	testing.expect_value(t, os.make_directory(tested_dir), os.Error(nil))
	testing.expect_value(t, os.make_directory(plain_dir), os.Error(nil))
	defer testing.expect_value(t, os.remove(base), os.Error(nil))
	defer os.remove(tested_dir)
	defer os.remove(plain_dir)

	tested_file := fmt.aprintf("%s/run_test.odin", tested_dir, allocator = context.allocator)
	defer delete(tested_file, context.allocator)
	plain_file := fmt.aprintf("%s/run.odin", plain_dir, allocator = context.allocator)
	defer delete(plain_file, context.allocator)
	testing.expect_value(t, os.write_entire_file(tested_file, []byte{}), os.Error(nil))
	defer os.remove(tested_file)
	testing.expect_value(t, os.write_entire_file(plain_file, []byte{}), os.Error(nil))
	defer os.remove(plain_file)

	names, strays, ok := tested_packages(base, context.allocator)
	defer delete(names, context.allocator)
	defer for name in names {
		delete(name, context.allocator)
	}
	defer delete(strays, context.allocator)
	defer for stray in strays {
		delete(stray, context.allocator)
	}

	testing.expect_value(t, ok, true)
	testing.expect_value(t, len(names), 1)
	testing.expect_value(t, names[0], "tested")
	testing.expect_value(t, len(strays), 0)
}

// A package holding no test file at all -- new, or one whose tests were all
// deleted -- and not declared exempt must be reported. `missing_from_test_recipe`
// alone never asks this question: it only ever walks packages `tested_packages`
// already found holding a test file (review round 5 finding).
@(test)
untested_and_unexempt_package_is_reported :: proc(t: ^testing.T) {
	missing := untested_packages(
		[]string{"child", "cli", "newpkg"},
		[]string{"child"},
		TEST_LESS_SRC_PACKAGES,
		context.allocator,
	)
	defer {
		for name in missing {
			delete(name, context.allocator)
		}
		delete(missing, context.allocator)
	}

	testing.expect_value(t, len(missing), 1)
	testing.expect_value(t, missing[0], "newpkg")
}

// Under the `tools/` root the same question has no roster to excuse anything:
// a `tools/` package holding no test file is reported however it is named.
@(test)
an_untested_tools_package_is_reported_with_no_roster_to_excuse_it :: proc(t: ^testing.T) {
	missing := untested_packages(
		[]string{"policy", "cli"},
		[]string{"policy"},
		NO_TEST_LESS_PACKAGES,
		context.allocator,
	)
	defer {
		for name in missing {
			delete(name, context.allocator)
		}
		delete(missing, context.allocator)
	}

	testing.expect_value(t, len(missing), 1)
	testing.expect_value(t, missing[0], "cli")
}

@(test)
an_exempt_untested_package_is_not_reported :: proc(t: ^testing.T) {
	missing := untested_packages(
		[]string{"cli"},
		[]string{},
		TEST_LESS_SRC_PACKAGES,
		context.allocator,
	)
	defer delete(missing, context.allocator)

	testing.expect_value(t, len(missing), 0)
}

@(test)
a_tested_package_is_not_reported_as_untested :: proc(t: ^testing.T) {
	missing := untested_packages(
		[]string{"child"},
		[]string{"child"},
		TEST_LESS_SRC_PACKAGES,
		context.allocator,
	)
	defer delete(missing, context.allocator)

	testing.expect_value(t, len(missing), 0)
}

// A small fixture on disk: one package holding only production source, no
// test file at all -- `all_packages` must still find it, since it is the
// whole point of the deny-by-default half of this check.
@(test)
all_packages_finds_a_package_with_no_test_file :: proc(t: ^testing.T) {
	base, base_ok := fixture_root("transcibr-policy-untested-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}
	plain_dir := fmt.aprintf("%s/plain", base, allocator = context.allocator)
	defer delete(plain_dir, context.allocator)

	testing.expect_value(t, os.make_directory(base), os.Error(nil))
	testing.expect_value(t, os.make_directory(plain_dir), os.Error(nil))
	defer testing.expect_value(t, os.remove(base), os.Error(nil))
	defer os.remove(plain_dir)

	plain_file := fmt.aprintf("%s/run.odin", plain_dir, allocator = context.allocator)
	defer delete(plain_file, context.allocator)
	testing.expect_value(t, os.write_entire_file(plain_file, []byte{}), os.Error(nil))
	defer os.remove(plain_file)

	names, ok := all_packages(base, context.allocator)
	defer delete(names, context.allocator)
	defer for name in names {
		delete(name, context.allocator)
	}

	testing.expect_value(t, ok, true)
	testing.expect_value(t, len(names), 1)
	testing.expect_value(t, names[0], "plain")
}

// A `*_test.odin` file sitting directly in a package root -- not inside any
// package directory -- belongs to no package. It must be reported through
// `strays`, never folded into `names` under an empty name: that empty name
// used to reach `is_test_less_package`'s `assert(len(name) > 0, ...)` and
// crash the whole `just check` run instead of reporting a violation (A8).
@(test)
a_stray_test_file_directly_under_a_package_root_is_reported_not_asserted :: proc(t: ^testing.T) {
	base, base_ok := fixture_root("transcibr-policy-stray-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}

	testing.expect_value(t, os.make_directory(base), os.Error(nil))
	defer os.remove(base)

	stray_file := fmt.aprintf("%s/stray_test.odin", base, allocator = context.allocator)
	defer delete(stray_file, context.allocator)
	testing.expect_value(t, os.write_entire_file(stray_file, []byte{}), os.Error(nil))
	defer os.remove(stray_file)

	names, strays, ok := tested_packages(base, context.allocator)
	defer delete(names, context.allocator)
	defer for name in names {
		delete(name, context.allocator)
	}
	defer delete(strays, context.allocator)
	defer for stray in strays {
		delete(stray, context.allocator)
	}

	testing.expect_value(t, ok, true)
	testing.expect_value(t, len(names), 0)
	testing.expect_value(t, len(strays), 1)
}

// The whole accounting run against a planted repository root, which is the
// only seam that proves `tools\` is accounted for at all: every helper above
// takes its root and its prefix as a parameter, so a run that simply never
// asks the question of `tools\` passes all of them (the reviewer's finding).
ACCOUNTING_FIXTURE_DIRS :: []string{"src", "src/kept", "tools", "tools/newtool", "tools/bare"}
ACCOUNTING_FIXTURE_FILES :: []string {
	"src/kept/kept_test.odin",
	"tools/newtool/newtool.odin",
	"tools/newtool/newtool_test.odin",
	"tools/bare/bare.odin",
	"tools/stray_test.odin",
}
ACCOUNTING_FIXTURE_JUSTFILE :: "test:\n\todin test src/kept {{vet}}\n"

@(test)
tools_packages_are_accounted_for_beside_src_packages :: proc(t: ^testing.T) {
	base, base_ok := fixture_root("transcibr-policy-tools-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}
	plant_accounting_fixture(t, base)
	defer remove_accounting_fixture(base)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	check_package_accounting(base, &violations, context.allocator)

	testing.expect_value(t, len(violations), 3)
	testing.expect(
		t,
		violations_mention(violations, "tools/newtool holds a *_test.odin file but is not named"),
	)
	testing.expect(t, violations_mention(violations, "tools/bare holds no *_test.odin file"))
	testing.expect(t, violations_mention(violations, "belongs to no package under tools/"))
}

@(require_results)
violations_mention :: proc(violations: [dynamic]Violation, needle: string) -> bool {
	assert(len(needle) > 0, "asked whether the violations mention nothing at all")
	for one in violations {
		if strings.contains(one.message, needle) {
			return true
		}
	}
	return false
}

@(require_results)
fixture_path :: proc(base: string, name: string, allocator: mem.Allocator) -> string {
	assert(len(base) > 0, "asked to name a fixture file under no root at all")
	assert(len(name) > 0, "asked to name a fixture file with no name at all")
	return fmt.aprintf("%s/%s", base, name, allocator = allocator)
}

// A fresh, pid-suffixed fixture root under `os.temp_dir()` -- joined with
// `core:path/filepath`'s `join`, never built by concatenating `temp_dir()`'s
// result straight onto a name. `os.temp_dir()` returns no trailing separator
// (#185), so that concatenation lands the fixture as a SIBLING of the temp
// directory rather than a child of it; `join` inserts the separator every
// platform needs.
@(require_results)
fixture_root :: proc(name: string, allocator: mem.Allocator) -> (path: string, ok: bool) {
	assert(len(name) > 0, "asked to build a fixture root with no name at all")
	assert(
		allocator.procedure != nil,
		"the fixture root outlives this call and needs a chosen allocator",
	)

	root, root_err := os.temp_dir(allocator)
	if root_err != nil {
		delete(root, allocator)
		return "", false
	}
	defer delete(root, allocator)

	dir_name := fmt.aprintf("%s-%d", name, os.get_pid(), allocator = allocator)
	defer delete(dir_name, allocator)

	joined, join_err := filepath.join([]string{root, dir_name}, allocator)
	if join_err != nil {
		return "", false
	}
	return joined, true
}

plant_accounting_fixture :: proc(t: ^testing.T, base: string) {
	assert(t != nil, "asked to plant a fixture for no test at all")
	assert(len(base) > 0, "asked to plant a fixture at no path at all")

	testing.expect_value(t, os.make_directory(base), os.Error(nil))
	for name in ACCOUNTING_FIXTURE_DIRS {
		path := fixture_path(base, name, context.allocator)
		defer delete(path, context.allocator)
		testing.expect_value(t, os.make_directory(path), os.Error(nil))
	}

	source := "package fixture\n"
	for name in ACCOUNTING_FIXTURE_FILES {
		path := fixture_path(base, name, context.allocator)
		defer delete(path, context.allocator)
		testing.expect_value(t, os.write_entire_file(path, transmute([]byte)source), os.Error(nil))
	}

	recipe := ACCOUNTING_FIXTURE_JUSTFILE
	justfile := fixture_path(base, "justfile", context.allocator)
	defer delete(justfile, context.allocator)
	testing.expect_value(t, os.write_entire_file(justfile, transmute([]byte)recipe), os.Error(nil))
}

remove_accounting_fixture :: proc(base: string) {
	assert(len(base) > 0, "asked to remove a fixture at no path at all")

	justfile := fixture_path(base, "justfile", context.allocator)
	defer delete(justfile, context.allocator)
	os.remove(justfile)

	for name in ACCOUNTING_FIXTURE_FILES {
		path := fixture_path(base, name, context.allocator)
		defer delete(path, context.allocator)
		os.remove(path)
	}
	#reverse for name in ACCOUNTING_FIXTURE_DIRS {
		path := fixture_path(base, name, context.allocator)
		defer delete(path, context.allocator)
		os.remove(path)
	}
	os.remove(base)
}

// The exact pid-collision failure mode the #109 review measured: the OLD
// shape's name -- `temp_dir()` concatenated straight onto the fixture name,
// no separator -- lands as a SIBLING of the temp directory rather than a
// child of it. The new, join-based `fixture_root` must build a distinct
// path that sits properly under `root`, without ever creating a directory
// outside `os.temp_dir()` to prove it: both `old_shape` and the property
// checked against it are plain strings, never planted on disk. The old
// shape landed there because `os.temp_dir()` carries no trailing separator;
// a recycled pid landing on such a stray made `os.make_directory` return
// `Exist` and turned unrelated tests red.
@(test)
fixture_root_survives_a_stray_directory_at_the_old_sibling_name :: proc(t: ^testing.T) {
	root, root_err := os.temp_dir(context.allocator)
	testing.expect_value(t, root_err, nil)
	defer delete(root, context.allocator)

	name := "transcibr-policy-mutation-fixture"
	old_shape := fmt.aprintf("%s%s-%d", root, name, os.get_pid(), allocator = context.allocator)
	defer delete(old_shape, context.allocator)

	base, base_ok := fixture_root(name, context.allocator)
	defer delete(base, context.allocator)

	testing.expect_value(t, base_ok, true)
	testing.expect(t, base != old_shape)
	testing.expect(t, strings.has_prefix(base, root))
}
