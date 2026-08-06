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
// every `src\` package holding a `*_test.odin` file must be named in the
// justfile's own `test` recipe.
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
// name is written out FIRST in the caller's discovery, before this reads the
// bytes -- see check_repository and render_file's own reasoning: reading a
// file is what can still take this program down.
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

// The check ticket #152 added: every `src\` package holding a `*_test.odin`
// file must appear in the justfile's own `test` recipe.
check_package_accounting :: proc(
	root: string,
	into: ^[dynamic]Violation,
	allocator: mem.Allocator,
) {
	assert(len(root) > 0, "asked to account for the packages of no repository root at all")
	assert(into != nil, "asked to collect violations into nothing at all")

	src_root := strings.concatenate({root, "/src"}, allocator)
	defer delete(src_root, allocator)
	tested, discovered := tested_src_packages(src_root, allocator)
	defer delete(tested, allocator)
	defer for name in tested {
		delete(name, allocator)
	}
	if !discovered {
		message := strings.clone("could not walk src\\ looking for tested packages", allocator)
		append(into, make_violation(src_root, 0, message, allocator))
		return
	}

	justfile_path := strings.concatenate({root, "/justfile"}, allocator)
	defer delete(justfile_path, allocator)
	justfile_bytes, read_error := os.read_entire_file(justfile_path, allocator)
	if read_error != nil {
		message := fmt.aprintf("cannot be read: %v", read_error, allocator = allocator)
		append(into, make_violation(justfile_path, 0, message, allocator))
		return
	}
	defer delete(justfile_bytes, allocator)

	missing := missing_from_test_recipe(tested, string(justfile_bytes), allocator)
	defer delete(missing, allocator)
	for name in missing {
		message := fmt.aprintf(
			"src/%s holds a *_test.odin file but is not named in the justfile's test recipe",
			name,
			allocator = allocator,
		)
		append(into, make_violation(justfile_path, 0, message, allocator))
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
