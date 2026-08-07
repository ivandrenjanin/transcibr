#+vet explicit-allocators
package cliargs

import "core:testing"
import "transcibr:transcript"

@(test)
read_plan_options_accepts_a_well_formed_command_line :: proc(t: ^testing.T) {
	o, ok, _ := read_plan_options(
		[]string {
			PLAN,
			"recordings",
			"--model-file",
			"model.bin",
			"--engine-exe",
			"engine.exe",
			"--prompt",
			"a prompt",
			"--profile",
			"conversation",
			"--follow-reparse-points",
			"yes",
		},
	)

	testing.expect(t, ok, "a well-formed --plan command line was refused")
	testing.expect_value(t, o.root, "recordings")
	testing.expect_value(t, o.model, "model.bin")
	testing.expect_value(t, o.engine, "engine.exe")
	testing.expect_value(t, o.prompt, "a prompt")
	testing.expect_value(t, o.profile, transcript.Merge_Profile.Conversation)
	testing.expect_value(t, o.follow, true)
}

@(test)
read_plan_options_defaults_the_profile_when_none_is_given :: proc(t: ^testing.T) {
	o, ok, _ := read_plan_options(
		[]string{PLAN, "recordings", "--model-file", "model.bin", "--engine-exe", "engine.exe"},
	)

	testing.expect(t, ok, "a command line with no --profile was refused")
	testing.expect_value(t, o.profile, transcript.DEFAULT_PROFILE)
}

@(test)
read_plan_options_leaves_the_follow_flag_unset_when_none_is_given :: proc(t: ^testing.T) {
	o, ok, _ := read_plan_options(
		[]string{PLAN, "recordings", "--model-file", "model.bin", "--engine-exe", "engine.exe"},
	)

	testing.expect(t, ok, "a command line with no --follow-reparse-points was refused")
	testing.expect_value(t, o.follow, false)
}

@(test)
read_plan_options_refuses_a_trailing_name_with_no_value_after_it :: proc(t: ^testing.T) {
	ok, refusal := plan_options_refusal([]string{PLAN, "recordings", "--model-file"})

	testing.expect(t, !ok, "a trailing name with no value was accepted")
	testing.expect_value(
		t,
		refusal.complaint,
		"%q stands at the end of the command line with no value after it.",
	)
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--model-file"))
}

@(test)
read_plan_options_refuses_an_unknown_option :: proc(t: ^testing.T) {
	ok, refusal := plan_options_refusal([]string{PLAN, "recordings", "--bogus", "value"})

	testing.expect(t, !ok, "an unknown option was accepted")
	testing.expect_value(t, refusal.complaint, "unknown option %q.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--bogus"))
}

// The ADR's plan-specific clause: Plan_Options does not embed Common_Options,
// so --cache, --ffmpeg and --ffprobe are not silently accepted into a field a
// shared struct happens to carry -- they fall through read_plan_option's
// case: exactly like any other name outside this grammar's vocabulary, and
// must go on being refused byte-identically to today (A8, ADR-0038's
// plan-specific clause).
@(test)
read_plan_options_refuses_cache_ffmpeg_and_ffprobe_as_unknown_options :: proc(t: ^testing.T) {
	Case :: struct {
		flag: string,
	}
	cases := []Case{{flag = "--cache"}, {flag = "--ffmpeg"}, {flag = "--ffprobe"}}

	for c in cases {
		ok, refusal := plan_options_refusal(
			[]string {
				PLAN,
				"recordings",
				"--model-file",
				"model.bin",
				"--engine-exe",
				"engine.exe",
				c.flag,
				"some-value",
			},
		)

		testing.expectf(t, !ok, "%s was accepted by --plan's grammar", c.flag)
		testing.expect_value(t, refusal.complaint, "unknown option %q.")
		testing.expect_value(t, refusal.args[0], Refusal_Arg(c.flag))
	}
}

@(test)
read_plan_options_refuses_an_unknown_profile :: proc(t: ^testing.T) {
	ok, refusal := plan_options_refusal(
		[]string {
			PLAN,
			"recordings",
			"--model-file",
			"model.bin",
			"--engine-exe",
			"engine.exe",
			"--profile",
			"bogus",
		},
	)

	testing.expect(t, !ok, "an unknown profile was accepted")
	testing.expect_value(t, refusal.complaint, "no merge profile called %q.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg("bogus"))
}

@(test)
read_plan_options_refuses_an_unknown_follow_value :: proc(t: ^testing.T) {
	ok, refusal := plan_options_refusal(
		[]string{PLAN, "recordings", "--follow-reparse-points", "sometimes"},
	)

	testing.expect(t, !ok, "an unknown --follow-reparse-points value was accepted")
	testing.expect_value(t, refusal.complaint, "--follow-reparse-points takes %s, not %q.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg("yes|no"))
	testing.expect_value(t, refusal.args[1], Refusal_Arg("sometimes"))
}

@(test)
read_plan_options_refuses_a_missing_root_first :: proc(t: ^testing.T) {
	ok, refusal := plan_options_refusal(
		[]string{"--model-file", "model.bin", "--engine-exe", "engine.exe"},
	)

	testing.expect(t, !ok, "a command line naming no folder was accepted")
	testing.expect_value(t, refusal.complaint, "%s names nothing.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg(PLAN))
}

@(test)
read_plan_options_refuses_a_missing_model_second :: proc(t: ^testing.T) {
	ok, refusal := plan_options_refusal([]string{PLAN, "recordings", "--engine-exe", "engine.exe"})

	testing.expect(t, !ok, "a command line naming no Model was accepted")
	testing.expect_value(t, refusal.complaint, "%s names nothing.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--model-file"))
}

@(test)
read_plan_options_refuses_a_missing_engine_third :: proc(t: ^testing.T) {
	ok, refusal := plan_options_refusal([]string{PLAN, "recordings", "--model-file", "model.bin"})

	testing.expect(t, !ok, "a command line naming no Engine was accepted")
	testing.expect_value(t, refusal.complaint, "%s names nothing.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--engine-exe"))
}

// Each case supplies everything through one field short of the next, so the
// missing field named in the refusal is exactly the row's own position --
// pinning required_fields_present's row ORDER against an adjacent swap,
// never just "first among an otherwise-complete line" (mirrors
// transcribe_options_test.odin's and batch_options_test.odin's own
// prefix-walking test, ADR-0038).
@(test)
read_plan_options_refuses_the_earliest_missing_field_for_every_prefix_of_supplied_fields :: proc(
	t: ^testing.T,
) {
	Case :: struct {
		arguments:    []string,
		expected_arg: string,
	}
	cases := []Case {
		{arguments = []string{}, expected_arg = PLAN},
		{arguments = []string{PLAN, "recordings"}, expected_arg = "--model-file"},
		{
			arguments = []string{PLAN, "recordings", "--model-file", "model.bin"},
			expected_arg = "--engine-exe",
		},
	}

	for c in cases {
		ok, refusal := plan_options_refusal(c.arguments)

		testing.expect(t, !ok, "a command line missing a required field was accepted")
		testing.expect_value(t, refusal.complaint, "%s names nothing.")
		testing.expect_value(t, refusal.args[0], Refusal_Arg(c.expected_arg))
	}
}

@(private)
@(require_results)
plan_options_refusal :: proc(arguments: []string) -> (ok: bool, refusal: Refusal) {
	_, ok, refusal = read_plan_options(arguments)
	return ok, refusal
}
