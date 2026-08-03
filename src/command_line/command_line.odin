// Package command_line builds the one string Windows hands a child process as
// its command line, from a program path and a list of arguments.
//
// Pure core (ADR-0009), and on that ADR's own list: no I/O, no clock, no Win32,
// no globals. The result is UTF-8 and the caller owns it; converting to UTF-16
// and handing it to `CreateProcessW` is the shell's job (ADR-0004).
//
// Windows has no argument vector. `CreateProcessW` takes a single string, and
// the child splits it again -- almost always with `CommandLineToArgvW`, or with
// the identical rules baked into the C runtime that fills `argv`. Quoting is
// therefore the caller's problem, and getting it wrong is SILENT: an argument
// disappears, or one argument becomes two, and the child does something subtly
// different from what was asked. `-i` followed by a path that lost its quoting
// is ffmpeg reading the first word of a folder name.
//
// The rules below are not this package's reading of the documentation. They were
// measured against `CommandLineToArgvW` itself, and the suite in
// command_line_test.odin re-measures them on every run.
package command_line

import "core:mem"
import "core:strings"

// How the builder refused. `.None` is the only value that comes with a result.
//
// A8: a program path and an argument list arrive from outside -- a CLI flag, a
// discovered recording, a configured model path -- so a bad one is an operating
// error reported through this return, never an assertion.
Build_Error :: enum u8 {
	None,
}

// Builds the command line for one child. The caller owns the returned string and
// frees it with `delete`; nothing is allocated on the error paths.
build :: proc(
	program: string,
	arguments: []string,
	allocator: mem.Allocator,
) -> (
	command_line: string,
	err: Build_Error,
) {
	b := strings.builder_make(allocator)
	write_program(&b, program)
	for argument in arguments {
		strings.write_byte(&b, ' ')
		write_argument(&b, argument)
	}

	out := strings.to_string(b)
	assert(len(out) >= 2, "a command line always carries at least the quoted program path")
	assert(out[0] == '"', "the program path is not quoted")
	return out, .None
}

// The program path, quoted -- and NOT escaped, because argv[0] is parsed by a
// different rule from every argument after it.
//
// Measured: `"C:\dir with space\" one` yields argv[0] `C:\dir with space\` and
// argv[1] `one`. A trailing backslash needs no doubling here, and doubling it
// would put a literal second backslash in the path. The scan is simply "skip the
// opening quote, copy until the next one" -- no backslash is special, which is
// exactly why the general argument rule below must not be reused here.
@(private)
write_program :: proc(b: ^strings.Builder, program: string) {
	assert(len(program) > 0, "the program path must not be empty")

	strings.write_byte(b, '"')
	strings.write_string(b, program)
	strings.write_byte(b, '"')
}

// The characters that force an argument to be quoted, and there are exactly two
// of them plus the quote itself.
//
// MEASURED against CommandLineToArgvW, not assumed: space and tab separate
// arguments, and newline, carriage return, vertical tab, form feed, U+00A0 and
// U+3000 do not. Neither do cmd.exe's metacharacters -- `^ & | % > <` are
// ordinary text here, because CreateProcessW starts the child directly and there
// is no shell anywhere in this path to interpret them.
@(private)
needs_quoting :: proc(argument: string) -> bool {
	// An EMPTY argument must be quoted or it disappears: the child then reads the
	// next flag as this argument's value, which is the silent misfire the whole
	// package exists to prevent. Measured: `x.exe  -flag` and `x.exe "" -flag`
	// give argc 2 and argc 3.
	if len(argument) == 0 {
		return true
	}
	return strings.index_any(argument, " \t\"") >= 0
}

// One argument, escaped the way CommandLineToArgvW un-escapes it.
//
// The rule that catches people out is the backslash one, and it is not "escape
// every backslash". A run of backslashes is LITERAL unless it meets a quote; a
// run of 2n before a quote is n backslashes and a structural quote, and 2n+1 is
// n backslashes and a literal one. The closing quote counts as a quote, which is
// why `C:\path with space\` -- quoted naively -- ends `\"` and runs on into the
// next argument.
//
// Byte-wise rather than rune-wise on purpose: `\` and `"` are ASCII, and UTF-8
// never encodes them as a continuation byte, so every non-ASCII byte is copied
// through untouched and a surrogate pair cannot be split.
@(private)
write_argument :: proc(b: ^strings.Builder, argument: string) {
	if !needs_quoting(argument) {
		assert(len(argument) > 0, "an empty argument is never written unquoted")
		strings.write_string(b, argument)
		return
	}

	strings.write_byte(b, '"')
	backslashes := 0
	for i in 0 ..< len(argument) {
		switch c := argument[i]; c {
		case '\\':
			backslashes += 1
		case '"':
			// Doubled, plus one to escape the quote that follows them.
			write_backslashes(b, backslashes * 2 + 1)
			backslashes = 0
			strings.write_byte(b, '"')
		case:
			// Not before a quote, so literal and left alone.
			write_backslashes(b, backslashes)
			backslashes = 0
			strings.write_byte(b, c)
		}
	}
	// The closing quote is a quote like any other, so the run in front of it
	// doubles too -- without this the argument ends in an ESCAPED quote and
	// swallows everything after it.
	write_backslashes(b, backslashes * 2)
	strings.write_byte(b, '"')
}

@(private)
write_backslashes :: proc(b: ^strings.Builder, count: int) {
	assert(count >= 0, "a backslash run cannot be negative")

	for _ in 0 ..< count {
		strings.write_byte(b, '\\')
	}
}
