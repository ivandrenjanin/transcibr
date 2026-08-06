#+vet explicit-allocators
// This file is the package-accounting check the ticket that retired
// scripts\ asked for: every package under `src/` holding at least one
// `*_test.odin` file must appear in the justfile's `test` recipe, replacing
// scripts\common.ps1's hand-maintained $OdinPackagesWithoutTests. `cli`'s
// ADR-0009 exemption -- an entry point thin enough to read, with no tests of
// its own -- moves here as the one name this check does not demand.
package policy

import "core:mem"
import "core:os"
import "core:strings"

// The one src\ package this check does not require of the justfile's test
// recipe. ADR-0009: logic worth testing belongs in the pure core, and `cli`
// is the entry point thin enough to read without any.
TEST_LESS_SRC_PACKAGES :: []string{"cli"}

// Every directory under `src_root` holding at least one `*_test.odin` file,
// named relative to `src_root` and forward-slashed: `child`, `net/winhttp`.
@(require_results)
tested_src_packages :: proc(
	src_root: string,
	allocator: mem.Allocator,
) -> (
	names: []string,
	ok: bool,
) {
	assert(len(src_root) > 0, "asked which packages under no root at all hold tests")
	assert(
		allocator.procedure != nil,
		"the package names outlive this call and need a chosen allocator",
	)

	seen := make([dynamic]string, 0, allocator)
	walker := os.walker_create(src_root)
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
		note_tested_package(entry.fullpath, src_root, &seen, allocator)
	}

	if _, walk_error := os.walker_error(&walker); walk_error != nil {
		return seen[:], false
	}
	return seen[:], true
}

// Records the package one test file belongs to, unless it is already there.
note_tested_package :: proc(
	test_file: string,
	src_root: string,
	into: ^[dynamic]string,
	allocator: mem.Allocator,
) {
	assert(len(test_file) > 0, "asked to attribute no test file at all to a package")
	assert(into != nil, "asked to record a package into nothing at all")

	directory, _ := os.split_path(test_file)
	name := relative_slashed(directory, src_root, allocator)
	for existing in into {
		if existing == name {
			delete(name, allocator)
			return
		}
	}
	append(into, name)
}

// Whether `name` is exempt from appearing in the justfile's `test` recipe.
@(require_results)
is_test_less_package :: proc(name: string) -> bool {
	assert(len(name) > 0, "asked whether a nameless package is exempt")
	for exempt in TEST_LESS_SRC_PACKAGES {
		if name == exempt {
			return true
		}
	}
	return false
}

// Every name in `tested` that is also declared exempt in
// `TEST_LESS_SRC_PACKAGES`. The exemption is for a package that holds no
// tests at all (ADR-0009: an entry point thin enough to read); a package
// that IS exempt but DOES hold a `*_test.odin` file has tests no recipe ever
// compiles or runs, which is the exact silence this check exists to end.
@(require_results)
exempt_packages_holding_tests :: proc(tested: []string, allocator: mem.Allocator) -> []string {
	assert(
		allocator.procedure != nil,
		"the offending package names outlive this call and need a chosen allocator",
	)

	offending := make([dynamic]string, 0, allocator)
	for name in tested {
		if is_test_less_package(name) {
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
// `src/<package>` token, over a file this program does not parse as Odin at
// all -- `contains_package_token` bounds the match so `src/plan` cannot
// match inside `src/planning`.
@(require_results)
missing_from_test_recipe :: proc(
	tested: []string,
	justfile_text: string,
	allocator: mem.Allocator,
) -> []string {
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
			if !is_test_less_package(name) {
				append(&missing, strings.clone(name, allocator))
			}
		}
		return missing[:]
	}

	for name in tested {
		if is_test_less_package(name) {
			continue
		}
		needle := strings.concatenate({"src/", name}, allocator)
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

// Whether `needle` (a `src/<name>` path) occurs in `body` as a whole token,
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
