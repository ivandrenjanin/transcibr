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
// would not. Round 1 of the #156 review measured that four wiring seams --
// collect_length_violations, collect_remove_all_violations,
// collect_network_violations, and report_exempt_packages_holding_tests --
// could each be deleted from their call sites with this fixture (and the
// whole 89-test suite) still green, so this fixture now plants what each of
// those four needs to fire at least once.
package policy

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"

// The fixture's shape: under `src/`, one package holding tests and named in
// the planted justfile (`kept`) beside one holding none at all and excused
// by no roster (`spare`), beside one the repository's own
// TEST_LESS_SRC_PACKAGES roster names test-less (`cli`) that holds a test
// file anyway; under `tools/`, one package holding tests but unnamed in the
// recipe (`newtool`) beside one holding none at all -- `tools/` has no
// exemption roster, so `bare` is a violation however it is named -- plus one
// `*_test.odin` file sitting directly under `tools/` and belonging to no
// package. Directories are listed parent before child, the order
// `os.make_directory` needs and `remove_e2e_fixture` walks in reverse.
E2E_FIXTURE_DIRS :: []string {
	"src",
	"src/kept",
	"src/spare",
	"src/cli",
	"tools",
	"tools/newtool",
	"tools/bare",
}

// `messy.odin` is the one file in this fixture with anything wrong with it,
// on purpose, and every per-file violation this program can compute comes
// from this one file so the file-discovery walk order never affects the
// assertion below: a `winhttp` string outside `src/net/winhttp.odin` (the
// network-confinement check), a comment inside a procedure body (section 0),
// a 71-line procedure (rule F1), a returning procedure with no
// `@(require_results)` (rule F2), no `#+vet explicit-allocators` tag at all
// (rule M2), and an `os.remove_all(...)` call (issue #97/#105). Every other
// planted file declares its vet tag, names no network code, calls no
// `remove_all`, and stays within the line limit, so the only per-file
// violations `check_repository` can report are these six.
E2E_Fixture_File :: struct {
	path:    string,
	content: string,
}

// `padded`'s 69 blank lines between its header and its closing brace put its
// own span at 71 lines, one over CLAUDE.md rule F1's 70-line limit -- rule
// F1 counts "comments and blanks included", so blank lines are the cheapest
// way to plant a violation without planting real, reviewable-looking code.
MESSY_ODIN_CONTENT :: `package kept

import "core:os"

winhttp_name :: "winhttp"

answers :: proc(x: int) -> bool {
	// this comment trips section 0
	return x > 0
}

padded :: proc() {





































































}

wipes :: proc() {
	os.remove_all("x")
}
`

E2E_FIXTURE_FILES :: []E2E_Fixture_File {
	{
		"src/kept/kept_test.odin",
		"#+vet explicit-allocators\npackage kept\n\nimport \"core:testing\"\n\n@(test)\nchecks :: proc(t: ^testing.T) {\n}\n",
	},
	{"src/kept/messy.odin", MESSY_ODIN_CONTENT},
	{"src/spare/spare.odin", "#+vet explicit-allocators\npackage spare\n\nhelp :: proc() {\n}\n"},
	{
		"src/cli/cli_test.odin",
		"#+vet explicit-allocators\npackage cli\n\nimport \"core:testing\"\n\n@(test)\nchecks :: proc(t: ^testing.T) {\n}\n",
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
// `check_package_accounting`, so the six violations `messy.odin` carries come
// first, in the order `check_one_file` computes them: the network check, then
// `collect_violations`' own fixed order (section 0, rule F1, rule F2, rule
// M2, then the #97/#105 ban). `check_package_accounting` then runs the `src/`
// scope before the `tools/` one, and within each scope `check_root_accounting`
// computes strays, then untested packages, then exempt packages holding
// tests, then packages missing from the recipe, in that fixed order -- `src/`
// has no stray and nothing missing from the recipe, only its untested
// package (`spare`) and its exempt package holding tests (`cli`), so the
// ordering collapses to: `spare` untested, then `cli` exempt-holding-tests,
// then the three `tools/` violations.
@(test)
check_repository_reports_the_full_violation_set_over_a_planted_fixture :: proc(t: ^testing.T) {
	base, base_ok := fixture_root("transcibr-policy-e2e-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	plant_e2e_fixture(t, base)
	defer remove_e2e_fixture(base)

	violations := check_repository(base, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)

	testing.expect_value(t, len(violations), 11)
	if len(violations) != 11 {
		return
	}

	expect_e2e_violation(
		t,
		violations,
		0,
		"src/kept/messy.odin",
		"'winhttp' appears outside src/net/winhttp.odin",
	)
	expect_e2e_violation(t, violations, 1, "src/kept/messy.odin", "comment inside answers")
	expect_e2e_violation(
		t,
		violations,
		2,
		"src/kept/messy.odin",
		"padded is 71 lines, over CLAUDE.md rule F1's 70-line limit",
	)
	expect_e2e_violation(
		t,
		violations,
		3,
		"src/kept/messy.odin",
		"answers hands back an answer with no @(require_results)",
	)
	expect_e2e_violation(
		t,
		violations,
		4,
		"src/kept/messy.odin",
		"does not declare #+vet explicit-allocators",
	)
	expect_e2e_violation(t, violations, 5, "src/kept/messy.odin", "os.remove_all(...) call")
	expect_e2e_violation(t, violations, 6, "", "src/spare holds no *_test.odin file")
	expect_e2e_violation(t, violations, 7, "", "src/cli is declared test-less but holds")
	expect_e2e_violation(t, violations, 8, "stray_test.odin", "belongs to no package under tools/")
	expect_e2e_violation(t, violations, 9, "", "tools/bare holds no *_test.odin file")
	expect_e2e_violation(
		t,
		violations,
		10,
		"",
		"tools/newtool holds a *_test.odin file but is not named",
	)
}

// One violation's file (when `file_contains` is non-empty) and message,
// checked by substring -- factored out so the test above stays inside
// CLAUDE.md rule F1's 70-line limit despite asserting all eleven entries.
expect_e2e_violation :: proc(
	t: ^testing.T,
	violations: [dynamic]Violation,
	index: int,
	file_contains: string,
	message_contains: string,
) {
	assert(t != nil, "asked to check a violation for no test at all")
	assert(len(message_contains) > 0, "asked to check a violation with nothing expected in it")
	if len(file_contains) > 0 {
		testing.expect(t, strings.contains(violations[index].file, file_contains))
	}
	testing.expect(t, strings.contains(violations[index].message, message_contains))
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
