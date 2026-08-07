#+vet explicit-allocators
// The one option every grammar's own pair-off loop cannot express: it takes
// no value, so read_pairs (which always consumes a name and the argument
// after it) would either misread the argument after --help as its value or
// refuse a trailing --help outright. Answered before any grammar's own loop
// runs instead -- a second, name-only scan with the SAME stride read_pairs
// uses, so --help is only ever found where a NAME may stand, never where a
// preceding option's value belongs (issue #75 fix round 1, PR #253 finding
// 2: a scan taken with stride one read "--from-json --help" as a request
// for usage and reported success on a render that never happened).
package cliargs

HELP :: "--help"

@(require_results)
asks_for_help :: proc(arguments: []string) -> bool {
	for at := 0; at < len(arguments); at += 2 {
		if arguments[at] == HELP {
			return true
		}
	}
	return false
}
