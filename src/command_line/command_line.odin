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
	// Nothing to run. Refused rather than passed on, because an EMPTY command
	// line is not an error to Windows: measured, `CommandLineToArgvW` answers one
	// with the RUNNING executable's own path as argv[0], so a child handed one
	// would silently run against itself.
	Empty_Program,
	// argv[0] has no escape mechanism -- the scan ends at the next quote, whatever
	// precedes it -- so a program path containing one cannot be expressed at all.
	// Windows forbids `"` in a filename anyway.
	Quote_In_Program,
	// A NUL ends the command line where Windows reads it, silently discarding
	// every argument after it.
	Embedded_Nul,
	// Past `CreateProcessW`'s documented ceiling; see MAX_COMMAND_LINE_UNITS.
	Too_Long,
}

// `CreateProcessW`'s documented limit on `lpCommandLine`: 32,767 characters
// INCLUDING the terminating null character.
//
// Characters means UTF-16 code units, which is neither bytes nor runes: one rune
// outside the Basic Multilingual Plane is up to four UTF-8 bytes and exactly two
// of these. Counting bytes refuses command lines that fit; counting runes accepts
// ones that do not, and Windows truncates rather than complaining.
MAX_COMMAND_LINE_UNITS :: 32767

// What one argument costs beyond twice its bytes: the separating space and the
// two quotes that may go around it.
//
// Twice its bytes is the escaping's own worst case, and it is reached rather than
// merely bounded -- an argument of nothing but quotes writes `\"` for every one,
// and `\\\\"` writes nine backslashes and a quote for five bytes. No byte can
// cost more: a quote becomes two, a backslash becomes at most two, and everything
// else is copied through. So the reservation below never runs short, which is
// what the assertion after the build checks rather than assumes.
@(private)
MAX_ESCAPED_OVERHEAD :: 3

// Builds the command line for one child. The caller owns the returned string and
// frees it with `delete`; nothing is allocated on any error path.
//
// A8: the program path and every argument arrive from outside this program -- a
// CLI flag, a discovered recording, a configured model path -- so each is checked
// and refused through `err`. No input reaches an assertion here.
build :: proc(
	program: string,
	arguments: []string,
	allocator: mem.Allocator,
) -> (
	command_line: string,
	err: Build_Error,
) {
	if len(program) == 0 {
		return "", .Empty_Program
	}
	if strings.index_byte(program, '"') >= 0 {
		return "", .Quote_In_Program
	}
	if strings.index_byte(program, 0) >= 0 {
		return "", .Embedded_Nul
	}
	// The reservation is accumulated by the scan that has to walk these anyway, so
	// it costs nothing beyond the addition. See MAX_ESCAPED_OVERHEAD.
	reserve := len(program) + 2
	for argument in arguments {
		if strings.index_byte(argument, 0) >= 0 {
			return "", .Embedded_Nul
		}
		reserve += 2 * len(argument) + MAX_ESCAPED_OVERHEAD
	}

	b := strings.builder_make(0, reserve, allocator)
	write_program(&b, program)
	for argument in arguments {
		strings.write_byte(&b, ' ')
		write_argument(&b, argument)
	}

	out := strings.to_string(b)
	// The reservation's own check (A4): it is a claim about how far the escaping
	// above can expand its input, and this is the read side of it. A rule that
	// grew an argument past twice its bytes would otherwise just reallocate, and
	// the bound would go quietly wrong instead of loudly.
	assert(len(out) <= reserve, "the escaping outgrew the reservation made for it")
	assert(
		len(out) >= len(program) + 2,
		"the command line is shorter than the quoted program path",
	)
	assert(out[0] == '"', "the program path is not quoted")
	// The negative space (A3): with no arguments there is nothing after the
	// closing quote, so a stray separator or a dropped argument shows up here
	// rather than as a child's misreading.
	if len(arguments) == 0 {
		assert(
			len(out) == len(program) + 2,
			"a command line with no arguments carries something anyway",
		)
	}

	// Measured on the finished line rather than estimated from the inputs: the
	// quoting is what pushes a line over, and an estimate that disagreed with the
	// result would refuse lines that fit.
	if utf16_units(out) + 1 > MAX_COMMAND_LINE_UNITS {
		strings.builder_destroy(&b)
		return "", .Too_Long
	}
	return out, .None
}

// How many UTF-16 code units this UTF-8 string becomes -- the unit Windows counts
// the command line in, and the reason this is not `len`.
@(private)
utf16_units :: proc(s: string) -> int {
	units := 0
	for r in s {
		// A rune past the BMP is encoded as a surrogate PAIR.
		units += 2 if r >= 0x10000 else 1
	}

	// One UTF-16 unit per UTF-8 byte is the real ceiling, and it is tight enough
	// to catch an edit to the branch above. Every encoding yields at most one unit
	// per byte: ASCII is one byte and one unit, the two- and three-byte forms are
	// one unit, and the four-byte form is the only one that pairs -- two units for
	// four bytes, still under.
	//
	// The bound this replaced was `len(s) * 2`, which is the surrogate pair's ratio
	// applied to every byte and is therefore satisfied by any counting mistake that
	// stays within a factor of two. Measured: change the BMP branch to add 2 and
	// ASCII reports exactly `2 * len(s)`, which passes that bound and fails this
	// one. An assert that cannot fail on the edit it exists to catch is a comment
	// with a runtime cost (A6).
	assert(units <= len(s), "more UTF-16 units than there are UTF-8 bytes")
	return units
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
	// Both of these are refused at the boundary in `build`; asserted again here,
	// on the write side, because that is where a path this shape becomes a command
	// line nobody can read back (A4). A quote in particular is unrecoverable: it
	// ends argv[0] early and every argument after it shifts.
	assert(len(program) > 0, "the program path must not be empty")
	assert(strings.index_byte(program, '"') == -1, "a quote reached the program path writer")

	start := strings.builder_len(b^)
	strings.write_byte(b, '"')
	strings.write_string(b, program)
	strings.write_byte(b, '"')

	assert(
		strings.builder_len(b^) == start + len(program) + 2,
		"the program path was not written whole",
	)
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
	// Refused at the boundary, asserted on the write side (A4): a NUL here would
	// end the command line mid-build and drop every argument after this one.
	assert(strings.index_byte(argument, 0) == -1, "a NUL reached the argument writer")

	start := strings.builder_len(b^)
	// An argument ALWAYS writes at least one byte -- an empty one writes `""`.
	// This is the write-side pair for the empty-argument rule: a change that let
	// an empty argument write nothing would shift every argument after it, and
	// this is where that becomes visible rather than at the child.
	defer assert(strings.builder_len(b^) > start, "an argument wrote nothing and would be dropped")

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

	start := strings.builder_len(b^)
	for _ in 0 ..< count {
		strings.write_byte(b, '\\')
	}

	// A short write here is an argument that ends in an escaped quote and
	// swallows its neighbour, which is the loudest bug in the package and the
	// quietest symptom.
	assert(strings.builder_len(b^) == start + count, "the backslash run was not written whole")
}
