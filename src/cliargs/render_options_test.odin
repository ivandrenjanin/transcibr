#+vet explicit-allocators
package cliargs

import "core:testing"
import "transcibr:transcript"

@(test)
read_render_options_accepts_a_well_formed_command_line :: proc(t: ^testing.T) {
	o, ok, _ := read_render_options(
		[]string {
			FROM_JSON,
			"engine-output.json",
			"--source",
			"recording.wav",
			"--model",
			"large",
			"--engine",
			"1.5.0",
			"--profile",
			"conversation",
		},
	)

	testing.expect(t, ok, "a well-formed --from-json command line was refused")
	testing.expect_value(t, o.json_path, "engine-output.json")
	testing.expect_value(t, o.source, "recording.wav")
	testing.expect_value(t, o.model, "large")
	testing.expect_value(t, o.engine, "1.5.0")
	testing.expect_value(t, o.profile, transcript.Merge_Profile.Conversation)
}

@(test)
read_render_options_defaults_the_profile_when_none_is_given :: proc(t: ^testing.T) {
	o, ok, _ := read_render_options([]string{FROM_JSON, "engine-output.json"})

	testing.expect(t, ok, "a command line with no --profile was refused")
	testing.expect_value(t, o.profile, transcript.DEFAULT_PROFILE)
}

@(test)
read_render_options_falls_the_source_back_to_the_json_path_when_none_is_given :: proc(
	t: ^testing.T,
) {
	o, ok, _ := read_render_options([]string{FROM_JSON, "engine-output.json"})

	testing.expect(t, ok, "a command line with no --source was refused")
	testing.expect_value(t, o.source, "engine-output.json")
}

@(test)
read_render_options_keeps_an_explicit_source_rather_than_the_json_path :: proc(t: ^testing.T) {
	o, ok, _ := read_render_options(
		[]string{FROM_JSON, "engine-output.json", "--source", "recording.wav"},
	)

	testing.expect(t, ok, "a command line with an explicit --source was refused")
	testing.expect_value(t, o.source, "recording.wav")
}

@(test)
read_render_options_settles_an_unnamed_model_and_engine_to_unknown :: proc(t: ^testing.T) {
	o, ok, _ := read_render_options([]string{FROM_JSON, "engine-output.json"})

	testing.expect(t, ok, "a command line with no --model or --engine was refused")
	testing.expect_value(t, o.model, transcript.UNKNOWN)
	testing.expect_value(t, o.engine, transcript.UNKNOWN)
}

@(test)
read_render_options_refuses_a_trailing_name_with_no_value_after_it :: proc(t: ^testing.T) {
	ok, refusal := render_options_refusal([]string{FROM_JSON})

	testing.expect(t, !ok, "a trailing name with no value was accepted")
	testing.expect_value(
		t,
		refusal.complaint,
		"%q stands at the end of the command line with no value after it.",
	)
	testing.expect_value(t, refusal.args[0], Refusal_Arg(FROM_JSON))
}

@(test)
read_render_options_refuses_an_unknown_option :: proc(t: ^testing.T) {
	ok, refusal := render_options_refusal(
		[]string{FROM_JSON, "engine-output.json", "--bogus", "value"},
	)

	testing.expect(t, !ok, "an unknown option was accepted")
	testing.expect_value(t, refusal.complaint, "unknown option %q.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--bogus"))
}

@(test)
read_render_options_refuses_an_empty_option_name :: proc(t: ^testing.T) {
	ok, refusal := render_options_refusal([]string{FROM_JSON, "engine-output.json", "", "value"})

	testing.expect(t, !ok, "an empty option name was accepted")
	testing.expect_value(t, refusal.complaint, "unknown option %q.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg(""))
}

@(test)
read_render_options_refuses_an_unknown_profile :: proc(t: ^testing.T) {
	ok, refusal := render_options_refusal(
		[]string{FROM_JSON, "engine-output.json", "--profile", "bogus"},
	)

	testing.expect(t, !ok, "an unknown profile was accepted")
	testing.expect_value(t, refusal.complaint, "no merge profile called %q.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg("bogus"))
}

// "nothing to render." predates the shared required-field sweep's
// "%s names nothing." complaint and names no field -- byte-identical to
// src/cli/main.odin's own message before this migration (ADR-0038's
// migration contract).
@(test)
read_render_options_refuses_a_missing_json_path_with_its_own_wording :: proc(t: ^testing.T) {
	ok, refusal := render_options_refusal([]string{})

	testing.expect(t, !ok, "a command line naming nothing to render was accepted")
	testing.expect_value(t, refusal.complaint, "nothing to render.")
	testing.expect_value(t, refusal.arg_count, 0)
}

@(private)
@(require_results)
render_options_refusal :: proc(arguments: []string) -> (ok: bool, refusal: Refusal) {
	_, ok, refusal = read_render_options(arguments)
	return ok, refusal
}
