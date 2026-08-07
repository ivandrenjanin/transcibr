#+vet explicit-allocators
package cliargs

import "core:testing"

@(private)
Collected_Pairs :: struct {
	names:  [dynamic]string,
	values: [dynamic]string,
}

@(private)
@(require_results)
collecting_reader :: proc(
	name: string,
	value: string,
	user: rawptr,
) -> (
	ok: bool,
	refusal: Refusal,
) {
	collected := cast(^Collected_Pairs)user
	append(&collected.names, name)
	append(&collected.values, value)
	return true, {}
}

@(test)
read_pairs_dispatches_every_name_value_pair_in_order :: proc(t: ^testing.T) {
	collected: Collected_Pairs
	defer delete(collected.names)
	defer delete(collected.values)

	ok, _ := read_pairs(
		[]string{"--model-file", "model.bin", "--cache", "cache-dir"},
		collecting_reader,
		&collected,
	)

	testing.expect(t, ok, "reading two well-formed pairs was refused")
	testing.expect_value(t, len(collected.names), 2)
	testing.expect_value(t, collected.names[0], "--model-file")
	testing.expect_value(t, collected.values[0], "model.bin")
	testing.expect_value(t, collected.names[1], "--cache")
	testing.expect_value(t, collected.values[1], "cache-dir")
}

@(private)
@(require_results)
always_ok_reader :: proc(
	name: string,
	value: string,
	user: rawptr,
) -> (
	ok: bool,
	refusal: Refusal,
) {
	return true, {}
}

@(test)
read_pairs_refuses_a_trailing_name_with_no_value_after_it :: proc(t: ^testing.T) {
	ok, refusal := read_pairs(
		[]string{"--model-file", "model.bin", "--cache"},
		always_ok_reader,
		nil,
	)

	testing.expect(t, !ok, "a trailing name with no value was accepted")
	testing.expect_value(
		t,
		refusal.complaint,
		"%q stands at the end of the command line with no value after it.",
	)
	testing.expect_value(t, refusal.arg_count, 1)
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--cache"))
}

@(private)
@(require_results)
always_refuse_reader :: proc(
	name: string,
	value: string,
	user: rawptr,
) -> (
	ok: bool,
	refusal: Refusal,
) {
	return false, make_refusal("unknown option %q.", Refusal_Arg(name))
}

@(test)
read_pairs_stops_and_propagates_the_first_readers_own_refusal :: proc(t: ^testing.T) {
	ok, refusal := read_pairs([]string{"--bogus", "value"}, always_refuse_reader, nil)

	testing.expect(t, !ok, "an unknown option was accepted")
	testing.expect_value(t, refusal.complaint, "unknown option %q.")
	testing.expect_value(t, refusal.args[0], Refusal_Arg("--bogus"))
}
