package process

// This file is the progress display's own half of the Process contract: the
// chunks a child's diagnostic pipe hands back reassembled into lines, and -- in
// the second half of the file -- what the display should show given what the
// Engine has said and how long ago it last said anything.
//
// Pure like the rest of the package (ADR-0009). No clock is read here: every
// reading is HANDED IN, which is the shape `remaining_ms` in `transcibr:child`
// established and ADR-0018 wrote down, and it is what makes a child that has
// gone quiet, one that has gone silent and a deadline exactly reached into
// values a case can produce rather than states a test would have to wait for.

// The longest diagnostic line this package will hold, in bytes.
//
// FIXED AND NEVER GROWN, which is the point rather than a limitation. Everything
// on this stream is outside the program (A8), so a child that writes ten
// megabytes with no newline in it must cost a bounded amount of memory and
// degrade the progress bar -- not exhaust the machine, and not wedge the child
// by making the drain slower than the write.
//
// Sized against a PATH and not against what was measured, because the longest
// line the Engine writes is the startup banner and the banner quotes the audio's
// own path. The longest line in the fixture is the system-information line at
// 261 bytes; four kilobytes is fifteen times that and more than the extended
// path limit Windows itself documents.
MAX_DIAGNOSTIC_LINE :: 4096

// Whatever a child has said that has not yet become a whole line.
//
// A fixed array and no allocator, so a caller can keep one per running child on
// its own stack and there is nothing to free. The line it hands back is a VIEW
// INTO THIS RECORD and is only good until the next call -- a caller that needs
// to keep one clones it.
Line_Reader :: struct {
	held:     [MAX_DIAGNOSTIC_LINE]u8,
	count:    int,
	// True while the rest of a line too long to hold is being walked past.
	//
	// THE REST IS DROPPED AND THE FRONT IS NOT KEPT. A line this reader could not
	// hold is a line it has already failed to read, and the first four kilobytes
	// of one handed on as though whole is a reading nobody can trust -- the
	// truncation is invisible by the time anything downstream sees it.
	skipping: bool,
}

// Takes the next whole line out of `remaining`, holding whatever is left over
// for the chunk after it.
//
// `remaining` is advanced past everything consumed, so a caller loops until this
// answers false and then hands in the next chunk. False means the chunk ran out
// mid-line, which is the ordinary outcome: a read off an anonymous pipe ends
// wherever the kernel had bytes and nothing aligns that to a line.
next_line :: proc(r: ^Line_Reader, remaining: ^string) -> (line: string, ok: bool) {
	assert(r != nil, "there is nothing here to read a line into")
	assert(remaining != nil, "there is no chunk here to read a line out of")
	assert(r.count <= len(r.held), "the reader is holding more than it has room for")

	for len(remaining^) > 0 {
		c := remaining^[0]
		remaining^ = remaining^[1:]

		if c == '\n' {
			whole := !r.skipping
			held := trimmed(r.held[:r.count])
			r.count = 0
			r.skipping = false
			if whole {
				return held, true
			}
			continue
		}
		if r.skipping {
			continue
		}
		if r.count == len(r.held) {
			r.skipping = true
			r.count = 0
			continue
		}
		r.held[r.count] = c
		r.count += 1
	}
	return "", false
}

// Whatever is held behind no newline at all, once the child is gone.
//
// A child that exits without a final newline still said what it said, and the
// last thing a Recording's Engine says is the one most worth not dropping.
// Answers false the second time, so a caller that asks again is not handed the
// same line for ever.
last_line :: proc(r: ^Line_Reader) -> (line: string, ok: bool) {
	assert(r != nil, "there is nothing here to read a last line out of")
	assert(r.count <= len(r.held), "the reader is holding more than it has room for")

	if r.count == 0 {
		return "", false
	}
	// The negative space of the same case (A3): a line that was being SKIPPED
	// leaves nothing held, so there is no path where the tail of an oversized
	// line escapes here.
	assert(!r.skipping, "a line being walked past was held on to anyway")

	held := trimmed(r.held[:r.count])
	r.count = 0
	return held, true
}

// One assembled line with its carriage return taken off.
//
// The carriage return is FRAMING and not content: the Engine writes CRLF on
// Windows, so a reader downstream would otherwise be comparing against a byte
// nobody meant. Taken off exactly once, here, rather than by every reader
// remembering to.
@(private)
trimmed :: proc(held: []u8) -> string {
	if len(held) > 0 && held[len(held) - 1] == '\r' {
		return string(held[:len(held) - 1])
	}
	return string(held)
}
