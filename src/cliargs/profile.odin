#+vet explicit-allocators
// --profile parsing, shared by every command that accepts it (main.odin,
// plan.odin, transcribe.odin's read_common_option -- ADR-0038), returning a
// refusal as a value rather than writing to stderr itself.
package cliargs

import "transcibr:transcript"

UNKNOWN_PROFILE_COMPLAINT :: "no merge profile called %q."

@(require_results)
parse_profile :: proc(
	value: string,
) -> (
	profile: transcript.Merge_Profile,
	ok: bool,
	refusal: Refusal,
) {
	defer if ok {
		assert(
			transcript.profile_name(profile) == value,
			"a profile was accepted under a name that does not name it",
		)
	} else {
		assert(refusal.arg_count == 1, "a profile refusal must name the value that was refused")
	}

	named, known := transcript.profile_named(value)
	if !known {
		return {}, false, make_refusal(UNKNOWN_PROFILE_COMPLAINT, Refusal_Arg(value))
	}
	return named, true, {}
}
