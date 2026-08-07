#+vet explicit-allocators
package cliargs

import "core:testing"

@(test)
read_doctor_options_accepts_a_well_formed_command_line :: proc(t: ^testing.T) {
	o, ok, _ := read_doctor_options(
		[]string {
			"--model-file",
			"model.bin",
			"--engine-exe",
			"engine.exe",
			"--ffmpeg",
			"ffmpeg.exe",
			"--ffprobe",
			"ffprobe.exe",
		},
	)

	testing.expect(t, ok, "a well-formed --doctor command line was refused")
	testing.expect_value(t, o.model, "model.bin")
	testing.expect_value(t, o.engine, "engine.exe")
	testing.expect_value(t, o.tools.ffmpeg, "ffmpeg.exe")
	testing.expect_value(t, o.tools.ffprobe, "ffprobe.exe")
}

@(test)
read_doctor_options_leaves_the_tools_unset_when_none_are_given :: proc(t: ^testing.T) {
	o, ok, _ := read_doctor_options(
		[]string{"--model-file", "model.bin", "--engine-exe", "engine.exe"},
	)

	testing.expect(t, ok, "a command line with no --ffmpeg/--ffprobe was refused")
	testing.expect_value(t, o.tools.ffmpeg, "")
	testing.expect_value(t, o.tools.ffprobe, "")
}

@(test)
read_doctor_options_refuses_an_empty_option_name :: proc(t: ^testing.T) {
	ok, refusal := doctor_options_refusal(
		[]string{"--model-file", "model.bin", "--engine-exe", "engine.exe", "", "value"},
	)

	testing.expect(t, !ok, "an empty option name was accepted")
	testing.expect_value(t, refusal.complaint, UNKNOWN_OPTION_COMPLAINT)
	testing.expect_value(t, refusal.args[0], Refusal_Arg(""))
}

@(test)
read_doctor_options_refuses_a_trailing_name_with_no_value_after_it :: proc(t: ^testing.T) {
	ok, refusal := doctor_options_refusal([]string{"--model-file"})

	testing.expect(t, !ok, "a trailing name with no value was accepted")
	testing.expect_value(t, refusal.complaint, NO_VALUE_AFTER_NAME_COMPLAINT)
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--model-file"))
}

@(test)
read_doctor_options_refuses_an_unknown_option :: proc(t: ^testing.T) {
	ok, refusal := doctor_options_refusal([]string{"--bogus", "value"})

	testing.expect(t, !ok, "an unknown option was accepted")
	testing.expect_value(t, refusal.complaint, UNKNOWN_OPTION_COMPLAINT)
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--bogus"))
}

// Doctor_Options does not embed Common_Options -- it has no cache field, no
// prompt field and no profile field, so --cache, --prompt and --profile fall
// through read_doctor_option's case: exactly like any other name outside this
// grammar's vocabulary, the same deliberate refusal Plan_Options keeps for
// its own missing fields (A8, ADR-0038's plan-specific clause applied here).
@(test)
read_doctor_options_refuses_cache_prompt_and_profile_as_unknown_options :: proc(t: ^testing.T) {
	Case :: struct {
		flag: string,
	}
	cases := []Case{{flag = "--cache"}, {flag = "--prompt"}, {flag = "--profile"}}

	for c in cases {
		ok, refusal := doctor_options_refusal(
			[]string {
				"--model-file",
				"model.bin",
				"--engine-exe",
				"engine.exe",
				c.flag,
				"some-value",
			},
		)

		testing.expectf(t, !ok, "%s was accepted by --doctor's grammar", c.flag)
		testing.expect_value(t, refusal.complaint, UNKNOWN_OPTION_COMPLAINT)
		testing.expect_value(t, refusal.args[0], Refusal_Arg(c.flag))
	}
}

@(test)
read_doctor_options_refuses_a_missing_model_first :: proc(t: ^testing.T) {
	ok, refusal := doctor_options_refusal([]string{"--engine-exe", "engine.exe"})

	testing.expect(t, !ok, "a command line naming no Model was accepted")
	testing.expect_value(t, refusal.complaint, REQUIRED_FIELD_EMPTY_COMPLAINT)
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--model-file"))
}

@(test)
read_doctor_options_refuses_a_missing_engine_second :: proc(t: ^testing.T) {
	ok, refusal := doctor_options_refusal([]string{"--model-file", "model.bin"})

	testing.expect(t, !ok, "a command line naming no Engine was accepted")
	testing.expect_value(t, refusal.complaint, REQUIRED_FIELD_EMPTY_COMPLAINT)
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--engine-exe"))
}

// Each case supplies everything through one field short of the next, so the
// missing field named in the refusal is exactly the row's own position --
// pinning required_fields_present's row ORDER against an adjacent swap
// (mirrors plan_options_test.odin's own prefix-walking test, ADR-0038).
@(test)
read_doctor_options_refuses_the_earliest_missing_field_for_every_prefix_of_supplied_fields :: proc(
	t: ^testing.T,
) {
	Case :: struct {
		arguments:    []string,
		expected_arg: string,
	}
	cases := []Case {
		{arguments = []string{}, expected_arg = "--model-file"},
		{arguments = []string{"--model-file", "model.bin"}, expected_arg = "--engine-exe"},
	}

	for c in cases {
		ok, refusal := doctor_options_refusal(c.arguments)

		testing.expect(t, !ok, "a command line missing a required field was accepted")
		testing.expect_value(t, refusal.complaint, REQUIRED_FIELD_EMPTY_COMPLAINT)
		testing.expect_value(t, refusal.args[0], Refusal_Arg(c.expected_arg))
	}
}

@(private)
@(require_results)
doctor_options_refusal :: proc(arguments: []string) -> (ok: bool, refusal: Refusal) {
	_, ok, refusal = read_doctor_options(arguments)
	return ok, refusal
}
