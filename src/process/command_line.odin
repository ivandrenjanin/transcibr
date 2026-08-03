// Package process is the Process contract: everything pure about driving a child
// process. The spec names it as ONE core module owning two halves -- "builds
// command lines; interprets Engine output lines into progress and duration
// events" -- and names one test seam over both (spec S3). The second half is
// issue #9 and is not here yet.
//
// Named for the module rather than for this file, and split by file the way
// src/transcript is: that package is 1:1 with its own spec module and divided
// internally into cue, paragraph, render and engine_json. The alternative was a
// package called command_line that would end up holding progress parsing, or one
// spec module and one named seam spread over two directories. The rename cost a
// directory and no configuration, because packages are discovered rather than
// listed -- which is only true while the module has no consumers, so it was done
// now rather than after #9.
//
// THIS FILE builds the one string Windows hands a child process as its command
// line, from an executable path and a list of arguments.
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
package process

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:unicode/utf8"

// How the builder refused. `.None` is the only value that comes with a result.
//
// A8: an executable path and an argument list arrive from outside -- a CLI flag, a
// discovered recording, a configured model path -- so a bad one is an operating
// error reported through this return, never an assertion.
Build_Fault :: enum u8 {
	None = 0,
	// Nothing to run. Refused rather than passed on, because an EMPTY command
	// line is not an error to Windows: measured, `CommandLineToArgvW` answers one
	// with the RUNNING executable's own path as argv[0], so a child handed one
	// would silently run against itself.
	Empty_Executable,
	// argv[0] has no escape mechanism -- the scan ends at the next quote, whatever
	// precedes it -- so an executable path containing one cannot be expressed at all.
	// Windows forbids `"` in a filename anyway.
	Quote_In_Executable,
	// A NUL ends the command line where Windows reads it, silently discarding
	// every argument after it.
	//
	// TWO faults and not one, though the byte and the damage are identical. They
	// are produced by two different scans, and a caller holding a single
	// `Embedded_Nul` cannot tell which -- so it cannot keep the promise this
	// package makes below, that a refusal is reported against the input that
	// caused it. `a NUL somewhere` names no file to go and fix.
	Nul_In_Executable,
	Nul_In_Argument,
	// Not valid UTF-8, and therefore not convertible to the UTF-16 that
	// `CreateProcessW` is the only form of.
	//
	// Reachable from the filesystem rather than exotic: NTFS permits unpaired
	// surrogates in a name and `wstring_to_utf8` hands one back as WTF-8. Refused
	// HERE rather than left to the conversion, because the conversion answers nil
	// and nil names no argument -- and ADR-0009 says the layer holding it will
	// never have a unit test. The same argument that keeps MAX_COMMAND_LINE_UNITS
	// in the core.
	Invalid_Utf8_In_Executable,
	Invalid_Utf8_In_Argument,
	// Past `CreateProcessW`'s documented ceiling; see MAX_COMMAND_LINE_UNITS.
	Too_Long,
}

// One refused command line, named against the part that carried it.
//
// The culprit is BORROWED, never owned: it is the caller's own executable path or
// argument, and it lives at least as long as the report. Parse_Error next door
// holds `json_name` on exactly these terms.
Build_Error :: struct {
	fault:    Build_Fault,
	// The executable path or the argument the fault is about, or empty where there
	// is nothing to name -- `.Empty_Executable`, which had none, and `.Too_Long`,
	// which is about the finished line rather than any one part of it. Which of the
	// three it is follows from the fault and is checked in fault_at, never guessed
	// at from whether the string happens to be empty: an EMPTY argument is a legal
	// argument, so a fault about one carries an empty culprit and means it.
	culprit:  string,
	// The 1-based position of the offending argument, or 0 when the fault is not
	// about one. 1-based because it is printed: `argument 2` is what a reader
	// counts to, and the ordinal is the only handle they have on an argument list
	// this package never sees again.
	argument: int,
}

// What a caller should DO with a refusal, which is not something it can work out
// from the fault's name.
//
// Six of the seven are inputs that cannot be spelled on a Windows command line
// at all: no retry changes that. `.Too_Long` is a different kind of refusal
// entirely -- the same job fits if it is built from shorter paths, and ADR-0002
// puts the Engine's output under `<cache>\<job_id>` with the cache path
// transcibr's own to choose. A caller that treated all seven alike would either
// retry the unfixable forever or fail a job one shorter path would have run.
//
// Public and answered from the table below, for the reason engine_json.odin
// gives: the alternative is every consumer reconstructing this from a switch
// over the enumeration that nothing keeps in step with it.
Disposition :: enum u8 {
	// Nothing about running this again changes the answer.
	Fail_The_Job = 0,
	// Re-plannable: choose shorter paths and build the line again.
	Shorten_And_Replan,
}

// What the culprit of a given fault IS, so that no call site has to remember.
//
// Unset is the zero value and no row may carry it: FAULT is an enumerated array,
// so a Build_Fault added without a row still HAS a row, made of zeroes -- and a
// real blame sitting on zero would make that row a plausible answer rather than
// a detectable one. The same argument Fault_Scope makes next door.
@(private)
Fault_Blames :: enum u8 {
	Unset = 0,
	// There is no ONE input to name. Two faults answer this way and for different
	// reasons: `.Empty_Executable` had no executable to begin with, and `.Too_Long`
	// is about the finished line rather than any part that went into it -- the
	// executable path it was built from may be perfectly fine, and naming it reads
	// as an accusation against a path nobody needs to change.
	Nothing,
	The_Executable,
	An_Argument,
}

// Everything this package knows about a fault beyond its name. One record rather
// than parallel tables: they are answers to the same question, and a fault added
// to one but not the others is the drift they exist to prevent.
@(private)
Fault_Facts :: struct {
	// What the fault reads as, WITHOUT the culprit or the ordinal -- error_message
	// supplies those, so no entry here can forget to.
	says:        string,
	blames:      Fault_Blames,
	disposition: Disposition,
}

// The two sentences the table spells TWICE, as constants -- the shape
// MONOLOGUE_NAME and CONVERSATION_NAME have next door, for the same reason.
//
// One byte and one damage, reported against two different inputs, is what makes
// each of these two rows rather than one (see Build_Fault). The sentence is the
// part that is genuinely the same, and as two literals it was two things that
// happened to match: edit one and not the other and the two reports describe the
// same NUL differently, with nothing anywhere to catch it. Both rows stay
// non-empty, so neither guard in fault_facts fires.
//
// The suite keeps its own copy of each, written out on that side. That is what
// makes this dedup safe rather than merely tidy: a test reading these constants
// would agree with any edit to them by construction.
@(private)
NUL_SAYS :: "contains a NUL, which ends the command line where Windows reads it"
@(private)
INVALID_UTF8_SAYS :: "is not valid UTF-8, so Windows cannot encode it as a command line"

// An enumerated array rather than a switch, and it is guarded twice over.
//
// MEASURED, both layers. Add a Build_Fault and leave this table alone and the
// COMPILER refuses the build outright -- `Unhandled enumerated array case` --
// so the row cannot go missing in anything that ships. Write the row but leave
// it empty, which is what a hurried edit produces, and the compiler is satisfied
// while the fault carries no sentence, no blame and a disposition nobody chose;
// that one the assertion in fault_facts catches on the first report. One record
// per fault rather than parallel tables, so a single missing row is caught by a
// single check rather than three that can disagree.
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

// One fault's row, checked. THE ONE PLACE THE TABLE IS READ, and the one place a
// missing row is caught.
@(private)
fault_facts :: proc(fault: Build_Fault) -> (facts: Fault_Facts) {
	assert(fault != .None, "the success value is not a fault and carries no facts")

	facts = FAULT[fault]
	assert(len(facts.says) > 0, "a fault was added to Build_Fault without a row in FAULT")
	// The negative space of the same missing row (A3): a row could carry a
	// sentence and no blame, and error_message would then print an argument's
	// half-sentence as though it were about the executable.
	assert(facts.blames != .Unset, "a fault's row in FAULT names nothing to blame")
	return
}

// Whether a different plan would make this same job run.
disposition_of :: proc(fault: Build_Fault) -> Disposition {
	assert(fault != .None, "a build that did not fail has nothing to dispose of")
	return fault_facts(fault).disposition
}

// Renders one refusal as a line naming the input it came from.
//
// The allocator is explicit and never defaulted: the line outlives this procedure
// and may be written by a worker other than the one that reads it (ADR-0010).
// Free it with `delete` and the same allocator.
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
	// Unreachable: fault_facts refuses a row that blames nothing, and the switch
	// above covers every other value. Stated rather than left as a bare fallthrough
	// returning an empty string nobody could diagnose.
	panic("a fault's row in FAULT names nothing to blame")
}

// One rendered refusal, checked at the one place all three branches leave
// through. The read side (A4) of the escaping those branches do, and the reason
// the postcondition is HERE rather than repeated three times.
//
// The property is that the line can actually be SHOWN, and no format string
// guarantees it. A refusal reaches a user through a UTF-16 Win32 call
// (ADR-0004): a raw NUL cuts the report off where it is printed, and a byte that
// is not UTF-8 makes `utf8_to_utf16` answer nil for the whole line. Two of this
// package's faults exist so that a refusal can NAME a culprit carrying exactly
// those bytes, which is why the culprit is printed with %q rather than %s: %q
// escapes both, and this is what says so rather than a reader having to notice
// that two branches happened to use the same verb.
//
// The culprit is external input and this is not a check on it (A8). It is a check
// on the rendering, which is this package's own: %q cannot produce either byte,
// so a failure here is a bug in the branch above and never a bad path.
@(private)
deliverable :: proc(message: string) -> string {
	assert(len(message) > 0, "a refusal rendered as nothing at all")
	assert(
		strings.index_byte(message, 0) < 0,
		"a refusal carrying a NUL is cut short where it is printed",
	)
	assert(utf8.valid_string(message), "a refusal that is not valid UTF-8 cannot be shown at all")
	return message
}

// Builds a report, checking at the one place they are made that every report can
// actually be delivered.
@(private)
fault_at :: proc(fault: Build_Fault, culprit: string, argument: int) -> Build_Error {
	assert(fault != .None, "a fault of .None is the success value and reports nothing")

	// The ordinal and the culprit against the blame the fault declares, at the one
	// place a Build_Error is written -- so no call site has to remember the
	// convention and error_message can print by blame without checking either.
	// Both sides of it (A3), one blame at a time, because the three do not agree
	// about the culprit and the pair of `if`s this replaced said they did.
	switch fault_facts(fault).blames {
	case .An_Argument:
		assert(argument > 0, "a fault about one argument did not say which")
	// And deliberately NO rule on that argument's length. An EMPTY argument is
	// legal and routine -- `--language ""` -- so "an argument fault names
	// something non-empty" is a rule about external input, and A8 forbids this
	// procedure, of all of them, from holding one. It held one and was safe only
	// by accident: neither argument fault can fire on an empty argument, since
	// `index_byte("", 0)` is -1 and `utf8.valid_string("")` is true. A length rule
	// or a whitespace rule added to check_inputs later would have turned the
	// safety net into the thing that crashes on a legal command line.
	case .The_Executable:
		assert(argument == 0, "a fault that is not about an argument blamed one")
		// Safe where the argument rule is not, and for a reason rather than by
		// luck: check_inputs refuses an empty executable path as
		// `.Empty_Executable` before any fault that blames the executable can
		// fire. So an executable fault with no culprit is this package losing the
		// path between the check and the report, never a caller handing one in.
		assert(len(culprit) > 0, "a fault about the executable path was handed nothing")
	case .Nothing:
		assert(argument == 0, "a fault that is not about an argument blamed one")
		assert(len(culprit) == 0, "a fault with nothing to name was handed something")
	case .Unset:
	// Refused by fault_facts above, which is the one place a missing row in
	// FAULT is named. Stated here so the switch is exhaustive rather than
	// #partial, which would let a fourth blame go unhandled in silence.
	}
	return Build_Error{fault = fault, culprit = culprit, argument = argument}
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

// Builds the command line for one child.
//
// The caller owns the returned string and frees it with `delete` AND THE SAME
// ALLOCATOR. That is not pedantry: this result crosses a worker boundary, and a
// mismatched allocator across one is the defect class ADR-0010 exists for.
//
// Every error path returns an empty string, so there is never anything to free
// after a refusal. Note what that does NOT say. `.Too_Long` is decided on the
// FINISHED line, so on that path the builder is fully allocated and filled and
// then destroyed before the return -- nothing leaks, but the memory is taken and
// given back, and a caller passing a nearly-exhausted arena (ADR-0010) will feel
// it. The amount is proportional to the INPUTS and is not bounded by
// MAX_COMMAND_LINE_UNITS: the ceiling is what the finished line is measured
// against, not a limit on what may be handed in, so a one-megabyte argument
// reserves about two megabytes and is only then refused.
//
// A8: the executable path and every argument arrive from outside this program -- a
// CLI flag, a discovered recording, a configured model path -- so each is checked
// and refused through `err`. No input reaches an assertion here.
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
	// The reservation's own check (A4): it is a claim about how far the escaping
	// above can expand its input, and this is the read side of it. A rule that
	// grew an argument past twice its bytes would otherwise just reallocate, and
	// the bound would go quietly wrong instead of loudly.
	assert(len(out) <= reserve, "the escaping outgrew the reservation made for it")
	assert(
		len(out) >= len(executable) + 2,
		"the command line is shorter than the quoted executable path",
	)
	assert(out[0] == '"', "the executable path is not quoted")
	// The negative space (A3): with no arguments there is nothing after the
	// closing quote, so a stray separator or a dropped argument shows up here
	// rather than as a child's misreading.
	if len(arguments) == 0 {
		assert(
			len(out) == len(executable) + 2,
			"a command line with no arguments carries something anyway",
		)
	}

	// Measured on the finished line rather than estimated from the inputs: the
	// quoting is what pushes a line over, and an estimate that disagreed with the
	// result would refuse lines that fit.
	if utf16_units(out) + 1 > MAX_COMMAND_LINE_UNITS {
		strings.builder_destroy(&b)
		// Nothing named, because there is nothing here to name. The executable path
		// this line was built from may be entirely reasonable; what is too long is
		// the LINE, and no part of it is more at fault than any other. Naming the
		// path anyway reads as `C:\ffmpeg.exe: ...` -- an accusation against a file
		// the caller would then go and look at for no reason.
		return "", fault_at(.Too_Long, "", 0)
	}
	return out, Build_Error{}
}

// Everything refused at the boundary, and the reservation the accepted case
// needs -- one walk, because the checks and the sum read the same bytes.
//
// A8 lives here: this is the procedure that decides what is an operating error,
// and every check below is on data from outside. The writers downstream assert
// the same properties on the write side (A4), where a value of this shape
// becomes a command line nobody can read back.
@(private)
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
	// utf8.valid_string and not a hand-rolled scan, for the reason
	// json_nesting_is_bounded gives next door: a second answer to a question the
	// standard library already answers is only as good as the day it last agreed
	// with the first.
	//
	// That it agrees with Windows is MEASURED and not assumed, because the whole
	// refusal rests on it: across 194,984 random byte strings, `utf8.valid_string`
	// and `MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS)` returned the same
	// verdict every time, zero disagreements. Both reject unpaired surrogates,
	// overlong forms, truncated sequences and stray continuation bytes. The suite
	// keeps the named cases; the fuzz is what established the rule.
	if !utf8.valid_string(executable) {
		return 0, fault_at(.Invalid_Utf8_In_Executable, executable, 0)
	}

	// See MAX_ESCAPED_OVERHEAD; the sum costs an addition per argument.
	reserve = len(executable) + 2
	for argument, i in arguments {
		if strings.index_byte(argument, 0) >= 0 {
			// 1-based, so the report counts the way a reader does.
			return 0, fault_at(.Nul_In_Argument, argument, i + 1)
		}
		if !utf8.valid_string(argument) {
			return 0, fault_at(.Invalid_Utf8_In_Argument, argument, i + 1)
		}
		reserve += 2 * len(argument) + MAX_ESCAPED_OVERHEAD
	}
	return reserve, Build_Error{}
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

// The executable path, quoted -- and NOT escaped, because argv[0] is parsed by a
// different rule from every argument after it.
//
// Measured: `"C:\dir with space\" one` yields argv[0] `C:\dir with space\` and
// argv[1] `one`. A trailing backslash needs no doubling here, and doubling it
// would put a literal second backslash in the path. The scan is simply "skip the
// opening quote, copy until the next one" -- no backslash is special, which is
// exactly why the general argument rule below must not be reused here.
@(private)
write_executable :: proc(b: ^strings.Builder, executable: string) {
	// Both of these are refused at the boundary in `check_inputs`; asserted again here,
	// on the write side, because that is where a path this shape becomes a command
	// line nobody can read back (A4). A quote in particular is unrecoverable: it
	// ends argv[0] early and every argument after it shifts.
	assert(len(executable) > 0, "the executable path must not be empty")
	assert(strings.index_byte(executable, '"') == -1, "a quote reached the executable path writer")

	start := strings.builder_len(b^)
	strings.write_byte(b, '"')
	strings.write_string(b, executable)
	strings.write_byte(b, '"')

	// READ THIS BEFORE RELAXING IT. It is the first of three checks that stand
	// between a wrong argv[0] and a child, and it is the one a maintainer meets --
	// the mutant it stops is the reader's own "correction" of the rule above:
	// double the trailing backslash run here, the way write_argument does, and
	// `C:\dir with space\` reaches the child as `C:\dir with space\\`, a path
	// carrying a second backslash the filesystem does not have.
	//
	// MEASURED, defeating them one at a time:
	//   1. this one -- "the executable path was not written whole"
	//   2. "the escaping outgrew the reservation made for it", in
	//      build_command_line, because the extra byte overruns a reservation that
	//      allowed the path exactly its own length plus two quotes
	//   3. "a command line with no arguments carries something anyway", the A3
	//      negative-space check a few lines below that one
	//   4. only then do tests fail, and the right two do:
	//      a_trailing_backslash_in_the_executable_path_is_not_an_escape and
	//      the_executable_path_round_trips_under_its_own_rule, both naming the
	//      doubled path they got back from CommandLineToArgvW.
	//
	// Which is what A4's paired write-side and read-side assertions buy, and it is
	// worth knowing what the first three cost: the mutant HANGS the test runner
	// rather than crashing it, at any thread count, because two tests trip the
	// same assertion and that is the case CLAUDE.md names. A mutation run in this
	// package reads its answer off the [FATAL] line, not off a summary.
	assert(
		strings.builder_len(b^) == start + len(executable) + 2,
		"the executable path was not written whole",
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
