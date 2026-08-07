#+vet explicit-allocators
package cliargs

import "core:testing"

@(test)
required_fields_present_passes_when_every_value_is_non_empty :: proc(t: ^testing.T) {
	ok, _ := required_fields_present(
		[]Required_Field {
			{value = "recordings", name = "--batch"},
			{value = "model.bin", name = "--model-file"},
		},
	)

	testing.expect(t, ok, "every required field was present and it still refused")
}

@(test)
required_fields_present_refuses_the_first_missing_field_in_order :: proc(t: ^testing.T) {
	ok, refusal := required_fields_present(
		[]Required_Field {
			{value = "recordings", name = "--batch"},
			{value = "", name = "--model-file"},
			{value = "", name = "--engine-exe"},
		},
	)

	testing.expect(t, !ok, "a missing required field was accepted")
	testing.expect_value(t, refusal.complaint, "%s names nothing.")
	testing.expect_value(t, refusal.arg_count, 1)
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--model-file"))
}
