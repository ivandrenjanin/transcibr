#+vet explicit-allocators
// Issue #189 fix round 1: two findings the ticket's own committed tests never
// caught, both requiring the real built CLI as a witness -- `cli` carries no
// tests by design (ADR-0009), so a defect confined to a single `src/cli`
// call site can only be proven by spawning the binary and reading what it
// actually printed. This spawns the same debug binary
// `src/crashlog/crashlog_crash_test.odin` already builds as `just test`'s own
// first line (`build/odin-test/transcibr-cli-drill.exe`) in plain `--doctor`
// mode, never `--crash-drill`.
//
// Running either test below in isolation (`just test-one doctor <name>`)
// rebuilds that binary itself, as its own first dependency edge (issue
// #240's `drill-cli-exe` recipe, mapped to this package in fix round 1) --
// a bare `test-one`, with no prior `just test` and no hand-run build,
// always meets the current source.
//
// Finding 1: an unreadable Engine binary used to return OPERATING_ERROR
// before `run_preflight` ever ran, so the whole report -- all five existing
// verdict rows -- vanished instead of sitting beside the identity failure.
// `an_unreadable_engine_binary_still_reports_the_five_preflight_rows_before_refusing`
// proves the five rows now reach stdout even when the Engine cannot be
// identified.
//
// Finding 2: the ticket's own AC2 covering test
// (`src/artifact/engine_test.odin`'s
// `a_doctor_pass_and_a_batch_pass_identify_the_same_engine_binary_the_same_way`)
// calls `identify_engine` twice with identical arguments, so it can only fail
// if that procedure is nondeterministic -- never the property AC2 actually
// asks for. The defect that property has to catch lives at the one call site
// choosing WHICH local variable reaches `engine_identified`
// (src/cli/doctor.odin, `o.engine` versus `o.model`), invisible to any test
// that never drives `run_doctor` itself.
// `doctors_reported_engine_identity_names_the_engine_and_not_the_model` spawns
// the real CLI with an Engine and a Model that hash to two DIFFERENT digests
// and reads the identity line back off its stdout -- a doctor.odin that
// passed `o.model` where `o.engine` belongs prints the Model's digest under
// the label "engine identity:", which this test catches and the determinism
// test cannot.
package doctor

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "transcibr:artifact"
import "transcibr:testkit"

@(private)
DOCTOR_DRILL_CLI :: "build\\odin-test\\transcibr-cli-drill.exe"

// Shared by both tests below so the process_exec/error-handling shape lives
// in one place: the property each test checks is what the returned stdout
// names, not how the drill is spawned. Frees nothing on the caller's behalf
// but the drill's stderr, which no caller here needs to read.
@(private)
@(require_results)
run_doctor_drill :: proc(
	t: ^testing.T,
	engine_path: string,
	model_path: string,
	allocator: mem.Allocator,
) -> (
	stdout: string,
	stderr: string,
	exit_code: int,
	ran: bool,
) {
	assert(t != nil, "there is no test here to report a drill failure through")
	assert(len(engine_path) > 0, "the doctor drill needs an engine path, even an unreadable one")
	assert(len(model_path) > 0, "the doctor drill needs a model path, even an unreadable one")

	return testkit.run_cli_drill(
		t,
		DOCTOR_DRILL_CLI,
		[]string{"--doctor", "--engine-exe", engine_path, "--model-file", model_path},
		allocator,
	)
}

@(test)
an_unreadable_engine_binary_still_reports_the_five_preflight_rows_before_refusing :: proc(
	t: ^testing.T,
) {
	directory := testkit.made_scratch_cache(
		t,
		"doctor",
		"engine-unreadable-cli",
		context.allocator,
	)
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

	text, stderr_text, exit_code, ran := run_doctor_drill(
		t,
		missing_engine,
		model_path,
		context.allocator,
	)
	defer delete(missing_engine, context.allocator)
	defer delete(text, context.allocator)
	defer delete(stderr_text, context.allocator)
	if !ran {
		return
	}

	testing.expect_value(t, exit_code, 1)
	for row_name in ([]string{"ffmpeg", "ffprobe", "engine", "model", "gpu"}) {
		testing.expectf(
			t,
			strings.contains(text, row_name),
			"an unreadable Engine suppressed the %q preflight row: %s",
			row_name,
			text,
		)
	}
	testing.expectf(
		t,
		!strings.contains(text, "engine identity:"),
		"an Engine that could not be identified still printed an identity line: %s",
		text,
	)
}

@(test)
doctors_reported_engine_identity_names_the_engine_and_not_the_model :: proc(t: ^testing.T) {
	directory := testkit.made_scratch_cache(t, "doctor", "engine-identity-cli", context.allocator)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	engine_path := testkit.fixture_file(
		t,
		directory,
		"whisper-cli.exe",
		"engine bytes for issue 189 fix round 1",
		context.allocator,
	)
	defer delete(engine_path, context.allocator)
	model_path := testkit.fixture_file(
		t,
		directory,
		"ggml-model.bin",
		"model bytes, deliberately not the engine's",
		context.allocator,
	)
	defer delete(model_path, context.allocator)

	engine_digest, engine_fault := artifact.identify_engine(engine_path, context.allocator)
	defer delete(string(engine_digest), context.allocator)
	if !testing.expect_value(t, engine_fault, artifact.Engine_Fault.None) {
		return
	}
	model, model_fault := artifact.identify_model(model_path, context.allocator)
	defer artifact.destroy_model(model, context.allocator)
	if !testing.expect_value(t, model_fault, artifact.Model_Fault.None) {
		return
	}
	if !testing.expect(
		t,
		string(engine_digest) != string(model.digest),
		"the two fixtures hashed identically, so this test cannot tell them apart",
	) {
		return
	}

	expected_line := render_engine_identity(engine_digest, context.allocator)
	defer delete(expected_line, context.allocator)

	text, stderr_text, _, ran := run_doctor_drill(t, engine_path, model_path, context.allocator)
	defer delete(text, context.allocator)
	defer delete(stderr_text, context.allocator)
	if !ran {
		return
	}

	testing.expectf(
		t,
		strings.contains(text, expected_line),
		"the doctor report never named the Engine's own digest: %s",
		text,
	)
	testing.expectf(
		t,
		!strings.contains(text, string(model.digest)),
		"the doctor report named the Model's digest instead of the Engine's: %s",
		text,
	)
}

// Issue #216 fix round 1: the three unit-level tests the PR names as its pin
// (`process`'s and `artifact`'s framing tests) only prove the parameter
// plumbing between src/process and src/artifact -- none of them ever call
// into src/cli, so a regression at doctor.odin's own call site (reverting
// DOCTOR_ENGINE_REFUSAL_FRAMING, or losing the framing argument on a later
// edit) leaves every one of them green. This spawns the real drill binary
// with an unreadable Engine, the same way the two tests above already do,
// and reads the refusal off stderr -- the one place `run_doctor` actually
// prints it (`pipeline.report_fault`) -- so it is the only test in the tree
// that would catch --doctor's refusal prose regressing back to the Batch's
// wording.
@(test)
an_unreadable_engine_refusal_names_doctor_and_not_the_batch :: proc(t: ^testing.T) {
	directory := testkit.made_scratch_cache(t, "doctor", "engine-refusal-cli", context.allocator)
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

	stdout_text, stderr_text, _, ran := run_doctor_drill(
		t,
		missing_engine,
		model_path,
		context.allocator,
	)
	defer delete(missing_engine, context.allocator)
	defer delete(stdout_text, context.allocator)
	defer delete(stderr_text, context.allocator)
	if !ran {
		return
	}

	testing.expectf(
		t,
		strings.contains(stderr_text, "--doctor"),
		"the doctor refusal never named --doctor: %s",
		stderr_text,
	)
	testing.expectf(
		t,
		!strings.contains(stderr_text, "the Batch cannot start"),
		"the doctor refusal still claims a Batch cannot start: %s",
		stderr_text,
	)
	testing.expectf(
		t,
		strings.contains(stderr_text, "see the engine row above"),
		"the doctor refusal lost its pointer back to the engine row: %s",
		stderr_text,
	)
}
