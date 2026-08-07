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

EXIT_CLEAN_FILES :: []Fixture_File {
	{
		"src/pkg/pkg_test.odin",
		"#+vet explicit-allocators\npackage pkg\n\nimport \"core:testing\"\n\n@(test)\nchecks :: proc(t: ^testing.T) {\n}\n",
	},
}

EXIT_CLEAN_JUSTFILE :: "test:\n\todin test src/pkg {{vet}}\n"

// The dirty fixture is the clean one plus one file with no
// `#+vet explicit-allocators` tag at all -- the single, minimal M2 violation
// CLAUDE.md rule M2 requires every file to carry.
EXIT_DIRTY_FILES :: []Fixture_File {
	{
		"src/pkg/pkg_test.odin",
		"#+vet explicit-allocators\npackage pkg\n\nimport \"core:testing\"\n\n@(test)\nchecks :: proc(t: ^testing.T) {\n}\n",
	},
	{"src/pkg/bad.odin", "package pkg\n\nhelp :: proc() {\n}\n"},
}

// `plant_exit_fixture`/`remove_exit_fixture` are gone -- #184's near-verbatim
// copy of the accounting and e2e planters now plants and removes through
// `plant_fixture`/`remove_fixture` in fixture_test.odin, the one shape every
// fixture family in this package uses (issue #202's consolidation item).
// Both dirty and clean fixtures write the same justfile: `EXIT_CLEAN_JUSTFILE`
// names `src/pkg`, and both `EXIT_CLEAN_FILES` and `EXIT_DIRTY_FILES` still
// plant a real `src/pkg/pkg_test.odin` for it to name.

// The `os.exit(VIOLATION_ERROR)` half of the pin: a repository holding one
// violation must exit `VIOLATION_ERROR`, not 0. Before the #184 fix this
// still passed (the exit mapping itself was never inverted or dropped on
// this tree) -- what was missing was ANY test able to see it break, which is
// what this test now is.
@(test)
main_exits_violation_error_on_a_dirty_repository :: proc(t: ^testing.T) {
	base, base_ok := fixture_root(t, "transcibr-policy-exit-code-dirty-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}
	plant_fixture(t, base, EXIT_CLEAN_DIRS, EXIT_DIRTY_FILES, EXIT_CLEAN_JUSTFILE)
	defer testing.expect_value(
		t,
		remove_fixture(base, EXIT_CLEAN_DIRS, EXIT_DIRTY_FILES),
		os.Error(nil),
	)

	code, exited := policy_exit_code(t, base)
	testing.expect_value(t, exited, true)
	testing.expect_value(t, code, VIOLATION_ERROR)
}

// The other half: a repository holding no violations at all must exit 0, the
// silent-green failure the ticket named (an inverted mapping would exit
// VIOLATION_ERROR here instead).
@(test)
main_exits_zero_on_a_clean_repository :: proc(t: ^testing.T) {
	base, base_ok := fixture_root(t, "transcibr-policy-exit-code-clean-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}
	plant_fixture(t, base, EXIT_CLEAN_DIRS, EXIT_CLEAN_FILES, EXIT_CLEAN_JUSTFILE)
	defer testing.expect_value(
		t,
		remove_fixture(base, EXIT_CLEAN_DIRS, EXIT_CLEAN_FILES),
		os.Error(nil),
	)

	code, exited := policy_exit_code(t, base)
	testing.expect_value(t, exited, true)
	testing.expect_value(t, code, 0)
}
