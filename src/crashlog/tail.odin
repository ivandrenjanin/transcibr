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

// Whether `line` could still turn into a note-line stamp if more bytes
// arrived after it -- the multi-write shape's own partial-write case, one
// prefix byte at a time. Checked against the same fixed template
// `looks_like_a_note_line` reads, truncated to however many bytes `line`
// actually has: a byte that already contradicts the template (a letter
// where a digit belongs, the wrong separator) means `line` can never become
// a note-line stamp no matter what follows, which is what a partial CRASH,
// stack-frame or assert line looks like from its first byte on.
@(private)
@(require_results)
separator_at :: proc(i: int) -> (byte, bool) {
	switch i {
	case 4, 7:
		return '-', true
	case 10:
		return 'T', true
	case 13, 16:
		return ':', true
	case 19:
		return 'Z', true
	}
	return 0, false
}

@(private)
@(require_results)
could_be_a_note_line_prefix :: proc(line: string) -> bool {
	digit_positions := [14]int{0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18}
	n := len(line)
	if n > 20 {
		n = 20
	}
	for i in 0 ..< n {
		is_digit_pos := false
		for d in digit_positions {
			if d == i {
				is_digit_pos = true
				break
			}
		}
		if is_digit_pos {
			if line[i] < '0' || line[i] > '9' {
				return false
			}
			continue
		}
		want, has_sep := separator_at(i)
		if has_sep && line[i] != want {
			return false
		}
	}
	return true
}

// A8: `tail` is a file a user can hand this straight from
// `%LOCALAPPDATA%\transcibr\transcibr.log` -- empty, ordinary, or truncated
// mid-write by a process that died before its last `WriteFile` landed
// (`FILE_APPEND_DATA` makes each individual write atomic against the file's
// end, but nothing makes a multi-write line atomic as a whole; ADR-0039's
// own consequences section names exactly this interleaving risk). A
// trailing partial line -- one with no closing `\n` yet -- is judged by
// whether its bytes so far could still become a note-line stamp: a partial
// CRASH/stack-frame/assert line never can (the crash-hook line shapes start
// with a letter, not a timestamp digit), so it reads as a crash directly
// without waiting for a `\n` that a dead process will never write. Only a
// partial stamp that is genuinely still ambiguous falls back to the last
// complete line behind it. Refuses to crash or assert on any of the
// malformed shapes below.
@(require_results)
last_run_ended_in_a_crash :: proc(tail: string) -> bool {
	body := tail
	if len(body) == 0 {
		return false
	}
	if body[len(body) - 1] != '\n' {
		last_nl := strings.last_index_byte(body, '\n')
		partial := body[last_nl + 1:] if last_nl >= 0 else body
		if !could_be_a_note_line_prefix(partial) {
			return true
		}
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
