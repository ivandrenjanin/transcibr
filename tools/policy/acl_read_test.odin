#+vet explicit-allocators
// Issue #222's #169 deposit: `check_one_file`'s `fmt.aprintf("cannot be read:
// %v", ...)` (main.odin) had no coverage anywhere in this package -- with
// `Fault.Unreadable` deleted (the #169 review), that aprintf is now the ONLY
// rendering of a read failure this program can produce, so an inversion or a
// dropped call there would be silent. A real read failure needs a real file
// this account cannot read, which needs a real ACL deny -- `core:os` has no
// way to fake `Permission_Denied` from inside the process. The deny/undeny
// discipline below follows `src/planning/access_test.odin`'s own (issue
// #179): deny right before the operation under test, restore immediately
// after, no assert inside the window -- a run that dies between the two
// leaves the deny rule on disk, and `testing.expect` survives that where
// `assert` would not.
package policy

import "core:fmt"
import "core:os"
import "core:testing"
import "core:time"

@(private)
ACL_ICACLS :: "icacls.exe"

@(private)
@(require_results)
acl_denied :: proc(t: ^testing.T, path: string, rights: string) -> bool {
	who := os.get_env("USERNAME", context.allocator)
	defer delete(who, context.allocator)
	if !testing.expect(t, len(who) > 0, "USERNAME names nobody to deny anything to") {
		return false
	}

	rule := fmt.aprintf("%s:%s", who, rights, allocator = context.allocator)
	defer delete(rule, context.allocator)
	p, start_err := os.process_start({command = {ACL_ICACLS, path, "/deny", rule}})
	if !testing.expectf(t, start_err == nil, "icacls did not start: %v", start_err) {
		return false
	}
	state, wait_err := os.process_wait(p, 10 * time.Second)
	return(
		testing.expectf(t, wait_err == nil, "icacls did not finish denying: %v", wait_err) &&
		testing.expect(t, state.exited, "icacls did not run to completion denying access") \
	)
}

// What this answers is that the child ran to completion, never that icacls
// actually cleared a rule it could not find -- the next case to use `path` is
// what would be confused by a leftover deny, and nothing here can tell it so.
@(private)
acl_undenied :: proc(t: ^testing.T, path: string) {
	who := os.get_env("USERNAME", context.allocator)
	defer delete(who, context.allocator)
	if len(who) == 0 {
		return
	}

	p, start_err := os.process_start({command = {ACL_ICACLS, path, "/remove:d", who}})
	if !testing.expect(t, start_err == nil, "icacls did not start to undo a deny") {
		return
	}
	_, wait_err := os.process_wait(p, 10 * time.Second)
	testing.expect(
		t,
		wait_err == nil,
		"icacls did not run to completion, so a deny this case set may still be on the tree",
	)
}

// The in-process half: `check_one_file` against a file this account is
// denied read access to must append the exact violation the untested aprintf
// renders, never crash and never silently skip the file.
@(test)
check_one_file_reports_cannot_be_read_for_an_acl_denied_source_file :: proc(t: ^testing.T) {
	base, base_ok := fixture_root(t, "transcibr-policy-acl-read-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}
	testing.expect_value(t, ensure_fixture_root(base), os.Error(nil))
	defer testing.expect_value(t, os.remove(base), os.Error(nil))

	shut := fixture_path(base, "shut.odin", context.allocator)
	defer delete(shut, context.allocator)
	testing.expect_value(
		t,
		os.write_entire_file(shut, transmute([]byte)string("package shut\n")),
		os.Error(nil),
	)
	defer os.remove(shut)

	if !acl_denied(t, shut, "(R)") {
		return
	}

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	check_one_file(base, "shut.odin", []string{}, &violations, context.allocator)

	acl_undenied(t, shut)

	testing.expect_value(t, len(violations), 1)
	if len(violations) == 1 {
		testing.expect(t, violations_mention(violations, "cannot be read:"))
	}
}

// The process-level half: what exit code the real binary answers with when
// one source file is unreadable. Measured, not assumed -- `Fault.Unreadable`
// is gone, so a read failure is folded into the ordinary per-file violation
// list `check_repository` returns, which is the same list every other
// violation drives `os.exit(VIOLATION_ERROR)` from. There is no separate
// ROOT_ERROR-shaped path for a file (as opposed to the repository root)
// being unreadable; this pins that measurement rather than a name.
@(test)
main_exits_violation_error_not_root_error_when_a_source_file_is_acl_denied :: proc(t: ^testing.T) {
	base, base_ok := fixture_root(t, "transcibr-policy-acl-exit-fixture", context.allocator)
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

	shut := fixture_path(base, "src/pkg/pkg_test.odin", context.allocator)
	defer delete(shut, context.allocator)
	if !acl_denied(t, shut, "(R)") {
		return
	}

	code, exited := policy_exit_code(t, base)
	acl_undenied(t, shut)

	testing.expect_value(t, exited, true)
	testing.expect_value(t, code, VIOLATION_ERROR)
}
