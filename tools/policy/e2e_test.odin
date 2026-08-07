#+vet explicit-allocators
// This file is the end-to-end test issue #156 asked for: a planted fixture
// repository, small enough to hand-read, run through `check_repository`
// itself rather than through any one collaborator underneath it. Every other
// test in this package either hands a string fixture to `read_source`
// (policy_test.odin, check_test.odin) or calls `check_package_accounting`
// directly (packages_test.odin) -- both stop below the seam that discovers
// files, checks each one, and appends the accounting violations after them.
// A regression in that wiring itself (a root never passed to accounting, a
// violation list silently dropped, files checked but accounting skipped)
// would leave every one of those tests green; this is the one test that
// would not.
package policy

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

// The fixture's shape: two packages under `src/` sharing one directory --
// `kept`, tested and named in the planted justfile -- and two packages under
// `tools/`, one tested but unnamed and one holding no test file at all, plus
// one `*_test.odin` file sitting directly under `tools/` and belonging to no
// package. Directories are listed parent before child, the order
// `os.make_directory` needs and `remove_e2e_fixture` walks in reverse.
E2E_FIXTURE_DIRS :: []string{"src", "src/kept", "tools", "tools/newtool", "tools/bare"}

// `messy.odin` is the one file in this fixture with anything wrong with it,
// on purpose: a comment inside a procedure body (section 0), a returning
// procedure with no `@(require_results)` (rule F2), and no `#+vet
// explicit-allocators` tag at all (rule M2) -- three violations from the one
// file `check_one_file` reads, in the order `collect_violations` computes
// them. Every other planted file declares its vet tag and stays clean, so
// the only violations `check_repository` can report are these three plus
// whatever `check_package_accounting` finds over the directory shape itself.
E2E_Fixture_File :: struct {
	path:    string,
	content: string,
}

E2E_FIXTURE_FILES :: []E2E_Fixture_File {
	{
		"src/kept/kept_test.odin",
		"#+vet explicit-allocators\npackage kept\n\nimport \"core:testing\"\n\n@(test)\nchecks :: proc(t: ^testing.T) {\n}\n",
	},
	{
		"src/kept/messy.odin",
		"package kept\n\nanswers :: proc(x: int) -> bool {\n\t// this comment trips section 0\n\treturn x > 0\n}\n",
	},
	{
		"tools/newtool/newtool.odin",
		"#+vet explicit-allocators\npackage newtool\n\nhelp :: proc() {\n}\n",
	},
	{
		"tools/newtool/newtool_test.odin",
		"#+vet explicit-allocators\npackage newtool\n\nimport \"core:testing\"\n\n@(test)\nchecks :: proc(t: ^testing.T) {\n}\n",
	},
	{"tools/bare/bare.odin", "#+vet explicit-allocators\npackage bare\n\nhelp :: proc() {\n}\n"},
	{
		"tools/stray_test.odin",
		"#+vet explicit-allocators\npackage stray\n\nimport \"core:testing\"\n\n@(test)\nchecks :: proc(t: ^testing.T) {\n}\n",
	},
}

E2E_FIXTURE_JUSTFILE :: "test:\n\todin test src/kept {{vet}}\n"

// The whole run, over the whole fixture: discovery, per-file rendering,
// package accounting across both roots, and violation aggregation, all
// exercised by the one seam `main` itself calls. Ordering is asserted too --
// `check_repository` appends every per-file violation before it ever calls
// `check_package_accounting`, so the three violations `messy.odin` carries
// come first, in the order section 0, rule F2, rule M2 read (`collect_violations`),
// followed by the accounting violations in the order `check_root_accounting`
// computes them for the `tools/` scope: strays, then untested packages, then
// packages missing from the recipe. `src/` contributes none of its own,
// since `kept` is both tested and named.
@(test)
check_repository_reports_the_full_violation_set_over_a_planted_fixture :: proc(t: ^testing.T) {
	root, root_err := os.temp_dir(context.allocator)
	testing.expect_value(t, root_err, nil)
	defer delete(root, context.allocator)

	base := fmt.aprintf(
		"%stranscibr-policy-e2e-fixture-%d",
		root,
		os.get_pid(),
		allocator = context.allocator,
	)
	defer delete(base, context.allocator)
	plant_e2e_fixture(t, base)
	defer remove_e2e_fixture(base)

	violations := check_repository(base, context.allocator)
	defer violations_destroy(violations, context.allocator)
	defer delete(violations)

	testing.expect_value(t, len(violations), 6)
	if len(violations) != 6 {
		return
	}

	testing.expect_value(t, violations[0].file, "src/kept/messy.odin")
	testing.expect(t, strings.contains(violations[0].message, "comment inside answers"))

	testing.expect_value(t, violations[1].file, "src/kept/messy.odin")
	testing.expect(
		t,
		strings.contains(
			violations[1].message,
			"answers hands back an answer with no @(require_results)",
		),
	)

	testing.expect_value(t, violations[2].file, "src/kept/messy.odin")
	testing.expect(
		t,
		strings.contains(violations[2].message, "does not declare #+vet explicit-allocators"),
	)

	testing.expect(t, strings.contains(violations[3].file, "stray_test.odin"))
	testing.expect(
		t,
		strings.contains(violations[3].message, "belongs to no package under tools/"),
	)

	testing.expect(
		t,
		strings.contains(violations[4].message, "tools/bare holds no *_test.odin file"),
	)

	testing.expect(
		t,
		strings.contains(
			violations[5].message,
			"tools/newtool holds a *_test.odin file but is not named",
		),
	)
}

@(require_results)
e2e_fixture_path :: proc(base: string, name: string, allocator: mem.Allocator) -> string {
	assert(len(base) > 0, "asked to name an e2e fixture file under no root at all")
	assert(len(name) > 0, "asked to name an e2e fixture file with no name at all")
	return fmt.aprintf("%s/%s", base, name, allocator = allocator)
}

// Plants the fixture, per-entry -- no `os.remove_all` counterpart is needed
// here since planting never removes anything, but the same hand-rolled
// per-path shape is used for both halves so the pairing (CLAUDE.md rule A4)
// reads the same way at both ends.
plant_e2e_fixture :: proc(t: ^testing.T, base: string) {
	assert(t != nil, "asked to plant an e2e fixture for no test at all")
	assert(len(base) > 0, "asked to plant an e2e fixture at no path at all")

	testing.expect_value(t, os.make_directory(base), os.Error(nil))
	for name in E2E_FIXTURE_DIRS {
		path := e2e_fixture_path(base, name, context.allocator)
		defer delete(path, context.allocator)
		testing.expect_value(t, os.make_directory(path), os.Error(nil))
	}

	for file in E2E_FIXTURE_FILES {
		path := e2e_fixture_path(base, file.path, context.allocator)
		defer delete(path, context.allocator)
		testing.expect_value(
			t,
			os.write_entire_file(path, transmute([]byte)file.content),
			os.Error(nil),
		)
	}

	justfile := e2e_fixture_path(base, "justfile", context.allocator)
	defer delete(justfile, context.allocator)
	recipe := E2E_FIXTURE_JUSTFILE
	testing.expect_value(t, os.write_entire_file(justfile, transmute([]byte)recipe), os.Error(nil))
}

// Removes the fixture, per-entry: the #97/#105 rule (CLAUDE.md's Odin notes)
// bans `os.remove_all` anywhere in this tree, build-enforced by
// `collect_remove_all_violations` itself, so teardown here follows the same
// hand-rolled shape `packages_test.odin`'s own fixtures already use -- files
// first, then directories in reverse (child before parent), then the base.
remove_e2e_fixture :: proc(base: string) {
	assert(len(base) > 0, "asked to remove an e2e fixture at no path at all")

	justfile := e2e_fixture_path(base, "justfile", context.allocator)
	defer delete(justfile, context.allocator)
	os.remove(justfile)

	for file in E2E_FIXTURE_FILES {
		path := e2e_fixture_path(base, file.path, context.allocator)
		defer delete(path, context.allocator)
		os.remove(path)
	}
	#reverse for name in E2E_FIXTURE_DIRS {
		path := e2e_fixture_path(base, name, context.allocator)
		defer delete(path, context.allocator)
		os.remove(path)
	}
	os.remove(base)
}
