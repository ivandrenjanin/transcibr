#+vet explicit-allocators
// ADR-0038's import closure -- transcibr:transcript and transcibr:process
// only, core:testing added in tests, transcibr:audio and transcibr:child kept
// out structurally -- has no compiler enforcement of its own. common_options_test.odin's
// Tools-shape test cannot see a breach of it: audio.Tools is the
// byte-identical two-string struct, so a Tools test built the forbidden way
// still passes. This parses every file this package holds, with the same
// core:odin/parser tools/policy itself reads Odin with, and checks each
// file's own import list against the closure directly.
package cliargs

import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:strings"
import "core:testing"

@(private)
COMMON_OPTIONS_SOURCE :: #load("common_options.odin", string)
@(private)
COMMON_OPTIONS_TEST_SOURCE :: #load("common_options_test.odin", string)
@(private)
PAIR_OFF_SOURCE :: #load("pair_off.odin", string)
@(private)
PAIR_OFF_TEST_SOURCE :: #load("pair_off_test.odin", string)
@(private)
PROFILE_SOURCE :: #load("profile.odin", string)
@(private)
PROFILE_TEST_SOURCE :: #load("profile_test.odin", string)
@(private)
REFUSAL_SOURCE :: #load("refusal.odin", string)
@(private)
REFUSAL_TEST_SOURCE :: #load("refusal_test.odin", string)
@(private)
REQUIRED_SOURCE :: #load("required.odin", string)
@(private)
REQUIRED_TEST_SOURCE :: #load("required_test.odin", string)

@(private)
Package_File :: struct {
	name: string,
	src:  string,
}

@(private)
PACKAGE_FILES :: []Package_File {
	{"common_options.odin", COMMON_OPTIONS_SOURCE},
	{"common_options_test.odin", COMMON_OPTIONS_TEST_SOURCE},
	{"pair_off.odin", PAIR_OFF_SOURCE},
	{"pair_off_test.odin", PAIR_OFF_TEST_SOURCE},
	{"profile.odin", PROFILE_SOURCE},
	{"profile_test.odin", PROFILE_TEST_SOURCE},
	{"refusal.odin", REFUSAL_SOURCE},
	{"refusal_test.odin", REFUSAL_TEST_SOURCE},
	{"required.odin", REQUIRED_SOURCE},
	{"required_test.odin", REQUIRED_TEST_SOURCE},
}

// ADR-0038 bounds this package's transcibr:-internal closure to these two
// packages; core: imports are the standard library and outside the closure
// the ADR names.
@(private)
ALLOWED_TRANSCIBR_IMPORT_PATHS :: []string{"transcibr:transcript", "transcibr:process"}

@(private)
@(require_results)
is_allowed_import :: proc(path: string) -> bool {
	assert(len(path) > 0, "asked whether a nameless import path is allowed")
	if !strings.has_prefix(path, "transcibr:") {
		return true
	}
	for allowed in ALLOWED_TRANSCIBR_IMPORT_PATHS {
		if path == allowed {
			return true
		}
	}
	return false
}

@(private)
@(require_results)
import_paths_of :: proc(
	name: string,
	src: string,
	allocator: mem.Allocator,
) -> (
	paths: []string,
	ok: bool,
) {
	assert(len(name) > 0, "asked for the imports of a nameless file")
	assert(allocator.procedure != nil, "the collected import paths outlive this call")

	file := ast.File {
		fullpath = name,
		src      = src,
	}
	context.allocator = allocator
	reader := parser.default_parser()
	reader.err = nil
	reader.warn = nil
	if !parser.parse_file(&reader, &file) || file.syntax_error_count > 0 {
		return nil, false
	}

	found := make([dynamic]string, 0, allocator)
	for declaration in file.imports {
		assert(declaration != nil, "an import list holding a hole is a parser defect")
		append(&found, strings.clone(strings.trim(declaration.fullpath, `"`), allocator))
	}
	return found[:], true
}

@(test)
cliargs_never_imports_outside_its_transcript_and_process_closure :: proc(t: ^testing.T) {
	arena: mem.Dynamic_Arena
	mem.dynamic_arena_init(
		&arena,
		block_allocator = context.allocator,
		array_allocator = context.allocator,
	)
	defer mem.dynamic_arena_destroy(&arena)
	allocator := mem.dynamic_arena_allocator(&arena)

	checked := 0
	for file in PACKAGE_FILES {
		paths, ok := import_paths_of(file.name, file.src, allocator)
		if !testing.expectf(t, ok, "could not parse %s for its imports", file.name) {
			continue
		}
		for path in paths {
			checked += 1
			testing.expectf(
				t,
				is_allowed_import(path),
				"%s imports %q, outside ADR-0038's transcript/process closure",
				file.name,
				path,
			)
		}
	}
	testing.expect(
		t,
		checked > 0,
		"the closure check parsed zero imports across the whole package",
	)
}
