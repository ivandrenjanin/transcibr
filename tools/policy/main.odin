#+vet explicit-allocators
package policy

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"

// This is what `just check` runs. It discovers every `.odin` file the
// repository holds -- docs\reference\ included, the scope CLAUDE.md's source
// policies have always had -- computes the verdicts check.odin knows about
// for each one, and refuses the package-accounting check this ticket added:
// every `src\` and `tools\` package holding a `*_test.odin` file must be
// named in the justfile's own `test` recipe, and every package under either
// root holding no `*_test.odin` file at all is a violation unless that root's
// roster names it.
//
// The root is the one argument, or the working directory `just` starts this
// in when there is none. `just`'s recipes run from the repository root by
// default, so `odin run tools/policy` with no argument is the ordinary case;
// the argument exists for a caller -- a test, a different working directory
// -- that needs to say so explicitly.

ROOT_ERROR :: 2
VIOLATION_ERROR :: 3

main :: proc() {
	assert(len(os.args) > 0, "a process started with no argv at all, not even its own name")

	root, root_ok := repo_root(context.allocator)
	if !root_ok {
		fmt.eprintln(
			"cannot read the working directory to check; pass the repository root as the one argument.",
		)
		os.exit(ROOT_ERROR)
	}
	defer delete(root, context.allocator)

	violations := check_repository(root, context.allocator)
	defer violations_destroy(violations, context.allocator)
	defer delete(violations)

	report_violations(violations)
	if len(violations) > 0 {
		os.exit(VIOLATION_ERROR)
	}
	fmt.println("policy: clean")
}

// The repository root this run checks: the one command-line argument, or the
// working directory `just` already started this process in. RESOLVED to an
// absolute path either way, so every relative name this program builds from
// it -- the request file used to carry, and every violation now does --
// starts from the same footing a caller's "." would not give it.
@(require_results)
repo_root :: proc(allocator: mem.Allocator) -> (root: string, ok: bool) {
	assert(
		allocator.procedure != nil,
		"the root path outlives this call and needs a chosen allocator",
	)

	if len(os.args) >= 2 {
		absolute, err := os.get_absolute_path(os.args[1], allocator)
		return absolute, err == nil
	}
	dir, err := os.get_working_directory(allocator)
	if err != nil {
		return "", false
	}
	return dir, true
}

// Every violation this run found under `root`: the five per-file verdicts
// check.odin computes, and the package-accounting check beside them.
@(require_results)
check_repository :: proc(root: string, allocator: mem.Allocator) -> [dynamic]Violation {
	assert(len(root) > 0, "asked to check no repository root at all")
	assert(
		allocator.procedure != nil,
		"the violations outlive this call and need a chosen allocator",
	)

	violations := make([dynamic]Violation, 0, allocator)
	required := required_vet_tags(vet_tag_roster, allocator)
	defer delete(required, allocator)

	files, discovered := discover_odin_files(root, allocator)
	defer delete(files, allocator)
	defer for file in files {
		delete(file, allocator)
	}
	if !discovered {
		message := strings.clone(
			"could not walk the repository looking for .odin files",
			allocator,
		)
		append(&violations, make_violation(root, 0, message, allocator))
		return violations
	}
	if len(files) == 0 {
		message := strings.clone(
			"discovered zero .odin files, so the source policies would pass having read nothing",
			allocator,
		)
		append(&violations, make_violation(root, 0, message, allocator))
		return violations
	}

	for relative in files {
		check_one_file(root, relative, required, &violations, allocator)
	}
	check_package_accounting(root, &violations, allocator)
	return violations
}

// One file's verdicts, or the fault that stopped it being read. The relative
// name is written out FIRST here (`checking: %s`, to standard error), before
// this reads the bytes: reading a file is what can still take this program
// down.
check_one_file :: proc(
	root: string,
	relative: string,
	required: []string,
	into: ^[dynamic]Violation,
	allocator: mem.Allocator,
) {
	assert(len(relative) > 0, "asked to check a file with no name")
	assert(into != nil, "asked to collect violations into nothing at all")

	fmt.eprintfln("checking: %s", relative)

	full := strings.concatenate({root, "/", relative}, allocator)
	defer delete(full, allocator)

	src, read_error := os.read_entire_file(full, allocator)
	if read_error != nil {
		message := fmt.aprintf("cannot be read: %v", read_error, allocator = allocator)
		append(into, make_violation(relative, 0, message, allocator))
		return
	}
	defer delete(src, allocator)
	collect_network_violations(relative, string(src), into)

	facts := read_source(relative, string(src), allocator)
	defer facts_destroy(facts, allocator)
	if facts.fault != Fault.None {
		message := strings.clone(fault_says(facts.fault), allocator)
		append(into, make_violation(relative, 0, message, allocator))
		return
	}
	collect_violations(relative, facts, required, into)
}

// One package root as this check reads it: where it is on disk, the name it
// is spelled by in the justfile and in every message, the roster that may
// excuse a package there from holding tests, and the justfile the recipe half
// of the check reads. `justfile_ok` is false when the file could not be read
// at all, which is a violation of its own and not a reason to call every
// tested package missing from a recipe nobody could see.
Accounting_Scope :: struct {
	package_root:  string,
	prefix:        string,
	exempt:        []string,
	justfile_path: string,
	justfile_text: string,
	justfile_ok:   bool,
}

// The check ticket #152 added, over both roots this repository holds
// packages under: every `src\` and `tools\` package holding a `*_test.odin`
// file must appear in the justfile's own `test` recipe, and every package
// under either root holding no `*_test.odin` file at all is a violation
// unless that root's roster names it.
check_package_accounting :: proc(
	root: string,
	into: ^[dynamic]Violation,
	allocator: mem.Allocator,
) {
	assert(len(root) > 0, "asked to account for the packages of no repository root at all")
	assert(into != nil, "asked to collect violations into nothing at all")

	justfile_path := strings.concatenate({root, "/justfile"}, allocator)
	defer delete(justfile_path, allocator)
	justfile_bytes, read_error := os.read_entire_file(justfile_path, allocator)
	defer delete(justfile_bytes, allocator)
	if read_error != nil {
		message := fmt.aprintf("cannot be read: %v", read_error, allocator = allocator)
		append(into, make_violation(justfile_path, 0, message, allocator))
	}

	src_root := strings.concatenate({root, "/src"}, allocator)
	defer delete(src_root, allocator)
	tools_root := strings.concatenate({root, "/tools"}, allocator)
	defer delete(tools_root, allocator)

	scope := Accounting_Scope {
		package_root  = src_root,
		prefix        = "src",
		exempt        = TEST_LESS_SRC_PACKAGES,
		justfile_path = justfile_path,
		justfile_text = string(justfile_bytes),
		justfile_ok   = read_error == nil,
	}
	check_root_accounting(scope, into, allocator)

	scope.package_root = tools_root
	scope.prefix = "tools"
	scope.exempt = NO_TEST_LESS_PACKAGES
	check_root_accounting(scope, into, allocator)
}

// One root's accounting, both directions: a package holding tests that no
// `test` recipe line names, and a package holding no tests at all that no
// roster excuses.
check_root_accounting :: proc(
	scope: Accounting_Scope,
	into: ^[dynamic]Violation,
	allocator: mem.Allocator,
) {
	assert(len(scope.package_root) > 0, "asked to account for the packages of no root at all")
	assert(len(scope.prefix) > 0, "asked to account for a root with no name to report it by")
	assert(into != nil, "asked to collect violations into nothing at all")

	tested, strays, discovered := tested_packages(scope.package_root, allocator)
	defer delete(tested, allocator)
	defer for name in tested {
		delete(name, allocator)
	}
	defer delete(strays, allocator)
	defer for stray in strays {
		delete(stray, allocator)
	}
	if !discovered {
		message := fmt.aprintf(
			"could not walk %s\\ looking for tested packages",
			scope.prefix,
			allocator = allocator,
		)
		append(into, make_violation(scope.package_root, 0, message, allocator))
		return
	}

	report_stray_test_files(scope, strays, into, allocator)
	if !report_untested_packages(scope, tested, into, allocator) {
		return
	}
	report_exempt_packages_holding_tests(scope, tested, into, allocator)
	if scope.justfile_ok {
		report_missing_from_test_recipe(scope, tested, into, allocator)
	}
}

// One violation per stray `*_test.odin` file -- a file `tested_packages`
// found sitting directly in the root, belonging to no package (A8: report
// through the error return, never assert past a filesystem input that does
// not fit the package shape).
report_stray_test_files :: proc(
	scope: Accounting_Scope,
	strays: []string,
	into: ^[dynamic]Violation,
	allocator: mem.Allocator,
) {
	assert(len(scope.prefix) > 0, "asked to report a stray under a root with no name")
	assert(into != nil, "asked to collect violations into nothing at all")

	for stray in strays {
		message := fmt.aprintf(
			"a *_test.odin file that belongs to no package under %s/",
			scope.prefix,
			allocator = allocator,
		)
		append(into, make_violation(stray, 0, message, allocator))
	}
}

// One violation per package under this root holding no `*_test.odin` file at
// all and not named by the root's own roster -- the deny-by-default half of
// this check (review round 5): a package with zero test files, new or
// emptied, used to pass `just check` silently. Returns false only when the
// walk itself failed, matching `tested_packages`' own failure shape.
@(require_results)
report_untested_packages :: proc(
	scope: Accounting_Scope,
	tested: []string,
	into: ^[dynamic]Violation,
	allocator: mem.Allocator,
) -> bool {
	assert(len(scope.package_root) > 0, "asked to find untested packages under no root at all")
	assert(into != nil, "asked to collect violations into nothing at all")

	all, discovered := all_packages(scope.package_root, allocator)
	defer delete(all, allocator)
	defer for name in all {
		delete(name, allocator)
	}
	if !discovered {
		message := fmt.aprintf(
			"could not walk %s\\ looking for every package",
			scope.prefix,
			allocator = allocator,
		)
		append(into, make_violation(scope.package_root, 0, message, allocator))
		return false
	}

	untested := untested_packages(all, tested, scope.exempt, allocator)
	defer delete(untested, allocator)
	for name in untested {
		message := untested_package_says(scope, name, allocator)
		append(into, make_violation(scope.package_root, 0, message, allocator))
		delete(name, allocator)
	}
	return true
}

// What an untested package is told, which is not the same sentence under both
// roots: `src\` has a roster a package can be named in, and `tools\` has none
// at all, so pointing a tool at TEST_LESS_SRC_PACKAGES would name a way out
// that does not exist for it.
@(require_results)
untested_package_says :: proc(
	scope: Accounting_Scope,
	name: string,
	allocator: mem.Allocator,
) -> string {
	assert(len(name) > 0, "asked what to say about a package with no name")
	assert(len(scope.prefix) > 0, "asked what to say about a package under a root with no name")

	if len(scope.exempt) > 0 {
		return fmt.aprintf(
			"%s/%s holds no *_test.odin file and is not named in TEST_LESS_SRC_PACKAGES",
			scope.prefix,
			name,
			allocator = allocator,
		)
	}
	return fmt.aprintf(
		"%s/%s holds no *_test.odin file, and %s\\ has no exemption roster at all",
		scope.prefix,
		name,
		scope.prefix,
		allocator = allocator,
	)
}

// One violation per package this root's roster declares test-less that holds
// a `*_test.odin` file anyway: tests no recipe compiles or runs.
report_exempt_packages_holding_tests :: proc(
	scope: Accounting_Scope,
	tested: []string,
	into: ^[dynamic]Violation,
	allocator: mem.Allocator,
) {
	assert(len(scope.prefix) > 0, "asked to report an exemption under a root with no name")
	assert(into != nil, "asked to collect violations into nothing at all")

	offending := exempt_packages_holding_tests(tested, scope.exempt, allocator)
	defer delete(offending, allocator)
	for name in offending {
		message := fmt.aprintf(
			"%s/%s is declared test-less but holds a *_test.odin file that no recipe compiles or runs",
			scope.prefix,
			name,
			allocator = allocator,
		)
		append(into, make_violation(scope.package_root, 0, message, allocator))
		delete(name, allocator)
	}
}

// One violation per tested package under this root that the justfile's own
// `test` recipe body does not name.
report_missing_from_test_recipe :: proc(
	scope: Accounting_Scope,
	tested: []string,
	into: ^[dynamic]Violation,
	allocator: mem.Allocator,
) {
	assert(scope.justfile_ok, "asked to read a test recipe out of a justfile nobody could read")
	assert(into != nil, "asked to collect violations into nothing at all")

	missing := missing_from_test_recipe(
		tested,
		scope.justfile_text,
		scope.prefix,
		scope.exempt,
		allocator,
	)
	defer delete(missing, allocator)
	for name in missing {
		message := fmt.aprintf(
			"%s/%s holds a *_test.odin file but is not named in the justfile's test recipe",
			scope.prefix,
			name,
			allocator = allocator,
		)
		append(into, make_violation(scope.justfile_path, 0, message, allocator))
		delete(name, allocator)
	}
}

// Every violation, one line each, to standard error: the stream the compiler
// and the test runner already report through, so a developer watching `just
// check` sees the same kind of output either way.
report_violations :: proc(violations: [dynamic]Violation) {
	for one in violations {
		if one.line > 0 {
			fmt.eprintfln("%s:%d: %s", one.file, one.line, one.message)
		} else {
			fmt.eprintfln("%s: %s", one.file, one.message)
		}
	}
	if len(violations) > 0 {
		fmt.eprintfln("policy: %d violation(s)", len(violations))
	}
}
