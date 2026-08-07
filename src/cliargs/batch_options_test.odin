#+vet explicit-allocators
package cliargs

import "core:testing"
import "transcibr:transcript"

@(private)
TEST_WORKER_CEILINGS := Worker_Ceilings {
	.Extract_Workers = 2,
	.Queue_Depth     = 2,
}

@(test)
read_batch_options_accepts_a_well_formed_command_line :: proc(t: ^testing.T) {
	o, ok, _ := read_batch_options(
		[]string {
			BATCH,
			"recordings",
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
			"--follow-reparse-points",
			"yes",
			"--extract-workers",
			"2",
			"--queue-depth",
			"1",
		},
		TEST_WORKER_CEILINGS,
	)

	testing.expect(t, ok, "a well-formed --batch command line was refused")
	testing.expect_value(t, o.root, "recordings")
	testing.expect_value(t, o.model, "model.bin")
	testing.expect_value(t, o.engine, "engine.exe")
	testing.expect_value(t, o.cache, "cache-dir")
	testing.expect_value(t, o.tools.ffmpeg, "ffmpeg.exe")
	testing.expect_value(t, o.tools.ffprobe, "ffprobe.exe")
	testing.expect_value(t, o.prompt, "a prompt")
	testing.expect_value(t, o.profile, transcript.Merge_Profile.Conversation)
	testing.expect_value(t, o.follow, true)
	testing.expect_value(t, o.extract_workers, 2)
	testing.expect_value(t, o.queue_depth, 1)
}

@(test)
read_batch_options_defaults_the_profile_when_none_is_given :: proc(t: ^testing.T) {
	o, ok, _ := read_batch_options(
		[]string {
			BATCH,
			"recordings",
			"--model-file",
			"model.bin",
			"--engine-exe",
			"engine.exe",
			"--cache",
			"cache-dir",
		},
		TEST_WORKER_CEILINGS,
	)

	testing.expect(t, ok, "a command line with no --profile was refused")
	testing.expect_value(t, o.profile, transcript.DEFAULT_PROFILE)
}

@(test)
read_batch_options_leaves_the_worker_counts_and_follow_flag_unset_when_none_are_given :: proc(
	t: ^testing.T,
) {
	o, ok, _ := read_batch_options(
		[]string {
			BATCH,
			"recordings",
			"--model-file",
			"model.bin",
			"--engine-exe",
			"engine.exe",
			"--cache",
			"cache-dir",
		},
		TEST_WORKER_CEILINGS,
	)

	testing.expect(t, ok, "a command line with no worker options was refused")
	testing.expect_value(t, o.extract_workers, 0)
	testing.expect_value(t, o.queue_depth, 0)
	testing.expect_value(t, o.follow, false)
}

@(test)
read_batch_options_refuses_a_trailing_name_with_no_value_after_it :: proc(t: ^testing.T) {
	ok, refusal := batch_options_refusal([]string{BATCH, "recordings", "--model-file"})

	testing.expect(t, !ok, "a trailing name with no value was accepted")
	testing.expect_value(
		t,
		refusal.complaint,
		"%q stands at the end of the command line with no value after it.",
	)
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--model-file"))
}

@(test)
read_batch_options_refuses_an_unknown_option :: proc(t: ^testing.T) {
	ok, refusal := batch_options_refusal([]string{BATCH, "recordings", "--bogus", "value"})

	testing.expect(t, !ok, "an unknown option was accepted")
	testing.expect_value(t, refusal.complaint, "unknown option %q.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--bogus"))
}

@(test)
read_batch_options_refuses_an_unknown_profile :: proc(t: ^testing.T) {
	ok, refusal := batch_options_refusal(
		[]string {
			BATCH,
			"recordings",
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
read_batch_options_refuses_an_unknown_follow_value :: proc(t: ^testing.T) {
	ok, refusal := batch_options_refusal(
		[]string{BATCH, "recordings", "--follow-reparse-points", "sometimes"},
	)

	testing.expect(t, !ok, "an unknown --follow-reparse-points value was accepted")
	testing.expect_value(t, refusal.complaint, "--follow-reparse-points takes %s, not %q.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg("yes|no"))
	testing.expect_value(t, refusal.args[1], Refusal_Arg("sometimes"))
}

@(test)
read_batch_options_refuses_extract_workers_over_its_own_ceiling :: proc(t: ^testing.T) {
	ok, refusal := batch_options_refusal([]string{BATCH, "recordings", "--extract-workers", "3"})

	testing.expect(t, !ok, "an over-ceiling --extract-workers value was accepted")
	testing.expect_value(t, refusal.complaint, "%s takes a whole number from 1 to %d, not %q.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--extract-workers"))
	testing.expect_value(t, refusal.args[1], Refusal_Arg(2))
	testing.expect_value(t, refusal.args[2], Refusal_Arg("3"))
}

// Issue #94: --extract-workers and --queue-depth must each refuse against
// THEIR OWN ceiling, never the other option's -- the defect this whole
// worker-ceiling shape exists to close. Distinct ceilings prove it where
// today's equal MAX_EXTRACT_WORKERS/MAX_QUEUE_DEPTH values cannot.
@(test)
read_batch_options_refuses_each_worker_option_against_its_own_ceiling_and_not_the_others :: proc(
	t: ^testing.T,
) {
	distinct_ceilings := Worker_Ceilings {
		.Extract_Workers = 1,
		.Queue_Depth     = 4,
	}

	extract_ok, extract_refusal := batch_options_refusal_with_ceilings(
		[]string{BATCH, "recordings", "--extract-workers", "4"},
		distinct_ceilings,
	)
	testing.expect(t, !extract_ok, "--extract-workers 4 sailed past a ceiling of 1")
	testing.expect_value(t, extract_refusal.args[1], Refusal_Arg(1))

	_, queue_ok, _ := read_batch_options(
		[]string {
			BATCH,
			"recordings",
			"--model-file",
			"model.bin",
			"--engine-exe",
			"engine.exe",
			"--cache",
			"cache-dir",
			"--queue-depth",
			"4",
		},
		distinct_ceilings,
	)
	testing.expect(t, queue_ok, "--queue-depth 4 was refused against its own ceiling of 4")
}

@(test)
read_batch_options_refuses_a_missing_root_first :: proc(t: ^testing.T) {
	ok, refusal := batch_options_refusal(
		[]string {
			"--model-file",
			"model.bin",
			"--engine-exe",
			"engine.exe",
			"--cache",
			"cache-dir",
		},
	)

	testing.expect(t, !ok, "a command line naming no folder was accepted")
	testing.expect_value(t, refusal.complaint, "%s names nothing.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg(BATCH))
}

// required_fields_present refuses the FIRST empty field in the list
// read_batch_options builds -- so a single-field-omission test only ever
// pins whichever row happens to sit first; every other row's ORDER is
// unpinned by it and a reordering of required_fields_present's own row
// list leaves such a test green (fix round 3, PR #212 finding 1, mirroring
// transcribe_options_test.odin's own
// read_transcribe_options_refuses_the_earliest_missing_field_for_every_prefix_of_supplied_fields).
// Omitting every field after the walked prefix is what pins each row
// against an adjacent swap: each case below supplies everything through
// one field short of the next, so the missing field named in the refusal
// is exactly the row's own position, not merely "first among an
// otherwise-complete line."
@(test)
read_batch_options_refuses_the_earliest_missing_field_for_every_prefix_of_supplied_fields :: proc(
	t: ^testing.T,
) {
	Case :: struct {
		arguments:    []string,
		expected_arg: string,
	}
	cases := []Case {
		{arguments = []string{}, expected_arg = BATCH},
		{arguments = []string{BATCH, "recordings"}, expected_arg = "--model-file"},
		{
			arguments = []string{BATCH, "recordings", "--model-file", "model.bin"},
			expected_arg = "--engine-exe",
		},
		{
			arguments = []string {
				BATCH,
				"recordings",
				"--model-file",
				"model.bin",
				"--engine-exe",
				"engine.exe",
			},
			expected_arg = "--cache",
		},
	}

	for c in cases {
		ok, refusal := batch_options_refusal(c.arguments)

		testing.expect(t, !ok, "a command line missing a required field was accepted")
		testing.expect_value(t, refusal.complaint, "%s names nothing.")
		testing.expect_value(t, refusal.args[0], Refusal_Arg(c.expected_arg))
	}
}

@(private)
@(require_results)
batch_options_refusal :: proc(arguments: []string) -> (ok: bool, refusal: Refusal) {
	_, ok, refusal = read_batch_options(arguments, TEST_WORKER_CEILINGS)
	return ok, refusal
}

@(private)
@(require_results)
batch_options_refusal_with_ceilings :: proc(
	arguments: []string,
	ceilings: Worker_Ceilings,
) -> (
	ok: bool,
	refusal: Refusal,
) {
	_, ok, refusal = read_batch_options(arguments, ceilings)
	return ok, refusal
}
