#+vet explicit-allocators
package policy

import "core:fmt"
import "core:os"
import "core:testing"

@(test)
cli_is_the_one_exempt_package :: proc(t: ^testing.T) {
	testing.expect_value(t, is_test_less_package("cli"), true)
	testing.expect_value(t, is_test_less_package("child"), false)
}

@(test)
a_package_named_in_the_justfile_is_not_missing :: proc(t: ^testing.T) {
	justfile := "test:\n\todin test src/child {{vet}}\n\todin test tools/policy {{vet}}\n"
	missing := missing_from_test_recipe([]string{"child"}, justfile, context.allocator)
	defer delete(missing, context.allocator)

	testing.expect_value(t, len(missing), 0)
}

@(test)
a_package_absent_from_the_justfile_is_missing :: proc(t: ^testing.T) {
	justfile := "test:\n\todin test src/child {{vet}}\n"
	missing := missing_from_test_recipe([]string{"child", "audio"}, justfile, context.allocator)
	defer {
		for name in missing {
			delete(name, context.allocator)
		}
		delete(missing, context.allocator)
	}

	testing.expect_value(t, len(missing), 1)
	testing.expect_value(t, missing[0], "audio")
}

@(test)
the_test_less_package_is_never_reported_missing :: proc(t: ^testing.T) {
	missing := missing_from_test_recipe([]string{"cli"}, "test:\n", context.allocator)
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
	missing := missing_from_test_recipe([]string{"child"}, justfile, context.allocator)
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
	missing := missing_from_test_recipe([]string{"plan"}, justfile, context.allocator)
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
	offending := exempt_packages_holding_tests([]string{"cli", "child"}, context.allocator)
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
	offending := exempt_packages_holding_tests([]string{"child", "audio"}, context.allocator)
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
tested_src_packages_finds_only_directories_holding_a_test_file :: proc(t: ^testing.T) {
	root, root_err := os.temp_dir(context.allocator)
	testing.expect_value(t, root_err, nil)
	defer delete(root, context.allocator)

	base := fmt.aprintf(
		"%stranscibr-policy-fixture-%d",
		root,
		os.get_pid(),
		allocator = context.allocator,
	)
	defer delete(base, context.allocator)
	tested_dir := fmt.aprintf("%s/tested", base, allocator = context.allocator)
	defer delete(tested_dir, context.allocator)
	plain_dir := fmt.aprintf("%s/plain", base, allocator = context.allocator)
	defer delete(plain_dir, context.allocator)

	testing.expect_value(t, os.make_directory(base), os.Error(nil))
	testing.expect_value(t, os.make_directory(tested_dir), os.Error(nil))
	testing.expect_value(t, os.make_directory(plain_dir), os.Error(nil))
	defer os.remove(plain_dir)
	defer os.remove(tested_dir)
	defer os.remove(base)

	tested_file := fmt.aprintf("%s/run_test.odin", tested_dir, allocator = context.allocator)
	defer delete(tested_file, context.allocator)
	plain_file := fmt.aprintf("%s/run.odin", plain_dir, allocator = context.allocator)
	defer delete(plain_file, context.allocator)
	testing.expect_value(t, os.write_entire_file(tested_file, []byte{}), os.Error(nil))
	defer os.remove(tested_file)
	testing.expect_value(t, os.write_entire_file(plain_file, []byte{}), os.Error(nil))
	defer os.remove(plain_file)

	names, strays, ok := tested_src_packages(base, context.allocator)
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

// A `*_test.odin` file sitting directly in `src_root` -- not inside any
// package directory -- belongs to no package. It must be reported through
// `strays`, never folded into `names` under an empty name: that empty name
// used to reach `is_test_less_package`'s `assert(len(name) > 0, ...)` and
// crash the whole `just check` run instead of reporting a violation (A8).
@(test)
a_stray_test_file_directly_under_src_root_is_reported_not_asserted :: proc(t: ^testing.T) {
	root, root_err := os.temp_dir(context.allocator)
	testing.expect_value(t, root_err, nil)
	defer delete(root, context.allocator)

	base := fmt.aprintf(
		"%stranscibr-policy-stray-fixture-%d",
		root,
		os.get_pid(),
		allocator = context.allocator,
	)
	defer delete(base, context.allocator)

	testing.expect_value(t, os.make_directory(base), os.Error(nil))
	defer os.remove(base)

	stray_file := fmt.aprintf("%s/stray_test.odin", base, allocator = context.allocator)
	defer delete(stray_file, context.allocator)
	testing.expect_value(t, os.write_entire_file(stray_file, []byte{}), os.Error(nil))
	defer os.remove(stray_file)

	names, strays, ok := tested_src_packages(base, context.allocator)
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
