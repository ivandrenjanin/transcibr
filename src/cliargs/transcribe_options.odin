#+vet explicit-allocators
// --transcribe's grammar (ADR-0038 Stage 3): Transcribe_Options embeds
// Common_Options via `using`, and read_transcribe_options is built entirely
// from the stage-2 helpers (read_pairs, required_fields_present,
// parse_profile) -- the same shape src/cli/transcribe.odin's
// read_transcribe_options read by hand, returning its verdict as a value
// instead of writing to stderr itself. It does not default the two-string
// Tools -- that stays src/cli's job, run after this procedure returns, the
// same place `audio.defaulted_tools` runs today (ADR-0038's import-closure
// section: audio.Tools would pull transcibr:child into this package).
package cliargs

import "transcibr:transcript"

TRANSCRIBE :: "--transcribe"

UNKNOWN_OPTION_COMPLAINT :: "unknown option %q."

Transcribe_Options :: struct {
	using common: Common_Options,
	source:       string,
}

@(require_results)
read_transcribe_options :: proc(
	arguments: []string,
) -> (
	o: Transcribe_Options,
	ok: bool,
	refusal: Refusal,
) {
	defer if ok {
		assert(len(o.source) > 0, "accepted a command line with no Recording to transcribe")
		assert(len(o.model) > 0, "accepted a command line naming no Model")
		assert(len(o.engine) > 0, "accepted a command line naming no Engine")
		assert(len(o.cache) > 0, "accepted a command line naming no scratch cache")
	} else {
		assert(len(o.source) == 0, "refused a command line and kept what it asked for")
	}

	o.profile = transcript.DEFAULT_PROFILE

	pair_ok, pair_refusal := read_pairs(arguments, read_transcribe_option, &o)
	if !pair_ok {
		return {}, false, pair_refusal
	}

	fields_ok, fields_refusal := required_fields_present(
		[]Required_Field {
			{o.source, TRANSCRIBE},
			{o.model, "--model-file"},
			{o.engine, "--engine-exe"},
			{o.cache, "--cache"},
		},
	)
	if !fields_ok {
		return {}, false, fields_refusal
	}
	return o, true, {}
}

// `--model-file` and `--engine-exe`, not `--model` and `--engine`, for the
// reason src/cli/transcribe.odin's own comment names: those two spellings
// are already the provenance fields a Transcript records next door.
@(private)
@(require_results)
read_transcribe_option :: proc(
	name: string,
	value: string,
	user: rawptr,
) -> (
	ok: bool,
	refusal: Refusal,
) {
	assert(user != nil, "there is nowhere here to read an option into")
	o := cast(^Transcribe_Options)user

	switch name {
	case TRANSCRIBE:
		o.source = value
	case "--model-file":
		o.model = value
	case "--engine-exe":
		o.engine = value
	case "--cache":
		o.cache = value
	case "--ffmpeg":
		o.tools.ffmpeg = value
	case "--ffprobe":
		o.tools.ffprobe = value
	case "--prompt":
		o.prompt = value
	case "--profile":
		profile, known, profile_refusal := parse_profile(value)
		if !known {
			return false, profile_refusal
		}
		o.profile = profile
	case:
		return false, make_refusal(UNKNOWN_OPTION_COMPLAINT, Refusal_Arg(name))
	}
	return true, {}
}
