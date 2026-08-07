#+vet explicit-allocators
package cliargs

import "core:strings"
import "core:testing"

// ADR-0038 derives 3 from the measured widest call site,
// `read_batch_worker_option` (batch_options.odin), which lands with this
// stage: `%s takes a whole number from 1 to %d, not %q.` interpolates the
// option name, the ceiling and the offending value, all three. Pinned so
// raising MAX_REFUSAL_ARGS to 4 does not leave the whole suite green with
// nothing that actually needs the fourth slot (stage-2 review deposit 4, PR
// #194).
@(test)
max_refusal_args_is_three_the_width_read_batch_worker_option_needs :: proc(t: ^testing.T) {
	testing.expect_value(t, MAX_REFUSAL_ARGS, 3)
}

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

// Recurses depth levels deep, writing a distinct pattern into a stack-local
// buffer at every level, to make sure the frames build_refusal_from_a_local_slice
// occupied are genuinely reused and overwritten -- unlike a filler array
// declared once in the caller's own frame, which sits above the callee and
// never touches the memory the callee vacated.
@(private)
@(require_results)
scribble_stack :: proc(depth: int) -> int {
	if depth <= 0 {
		return 0
	}
	backing: [64]int
	for i in 0 ..< len(backing) {
		backing[i] = depth * 1000 + i
	}
	return backing[63] + scribble_stack(depth - 1)
}

@(test)
a_refusal_returned_by_value_still_reads_its_argv_slice_after_the_frame_that_built_it_returns :: proc(
	t: ^testing.T,
) {
	argv := make([dynamic]string, 0, 3, context.allocator)
	defer delete(argv)
	append(&argv, strings.clone("--from-json", context.allocator))
	append(&argv, strings.clone("path.json", context.allocator))
	append(&argv, strings.clone("--profile", context.allocator))
	defer {
		for s in argv {
			delete(s, context.allocator)
		}
	}

	r := build_refusal_from_a_local_slice(argv[2])

	sink := scribble_stack(256)

	testing.expect_value(t, r.arg_count, 1)
	testing.expect_value(t, r.args[0], Refusal_Arg("--profile"))
	testing.expect(
		t,
		sink != 0,
		"the scribbler never touched the stack, so the probe proved nothing",
	)
}
