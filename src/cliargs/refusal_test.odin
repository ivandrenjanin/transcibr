#+vet explicit-allocators
package cliargs

import "core:testing"

@(test)
make_refusal_holds_its_complaint_and_arguments_by_value :: proc(t: ^testing.T) {
	r := make_refusal(
		"%s takes a whole number from 1 to %d, not %q.",
		Refusal_Arg("--extract-workers"),
		Refusal_Arg(2),
		Refusal_Arg("99"),
	)

	testing.expect_value(t, r.complaint, "%s takes a whole number from 1 to %d, not %q.")
	testing.expect_value(t, r.arg_count, 3)
	testing.expect_value(t, r.args[0], Refusal_Arg("--extract-workers"))
	testing.expect_value(t, r.args[1], Refusal_Arg(2))
	testing.expect_value(t, r.args[2], Refusal_Arg("99"))
}

@(test)
make_refusal_with_no_arguments_carries_zero_arg_count :: proc(t: ^testing.T) {
	r := make_refusal("nothing to render.")

	testing.expect_value(t, r.complaint, "nothing to render.")
	testing.expect_value(t, r.arg_count, 0)
}

@(private)
@(require_results)
build_refusal_from_a_local_slice :: proc(name: string) -> Refusal {
	return make_refusal(
		"%q stands at the end of the command line with no value after it.",
		Refusal_Arg(name),
	)
}

@(test)
a_refusal_returned_by_value_still_reads_its_argv_slice_after_the_frame_that_built_it_returns :: proc(
	t: ^testing.T,
) {
	argv := []string{"--from-json", "path.json", "--profile"}

	r := build_refusal_from_a_local_slice(argv[2])

	filler: [64]int
	for i in 0 ..< len(filler) {
		filler[i] = i
	}

	testing.expect_value(t, r.arg_count, 1)
	testing.expect_value(t, r.args[0], Refusal_Arg("--profile"))
	testing.expect(t, filler[63] == 63, "the filler was not touched, so the probe proved nothing")
}
