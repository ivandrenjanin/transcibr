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

// The substring test above only pins a match with LEADING context; it
// cannot catch a prefix weakening (strings.has_prefix(argument, HELP))
// because "x--help.json" does not start with "--help". A file genuinely
// named --help.json is a real, reachable json path and must never match.
@(test)
asks_for_help_does_not_match_help_as_a_prefix :: proc(t: ^testing.T) {
	testing.expect(
		t,
		!asks_for_help([]string{"--from-json", "--help.json"}),
		"--help.json was wrongly recognized as a request for help",
	)
}

@(test)
asks_for_help_finds_nothing_in_an_empty_argument_list :: proc(t: ^testing.T) {
	testing.expect(t, !asks_for_help([]string{}), "an empty argument list asked for help")
}

// Every other test places --help in the FINAL argv slot, which a
// last-slot-only scan would also pass. --help is sovereign wherever it
// stands, including first with arguments still trailing after it -- base
// behavior this PR must not silently regress.
@(test)
asks_for_help_finds_help_first_with_arguments_after_it :: proc(t: ^testing.T) {
	testing.expect(
		t,
		asks_for_help([]string{HELP, "--transcribe", "--source", "x"}),
		"--help first, with arguments after it, was not recognized",
	)
}

@(test)
asks_for_help_finds_help_mid_line :: proc(t: ^testing.T) {
	testing.expect(
		t,
		asks_for_help([]string{"--from-json", HELP, "nope.json"}),
		"--help in the middle of argv, with arguments after it, was not recognized",
	)
}

// --prompt is free user text, unlike a path-valued option: there is no .\
// escape form of a prompt string, so a prompt whose literal text is --help
// is an accepted, escape-route-less consequence of the any-slot ruling
// (issue #261 fix round 3), not an oversight.
@(test)
asks_for_help_finds_help_as_a_prompt_value :: proc(t: ^testing.T) {
	testing.expect(
		t,
		asks_for_help([]string{"--transcribe", "--prompt", HELP}),
		"--help standing where --prompt's own value belongs was not recognized as a request for help",
	)
}
