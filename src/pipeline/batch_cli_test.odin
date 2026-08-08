#+vet explicit-allocators
// Issue #283, filed from the #249 review (PR #279, merged): `--plan` and
// `--transcribe` each have a CLI-spawning integration test
// (`plan_cli_test.odin`, `transcribe_cli_test.odin`) pinning their refusal
// wording through the real built binary; `--batch` had none. After #279's
// convergence `src/cli/batch.odin` passes `process.BATCH_CANNOT_START`
// directly at both `model_identified_framed` and `engine_identified_framed`
// call sites -- the framing every other command has to name a constant for
// is, for `--batch`, simply the truth (a Batch really cannot start), so the
// deferred minor the #249 review left open is that nothing pins those two
// bytes AT THAT CALL SITE: swap either argument for a different string (a
// per-command framing the way `--plan`/`--transcribe` use, or a typo) and
// every unit-level test in `src/process` and `src/artifact` stays green,
// because none of them ever call into `src/cli`. `cli` carries no tests by
// design (ADR-0009), so this spawns the same debug binary
// `src/crashlog/crashlog_crash_test.odin`, `src/doctor/identity_cli_test.odin`
// and this package's own `transcribe_cli_test.odin` already build as `just
// test`'s own first line (`build/odin-test/transcibr-cli-drill.exe`), in
// `--batch` mode, and reads the refusal back off stderr, the one place
// `run_batch_command` actually prints it (`pipeline.report_fault`).
//
// `--batch` checks its scratch cache first, its Model second and its Engine
// third (`run_batch_command`, `src/cli/batch.odin`), all three before the
// root folder is ever walked -- so every case below hands a root that is
// never read, and the Engine and Model cases below hand the OTHER identity a
// fixture that passes its own check, so the refusal under test is the one
// that actually fires first.
//
// The #189/#216 review's own covering matrix -- a missing path, a directory
// passed where a file belongs, and a file another handle holds open -- all
// collapse to the same `artifact.Engine_Fault.Unreadable`/`Model_Fault.Unreadable`
// and so the same refusal bytes (`src/artifact/engine_test.odin`'s
// `an_unreadable_engine_carries_its_callers_framing_across_missing_directory_and_locked_shapes`
// proves that at the unit level); re-driving all three shapes here through
// the real binary is what proves the CLI wiring itself survives every shape,
// not only the one every other sibling CLI drill happens to use.
//
// Running any test in this file in isolation (`just test-one pipeline <name>`)
// rebuilds that binary itself, as its own first dependency edge (issue #240's
// `drill-cli-exe` recipe, already mapped to this package) -- a bare
// `test-one`, with no prior `just test` and no hand-run build, always meets
// the current source.
package pipeline

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"
import "core:testing"
import "transcibr:testkit"

@(private)
BATCH_DRILL_CLI :: "build\\odin-test\\transcibr-cli-drill.exe"

@(private)
@(require_results)
run_batch_drill :: proc(
	t: ^testing.T,
	root: string,
	engine_path: string,
	model_path: string,
	cache_path: string,
	allocator: mem.Allocator,
) -> (
	stderr: string,
	exit_code: int,
	ran: bool,
) {
	assert(t != nil, "there is no test here to report a drill failure through")
	assert(len(root) > 0, "the batch drill needs a folder to walk, even an empty one")
	assert(len(engine_path) > 0, "the batch drill needs an engine path, even an unreadable one")
	assert(len(model_path) > 0, "the batch drill needs a model path, even an unreadable one")
	assert(len(cache_path) > 0, "the batch drill needs a scratch cache to open")

	stdout: string
	drill_ran: bool
	stdout, stderr, exit_code, drill_ran = testkit.run_cli_drill(
		t,
		BATCH_DRILL_CLI,
		[]string {
			"--batch",
			root,
			"--model-file",
			model_path,
			"--engine-exe",
			engine_path,
			"--cache",
			cache_path,
		},
		allocator,
	)
	delete(stdout, allocator)
	if !drill_ran {
		delete(stderr, allocator)
		return "", 0, false
	}
	return stderr, exit_code, true
}

// Runs one drill and checks the two properties every case in this file
// cares about: a batch-setup refusal always exits 1, and its exact bytes
// carry `process.BATCH_CANNOT_START`'s framing -- never a per-command one, and
// never silence. Split out of the matrix tests below (fix round 1, CLAUDE.md
// rule F1): three shapes times this pair of assertions was what pushed each
// of them over the 70-line procedure cap.
@(private)
assert_batch_setup_refusal :: proc(
	t: ^testing.T,
	root: string,
	engine_path: string,
	model_path: string,
	cache: string,
	expected: string,
	allocator: mem.Allocator,
) {
	assert(t != nil, "there is no test here to report a refusal check through")
	assert(len(expected) > 0, "there is no expected refusal sentence to check stderr against")

	stderr_text, exit_code, ran := run_batch_drill(
		t,
		root,
		engine_path,
		model_path,
		cache,
		allocator,
	)
	defer delete(stderr_text, allocator)
	if !ran {
		return
	}

	testing.expectf(
		t,
		exit_code == 1,
		"the batch refusal exited %d, not 1: %s",
		exit_code,
		stderr_text,
	)
	testing.expectf(
		t,
		strings.contains(stderr_text, expected),
		"the batch refusal did not carry the Batch's own framing, in its exact words: %s",
		stderr_text,
	)
}

// The same primitive `src/artifact/engine_test.odin`'s `locked_engine_fixture`
// uses: `share_mode = 0` conflicts with every other open handle, so this
// holds one open while the drill tries to read it.
@(private)
@(require_results)
locked_batch_fixture :: proc(t: ^testing.T, path: string) -> win32.HANDLE {
	assert(t != nil, "there is no test here to report a lock failure through")
	assert(len(path) > 0, "there is no path here to lock")

	wide := win32.utf8_to_utf16(path, context.allocator)
	defer delete(wide, context.allocator)
	handle := win32.CreateFileW(
		win32.wstring(raw_data(wide)),
		win32.GENERIC_READ,
		0,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	testing.expect(
		t,
		handle != win32.INVALID_HANDLE_VALUE,
		"could not lock the fixture this case exists to test against",
	)
	return handle
}

// The #189/#216 review's own three unreadable shapes, built once here and
// shared by the Engine and Model matrices below: a never-written path, a
// directory sitting where `extension` names a file, and a file another
// handle holds open with no share mode at all. The caller frees each shape
// with `allocator` and closes `handle`.
@(private)
@(require_results)
unreadable_shape_fixtures :: proc(
	t: ^testing.T,
	directory: string,
	extension: string,
	allocator: mem.Allocator,
) -> (
	shapes: [3]string,
	handle: win32.HANDLE,
) {
	assert(t != nil, "there is no test here to report a fixture failure through")
	assert(len(directory) > 0, "there is nowhere here to write the unreadable-shape fixtures")
	assert(len(extension) > 0, "an unreadable-shape fixture with no extension names no real file")

	shapes[0] = fmt.aprintf("%s\\never-written%s", directory, extension, allocator = allocator)

	shapes[1] = fmt.aprintf("%s\\not-a-file%s", directory, extension, allocator = allocator)
	testing.expect(
		t,
		os.make_directory_all(shapes[1]) == nil,
		"could not make the directory-as-file fixture",
	)

	relative := fmt.aprintf("locked%s", extension, allocator = allocator)
	defer delete(relative, allocator)
	shapes[2] = testkit.fixture_file(t, directory, relative, "abc", allocator)
	handle = locked_batch_fixture(t, shapes[2])
	return
}

// Issue #216/#249's covering matrix, re-driven through the real binary
// (issue #283): a missing path, a directory passed where `--engine-exe`
// belongs, and a locked file all report `artifact.Engine_Fault.Unreadable`,
// so all three land on the same refusal bytes -- proving the CLI wiring
// itself, not only `identify_engine`'s own fault translation, survives every
// shape. `model_path` is a readable fixture throughout so the Engine is what
// actually refuses first, ahead of it in `run_batch_command`'s own order.
@(test)
a_batch_refuses_an_unreadable_engine_across_missing_directory_and_locked_shapes_naming_the_batch :: proc(
	t: ^testing.T,
) {
	fixtures := testkit.made_scratch_cache(
		t,
		"pipeline",
		"batch-engine-refusal-cli-fixtures",
		context.allocator,
	)
	defer delete(fixtures, context.allocator)
	defer testkit.remove_cache(fixtures, context.allocator)

	root := testkit.made_scratch_cache(
		t,
		"pipeline",
		"batch-engine-refusal-cli-root",
		context.allocator,
	)
	defer delete(root, context.allocator)
	defer testkit.remove_cache(root, context.allocator)

	cache := testkit.made_scratch_cache(
		t,
		"pipeline",
		"batch-engine-refusal-cli-cache",
		context.allocator,
	)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	model_path := testkit.fixture_file(
		t,
		fixtures,
		"ggml-model.bin",
		"a model fixture, readable but not a real Model",
		context.allocator,
	)
	defer delete(model_path, context.allocator)

	shapes, handle := unreadable_shape_fixtures(t, fixtures, ".exe", context.allocator)
	defer for shape in shapes {delete(shape, context.allocator)}
	defer win32.CloseHandle(handle)

	for shape in shapes {
		assert_batch_setup_refusal(
			t,
			root,
			shape,
			model_path,
			cache,
			"the Engine binary could not be read -- the Batch cannot start",
			context.allocator,
		)
	}
}

// As the Engine matrix above, for the Model: `run_batch_command` identifies
// the Model before the Engine, so `engine_path` here is a bare, never-opened
// string -- the refusal under test is the Model's, not the Engine's.
@(test)
a_batch_refuses_an_unreadable_model_across_missing_directory_and_locked_shapes_naming_the_batch :: proc(
	t: ^testing.T,
) {
	fixtures := testkit.made_scratch_cache(
		t,
		"pipeline",
		"batch-model-refusal-cli-fixtures",
		context.allocator,
	)
	defer delete(fixtures, context.allocator)
	defer testkit.remove_cache(fixtures, context.allocator)

	root := testkit.made_scratch_cache(
		t,
		"pipeline",
		"batch-model-refusal-cli-root",
		context.allocator,
	)
	defer delete(root, context.allocator)
	defer testkit.remove_cache(root, context.allocator)

	cache := testkit.made_scratch_cache(
		t,
		"pipeline",
		"batch-model-refusal-cli-cache",
		context.allocator,
	)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	shapes, handle := unreadable_shape_fixtures(t, fixtures, ".bin", context.allocator)
	defer for shape in shapes {delete(shape, context.allocator)}
	defer win32.CloseHandle(handle)

	for shape in shapes {
		assert_batch_setup_refusal(
			t,
			root,
			"whisper-cli.exe",
			shape,
			cache,
			"the Model could not be read -- the Batch cannot start",
			context.allocator,
		)
	}
}

// The cache cell of the same matrix: `run_batch_command` checks the scratch
// cache before it ever identifies the Model or the Engine, so both of those
// are bare, never-opened strings here -- the same shape
// `transcribe_cli_test.odin`'s own cache refusal test uses.
@(test)
a_batch_refuses_an_unusable_cache_naming_the_batch :: proc(t: ^testing.T) {
	directory := testkit.made_scratch_cache(
		t,
		"pipeline",
		"batch-cache-refusal-cli",
		context.allocator,
	)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	root := testkit.made_scratch_cache(
		t,
		"pipeline",
		"batch-cache-refusal-cli-root",
		context.allocator,
	)
	defer delete(root, context.allocator)
	defer testkit.remove_cache(root, context.allocator)

	not_a_directory := testkit.fixture_file(
		t,
		directory,
		"not-a-dir.txt",
		"a file, so the cache path names it instead of a directory",
		context.allocator,
	)
	defer delete(not_a_directory, context.allocator)

	assert_batch_setup_refusal(
		t,
		root,
		"whisper-cli.exe",
		"ggml-model.bin",
		not_a_directory,
		"the scratch cache path names an existing file, not a directory -- the Batch cannot start",
		context.allocator,
	)
}
