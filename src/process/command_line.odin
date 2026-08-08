#+vet explicit-allocators
// Package process is the pure core of driving a child process. Every result is
// UTF-8 and the caller owns it; converting to UTF-16 for Win32 is the shell's job.
package process

import "core:fmt"
import "core:mem"
import "core:strings"
import win32 "core:sys/windows"
import "core:unicode/utf8"

// Builds the one string Windows hands a child process as its command line.

// How the builder refused. `.None` is the only value that comes with a result.
// Why each of these is refused rather than passed on: ADR-0019.
Build_Fault :: enum u8 {
	None = 0,
	Empty_Executable,
	Quote_In_Executable,
	Nul_In_Executable,
	Nul_In_Argument,
	Invalid_Utf8_In_Executable,
	Invalid_Utf8_In_Argument,
	Too_Long,
}

// The culprit is BORROWED, never owned: it is the caller's own executable path or
// argument, and it lives at least as long as the report.
Build_Error :: struct {
	fault:    Build_Fault,
	culprit:  string,
	argument: int,
}

@(private)
Fault_Blames :: enum u8 {
	Unset = 0,
	Nothing,
	The_Executable,
	An_Argument,
}

@(private)
Fault_Facts :: struct {
	says:        string,
	blames:      Fault_Blames,
	disposition: Disposition,
}

@(private)
NUL_SAYS :: "contains a NUL, which ends the command line where Windows reads it"
@(private)
INVALID_UTF8_SAYS :: "is not valid UTF-8, so Windows cannot encode it as a command line"

// See CLAUDE.md, Odin notes: enumerated arrays and switches. fault_facts's three
// asserts below are each paired with a walking test that reads the row directly:
// command_line_test.odin's every_build_fault_names_a_sentence (.says),
// every_build_fault_names_who_it_blames (.blames), and
// every_build_fault_names_a_disposition (.disposition).
@(private, rodata)
FAULT := [Build_Fault]Fault_Facts {
	.None = {},
	.Empty_Executable = {
		says = "there is no executable to run",
		blames = .Nothing,
		disposition = .Fail_The_Recording,
	},
	.Quote_In_Executable = {
		says = "contains a quote, and argv[0] has no escape for one",
		blames = .The_Executable,
		disposition = .Fail_The_Recording,
	},
	.Nul_In_Executable = {
		says = NUL_SAYS,
		blames = .The_Executable,
		disposition = .Fail_The_Recording,
	},
	.Nul_In_Argument = {says = NUL_SAYS, blames = .An_Argument, disposition = .Fail_The_Recording},
	.Invalid_Utf8_In_Executable = {
		says = INVALID_UTF8_SAYS,
		blames = .The_Executable,
		disposition = .Fail_The_Recording,
	},
	.Invalid_Utf8_In_Argument = {
		says = INVALID_UTF8_SAYS,
		blames = .An_Argument,
		disposition = .Fail_The_Recording,
	},
	.Too_Long = {
		says = "the command line needs more than the 32,767 code units CreateProcessW accepts",
		blames = .Nothing,
		disposition = .Shorten_And_Replan,
	},
}

@(private)
@(require_results)
fault_facts :: proc(fault: Build_Fault) -> (facts: Fault_Facts) {
	assert(fault != .None, "the success value is not a fault and carries no facts")

	facts = FAULT[fault]
	assert(len(facts.says) > 0, "a fault was added to Build_Fault without a row in FAULT")
	assert(facts.blames != .Unset, "a fault's row in FAULT names nothing to blame")
	assert(facts.disposition != .Unset, "a fault's row in FAULT names no disposition")
	return
}

@(require_results)
disposition_of :: proc(fault: Build_Fault) -> Disposition {
	assert(fault != .None, "a build that did not fail has nothing to dispose of")
	return fault_facts(fault).disposition
}

// Free the result with `delete` and the same allocator: the line outlives this
// procedure and may be written by a worker other than the one that reads it
// (ADR-0010).
//
// The `assert(err.fault != .None, ...)` below relies on every refusal a
// caller can hand in here still carrying the fault it was built with.
// build_command_line returns a Build_Error refusal from two places: the
// `refusal` it forwards unchanged from check_inputs, and its own
// `fault_at(.Too_Long, "", 0)` literal once the finished line is measured
// against the Windows ceiling. Both are pinned, guard-side, by
// command_line_test.odin's
// every_refusal_out_of_build_command_line_carries_its_own_fault (issue #255,
// the #208/#223 family's intra-package edition).
@(require_results)
error_message :: proc(err: Build_Error, allocator: mem.Allocator) -> string {
	assert(err.fault != .None, "there is no message for a build that did not fail")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs a chosen allocator",
	)

	facts := fault_facts(err.fault)
	switch facts.blames {
	case .An_Argument:
		return refusal_line(
			fmt.aprintf(
				"argument %d (%q): %s",
				err.argument,
				err.culprit,
				facts.says,
				allocator = allocator,
			),
		)
	case .The_Executable:
		return refusal_line(fmt.aprintf("%q: %s", err.culprit, facts.says, allocator = allocator))
	case .Nothing:
		return refusal_line(strings.clone(facts.says, allocator))
	case .Unset:
	}
	panic("a fault's row in FAULT names nothing to blame")
}

// The non-empty, NUL-free, valid-UTF-8 guard every Recording-level refusal
// passes through before it reaches a user through a UTF-16 Win32 call: a NUL
// truncates the line where it is printed, and a byte that is not valid UTF-8
// converts the whole of it to nil. Exported (issue #63) so `audio`,
// `artifact`, `child` and `engine` -- the renderers that interpolate the
// paths and Engine bytes this guard exists to catch -- call it directly
// instead of each spelling a weaker, non-empty-only copy. Named for what it
// hands back rather than for `CONTEXT.md`'s `Transcript` ("the deliverable"),
// which this is not: `Transcript` is one specific finished document, and this
// runs over any refusal line any of these packages renders.
@(require_results)
refusal_line :: proc(message: string) -> string {
	assert(len(message) > 0, "a refusal rendered as nothing at all")
	assert(
		strings.index_byte(message, 0) < 0,
		"a refusal carrying a NUL is cut short where it is printed",
	)
	assert(utf8.valid_string(message), "a refusal that is not valid UTF-8 cannot be shown at all")
	return message
}

@(private)
@(require_results)
fault_at :: proc(fault: Build_Fault, culprit: string, argument: int) -> Build_Error {
	assert(fault != .None, "a fault of .None is the success value and reports nothing")

	switch fault_facts(fault).blames {
	case .An_Argument:
		assert(argument > 0, "a fault about one argument did not say which")
	case .The_Executable:
		assert(argument == 0, "a fault that is not about an argument blamed one")
		assert(len(culprit) > 0, "a fault about the executable path was handed nothing")
	case .Nothing:
		assert(argument == 0, "a fault that is not about an argument blamed one")
		assert(len(culprit) == 0, "a fault with nothing to name was handed something")
	case .Unset:
	}
	return Build_Error{fault = fault, culprit = culprit, argument = argument}
}

// `CreateProcessW`'s documented limit on `lpCommandLine`: 32,767 characters
// INCLUDING the terminating null, where characters means UTF-16 code units.
MAX_COMMAND_LINE_UNITS :: 32767

// What one argument costs beyond twice its bytes: the separating space and the
// two quotes that may go around it.
@(private)
MAX_ESCAPED_OVERHEAD :: 3

// The caller owns the result and frees it with `delete` and the same allocator
// (ADR-0010). `.Too_Long` is decided on the finished line, so that path allocates
// in proportion to its inputs before destroying the builder: nothing leaks, but a
// caller on a nearly-exhausted arena will feel it. Measured; see ADR-0019.
@(require_results)
build_command_line :: proc(
	executable: string,
	arguments: []string,
	allocator: mem.Allocator,
) -> (
	command_line: string,
	err: Build_Error,
) {
	reserve, refusal := check_inputs(executable, arguments)
	if refusal.fault != .None {
		return "", refusal
	}

	b := strings.builder_make(0, reserve, allocator)
	write_executable(&b, executable)
	for argument in arguments {
		strings.write_byte(&b, ' ')
		write_argument(&b, argument)
	}

	out := strings.to_string(b)
	assert(len(out) <= reserve, "the escaping outgrew the reservation made for it")
	assert(
		len(out) >= len(executable) + 2,
		"the command line is shorter than the quoted executable path",
	)
	assert(out[0] == '"', "the executable path is not quoted")
	if len(arguments) == 0 {
		assert(
			len(out) == len(executable) + 2,
			"a command line with no arguments carries something anyway",
		)
	}

	if utf16_units(out) + 1 > MAX_COMMAND_LINE_UNITS {
		strings.builder_destroy(&b)
		return "", fault_at(.Too_Long, "", 0)
	}
	return out, Build_Error{}
}

@(private)
@(require_results)
check_inputs :: proc(executable: string, arguments: []string) -> (reserve: int, err: Build_Error) {
	if len(executable) == 0 {
		return 0, fault_at(.Empty_Executable, "", 0)
	}
	if strings.index_byte(executable, '"') >= 0 {
		return 0, fault_at(.Quote_In_Executable, executable, 0)
	}
	if strings.index_byte(executable, 0) >= 0 {
		return 0, fault_at(.Nul_In_Executable, executable, 0)
	}
	if !utf8.valid_string(executable) {
		return 0, fault_at(.Invalid_Utf8_In_Executable, executable, 0)
	}

	reserve = len(executable) + 2
	for argument, i in arguments {
		if strings.index_byte(argument, 0) >= 0 {
			return 0, fault_at(.Nul_In_Argument, argument, i + 1)
		}
		if !utf8.valid_string(argument) {
			return 0, fault_at(.Invalid_Utf8_In_Argument, argument, i + 1)
		}
		reserve += 2 * len(argument) + MAX_ESCAPED_OVERHEAD
	}
	return reserve, Build_Error{}
}

// Why the bound is `len(s)` and not `len(s) * 2`: ADR-0019.
@(private)
@(require_results)
utf16_units :: proc(s: string) -> int {
	units := 0
	for r in s {
		units += 2 if r >= 0x10000 else 1
	}

	assert(units <= len(s), "more UTF-16 units than there are UTF-8 bytes")
	return units
}

// Quoted and never escaped: argv[0] is parsed by a rule of its own, under which
// no backslash is special.
@(private)
write_executable :: proc(b: ^strings.Builder, executable: string) {
	assert(len(executable) > 0, "the executable path must not be empty")
	assert(strings.index_byte(executable, '"') == -1, "a quote reached the executable path writer")

	start := strings.builder_len(b^)
	strings.write_byte(b, '"')
	strings.write_string(b, executable)
	strings.write_byte(b, '"')

	assert(
		strings.builder_len(b^) == start + len(executable) + 2,
		"the executable path was not written whole",
	)
}

@(private)
@(require_results)
needs_quoting :: proc(argument: string) -> bool {
	if len(argument) == 0 {
		return true
	}
	return strings.index_any(argument, " \t\"") >= 0
}

// A run of backslashes is literal unless it meets a quote, and the closing quote
// counts as one.
@(private)
write_argument :: proc(b: ^strings.Builder, argument: string) {
	assert(strings.index_byte(argument, 0) == -1, "a NUL reached the argument writer")

	start := strings.builder_len(b^)
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
			write_backslashes(b, backslashes * 2 + 1)
			backslashes = 0
			strings.write_byte(b, '"')
		case:
			write_backslashes(b, backslashes)
			backslashes = 0
			strings.write_byte(b, c)
		}
	}
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

	assert(strings.builder_len(b^) == start + count, "the backslash run was not written whole")
}

// Splits a UTF-16 command line the way Windows itself splits one, and hands
// every argument back as UTF-8. The caller owns the slice and every string in
// it; free both with `delete_argv` and the same allocator (ADR-0010).
//
// Why this exists: ADR-0025 / issue #35. Odin's Windows entry point is
// `main :: proc "c" (argc: i32, argv: [^]cstring)`, the C runtime's ANSI
// argv -- a non-ASCII byte is already lost to the system code page by the
// time that argv reaches `main`. `GetCommandLineW`'s raw UTF-16 line has not
// been through that conversion, and `CommandLineToArgvW` is the same parser
// `command_line_test.odin` has verified this package's own quoter round-trips
// through, non-ASCII cases included.
@(require_results)
argv_from_wide_command_line :: proc(
	line: win32.wstring,
	allocator: mem.Allocator,
) -> (
	argv: []string,
	ok: bool,
) {
	assert(line != nil, "there is no command line here to split")
	assert(
		allocator.procedure != nil,
		"argv is owned by the caller and needs an allocator to live in",
	)

	count: win32.c_int
	wide_argv := win32.CommandLineToArgvW(line, &count)
	if wide_argv == nil {
		return nil, false
	}
	defer win32.LocalFree(rawptr(wide_argv))
	assert(count > 0, "CommandLineToArgvW split a command line into zero arguments")

	out := make([]string, int(count), allocator)
	for i in 0 ..< int(count) {
		text, err := win32.wstring_to_utf8(wide_argv[i], -1, allocator)
		if err != .None {
			for j in 0 ..< i {
				delete(out[j], allocator)
			}
			delete(out, allocator)
			return nil, false
		}
		out[i] = text
	}
	return out, true
}

// This process's own argv, read the way ffmpeg reads its (ADR-0025's third
// measurement, taken against `whisper-cli`, applies here too): `GetCommandLineW`
// plus `CommandLineToArgvW`, never `os.args`. `transcibr-cli`'s `main` is the
// production caller; there is no test that can run as a second process with a
// command line of its own, so `argv_from_wide_command_line` above carries the
// coverage and this is a thin, unbranching wrapper around it.
@(require_results)
process_argv :: proc(allocator: mem.Allocator) -> (argv: []string, ok: bool) {
	assert(
		allocator.procedure != nil,
		"argv is owned by the caller and needs an allocator to live in",
	)

	line := win32.GetCommandLineW()
	assert(line != nil, "GetCommandLineW returned nothing for a process that is running")
	return argv_from_wide_command_line(line, allocator)
}

// Frees an `argv` returned by `argv_from_wide_command_line` or `process_argv`,
// and every string in it, with the same allocator both were built with.
delete_argv :: proc(argv: []string, allocator: mem.Allocator) {
	for text in argv {
		delete(text, allocator)
	}
	delete(argv, allocator)
}
