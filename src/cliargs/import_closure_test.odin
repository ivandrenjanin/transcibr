#+vet explicit-allocators
// ADR-0038's import closure -- transcibr:transcript and transcibr:process
// only, core:testing added in tests, transcibr:audio and transcibr:child kept
// out structurally -- has no compiler enforcement of its own. common_options_test.odin's
// Tools-shape test cannot see a breach of it: audio.Tools is the
// byte-identical two-string struct, so a Tools test built the forbidden way
// still passes. This walks src/cliargs on disk (the same way tools/policy's
// own discover_odin_files walks the repository, rather than trusting a
// hand-written file roster that a later migration PR could silently outrun),
// parses every file it finds with the same core:odin/parser tools/policy
// itself reads Odin with, and checks each file's own import list against the
// closure directly -- both the transcibr:-prefixed spelling and the relative
// spelling Odin equally accepts.
package cliargs

import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:strings"
import "core:testing"

// The directory this test walks, relative to the working directory every
// `odin test` invocation in this repository runs from (the repository
// root) -- the same assumption tools/policy's own `repo_root` makes for
// `just check`.
@(private)
CLIARGS_DIRECTORY :: "src/cliargs"

// A PIN, not a floor: the stage-2 review deposit that first named this
// constant asked for the floor-vs-pin call to be made once slack stopped
// being cheap, and the stage-5 deposit measured it running 6 files behind
// the real count -- a gap that only ever widens under `>=`, silently, one
// migration at a time. This package is done growing after this stage
// (ADR-0038's five migration sites are all landed, the readers they
// replaced are deleted), so `==` is the stronger guarantee: it catches a
// file's DELETION as loudly as its addition, where a floor forgives one and
// the other silently. 22 is every .odin file src/cliargs holds once this
// stage's render_options.odin and render_options_test.odin land.
@(private)
MIN_PACKAGE_FILE_COUNT :: 22

@(private)
Package_File :: struct {
	name: string,
	src:  string,
}

// Every `.odin` file src/cliargs holds right now, read off disk. Unlike a
// hand-written roster, this cannot go stale: a file added to the directory
// and never mentioned anywhere else is still walked here.
@(private)
@(require_results)
package_files :: proc(allocator: mem.Allocator) -> (files: []Package_File, ok: bool) {
	assert(allocator.procedure != nil, "the collected files outlive this call")

	if !os.exists(CLIARGS_DIRECTORY) {
		return nil, false
	}

	found := make([dynamic]Package_File, 0, allocator)
	walker := os.walker_create(CLIARGS_DIRECTORY)
	defer os.walker_destroy(&walker)

	for entry in os.walker_walk(&walker) {
		if entry.type != .Regular || !strings.has_suffix(entry.name, ".odin") {
			continue
		}
		contents, read_error := os.read_entire_file(entry.fullpath, allocator)
		if read_error != nil {
			return found[:], false
		}
		append(
			&found,
			Package_File{name = strings.clone(entry.name, allocator), src = string(contents)},
		)
	}

	if _, walk_error := os.walker_error(&walker); walk_error != nil {
		return found[:], false
	}
	return found[:], true
}

// ADR-0038 bounds this package's transcibr:-internal closure to these two
// packages, spelled the way `transcibr:` collection imports name them.
@(private)
ALLOWED_TRANSCIBR_IMPORT_PATHS :: []string{"transcibr:transcript", "transcibr:process"}

// This package's own location in the collection: `transcibr:cliargs` is
// `src/cliargs`, so a relative import's ".." climbs out of `cliargs` into
// `src` exactly once before it names a sibling package.
@(private)
CLIARGS_PACKAGE_DIRECTORY_SEGMENTS :: []string{"src", "cliargs"}

// `path` resolved to the `transcibr:` spelling it names, whatever spelling
// it arrived in. core:/base:/vendor: paths are the standard library and
// outside ADR-0038's closure claim entirely, so they resolve to themselves
// unchecked. A `transcibr:` path resolves to itself. Anything else is an
// Odin relative import -- resolved against this package's own directory --
// because Odin accepts that spelling exactly as it accepts the collection
// one, and a guard that only recognizes one spelling recognizes neither.
@(private)
@(require_results)
resolve_import_path :: proc(
	path: string,
	allocator: mem.Allocator,
) -> (
	resolved: string,
	ok: bool,
) {
	assert(len(path) > 0, "asked to resolve a nameless import path")
	assert(allocator.procedure != nil, "the resolved path outlives this call")

	if strings.has_prefix(path, "core:") ||
	   strings.has_prefix(path, "base:") ||
	   strings.has_prefix(path, "vendor:") {
		return strings.clone(path, allocator), true
	}
	if strings.has_prefix(path, "transcibr:") {
		return strings.clone(path, allocator), true
	}

	stack := make([dynamic]string, allocator)
	for segment in CLIARGS_PACKAGE_DIRECTORY_SEGMENTS {
		append(&stack, segment)
	}
	segments := strings.split(path, "/", allocator)
	for segment in segments {
		switch segment {
		case "", ".":
		case "..":
			if len(stack) == 0 {
				return "", false
			}
			pop(&stack)
		case:
			append(&stack, segment)
		}
	}
	if len(stack) < 2 || stack[0] != "src" {
		return "", false
	}

	joined := strings.join(stack[1:], "/", allocator)
	defer delete(joined, allocator)
	return strings.concatenate([]string{"transcibr:", joined}, allocator), true
}

@(private)
@(require_results)
is_allowed_import :: proc(path: string, allocator: mem.Allocator) -> bool {
	assert(len(path) > 0, "asked whether a nameless import path is allowed")

	resolved, resolved_ok := resolve_import_path(path, allocator)
	if !resolved_ok {
		return false
	}
	defer delete(resolved, allocator)

	if !strings.has_prefix(resolved, "transcibr:") {
		return true
	}
	for allowed in ALLOWED_TRANSCIBR_IMPORT_PATHS {
		if resolved == allowed {
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

	files, files_ok := package_files(allocator)
	if !testing.expect(t, files_ok, "could not walk src/cliargs to discover its own files") {
		return
	}
	testing.expect_value(t, len(files), MIN_PACKAGE_FILE_COUNT)

	checked := 0
	for file in files {
		paths, ok := import_paths_of(file.name, file.src, allocator)
		if !testing.expectf(t, ok, "could not parse %s for its imports", file.name) {
			continue
		}
		for path in paths {
			checked += 1
			testing.expectf(
				t,
				is_allowed_import(path, allocator),
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
