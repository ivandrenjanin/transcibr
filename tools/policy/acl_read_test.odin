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
import "core:slice"
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
// the fixture's only source file is ACL-denied. Since the #267 fix
// (`is_odin_source_candidate` in discover.odin), an ACL-denied file is no
// longer invisible to `discover_odin_files` -- it comes back with
// `entry.type == .Undetermined` and flows on to `check_one_file`, whose own
// read attempt renders the `"cannot be read:"` violation
// (`check_one_file_reports_cannot_be_read_for_an_acl_denied_source_file`
// above pins that rendering directly). THAT violation, not
// `check_repository`'s `len(files) == 0` guard, is what now drives
// `os.exit(VIOLATION_ERROR)` for this fixture -- the guard never fires here
// because the walk no longer reports zero files. This test only pins the
// process-level exit code; the zero-files guard itself is covered
// separately, on a fixture with no `.odin` files at all and no ACL deny, by
// `check_repository_reports_the_zero_files_guard_violation_over_a_repository_with_no_odin_files`
// below.
@(test)
main_exits_violation_error_for_an_acl_denied_sole_source_file :: proc(t: ^testing.T) {
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

// Issue #267: `discover_odin_files` itself is the silent-omission site. A
// deny-ACL'd file has its type left `.Undetermined` by `core:os`'s own
// `find_data_to_file_info` (`dir_windows.odin`: the per-entry open used only
// to classify the file type fails silently, `handle == nil`, and
// `_file_type_mode_from_file_attributes` never reaches the `h != nil` arm
// that would set `.Regular`) -- so the OLD `entry.type != .Regular`
// filter dropped it exactly like a non-`.odin` file, with no error recorded
// anywhere: `os.walker_error` stays nil because `find_data_to_file_info`
// itself returns `err == nil`. This is the review's own measurement: with a
// readable SIBLING present, only the sibling used to come back from this
// call, and the denied file vanished with no trace at this seam at all. The
// fix widens the filter to also collect an `.Undetermined`, non-empty-named
// entry whose name still ends `.odin` -- letting it flow on to
// `check_one_file`, whose own open attempt is what actually reports why.
@(test)
discover_odin_files_includes_an_acl_denied_odin_file_rather_than_omitting_it :: proc(
	t: ^testing.T,
) {
	base, base_ok := fixture_root(t, "transcibr-policy-acl-discover-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}
	testing.expect_value(t, ensure_fixture_root(base), os.Error(nil))
	defer testing.expect_value(t, os.remove(base), os.Error(nil))

	open := fixture_path(base, "open.odin", context.allocator)
	defer delete(open, context.allocator)
	testing.expect_value(
		t,
		os.write_entire_file(open, transmute([]byte)string("package fixture\n")),
		os.Error(nil),
	)
	defer os.remove(open)

	shut := fixture_path(base, "shut.odin", context.allocator)
	defer delete(shut, context.allocator)
	testing.expect_value(
		t,
		os.write_entire_file(shut, transmute([]byte)string("package fixture\n")),
		os.Error(nil),
	)
	defer os.remove(shut)

	if !acl_denied(t, shut, "(R)") {
		return
	}

	files, discovered := discover_odin_files(base, context.allocator)
	defer delete(files, context.allocator)
	defer for file in files {
		delete(file, context.allocator)
	}

	acl_undenied(t, shut)

	testing.expect_value(t, discovered, true)
	testing.expect_value(t, len(files), 2)
	found_shut := slice.contains(files, "shut.odin")
	testing.expect(
		t,
		found_shut,
		"the ACL-denied file never came back from discover_odin_files at all",
	)
}

// The headline of #267, at the seam the review actually measured: with a
// readable, otherwise-tagged sibling present, `check_repository` used to
// report zero violations for a tree that in fact held one -- `just check`
// answers "policy: clean" over a file it never looked at. This is the exact
// scenario `main_exits_violation_error_via_the_zero_files_guard_...` above
// records as NOT yet true before this ticket (it only fired the zero-files
// guard because that fixture's ACL-denied file had no readable sibling). Here
// there IS a sibling, so before the discover.odin fix `check_repository`
// read only the sibling, found it clean, and returned zero violations.
@(test)
check_repository_reports_cannot_be_read_for_an_acl_denied_file_with_a_readable_sibling :: proc(
	t: ^testing.T,
) {
	base, base_ok := fixture_root(t, "transcibr-policy-acl-e2e-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}
	testing.expect_value(t, ensure_fixture_root(base), os.Error(nil))
	defer testing.expect_value(t, os.remove(base), os.Error(nil))

	src := fixture_path(base, "src", context.allocator)
	defer delete(src, context.allocator)
	testing.expect_value(t, os.make_directory(src), os.Error(nil))
	defer os.remove(src)

	tools := fixture_path(base, "tools", context.allocator)
	defer delete(tools, context.allocator)
	testing.expect_value(t, os.make_directory(tools), os.Error(nil))
	defer os.remove(tools)

	open := fixture_path(base, "open.odin", context.allocator)
	defer delete(open, context.allocator)
	testing.expect_value(
		t,
		os.write_entire_file(
			open,
			transmute([]byte)string("#+vet explicit-allocators\npackage fixture\n"),
		),
		os.Error(nil),
	)
	defer os.remove(open)

	shut := fixture_path(base, "shut.odin", context.allocator)
	defer delete(shut, context.allocator)
	testing.expect_value(
		t,
		os.write_entire_file(
			shut,
			transmute([]byte)string("#+vet explicit-allocators\npackage fixture\n"),
		),
		os.Error(nil),
	)
	defer os.remove(shut)

	justfile_path := fixture_path(base, "justfile", context.allocator)
	defer delete(justfile_path, context.allocator)
	testing.expect_value(t, os.write_entire_file(justfile_path, "test:\n"), os.Error(nil))
	defer os.remove(justfile_path)

	if !acl_denied(t, shut, "(R)") {
		return
	}

	violations := check_repository(base, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)

	acl_undenied(t, shut)

	testing.expect(
		t,
		len(violations) > 0,
		"an ACL-denied file with a readable sibling reported clean",
	)
	testing.expect(t, violations_mention(violations, "cannot be read:"))
}

// Issue #267 work item 3: `check_package_accounting`'s own
// `fmt.aprintf("cannot be read: %v", ...)` arm for an unreadable JUSTFILE
// (main.odin) had no coverage at all -- every other test that reaches it
// writes a real, readable justfile. The same deny/undeny discipline as the
// source-file case above, aimed at the justfile this time: the ACL deny
// makes `os.read_entire_file(justfile_path, ...)` itself fail with a real
// `Permission_Denied` (unlike the discover.odin case, `check_package_accounting`
// never lists the justfile through a walker -- it names the path directly and
// opens it, so no `.Undetermined`-type detour is needed here at all).
@(test)
check_package_accounting_reports_cannot_be_read_for_an_acl_denied_justfile :: proc(t: ^testing.T) {
	base, base_ok := fixture_root(t, "transcibr-policy-acl-justfile-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}
	testing.expect_value(t, ensure_fixture_root(base), os.Error(nil))
	defer testing.expect_value(t, os.remove(base), os.Error(nil))

	justfile_path := fixture_path(base, "justfile", context.allocator)
	defer delete(justfile_path, context.allocator)
	testing.expect_value(t, os.write_entire_file(justfile_path, "test:\n"), os.Error(nil))
	defer os.remove(justfile_path)

	if !acl_denied(t, justfile_path, "(R)") {
		return
	}

	violations := make([dynamic]Violation, 0, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)
	check_package_accounting(base, &violations, context.allocator)

	acl_undenied(t, justfile_path)

	testing.expect(t, violations_mention(violations, "cannot be read:"))
}

// Fix round 1 of #267's review: the widened `is_odin_source_candidate`
// (discover.odin) took the only test that could see `check_repository`'s own
// `len(files) == 0` guard (main.odin) disappear -- that fixture's ACL-denied
// sole file is now discovered (as `.Undetermined`) and flows to
// `check_one_file` instead, so a mutation that disarms the guard
// (`if len(files) == 0` -> `if false && len(files) == 0`) left the whole
// suite green. This test needs no ACL trick at all: a fixture root that
// genuinely holds zero `.odin` files is what the guard exists for, and
// `discover_odin_files` legitimately answers `ok = true, files = []` for
// one (an empty, existing directory is not a walker error). No readable
// sibling, no denied file -- just an empty root, at the `check_repository`
// seam directly.
@(test)
check_repository_reports_the_zero_files_guard_violation_over_a_repository_with_no_odin_files :: proc(
	t: ^testing.T,
) {
	base, base_ok := fixture_root(t, "transcibr-policy-zero-files-fixture", context.allocator)
	testing.expect_value(t, base_ok, true)
	defer delete(base, context.allocator)
	if !base_ok {
		return
	}
	testing.expect_value(t, ensure_fixture_root(base), os.Error(nil))
	defer testing.expect_value(t, os.remove(base), os.Error(nil))

	violations := check_repository(base, context.allocator)
	defer delete(violations)
	defer violations_destroy(violations, context.allocator)

	testing.expect_value(t, len(violations), 1)
	testing.expect(
		t,
		violations_mention(violations, "discovered zero .odin files"),
		"the zero-files guard did not fire over an empty repository",
	)
}
