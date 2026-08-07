#+vet explicit-allocators
package cliargs

import "core:testing"
import "transcibr:transcript"

@(test)
read_transcribe_options_accepts_a_well_formed_command_line :: proc(t: ^testing.T) {
	o, ok, _ := read_transcribe_options(
		[]string {
			TRANSCRIBE,
			"recording.mp4",
			"--model-file",
			"model.bin",
			"--engine-exe",
			"engine.exe",
			"--cache",
			"cache-dir",
			"--ffmpeg",
			"ffmpeg.exe",
			"--ffprobe",
			"ffprobe.exe",
			"--prompt",
			"a prompt",
			"--profile",
			"conversation",
		},
	)

	testing.expect(t, ok, "a well-formed --transcribe command line was refused")
	testing.expect_value(t, o.source, "recording.mp4")
	testing.expect_value(t, o.model, "model.bin")
	testing.expect_value(t, o.engine, "engine.exe")
	testing.expect_value(t, o.cache, "cache-dir")
	testing.expect_value(t, o.tools.ffmpeg, "ffmpeg.exe")
	testing.expect_value(t, o.tools.ffprobe, "ffprobe.exe")
	testing.expect_value(t, o.prompt, "a prompt")
	testing.expect_value(t, o.profile, transcript.Merge_Profile.Conversation)
}

@(test)
read_transcribe_options_defaults_the_profile_when_none_is_given :: proc(t: ^testing.T) {
	o, ok, _ := read_transcribe_options(
		[]string {
			TRANSCRIBE,
			"recording.mp4",
			"--model-file",
			"model.bin",
			"--engine-exe",
			"engine.exe",
			"--cache",
			"cache-dir",
		},
	)

	testing.expect(t, ok, "a command line with no --profile was refused")
	testing.expect_value(t, o.profile, transcript.DEFAULT_PROFILE)
}

@(test)
read_transcribe_options_refuses_a_trailing_name_with_no_value_after_it :: proc(t: ^testing.T) {
	ok, refusal := transcribe_options_refusal(
		[]string{TRANSCRIBE, "recording.mp4", "--model-file"},
	)

	testing.expect(t, !ok, "a trailing name with no value was accepted")
	testing.expect_value(
		t,
		refusal.complaint,
		"%q stands at the end of the command line with no value after it.",
	)
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--model-file"))
}

@(test)
read_transcribe_options_refuses_an_unknown_option :: proc(t: ^testing.T) {
	ok, refusal := transcribe_options_refusal(
		[]string{TRANSCRIBE, "recording.mp4", "--bogus", "value"},
	)

	testing.expect(t, !ok, "an unknown option was accepted")
	testing.expect_value(t, refusal.complaint, "unknown option %q.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--bogus"))
}

@(test)
read_transcribe_options_refuses_an_unknown_profile :: proc(t: ^testing.T) {
	ok, refusal := transcribe_options_refusal(
		[]string {
			TRANSCRIBE,
			"recording.mp4",
			"--model-file",
			"model.bin",
			"--engine-exe",
			"engine.exe",
			"--cache",
			"cache-dir",
			"--profile",
			"bogus",
		},
	)

	testing.expect(t, !ok, "an unknown profile was accepted")
	testing.expect_value(t, refusal.complaint, "no merge profile called %q.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg("bogus"))
}

@(test)
read_transcribe_options_refuses_a_missing_source_first :: proc(t: ^testing.T) {
	ok, refusal := transcribe_options_refusal(
		[]string {
			"--model-file",
			"model.bin",
			"--engine-exe",
			"engine.exe",
			"--cache",
			"cache-dir",
		},
	)

	testing.expect(t, !ok, "a command line naming no Recording was accepted")
	testing.expect_value(t, refusal.complaint, "%s names nothing.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg(TRANSCRIBE))
}

@(test)
read_transcribe_options_refuses_a_missing_model_second :: proc(t: ^testing.T) {
	ok, refusal := transcribe_options_refusal(
		[]string {
			TRANSCRIBE,
			"recording.mp4",
			"--engine-exe",
			"engine.exe",
			"--cache",
			"cache-dir",
		},
	)

	testing.expect(t, !ok, "a command line naming no Model was accepted")
	testing.expect_value(t, refusal.complaint, "%s names nothing.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--model-file"))
}

@(test)
read_transcribe_options_refuses_a_missing_engine_third :: proc(t: ^testing.T) {
	ok, refusal := transcribe_options_refusal(
		[]string{TRANSCRIBE, "recording.mp4", "--model-file", "model.bin", "--cache", "cache-dir"},
	)

	testing.expect(t, !ok, "a command line naming no Engine was accepted")
	testing.expect_value(t, refusal.complaint, "%s names nothing.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--engine-exe"))
}

@(test)
read_transcribe_options_refuses_a_missing_cache_fourth :: proc(t: ^testing.T) {
	ok, refusal := transcribe_options_refusal(
		[]string {
			TRANSCRIBE,
			"recording.mp4",
			"--model-file",
			"model.bin",
			"--engine-exe",
			"engine.exe",
		},
	)

	testing.expect(t, !ok, "a command line naming no cache was accepted")
	testing.expect_value(t, refusal.complaint, "%s names nothing.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--cache"))
}

// The four single-field tests above each omit exactly one required field, so
// none of them can go red on a reordering of required_fields_present's row
// list -- omitting two or more is the only shape that can (fix round 1, PR
// #201 finding 2). Omitting every field pins only the first row: swapping
// rows 2/3 or 3/4 still refuses "--transcribe" first and leaves that single
// case green (fix round 2, PR #201 finding). Walking one case per adjacent
// pair -- each supplying every field UP TO but not including the one under
// test -- pins all four rows against every adjacent swap: the case that
// supplies source alone can only name --model-file if row 2 is still
// "--model-file", regardless of what rows 3/4 hold.
@(test)
read_transcribe_options_refuses_the_earliest_missing_field_for_every_prefix_of_supplied_fields :: proc(
	t: ^testing.T,
) {
	Case :: struct {
		arguments:    []string,
		expected_arg: string,
	}
	cases := []Case {
		{arguments = []string{}, expected_arg = "--transcribe"},
		{arguments = []string{TRANSCRIBE, "recording.mp4"}, expected_arg = "--model-file"},
		{
			arguments = []string{TRANSCRIBE, "recording.mp4", "--model-file", "model.bin"},
			expected_arg = "--engine-exe",
		},
		{
			arguments = []string {
				TRANSCRIBE,
				"recording.mp4",
				"--model-file",
				"model.bin",
				"--engine-exe",
				"engine.exe",
			},
			expected_arg = "--cache",
		},
	}

	for c in cases {
		ok, refusal := transcribe_options_refusal(c.arguments)

		testing.expect(t, !ok, "a command line missing a required field was accepted")
		testing.expect_value(t, refusal.complaint, "%s names nothing.")
		testing.expect_value(t, refusal.args[0], Refusal_Arg(c.expected_arg))
	}
}

@(private)
@(require_results)
transcribe_options_refusal :: proc(arguments: []string) -> (ok: bool, refusal: Refusal) {
	_, ok, refusal = read_transcribe_options(arguments)
	return ok, refusal
}
