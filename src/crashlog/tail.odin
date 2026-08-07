#+vet explicit-allocators
package crashlog

import "core:strings"

// Whether the last COMPLETE line of a `transcibr.log` tail looks like a
// routine `note` line -- every one of those starts with the
// "YYYY-MM-DDTHH:MM:SSZ " stamp `format_timestamp` produces, and nothing
// else this package ever writes does, so its absence is what a run that
// never reached its own next `note` call (because it crashed) looks like on
// disk. Not exhaustive over the three crash line shapes by name -- it does
// not need to be, because it only has to tell "a note line" from
// "anything else", and "anything else" is closed under this package's own
// writer.
@(private)
@(require_results)
looks_like_a_note_line :: proc(line: string) -> bool {
	if len(line) < 20 {
		return false
	}
	digit_positions := [14]int{0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18}
	for i in digit_positions {
		if line[i] < '0' || line[i] > '9' {
			return false
		}
	}
	return(
		line[4] == '-' &&
		line[7] == '-' &&
		line[10] == 'T' &&
		line[13] == ':' &&
		line[16] == ':' &&
		line[19] == 'Z' \
	)
}

// A8: `tail` is a file a user can hand this straight from
// `%LOCALAPPDATA%\transcibr\transcibr.log` -- empty, ordinary, or truncated
// mid-write by a process that died before its last `WriteFile` landed
// (`FILE_APPEND_DATA` makes each individual write atomic against the file's
// end, but nothing makes a multi-write line atomic as a whole; ADR-0039's
// own consequences section names exactly this interleaving risk). A
// trailing partial line -- one with no closing `\n` yet -- is dropped
// rather than judged: it is not a complete line one way or the other, so
// this falls back to the last complete line behind it, and refuses to
// crash or assert on any of the three malformed shapes below.
@(require_results)
last_run_ended_in_a_crash :: proc(tail: string) -> bool {
	body := tail
	if len(body) > 0 && body[len(body) - 1] != '\n' {
		last_nl := strings.last_index_byte(body, '\n')
		if last_nl < 0 {
			return false
		}
		body = body[:last_nl + 1]
	}
	body = strings.trim_right(body, "\n")
	if len(body) == 0 {
		return false
	}

	last_nl := strings.last_index_byte(body, '\n')
	last_line := body[last_nl + 1:] if last_nl >= 0 else body
	return !looks_like_a_note_line(last_line)
}
