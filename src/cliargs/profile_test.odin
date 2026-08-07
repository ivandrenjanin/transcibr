#+vet explicit-allocators
package cliargs

import "core:testing"
import "transcibr:transcript"

@(test)
parse_profile_reads_a_known_profile_name :: proc(t: ^testing.T) {
	profile, ok, _ := parse_profile("conversation")

	testing.expect(t, ok, "a known profile name was refused")
	testing.expect_value(t, profile, transcript.Merge_Profile.Conversation)
}

@(test)
parse_profile_refuses_an_unknown_profile_name :: proc(t: ^testing.T) {
	_, ok, refusal := parse_profile("bogus")

	testing.expect(t, !ok, "an unknown profile name was accepted")
	testing.expect_value(t, refusal.complaint, "no merge profile called %q.")
	testing.expect_value(t, refusal.arg_count, 1)
	testing.expect_value(t, refusal.args[0], Refusal_Arg("bogus"))
}
