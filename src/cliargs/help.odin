#+vet explicit-allocators
// The one option every grammar's own pair-off loop cannot express: it takes
// no value, so read_pairs (which always consumes a name and the argument
// after it) would either misread the argument after --help as its value or
// refuse a trailing --help outright. Answered before any grammar's own loop
// runs instead -- a scan over every argv slot, name position and value
// position alike (issue #261 ruling: a user typing "--from-json --help"
// wants help, not a filesystem probe of a file literally named --help; no
// legitimate json path is spelled --help, since the same path is still
// reachable as .\--help). The match is exact-string equality against a
// whole argv element, never a substring, so a file genuinely named
// x--help.json is left alone.
package cliargs

HELP :: "--help"

@(require_results)
asks_for_help :: proc(arguments: []string) -> bool {
	for argument in arguments {
		if argument == HELP {
			return true
		}
	}
	return false
}
