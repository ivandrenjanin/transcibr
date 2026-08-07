#+vet explicit-allocators
// Issue #216 fix, item 1: the artifact/process-level framing tests only
// prove the parameter plumbing between src/process and src/artifact -- none
// of them ever call into src/cli, so a regression at transcribe.odin's own
// call site (reverting `TRANSCRIBE_ENGINE_REFUSAL_FRAMING`, or losing the
// framing argument on a later edit) leaves every one of them green. `cli`
// carries no tests by design (ADR-0009), so this spawns the same debug
// binary `src/crashlog/crashlog_crash_test.odin` and
// `src/doctor/identity_cli_test.odin` already build as `just test`'s own
// first line (`build/odin-test/transcibr-cli-drill.exe`), in `--transcribe`
// mode, and reads the refusal back off stderr, the one place
// `transcribe_one` actually prints it (`pipeline.report_fault`) -- the same
// shape the #237 doctor test used to catch the identical class of
// regression.
//
// Running this test in isolation (`just test-one pipeline <name>`) needs
// the same drill-build line `crashlog_crash_test.odin`'s doc comment names,
// run first, by hand:
// `odin build src/cli -collection:transcibr=src -out:build/odin-test/transcibr-cli-drill.exe -subsystem:console -debug <vet set>`.
package pipeline

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "transcibr:testkit"

@(private)
TRANSCRIBE_DRILL_CLI :: "build\\odin-test\\transcibr-cli-drill.exe"

@(private)
@(require_results)
run_transcribe_drill :: proc(
	t: ^testing.T,
	recording_path: string,
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
	assert(len(recording_path) > 0, "the transcribe drill needs a Recording, even an unreal one")
	assert(
		len(engine_path) > 0,
		"the transcribe drill needs an engine path, even an unreadable one",
	)
	assert(len(model_path) > 0, "the transcribe drill needs a model path, even an unreadable one")
	assert(len(cache_path) > 0, "the transcribe drill needs a scratch cache to open")

	state, out, err_out, err := os.process_exec(
		{
			command = {
				TRANSCRIBE_DRILL_CLI,
				"--transcribe",
				recording_path,
				"--model-file",
				model_path,
				"--engine-exe",
				engine_path,
				"--cache",
				cache_path,
			},
		},
		allocator,
	)
	delete(out, allocator)
	if !testing.expectf(t, err == nil, "the transcribe drill did not run: %v", err) {
		delete(err_out, allocator)
		return "", 0, false
	}
	return string(err_out), state.exit_code, true
}

// The #237 doctor shape's PR body names this as the covering test for the
// call site itself: an unreadable Engine used to tell a `--transcribe` user
// "the Batch cannot start" (issue #216) even though no Batch was ever asked
// for.
@(test)
a_transcribe_refuses_an_unreadable_engine_naming_itself_and_not_the_batch :: proc(t: ^testing.T) {
	directory := testkit.made_scratch_cache(t, "pipeline", "engine-refusal-cli", context.allocator)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	model_path := testkit.fixture_file(
		t,
		directory,
		"ggml-model.bin",
		"a model fixture, readable but not a real Model",
		context.allocator,
	)
	defer delete(model_path, context.allocator)
	missing_engine := testkit.fixture_file(
		t,
		directory,
		"whisper-cli.exe",
		"present so it can be removed",
		context.allocator,
	)
	os.remove(missing_engine)
	recording_path := testkit.fixture_file(
		t,
		directory,
		"clip.mp4",
		"never read: the drill refuses at the Engine before it is ever opened",
		context.allocator,
	)
	defer delete(recording_path, context.allocator)

	stderr_text, exit_code, ran := run_transcribe_drill(
		t,
		recording_path,
		missing_engine,
		model_path,
		directory,
		context.allocator,
	)
	defer delete(missing_engine, context.allocator)
	defer delete(stderr_text, context.allocator)
	if !ran {
		return
	}

	testing.expect_value(t, exit_code, 1)
	testing.expectf(
		t,
		strings.contains(stderr_text, "--transcribe cannot verify this Engine"),
		"the transcribe refusal did not name itself, in its exact words: %s",
		stderr_text,
	)
	testing.expectf(
		t,
		!strings.contains(stderr_text, "the Batch cannot start"),
		"the transcribe refusal still claims a Batch cannot start: %s",
		stderr_text,
	)
}

// Fix round 1 (PR #245's review, finding 1): `transcribe_one` opens the
// scratch cache before it ever touches the Engine or the Model, and that
// refusal kept the default `process.BATCH_CANNOT_START` framing -- issue
// #216's own headline defect, unfenced, one call site away from the Engine
// refusal the test above already covers.
@(test)
a_transcribe_refuses_an_unusable_cache_naming_itself_and_not_the_batch :: proc(t: ^testing.T) {
	directory := testkit.made_scratch_cache(t, "pipeline", "cache-refusal-cli", context.allocator)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	not_a_directory := testkit.fixture_file(
		t,
		directory,
		"not-a-dir.txt",
		"a file, so the cache path names it instead of a directory",
		context.allocator,
	)
	defer delete(not_a_directory, context.allocator)
	recording_path := testkit.fixture_file(
		t,
		directory,
		"clip.mp4",
		"never read: the drill refuses at the cache before it is ever opened",
		context.allocator,
	)
	defer delete(recording_path, context.allocator)

	stderr_text, exit_code, ran := run_transcribe_drill(
		t,
		recording_path,
		"whisper-cli.exe",
		"ggml-model.bin",
		not_a_directory,
		context.allocator,
	)
	defer delete(stderr_text, context.allocator)
	if !ran {
		return
	}

	testing.expect_value(t, exit_code, 1)
	testing.expectf(
		t,
		strings.contains(stderr_text, "--transcribe cannot open this cache"),
		"the transcribe cache refusal did not name itself, in its exact words: %s",
		stderr_text,
	)
	testing.expectf(
		t,
		!strings.contains(stderr_text, "the Batch cannot start"),
		"the transcribe cache refusal still claims a Batch cannot start: %s",
		stderr_text,
	)
}
