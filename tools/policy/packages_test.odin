#+vet explicit-allocators
package policy

import "core:fmt"
import "core:os"
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
// included. Issue #202 fix round 2: base's own creation now goes through
// `ensure_fixture_root` alone -- fix round 1 kept a bare `os.make_directory`
// as the first call and asserted it nil, so a genuine leftover (a prior
// crashed run at the recycled pid) still reds this exact line before
// `ensure_fixture_root` ever runs. `ensure_fixture_root` is itself tolerant
// of that leftover, so it is the only creation this site needs.
@(test)
tested_packages_finds_only_directories_holding_a_test_file :: proc(t: ^testing.T) {
	base, base_ok := fixture_root(t, "transcibr-policy-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}
	tested_dir := fmt.aprintf("%s/tested", base, allocator = context.allocator)
	defer delete(tested_dir, context.allocator)
	plain_dir := fmt.aprintf("%s/plain", base, allocator = context.allocator)
	defer delete(plain_dir, context.allocator)

	testing.expect_value(t, ensure_fixture_root(base), os.Error(nil))
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

// Fix round 1 finding 2: `packages_missing_test_procedures` was a
// behavior-identical duplicate of `untested_packages` -- the same set
// difference over a different pair of lists. Its call site (main.odin's
// `report_packages_missing_test_procedures`) now calls `untested_packages`
// directly, so issue #174's own question (a `*_test.odin` file present but
// no `@(test)` procedure inside it) is pinned by the existing
// `untested_and_unexempt_package_is_reported`, `a_tested_package_is_not_reported_as_untested`
// and `an_exempt_untested_package_is_not_reported` tests above, over
// `untested_packages` itself -- there is nothing left for a second,
// differently-named copy of the same three tests to pin.

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

// Issue #239: a `*_test.odin` file whose own `#+build` tags exclude the
// platform this check runs on declares no test procedure at all, even though
// its `@(test)` procedure parses clean -- `odin test` never compiles this
// file's body in on this platform, so `packages_with_test_procedures` must
// not credit it either. Before this fix, `file_declares_test_procedure` read
// only `facts.procedures` and never `facts.excluded_by_platform`, so a
// `#+build linux` file on this Windows checkout still reported true.
@(test)
a_build_tagged_test_file_excluding_the_current_platform_declares_no_test_procedure :: proc(
	t: ^testing.T,
) {
	source := "#+build linux\npackage fixture\n\nimport \"core:testing\"\n\n@(test)\nchecks_something :: proc(t: ^testing.T) {\n\t_ = t\n}\n"
	testing.expect_value(
		t,
		file_declares_test_procedure("tagged_test.odin", source, context.allocator),
		false,
	)
}

// The positive space of the same check (CLAUDE.md rule A3): a `#+build`
// line that includes this platform must not be mistaken for one that
// excludes it.
@(test)
a_build_tagged_test_file_naming_the_current_platform_still_declares_its_test_procedure :: proc(
	t: ^testing.T,
) {
	source := "#+build windows\npackage fixture\n\nimport \"core:testing\"\n\n@(test)\nchecks_something :: proc(t: ^testing.T) {\n\t_ = t\n}\n"
	testing.expect_value(
		t,
		file_declares_test_procedure("tagged_test.odin", source, context.allocator),
		true,
	)
}

// A small fixture on disk: two packages under one throwaway root, one whose
// `*_test.odin` file still holds a real `@(test)` procedure and one whose
// `*_test.odin` file holds none at all -- issue #174's own mutation, planted
// rather than merely asserted about. `packages_with_test_procedures` must
// name only the first. Issue #202 fix round 2: base's own creation now goes
// through `ensure_fixture_root` alone -- fix round 1 kept a bare
// `os.make_directory` as the first call and asserted it nil, so a genuine
// leftover (a prior crashed run at the recycled pid) still reds this exact
// line before `ensure_fixture_root` ever runs. `ensure_fixture_root` is
// itself tolerant of that leftover, so it is the only creation this site
// needs.
@(test)
packages_with_test_procedures_finds_only_files_holding_a_test_attribute :: proc(t: ^testing.T) {
	base, base_ok := fixture_root(t, "transcibr-policy-test-proc-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}
	live_dir := fixture_path(base, "live", context.allocator)
	defer delete(live_dir, context.allocator)
	hollow_dir := fixture_path(base, "hollow", context.allocator)
	defer delete(hollow_dir, context.allocator)

	testing.expect_value(t, ensure_fixture_root(base), os.Error(nil))
	testing.expect_value(t, os.make_directory(live_dir), os.Error(nil))
	testing.expect_value(t, os.make_directory(hollow_dir), os.Error(nil))
	defer testing.expect_value(t, os.remove(base), os.Error(nil))
	defer os.remove(live_dir)
	defer os.remove(hollow_dir)

	live_file := fixture_path(base, "live/run_test.odin", context.allocator)
	defer delete(live_file, context.allocator)
	hollow_file := fixture_path(base, "hollow/run_test.odin", context.allocator)
	defer delete(hollow_file, context.allocator)

	live_source := "package live\n\nimport \"core:testing\"\n\n@(test)\nchecks_something :: proc(t: ^testing.T) {\n\t_ = t\n}\n"
	hollow_source := "package hollow\n\nimport \"core:testing\"\n\n@(private)\nchecks_something :: proc(t: ^testing.T) {\n\t_ = t\n}\n"
	testing.expect_value(
		t,
		os.write_entire_file(live_file, transmute([]byte)live_source),
		os.Error(nil),
	)
	defer os.remove(live_file)
	testing.expect_value(
		t,
		os.write_entire_file(hollow_file, transmute([]byte)hollow_source),
		os.Error(nil),
	)
	defer os.remove(hollow_file)

	names, ok := packages_with_test_procedures(base, context.allocator)
	defer delete(names, context.allocator)
	defer for name in names {
		delete(name, context.allocator)
	}

	testing.expect_value(t, ok, true)
	testing.expect_value(t, len(names), 1)
	testing.expect_value(t, names[0], "live")
}

// A small fixture on disk: one package holding only production source, no
// test file at all -- `all_packages` must still find it, since it is the
// whole point of the deny-by-default half of this check. Issue #202 fix
// round 2: base's own creation now goes through `ensure_fixture_root` alone
// -- fix round 1 kept a bare `os.make_directory` as the first call and
// asserted it nil, so a genuine leftover (a prior crashed run at the
// recycled pid) still reds this exact line before `ensure_fixture_root`
// ever runs. `ensure_fixture_root` is itself tolerant of that leftover, so
// it is the only creation this site needs.
@(test)
all_packages_finds_a_package_with_no_test_file :: proc(t: ^testing.T) {
	base, base_ok := fixture_root(t, "transcibr-policy-untested-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}
	plain_dir := fmt.aprintf("%s/plain", base, allocator = context.allocator)
	defer delete(plain_dir, context.allocator)

	testing.expect_value(t, ensure_fixture_root(base), os.Error(nil))
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
// Issue #202 fix round 2: base's own creation now goes through
// `ensure_fixture_root` alone -- fix round 1 kept a bare `os.make_directory`
// as the first call and asserted it nil, so a genuine leftover (a prior
// crashed run at the recycled pid) still reds this exact line before
// `ensure_fixture_root` ever runs. `ensure_fixture_root` is itself tolerant
// of that leftover, so it is the only creation this site needs.
@(test)
a_stray_test_file_directly_under_a_package_root_is_reported_not_asserted :: proc(t: ^testing.T) {
	base, base_ok := fixture_root(t, "transcibr-policy-stray-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}

	testing.expect_value(t, ensure_fixture_root(base), os.Error(nil))
	defer testing.expect_value(t, os.remove(base), os.Error(nil))

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
ACCOUNTING_FIXTURE_DIRS :: []string {
	"src",
	"src/kept",
	"src/hollow",
	"tools",
	"tools/newtool",
	"tools/bare",
	"tools/hollow",
}
// `src/hollow/hollow_test.odin` and `tools/hollow/hollow_test.odin` are the
// files this fixture plants with NO `@(test)` procedure at all -- issue
// #174's own shape, a `*_test.odin` file whose test procedure was rewritten
// away while the file itself stayed put. Both roots get one: the reviewer's
// round 1 finding measured that a mutation silencing the new check for
// `tools/` alone left the whole suite green, because only `src/hollow`
// existed to prove the check fires at all. Every other `_test.odin` file
// gets a real `@(test)` procedure so the new check this ticket adds does not
// flag them for a reason unrelated to what they are already planted to
// exercise.
@(private)
ACCOUNTING_FIXTURE_TEST_SOURCE :: "package fixture\n\nimport \"core:testing\"\n\n@(test)\nchecks_something :: proc(t: ^testing.T) {\n\t_ = t\n}\n"
@(private)
ACCOUNTING_FIXTURE_HOLLOW_SOURCE :: "package fixture\n\n@(private)\nchecks_something :: proc() {\n}\n"

ACCOUNTING_FIXTURE_FILES :: []Fixture_File {
	{"src/kept/kept_test.odin", ACCOUNTING_FIXTURE_TEST_SOURCE},
	{"src/hollow/hollow_test.odin", ACCOUNTING_FIXTURE_HOLLOW_SOURCE},
	{"tools/newtool/newtool.odin", "package fixture\n"},
	{"tools/newtool/newtool_test.odin", ACCOUNTING_FIXTURE_TEST_SOURCE},
	{"tools/bare/bare.odin", "package fixture\n"},
	{"tools/stray_test.odin", ACCOUNTING_FIXTURE_TEST_SOURCE},
	{"tools/hollow/hollow_test.odin", ACCOUNTING_FIXTURE_HOLLOW_SOURCE},
}
ACCOUNTING_FIXTURE_JUSTFILE :: "test:\n\todin test src/kept {{vet}}\n\todin test src/hollow {{vet}}\n\todin test tools/hollow {{vet}}\n"

@(test)
tools_packages_are_accounted_for_beside_src_packages :: proc(t: ^testing.T) {
	base, base_ok := fixture_root(t, "transcibr-policy-tools-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}
	plant_fixture(
		t,
		base,
		ACCOUNTING_FIXTURE_DIRS,
		ACCOUNTING_FIXTURE_FILES,
		ACCOUNTING_FIXTURE_JUSTFILE,
	)
	defer testing.expect_value(
		t,
		remove_fixture(base, ACCOUNTING_FIXTURE_DIRS, ACCOUNTING_FIXTURE_FILES),
		os.Error(nil),
	)

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	check_package_accounting(base, &violations, context.allocator)

	testing.expect_value(t, len(violations), 5)
	testing.expect(
		t,
		violations_mention(violations, "tools/newtool holds a *_test.odin file but is not named"),
	)
	testing.expect(t, violations_mention(violations, "tools/bare holds no *_test.odin file"))
	testing.expect(t, violations_mention(violations, "belongs to no package under tools/"))
	testing.expect(
		t,
		violations_mention(violations, "src/hollow holds a *_test.odin file but no @(test)"),
	)
	testing.expect(
		t,
		violations_mention(violations, "tools/hollow holds a *_test.odin file but no @(test)"),
	)
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

// `fixture_path`, `fixture_root` and `ensure_fixture_root` live in
// fixture_test.odin now -- shared by every fixture family in this package,
// not just this file's own.

// The tolerance above, proven against a real leftover: an EMPTY directory
// already sitting at `base` when `ensure_fixture_root` runs must not be
// reported as `Exist` -- it must be silently removed and recreated, leaving
// `base` present and empty either way. Issue #202 fix round 2: the first
// call below IS the leftover -- it is the only creation `base` gets before
// the arm, so a genuine pre-existing leftover is exactly what it tolerates
// (fix round 1 still asserted a bare `os.make_directory(base)` nil ahead of
// it, which reds on a real leftover instead of proving anything about it).
// The second call then runs against a directory `ensure_fixture_root`
// itself just left empty, exercising the Exist-and-empty branch on purpose.
@(test)
ensure_fixture_root_tolerates_an_existing_empty_leftover_directory :: proc(t: ^testing.T) {
	base, base_ok := fixture_root(t, "transcibr-policy-leftover-fixture", context.allocator)
	defer delete(base, context.allocator)
	testing.expect_value(t, base_ok, true)
	if !base_ok {
		return
	}

	testing.expect_value(t, ensure_fixture_root(base), os.Error(nil))
	testing.expect_value(t, ensure_fixture_root(base), os.Error(nil))
	defer testing.expect_value(t, os.remove(base), os.Error(nil))

	testing.expect(t, os.exists(base), "ensure_fixture_root did not leave base present")
}

// The negative space (CLAUDE.md rule A3): a NON-empty leftover is a real
// collision, not a stale one, and must still be refused rather than
// silently swallowed. Issue #202 fix round 2: `base`'s own creation goes
// through `ensure_fixture_root` alone, so a genuine leftover at this name is
// tolerated here too rather than reding the setup line itself (fix round 1
// still asserted a bare `os.make_directory(base)` nil ahead of it).
@(test)
ensure_fixture_root_refuses_a_nonempty_existing_directory :: proc(t: ^testing.T) {
	base, base_ok := fixture_root(t, "transcibr-policy-dirty-leftover-fixture", context.allocator)
	defer delete(base, context.allocator)
	testing.expect_value(t, base_ok, true)
	if !base_ok {
		return
	}

	testing.expect_value(t, ensure_fixture_root(base), os.Error(nil))
	stray := fixture_path(base, "stray.txt", context.allocator)
	defer delete(stray, context.allocator)
	testing.expect_value(t, os.write_entire_file(stray, []byte{}), os.Error(nil))

	testing.expect_value(t, ensure_fixture_root(base), os.Error(os.General_Error.Exist))

	testing.expect_value(t, os.remove(stray), os.Error(nil))
	testing.expect_value(t, os.remove(base), os.Error(nil))
}

// `plant_accounting_fixture`/`remove_accounting_fixture` are gone -- this
// family now plants and removes through `plant_fixture`/`remove_fixture` in
// fixture_test.odin, the same shape every other family in this package uses.

// The exact pid-collision failure mode the #109 review measured: the OLD
// shape's name -- `os.get_env("TEMP")` concatenated straight onto the
// fixture name, no separator -- lands as a SIBLING of the temp directory
// rather than a child of it. This plants a real directory at that exact old
// shape (cleaned up by its exact path below) so the survival this test's
// name claims is a survival PROVEN against a real collision on disk, not
// just two strings that happen to differ: the new, join-based `fixture_root`
// must still build a distinct path that sits properly under `root` with the
// stray sitting right where the old bug would have put it. The old shape
// landed there because the bare env value carries no trailing separator; a
// recycled pid landing on such a stray made `os.make_directory` return
// `Exist` and turned unrelated tests red. Issue #202 fix round 1: the plant
// below used to be bare, with no tolerance of its own, at the one fixture
// path that sits outside %TEMP% and outside anything the suite sweeps -- a
// genuine leftover here (the ticket's own comment records ten such siblings
// in one review session) turned this test red with `got Exist`, and a crash
// mid-test would have left the directory permanently. Issue #202 fix round
// 2: this site's own creation now goes through `ensure_fixture_root` alone
// (fix round 1 still asserted a bare `os.make_directory(old_shape)` nil
// ahead of it, which reds on a genuine leftover instead of surviving one) --
// a real, non-empty collision there still fails loudly, since
// `ensure_fixture_root` refuses to touch a non-empty directory at all. Issue
// #202 fix round 3: `fixture_root` itself never touches the filesystem -- it
// only builds a string -- so the string comparisons below never actually
// exercised the collision this test's name claims to survive; deleting the
// plant left the test green. A file written into `old_shape` makes the
// collision real and non-empty, and `ensure_fixture_root(base)` -- creating
// the computed root for real, right beside the planted stray -- is the
// load-bearing proof: it only stays nil if `base` is a genuinely distinct,
// creatable path.
@(test)
fixture_root_survives_a_stray_directory_at_the_old_sibling_name :: proc(t: ^testing.T) {
	root := os.get_env("TEMP", context.allocator)
	defer delete(root, context.allocator)
	if !testing.expect(t, len(root) > 0, "TEMP names nowhere to plant the old-shape stray") {
		return
	}

	name := "transcibr-policy-mutation-fixture"
	old_shape := fmt.aprintf("%s%s-%d", root, name, os.get_pid(), allocator = context.allocator)
	defer delete(old_shape, context.allocator)

	testing.expect_value(t, ensure_fixture_root(old_shape), os.Error(nil))
	defer testing.expect_value(t, os.remove(old_shape), os.Error(nil))

	stray := fixture_path(old_shape, "stray.txt", context.allocator)
	defer delete(stray, context.allocator)
	testing.expect_value(t, os.write_entire_file(stray, []byte{}), os.Error(nil))
	defer testing.expect_value(t, os.remove(stray), os.Error(nil))

	base, base_ok := fixture_root(t, name, context.allocator)
	defer delete(base, context.allocator)

	testing.expect_value(t, base_ok, true)
	if !base_ok {
		return
	}
	testing.expect(t, base != old_shape)
	testing.expect(t, strings.has_prefix(base, root))

	testing.expect_value(t, ensure_fixture_root(base), os.Error(nil))
	defer testing.expect_value(t, os.remove(base), os.Error(nil))
}

// Fix round 1 finding 1's own regression test -- strip the real justfile's
// `odin test tools/policy` line and require `missing_from_test_recipe` to
// still report `policy` missing -- is gone from here. Issue #222 work item 2
// generalizes it: `justfile_guard_test.odin`'s
// `every_tested_packages_own_test_line_reddens_the_accounting_check_when_stripped`
// runs the same mutation over EVERY real tested package under both roots,
// `tools/policy` included, so this file's one hand-picked case is now a
// single iteration of that wider loop rather than a separate test.
