#+vet explicit-allocators
// This file is the package-accounting check issue #152 (the ticket that
// retired the PowerShell layer) asked for, over BOTH package roots the
// repository holds and in both directions. Every package under `src/` and
// under `tools/` holding at least one `*_test.odin` file must appear in the
// justfile's `test` recipe, and every package under either root holding
// `.odin` files and no `*_test.odin` file at all is a violation. Before
// #152, this was scripts\common.ps1's hand-maintained $OdinPackagesWithoutTests,
// whose own $OdinPackageRoots covered `tools\` too; `TEST_LESS_SRC_PACKAGES`
// below is that roster's successor. `cli`'s ADR-0009 exemption -- an entry
// point thin enough to read, with no tests of its own -- moves here as the
// one name this check does not demand, and it is a `src/` name: `tools/` has
// no exemption roster at all.
package policy

import "core:mem"
import "core:os"
import "core:strings"

// The one src\ package this check does not require of the justfile's test
// recipe. ADR-0009: logic worth testing belongs in the pure core, and `cli`
// is the entry point thin enough to read without any.
TEST_LESS_SRC_PACKAGES :: []string{"cli"}

// The `tools\` root's roster, and it is empty on purpose: a tool holding
// `.odin` files and no test file is a violation with no name that excuses it.
// ADR-0009's reasoning is about `src\`'s entry point, and nothing under
// `tools\` is an entry point to this program's own domain.
NO_TEST_LESS_PACKAGES :: []string{}

// Every directory under `package_root` holding at least one `*_test.odin`
// file, named relative to `package_root` and forward-slashed: `child`,
// `net/winhttp`. `strays` carries the full path of any `*_test.odin` file
// found sitting directly in `package_root` itself -- it belongs to no
// package, so it is reported through `strays` rather than folded into `names`
// under an empty name (A8: a filesystem input that does not fit the package
// shape is an operating error to report, not a precondition to assert past).
@(require_results)
tested_packages :: proc(
	package_root: string,
	allocator: mem.Allocator,
) -> (
	names: []string,
	strays: []string,
	ok: bool,
) {
	assert(len(package_root) > 0, "asked which packages under no root at all hold tests")
	assert(
		allocator.procedure != nil,
		"the package names outlive this call and need a chosen allocator",
	)

	seen := make([dynamic]string, 0, allocator)
	stray := make([dynamic]string, 0, allocator)
	walker := os.walker_create(package_root)
	defer os.walker_destroy(&walker)

	for entry in os.walker_walk(&walker) {
		if entry.type == .Directory {
			if is_excluded_directory(entry.name) {
				os.walker_skip_dir(&walker)
			}
			continue
		}
		if entry.type != .Regular || !strings.has_suffix(entry.name, "_test.odin") {
			continue
		}
		note_tested_package(entry.fullpath, package_root, &seen, &stray, allocator)
	}

	if _, walk_error := os.walker_error(&walker); walk_error != nil {
		return seen[:], stray[:], false
	}
	return seen[:], stray[:], true
}

// Records the package one test file belongs to, unless it is already there.
// A test file sitting directly in `package_root` -- so `relative_slashed`
// trims the whole path and returns the empty string -- belongs to no package;
// it is recorded into `strays` instead, never as a nameless entry in `into`.
note_tested_package :: proc(
	test_file: string,
	package_root: string,
	into: ^[dynamic]string,
	strays: ^[dynamic]string,
	allocator: mem.Allocator,
) {
	assert(len(test_file) > 0, "asked to attribute no test file at all to a package")
	assert(into != nil, "asked to record a package into nothing at all")
	assert(strays != nil, "asked to record a stray test file into nothing at all")

	directory, _ := os.split_path(test_file)
	name := relative_slashed(directory, package_root, allocator)
	if len(name) == 0 {
		delete(name, allocator)
		append(strays, strings.clone(test_file, allocator))
		return
	}
	for existing in into {
		if existing == name {
			delete(name, allocator)
			return
		}
	}
	append(into, name)
}

// Every directory under `package_root` holding at least one `.odin` file at
// all -- tested or not -- named the same way `tested_packages` names a tested
// package. A file sitting directly in `package_root` itself belongs to no
// package and is not counted here, matching `tested_packages`' own `strays`
// carve-out for the test-file case.
@(require_results)
all_packages :: proc(
	package_root: string,
	allocator: mem.Allocator,
) -> (
	names: []string,
	ok: bool,
) {
	assert(len(package_root) > 0, "asked which packages under no root at all exist")
	assert(
		allocator.procedure != nil,
		"the package names outlive this call and need a chosen allocator",
	)

	seen := make([dynamic]string, 0, allocator)
	walker := os.walker_create(package_root)
	defer os.walker_destroy(&walker)

	for entry in os.walker_walk(&walker) {
		if entry.type == .Directory {
			if is_excluded_directory(entry.name) {
				os.walker_skip_dir(&walker)
			}
			continue
		}
		if entry.type != .Regular || !strings.has_suffix(entry.name, ".odin") {
			continue
		}
		note_present_package(entry.fullpath, package_root, &seen, allocator)
	}

	if _, walk_error := os.walker_error(&walker); walk_error != nil {
		return seen[:], false
	}
	return seen[:], true
}

// Records the package one `.odin` file belongs to, unless it is already
// there. A file sitting directly in `package_root` -- `relative_slashed`
// trims the whole path and returns the empty string -- belongs to no package
// and is silently dropped, the same carve-out `note_tested_package` makes for
// a stray test file.
note_present_package :: proc(
	source_file: string,
	package_root: string,
	into: ^[dynamic]string,
	allocator: mem.Allocator,
) {
	assert(len(source_file) > 0, "asked to attribute no source file at all to a package")
	assert(into != nil, "asked to record a package into nothing at all")

	directory, _ := os.split_path(source_file)
	name := relative_slashed(directory, package_root, allocator)
	if len(name) == 0 {
		delete(name, allocator)
		return
	}
	for existing in into {
		if existing == name {
			delete(name, allocator)
			return
		}
	}
	append(into, name)
}

// Every name in `all` that `have` does not hold and that `exempt` does not
// name -- the set difference the accounting check asks twice, over two
// different pairs of lists sharing one exemption roster. Called with
// (all_packages, tested_packages) it answers "which package holds no
// `*_test.odin` file at all," which `missing_from_test_recipe` alone never
// asks because it only ever walks packages that already hold a test file.
// Called with (tested_packages, packages_with_test_procedures) it answers
// issue #174's question instead: which package the accounting check already
// requires tested (a `*_test.odin` file present) holds no `@(test)`
// procedure among its own test files at all -- a package rewritten so every
// `@(test)` becomes `@(private)` still keeps its test file, so `tested`
// alone cannot tell the two apart. `exempt` is the calling root's own
// roster: TEST_LESS_SRC_PACKAGES under `src\`, and the empty
// NO_TEST_LESS_PACKAGES under `tools\`; either way it excuses a package from
// being required at all, never from holding a *_test.odin file with nothing
// live inside it -- that is `exempt_packages_holding_tests`' own question.
@(require_results)
untested_packages :: proc(
	all: []string,
	have: []string,
	exempt: []string,
	allocator: mem.Allocator,
) -> []string {
	assert(
		allocator.procedure != nil,
		"the untested package names outlive this call and need a chosen allocator",
	)

	missing := make([dynamic]string, 0, allocator)
	for name in all {
		if is_test_less_package(name, exempt) {
			continue
		}
		has_test := false
		for candidate in have {
			if candidate == name {
				has_test = true
				break
			}
		}
		if !has_test {
			append(&missing, strings.clone(name, allocator))
		}
	}
	return missing[:]
}

// Every package name under `package_root` that holds at least one `@(test)`
// procedure in any of its own `*_test.odin` files -- the file's own content,
// read and parsed the same way `check_one_file` parses every file the build
// sweeps (`read_source`), never trusted from the file's mere existence the
// way `tested_packages` names one. Issue #174: a `*_test.odin` file rewritten
// so every `@(test)` becomes `@(private)` still exists, so `tested_packages`
// still names its package -- this is the read that tells the two apart.
@(require_results)
packages_with_test_procedures :: proc(
	package_root: string,
	allocator: mem.Allocator,
) -> (
	names: []string,
	ok: bool,
) {
	assert(len(package_root) > 0, "asked which packages under no root at all hold test procedures")
	assert(
		allocator.procedure != nil,
		"the package names outlive this call and need a chosen allocator",
	)

	seen := make([dynamic]string, 0, allocator)
	walker := os.walker_create(package_root)
	defer os.walker_destroy(&walker)

	for entry in os.walker_walk(&walker) {
		if entry.type == .Directory {
			if is_excluded_directory(entry.name) {
				os.walker_skip_dir(&walker)
			}
			continue
		}
		if entry.type != .Regular || !strings.has_suffix(entry.name, "_test.odin") {
			continue
		}
		note_package_with_test_procedure(entry.fullpath, package_root, &seen, allocator)
	}

	if _, walk_error := os.walker_error(&walker); walk_error != nil {
		return seen[:], false
	}
	return seen[:], true
}

// Records the package one `*_test.odin` file belongs to, but only once that
// file's own source is read and parsed and found to hold a procedure carrying
// `@(test)`. A package already recorded is skipped before the file is even
// read: one live test file anywhere in a package is enough to clear it, and
// a stray file sitting directly in `package_root` (`relative_slashed` trims
// the whole path and returns the empty string) belongs to no package and is
// dropped here exactly as `note_tested_package` drops it, since
// `tested_packages` already reports it through `strays`.
note_package_with_test_procedure :: proc(
	test_file: string,
	package_root: string,
	into: ^[dynamic]string,
	allocator: mem.Allocator,
) {
	assert(len(test_file) > 0, "asked to attribute no test file at all to a package")
	assert(into != nil, "asked to record a package into nothing at all")

	directory, _ := os.split_path(test_file)
	name := relative_slashed(directory, package_root, allocator)
	if len(name) == 0 {
		delete(name, allocator)
		return
	}
	defer delete(name, allocator)

	for existing in into {
		if existing == name {
			return
		}
	}

	src, read_error := os.read_entire_file(test_file, allocator)
	if read_error != nil {
		return
	}
	defer delete(src, allocator)

	if !file_declares_test_procedure(test_file, string(src), allocator) {
		return
	}
	append(into, strings.clone(name, allocator))
}

// Whether one file's own source, parsed the same way `read_source` answers
// every other question this program asks about a file, declares at least one
// procedure carrying `@(test)`. A file that fails to parse at all answers
// false rather than crashing this walk: A8 -- a source file is external
// input, and a file too broken to parse is not proof it holds a live test.
//
// Issue #239: a file whose own `#+build` tags exclude the platform this
// check is running on answers false as well, however many `@(test)`
// procedures parse clean inside it -- `odin test` never compiles that body
// in on this platform, so a live-looking procedure here is dead there, and
// crediting it would reopen the #174 hollow-package hole one tag line at a
// time.
@(require_results)
file_declares_test_procedure :: proc(name: string, src: string, allocator: mem.Allocator) -> bool {
	assert(len(name) > 0, "asked whether no file at all declares a test procedure")

	facts := read_source(name, src, allocator)
	defer facts_destroy(facts, allocator)
	if facts.fault != Fault.None {
		return false
	}
	if facts.excluded_by_platform {
		return false
	}
	for procedure in facts.procedures {
		if procedure.is_test {
			return true
		}
	}
	return false
}

// Whether `roster` names `name` exempt from appearing in the justfile's
// `test` recipe. The roster is the calling root's own, never a repository-wide
// one: `cli` is exempt under `src\` and exempt from nothing under `tools\`.
@(require_results)
is_test_less_package :: proc(name: string, roster: []string) -> bool {
	assert(len(name) > 0, "asked whether a nameless package is exempt")
	for exempt in roster {
		if name == exempt {
			return true
		}
	}
	return false
}

// Every name in `tested` that `exempt` also declares test-less. The exemption
// is for a package that holds no tests at all (ADR-0009: an entry point thin
// enough to read); a package that IS exempt but DOES hold a `*_test.odin`
// file has tests no recipe ever compiles or runs, which is the exact silence
// this check exists to end.
@(require_results)
exempt_packages_holding_tests :: proc(
	tested: []string,
	exempt: []string,
	allocator: mem.Allocator,
) -> []string {
	assert(
		allocator.procedure != nil,
		"the offending package names outlive this call and need a chosen allocator",
	)

	offending := make([dynamic]string, 0, allocator)
	for name in tested {
		if is_test_less_package(name, exempt) {
			append(&offending, strings.clone(name, allocator))
		}
	}
	return offending[:]
}

// The `test:` recipe's own body: every line strictly between its header and
// the next recipe header (a line starting at column zero), joined back into
// one string. SCOPED, and not a search of the whole file: `test-single`
// names `src/child` too, and a match against the whole justfile would call a
// package present the moment ANY recipe mentions it -- which is exactly the
// silence the package-accounting check exists to end.
@(require_results)
test_recipe_body :: proc(
	justfile_text: string,
	allocator: mem.Allocator,
) -> (
	body: string,
	ok: bool,
) {
	assert(
		allocator.procedure != nil,
		"the recipe body outlives this call and needs a chosen allocator",
	)

	lines := strings.split_lines(justfile_text, allocator)
	defer delete(lines, allocator)

	start := -1
	for line, i in lines {
		if line == "test:" {
			start = i + 1
			break
		}
	}
	if start < 0 {
		return "", false
	}

	end := len(lines)
	for i in start ..< len(lines) {
		line := lines[i]
		if len(line) > 0 && line[0] != '\t' && line[0] != ' ' {
			end = i
			break
		}
	}

	return strings.join(lines[start:end], "\n", allocator), true
}

// Every tested package the `test:` recipe's own body does not name as a
// `<prefix>/<package>` token, over a file this program does not parse as Odin
// at all -- `contains_package_token` bounds the match so `src/plan` cannot
// match inside `src/planning`, and `tools/plan` no more inside
// `tools/planning`. `prefix` is the calling root's own directory name and
// `exempt` its own roster.
@(require_results)
missing_from_test_recipe :: proc(
	tested: []string,
	justfile_text: string,
	prefix: string,
	exempt: []string,
	allocator: mem.Allocator,
) -> []string {
	assert(len(prefix) > 0, "asked which packages under no root name at all are missing")
	assert(
		allocator.procedure != nil,
		"the missing package names outlive this call and need a chosen allocator",
	)

	missing := make([dynamic]string, 0, allocator)
	body, found := test_recipe_body(justfile_text, allocator)
	defer if found {
		delete(body, allocator)
	}
	if !found {
		for name in tested {
			if !is_test_less_package(name, exempt) {
				append(&missing, strings.clone(name, allocator))
			}
		}
		return missing[:]
	}

	for name in tested {
		if is_test_less_package(name, exempt) {
			continue
		}
		needle := strings.concatenate({prefix, "/", name}, allocator)
		defer delete(needle, allocator)
		if !contains_package_token(body, needle) {
			append(&missing, strings.clone(name, allocator))
		}
	}
	return missing[:]
}

// Package-token boundary character: a letter, digit, `/`, `_` or `-` extends
// the token rather than ending it, so `src/plan` must not match inside
// `src/planning`. Everything else -- space, quote, end of string -- is a
// legal token boundary in the justfile's own recipe syntax.
@(require_results)
is_package_token_char :: proc(r: rune) -> bool {
	return(
		(r >= 'a' && r <= 'z') ||
		(r >= 'A' && r <= 'Z') ||
		(r >= '0' && r <= '9') ||
		r == '/' ||
		r == '_' ||
		r == '-' \
	)
}

// Whether `needle` (a `<prefix>/<name>` path) occurs in `body` as a whole token,
// not merely as a substring of a longer package path.
@(require_results)
contains_package_token :: proc(body: string, needle: string) -> bool {
	assert(len(needle) > 0, "asked whether an empty needle is a token in the body")

	search := body
	offset := 0
	for {
		index := strings.index(search, needle)
		if index < 0 {
			return false
		}
		start := offset + index
		end := start + len(needle)
		before_ok := start == 0 || !is_package_token_char(rune(body[start - 1]))
		after_ok := end == len(body) || !is_package_token_char(rune(body[end]))
		if before_ok && after_ok {
			return true
		}
		search = body[end:]
		offset = end
	}
}
