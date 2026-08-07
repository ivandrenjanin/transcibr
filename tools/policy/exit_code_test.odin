#+vet explicit-allocators
// #184's second residual: the `os.exit(VIOLATION_ERROR)` mapping in `main`
// had no coverage at all. Every other test in this package calls
// `check_repository` (or a collaborator under it) in-process and reads the
// `[]Violation` it returns -- none of them ever runs `main` itself, so an
// inverted or dropped `os.exit` mapping (report violations, exit 0 anyway)
// would leave the whole suite green. The only seam that can see `main`'s own
// exit code is the process boundary: spawn the built `tools/policy` binary
// as a CHILD process, the way `src/crashlog`'s crash-drill tests spawn
// `transcribr-cli`, and read back the code it exited with.
//
// The `test` recipe builds `build\odin-test\policy-cli.exe` before running
// this package's tests, the same way it builds the crash-drill binary before
// `src/crashlog`'s tests run. Running `just test-one policy <name>` for one
// of these in isolation needs that build line run first, by hand:
// `odin build tools/policy -collection:transcibr=src -out:build/odin-test/policy-cli.exe <vet set>`.
package policy

import "core:os"
import "core:testing"
import "core:time"

@(private)
POLICY_CLI :: "build\\odin-test\\policy-cli.exe"

@(private)
POLICY_BOUND :: 30 * time.Second

// Spawns `policy-cli.exe <root>`, waits for it to end, and hands back the
// code it ended with.
@(private)
@(require_results)
policy_exit_code :: proc(t: ^testing.T, root: string) -> (code: int, exited: bool) {
	assert(t != nil, "there is no test here to report a policy-cli failure through")
	assert(len(root) > 0, "asked to run policy-cli against no root at all")

	p, start_err := os.process_start({command = {POLICY_CLI, root}})
	if !testing.expectf(t, start_err == nil, "policy-cli did not start: %v", start_err) {
		return 0, false
	}

	state, wait_err := os.process_wait(p, POLICY_BOUND)
	if !testing.expectf(
		t,
		wait_err == nil,
		"policy-cli did not exit within the bound: %v",
		wait_err,
	) {
		_ = os.process_kill(p)
		return 0, false
	}
	return state.exit_code, state.exited
}

EXIT_CLEAN_DIRS :: []string{"src", "src/pkg", "tools"}

EXIT_CLEAN_FILES :: []E2E_Fixture_File {
	{
		"src/pkg/pkg_test.odin",
		"#+vet explicit-allocators\npackage pkg\n\nimport \"core:testing\"\n\n@(test)\nchecks :: proc(t: ^testing.T) {\n}\n",
	},
}

EXIT_CLEAN_JUSTFILE :: "test:\n\todin test src/pkg {{vet}}\n"

// The dirty fixture is the clean one plus one file with no
// `#+vet explicit-allocators` tag at all -- the single, minimal M2 violation
// CLAUDE.md rule M2 requires every file to carry.
EXIT_DIRTY_FILES :: []E2E_Fixture_File {
	{
		"src/pkg/pkg_test.odin",
		"#+vet explicit-allocators\npackage pkg\n\nimport \"core:testing\"\n\n@(test)\nchecks :: proc(t: ^testing.T) {\n}\n",
	},
	{"src/pkg/bad.odin", "package pkg\n\nhelp :: proc() {\n}\n"},
}

plant_exit_fixture :: proc(t: ^testing.T, base: string, files: []E2E_Fixture_File) {
	assert(t != nil, "asked to plant an exit-code fixture for no test at all")
	assert(len(base) > 0, "asked to plant an exit-code fixture at no path at all")

	testing.expect_value(t, os.make_directory(base), os.Error(nil))
	for name in EXIT_CLEAN_DIRS {
		path := fixture_path(base, name, context.allocator)
		defer delete(path, context.allocator)
		testing.expect_value(t, os.make_directory(path), os.Error(nil))
	}

	for file in files {
		path := fixture_path(base, file.path, context.allocator)
		defer delete(path, context.allocator)
		testing.expect_value(
			t,
			os.write_entire_file(path, transmute([]byte)file.content),
			os.Error(nil),
		)
	}

	justfile := fixture_path(base, "justfile", context.allocator)
	defer delete(justfile, context.allocator)
	recipe := EXIT_CLEAN_JUSTFILE
	testing.expect_value(t, os.write_entire_file(justfile, transmute([]byte)recipe), os.Error(nil))
}

@(require_results)
remove_exit_fixture :: proc(base: string, files: []E2E_Fixture_File) -> os.Error {
	assert(len(base) > 0, "asked to remove an exit-code fixture at no path at all")

	justfile := fixture_path(base, "justfile", context.allocator)
	defer delete(justfile, context.allocator)
	os.remove(justfile)

	for file in files {
		path := fixture_path(base, file.path, context.allocator)
		defer delete(path, context.allocator)
		os.remove(path)
	}
	#reverse for name in EXIT_CLEAN_DIRS {
		path := fixture_path(base, name, context.allocator)
		defer delete(path, context.allocator)
		os.remove(path)
	}
	return os.remove(base)
}

// The `os.exit(VIOLATION_ERROR)` half of the pin: a repository holding one
// violation must exit `VIOLATION_ERROR`, not 0. Before the #184 fix this
// still passed (the exit mapping itself was never inverted or dropped on
// this tree) -- what was missing was ANY test able to see it break, which is
// what this test now is.
@(test)
main_exits_violation_error_on_a_dirty_repository :: proc(t: ^testing.T) {
	base, base_ok := fixture_root("transcibr-policy-exit-code-dirty-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}
	plant_exit_fixture(t, base, EXIT_DIRTY_FILES)
	defer testing.expect_value(t, remove_exit_fixture(base, EXIT_DIRTY_FILES), os.Error(nil))

	code, exited := policy_exit_code(t, base)
	testing.expect_value(t, exited, true)
	testing.expect_value(t, code, VIOLATION_ERROR)
}

// The other half: a repository holding no violations at all must exit 0, the
// silent-green failure the ticket named (an inverted mapping would exit
// VIOLATION_ERROR here instead).
@(test)
main_exits_zero_on_a_clean_repository :: proc(t: ^testing.T) {
	base, base_ok := fixture_root("transcibr-policy-exit-code-clean-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}
	plant_exit_fixture(t, base, EXIT_CLEAN_FILES)
	defer testing.expect_value(t, remove_exit_fixture(base, EXIT_CLEAN_FILES), os.Error(nil))

	code, exited := policy_exit_code(t, base)
	testing.expect_value(t, exited, true)
	testing.expect_value(t, code, 0)
}
