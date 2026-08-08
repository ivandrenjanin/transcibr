#+vet explicit-allocators
// Issue #216 fix, item 1: the artifact/process-level framing tests only
// prove the parameter plumbing between src/process and src/artifact -- none
// of them ever call into src/cli, so a regression at plan.odin's own call
// site (reverting `PLAN_ENGINE_REFUSAL_FRAMING`, or losing the framing
// argument on a later edit) leaves every one of them green. `cli` carries no
// tests by design (ADR-0009), so this spawns the same debug binary
// `src/crashlog/crashlog_crash_test.odin` and `src/doctor/identity_cli_test.odin`
// already build as `just test`'s own first line
// (`build/odin-test/transcibr-cli-drill.exe`), in `--plan` mode, and reads
// the refusal back off stderr, the one place `run_batch_command`/`plan_batch`
// actually print it (`pipeline.report_fault`) -- the same shape the #237
// doctor test used to catch the identical class of regression.
//
// Running this test in isolation (`just test-one planning <name>`) rebuilds
// that binary itself, as its own first dependency edge (issue #240's
// `drill-cli-exe` recipe, mapped to this package in fix round 1) -- a bare
// `test-one`, with no prior `just test` and no hand-run build, always meets
// the current source.
package planning

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "transcibr:testkit"

@(private)
PLAN_DRILL_CLI :: "build\\odin-test\\transcibr-cli-drill.exe"

@(private)
@(require_results)
run_plan_drill :: proc(
	t: ^testing.T,
	root: string,
	engine_path: string,
	model_path: string,
	allocator: mem.Allocator,
) -> (
	stderr: string,
	exit_code: int,
	ran: bool,
) {
	assert(t != nil, "there is no test here to report a drill failure through")
	assert(len(root) > 0, "the plan drill needs a folder to walk, even an empty one")
	assert(len(engine_path) > 0, "the plan drill needs an engine path, even an unreadable one")
	assert(len(model_path) > 0, "the plan drill needs a model path, even an unreadable one")

	state, out, err_out, err := os.process_exec(
		{
			command = {
				PLAN_DRILL_CLI,
				"--plan",
				root,
				"--model-file",
				model_path,
				"--engine-exe",
				engine_path,
			},
		},
		allocator,
	)
	delete(out, allocator)
	if !testing.expectf(t, err == nil, "the plan drill did not run: %v", err) {
		delete(err_out, allocator)
		return "", 0, false
	}
	return string(err_out), state.exit_code, true
}

// The #237 doctor shape's PR body names this as the covering test for the
// call site itself: an unreadable Engine used to tell a `--plan` user "the
// Batch cannot start" (issue #216) even though no Batch was ever asked for.
//
// Fix round 1 (PR #245's review, finding 2): the first assertion used to
// check only `strings.contains(stderr_text, "--plan")`, which a wrong-noun
// framing (e.g. "--plan cannot verify this Model") still satisfies. Pinned
// to the exact sentence.
@(test)
a_plan_refuses_an_unreadable_engine_naming_itself_and_not_the_batch :: proc(t: ^testing.T) {
	directory := testkit.made_scratch_cache(t, "planning", "engine-refusal-cli", context.allocator)
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

	stderr_text, exit_code, ran := run_plan_drill(
		t,
		directory,
		missing_engine,
		model_path,
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
		strings.contains(stderr_text, "--plan cannot verify this Engine"),
		"the plan refusal did not name itself, in its exact words: %s",
		stderr_text,
	)
	testing.expectf(
		t,
		!strings.contains(stderr_text, "the Batch cannot start"),
		"the plan refusal still claims a Batch cannot start: %s",
		stderr_text,
	)
}

// Fix round 2 (PR #245's review): `--plan` identifies the Model before it
// ever touches the Engine, and that refusal used to call `main.odin`'s
// shared, unparametrized `model_identified`, which always reported "the
// Batch cannot start" -- issue #216's headline defect, live on `--plan`
// alongside the Engine refusal the test above already covers.
@(test)
a_plan_refuses_an_unreadable_model_naming_itself_and_not_the_batch :: proc(t: ^testing.T) {
	directory := testkit.made_scratch_cache(t, "planning", "model-refusal-cli", context.allocator)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	missing_model := testkit.fixture_file(
		t,
		directory,
		"ggml-model.bin",
		"present so it can be removed",
		context.allocator,
	)
	os.remove(missing_model)

	stderr_text, exit_code, ran := run_plan_drill(
		t,
		directory,
		"whisper-cli.exe",
		missing_model,
		context.allocator,
	)
	defer delete(missing_model, context.allocator)
	defer delete(stderr_text, context.allocator)
	if !ran {
		return
	}

	testing.expect_value(t, exit_code, 1)
	testing.expectf(
		t,
		strings.contains(stderr_text, "--plan cannot verify this Model"),
		"the plan refusal did not name itself, in its exact words: %s",
		stderr_text,
	)
	testing.expectf(
		t,
		!strings.contains(stderr_text, "the Batch cannot start"),
		"the plan refusal still claims a Batch cannot start: %s",
		stderr_text,
	)
}
