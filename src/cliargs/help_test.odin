#+vet explicit-allocators
package cliargs

import "core:testing"

@(test)
asks_for_help_finds_help_at_the_first_name_position :: proc(t: ^testing.T) {
	testing.expect(t, asks_for_help([]string{HELP}), "--help alone was not recognized")
}

@(test)
asks_for_help_finds_help_at_a_later_name_position :: proc(t: ^testing.T) {
	testing.expect(
		t,
		asks_for_help([]string{"--model", "name", HELP}),
		"--help after a complete name/value pair was not recognized",
	)
}

// The stride is two, not one: --help stands where a VALUE stands, never a
// name, once a preceding name has claimed the slot after it. Finding this
// with a stride of one reads "--from-json --help" as a request for usage and
// renders nothing, exactly the failure the stride exists to prevent.
@(test)
asks_for_help_does_not_treat_a_value_position_as_a_name :: proc(t: ^testing.T) {
	testing.expect(
		t,
		!asks_for_help([]string{"--from-json", HELP}),
		"--help standing where --from-json's own value belongs was wrongly recognized as a request for help",
	)
}

@(test)
asks_for_help_finds_nothing_in_an_empty_argument_list :: proc(t: ^testing.T) {
	testing.expect(t, !asks_for_help([]string{}), "an empty argument list asked for help")
}
