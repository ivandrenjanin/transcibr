#+vet explicit-allocators
// Package process is the pure core of driving a child process. Every result is
// UTF-8 and the caller owns it; converting to UTF-16 for Win32 is the shell's job.
package process

import "core:fmt"
import "core:mem"
import "core:strings"
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

Disposition :: enum u8 {
	Fail_The_Job = 0,
	Shorten_And_Replan,
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

// See CLAUDE.md, Odin notes: enumerated arrays and switches.
@(private, rodata)
FAULT := [Build_Fault]Fault_Facts {
	.None = {},
	.Empty_Executable = {
		says = "there is no executable to run",
		blames = .Nothing,
		disposition = .Fail_The_Job,
	},
	.Quote_In_Executable = {
		says = "contains a quote, and argv[0] has no escape for one",
		blames = .The_Executable,
		disposition = .Fail_The_Job,
	},
	.Nul_In_Executable = {says = NUL_SAYS, blames = .The_Executable, disposition = .Fail_The_Job},
	.Nul_In_Argument = {says = NUL_SAYS, blames = .An_Argument, disposition = .Fail_The_Job},
	.Invalid_Utf8_In_Executable = {
		says = INVALID_UTF8_SAYS,
		blames = .The_Executable,
		disposition = .Fail_The_Job,
	},
	.Invalid_Utf8_In_Argument = {
		says = INVALID_UTF8_SAYS,
		blames = .An_Argument,
		disposition = .Fail_The_Job,
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
		return deliverable(
			fmt.aprintf(
				"argument %d (%q): %s",
				err.argument,
				err.culprit,
				facts.says,
				allocator = allocator,
			),
		)
	case .The_Executable:
		return deliverable(fmt.aprintf("%q: %s", err.culprit, facts.says, allocator = allocator))
	case .Nothing:
		return deliverable(strings.clone(facts.says, allocator))
	case .Unset:
	}
	panic("a fault's row in FAULT names nothing to blame")
}

@(private)
@(require_results)
deliverable :: proc(message: string) -> string {
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
