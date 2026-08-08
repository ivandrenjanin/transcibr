#+vet explicit-allocators
package cliargs

import "core:testing"

@(test)
asks_for_help_finds_help_at_the_first_name_position :: proc(t: ^testing.T) {
	testing.expect(t, asks_for_help([]string{"--help"}), "--help alone was not recognized")
}

@(test)
asks_for_help_finds_help_at_a_later_name_position :: proc(t: ^testing.T) {
	testing.expect(
		t,
		asks_for_help([]string{"--model", "name", HELP}),
		"--help after a complete name/value pair was not recognized",
	)
}

// Issue #261: --help is sovereign in ANY argv slot, name position or value
// position. A user typing "--from-json --help" wants help, not a filesystem
// probe of a file literally named --help.
@(test)
asks_for_help_finds_help_standing_in_a_value_position :: proc(t: ^testing.T) {
	testing.expect(
		t,
		asks_for_help([]string{"--from-json", HELP}),
		"--help standing where --from-json's own value belongs was not recognized as a request for help",
	)
}

// The pathological-but-legal case stays reachable: a json path genuinely
// named --help is expressible as .\--help, which is a different string and
// never matches HELP by exact equality.
@(test)
asks_for_help_leaves_the_escaped_literal_path_alone :: proc(t: ^testing.T) {
	testing.expect(
		t,
		!asks_for_help([]string{"--from-json", `.\--help`}),
		".\\--help was wrongly recognized as a request for help",
	)
}

// A bare token match only: a file genuinely named x--help.json is a
// different string from --help and must never match as a substring.
@(test)
asks_for_help_does_not_match_help_as_a_substring :: proc(t: ^testing.T) {
	testing.expect(
		t,
		!asks_for_help([]string{"--from-json", "x--help.json"}),
		"x--help.json was wrongly recognized as a request for help",
	)
}

@(test)
asks_for_help_finds_nothing_in_an_empty_argument_list :: proc(t: ^testing.T) {
	testing.expect(t, !asks_for_help([]string{}), "an empty argument list asked for help")
}
