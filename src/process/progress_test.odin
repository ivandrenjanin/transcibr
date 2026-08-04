package process

import "core:strings"
import "core:testing"

// The progress display's own half: chunks off a pipe reassembled into lines,
// and what the display should show given what the Engine has said and when it
// last said anything at all.

// Everything one chunk yields, as a list a case can compare against.
//
// The lines are CLONED, because `next_line` hands back a view into the reader's
// own buffer and the next call overwrites it -- which is the whole point of a
// fixed buffer and is exactly the mistake a case would otherwise make silently.
@(private)
lines_of :: proc(
	r: ^Line_Reader,
	chunk: string,
	into: ^[dynamic]string,
	allocator := context.allocator,
) {
	remaining := chunk
	for {
		line, ok := next_line(r, &remaining)
		if !ok {
			return
		}
		append(into, strings.clone(line, allocator))
	}
}

@(private)
free_lines :: proc(lines: ^[dynamic]string, allocator := context.allocator) {
	for line in lines {
		delete(line, allocator)
	}
	delete(lines^)
}

@(test)
a_line_cut_in_half_by_the_pipe_is_put_back_together :: proc(t: ^testing.T) {
	// A read off an anonymous pipe ends wherever the kernel had bytes, and
	// nothing aligns that to a line. This is the ordinary case rather than an
	// edge one: half a progress line held over to the next read is what the
	// spawner produces every time it drains mid-line.
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected)

	lines_of(&r, "whisper_print_progress_callback: prog", &collected)
	testing.expect_value(t, len(collected), 0)

	lines_of(&r, "ress =  42%\n", &collected)
	if !testing.expect_value(t, len(collected), 1) {
		return
	}
	said := read_engine_line(collected[0])
	testing.expect_value(t, said.says, Engine_Says.Progress)
	testing.expect_value(t, said.percent, 42)
}

@(test)
a_crlf_line_arrives_without_its_carriage_return :: proc(t: ^testing.T) {
	// The Engine writes CRLF on Windows, and the carriage return is the framing
	// rather than the line -- so it is taken off HERE, once, instead of by every
	// reader downstream remembering to.
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected)

	lines_of(&r, "whisper_model_load: loading model\r\nsecond\r\n", &collected)
	if !testing.expect_value(t, len(collected), 2) {
		return
	}
	testing.expect_value(t, collected[0], "whisper_model_load: loading model")
	testing.expect_value(t, collected[1], "second")
}

@(test)
a_line_too_long_to_hold_is_dropped_whole_and_the_next_one_still_reads :: proc(t: ^testing.T) {
	// A child that writes ten megabytes with no newline in it. The buffer is
	// FIXED (A8), so what has to be true is that the memory is bounded and the
	// reader recovers -- and that the oversized line is not handed on in a
	// truncated form, which would be a reading nobody could trust.
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected)

	flood := strings.repeat("x", 4 * MAX_DIAGNOSTIC_LINE, context.allocator)
	defer delete(flood, context.allocator)

	lines_of(&r, flood, &collected)
	testing.expect_value(t, len(collected), 0)

	lines_of(&r, "\nwhisper_print_progress_callback: progress =  52%\n", &collected)
	if !testing.expect_value(t, len(collected), 1) {
		return
	}
	// The line that ENDED the flood is not handed back at all, and the one after
	// it is whole. Both halves (A3): a reader that kept the first four kilobytes
	// would answer two lines here, and one that never recovered would answer none.
	testing.expect_value(t, read_engine_line(collected[0]).percent, 52)
}

@(test)
bytes_that_are_not_utf8_pass_through_and_read_as_nothing :: proc(t: ^testing.T) {
	// NTFS permits an unpaired surrogate in a filename, the Engine quotes the
	// audio's path in its banner, and this stream carries whatever bytes the
	// child wrote. Nothing here decodes anything, so the only property that
	// matters is that a line survives being carried and reads as no reading.
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected)

	lines_of(&r, "main: \xff\xfe\x80 processing\nwhisper: \xc3\x28\n", &collected)
	if !testing.expect_value(t, len(collected), 2) {
		return
	}
	for line in collected {
		testing.expectf(t, read_engine_line(line).says == .Nothing, "%q read as something", line)
	}
}

@(test)
what_is_held_behind_no_newline_is_a_line_at_end_of_stream :: proc(t: ^testing.T) {
	// A child that exits without a final newline. Whatever it managed to say is
	// still what it said, and the last reading of a Recording is the one most
	// worth not dropping.
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected)

	lines_of(&r, "whisper_print_progress_callback: progress = 100%", &collected)
	testing.expect_value(t, len(collected), 0)

	line, ok := last_line(&r)
	if !testing.expect(t, ok, "the reader dropped what it was holding at end of stream") {
		return
	}
	testing.expect_value(t, read_engine_line(line).percent, 100)

	// The negative space (A3): asked twice, it has nothing left. A reader that
	// answered the same line again would have the shell reading one percentage
	// for ever.
	_, again := last_line(&r)
	testing.expect(t, !again, "the reader handed back what it had already given up")
}

@(test)
a_chunk_with_nothing_in_it_yields_nothing :: proc(t: ^testing.T) {
	r: Line_Reader
	collected := make([dynamic]string, context.allocator)
	defer free_lines(&collected)

	lines_of(&r, "", &collected)
	testing.expect_value(t, len(collected), 0)

	// A run of newlines is a run of EMPTY lines and not nothing: the Engine
	// writes a blank line either side of its progress block, and a reader that
	// swallowed them would be one that could swallow a line with content too.
	lines_of(&r, "\n\n", &collected)
	testing.expect_value(t, len(collected), 2)
	if len(collected) == 2 {
		testing.expect_value(t, collected[0], "")
		testing.expect_value(t, collected[1], "")
	}
}
