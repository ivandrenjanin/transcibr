package command_line

import "core:fmt"
import "core:mem"
import "core:strings"
import win32 "core:sys/windows"
import "core:testing"

// Every argument the real Windows parser found in a command line, as UTF-8.
//
// THIS IS THE POINT OF THE PACKAGE'S TEST SUITE. A round trip through a parser
// written here would only prove that the builder and the parser share an
// assumption; both would agree, and a child linked against the real one would
// still receive something else. So the command line goes to `CommandLineToArgvW`
// -- the shell32 entry point that actually parses `GetCommandLineW()` for every
// program that does not roll its own -- and what comes back is compared against
// what went in.
//
// The builder stays pure (ADR-0009); this does not. That asymmetry is deliberate
// and is the only reason the criterion can be met at all: purity is a property of
// `build`, not of the harness that checks it.
//
// The caller owns the slice and every string in it; `free_argv` returns both.
@(private)
argv_of :: proc(t: ^testing.T, command_line: string, allocator: mem.Allocator) -> []string {
	wide := win32.utf8_to_utf16(command_line, allocator)
	defer delete(wide, allocator)
	if !testing.expect(t, wide != nil, "the command line is not convertible to UTF-16") {
		return nil
	}

	count: win32.c_int
	argv := win32.CommandLineToArgvW(win32.wstring(raw_data(wide)), &count)
	if !testing.expect(t, argv != nil, "CommandLineToArgvW refused the command line") {
		return nil
	}
	defer win32.LocalFree(rawptr(argv))

	out := make([]string, int(count), allocator)
	for i in 0 ..< int(count) {
		text, err := win32.wstring_to_utf8(argv[i], -1, allocator)
		testing.expect_value(t, err, mem.Allocator_Error.None)
		out[i] = text
	}
	return out
}

@(private)
free_argv :: proc(argv: []string, allocator: mem.Allocator) {
	for text in argv {
		delete(text, allocator)
	}
	delete(argv, allocator)
}

// One case: build it, hand it to Windows, and check every argument came back.
@(private)
expect_round_trip :: proc(t: ^testing.T, program: string, arguments: []string, name: string) {
	line, err := build(program, arguments, context.allocator)
	defer delete(line, context.allocator)
	testing.expectf(t, err == .None, "%s: build refused with %v", name, err)

	argv := argv_of(t, line, context.allocator)
	defer free_argv(argv, context.allocator)
	if !testing.expectf(
		t,
		len(argv) == len(arguments) + 1,
		"%s: <%s> parsed as %d argument(s), wanted %d",
		name,
		line,
		len(argv),
		len(arguments) + 1,
	) {
		return
	}

	testing.expectf(t, argv[0] == program, "%s: argv[0] came back <%s>", name, argv[0])
	for want, i in arguments {
		testing.expectf(
			t,
			argv[i + 1] == want,
			"%s: argv[%d] came back <%s>, wanted <%s>",
			name,
			i + 1,
			argv[i + 1],
			want,
		)
	}
}

// Every argument in one table is round-tripped on its own AND with the whole
// table passed as one argument list. Alone catches a case the builder mangles;
// together catches a case whose damage only shows up as a neighbour's argument
// -- a lost quote runs two of them into one, which a single-argument case cannot
// see because there is no neighbour to run into.
@(private)
expect_each_and_all :: proc(t: ^testing.T, group: string, cases: []string) {
	for value, i in cases {
		expect_round_trip(t, EXE, {value}, tprint_case(group, i))
	}
	expect_round_trip(t, EXE, cases, group)
	// A neighbour on each side, so a case that swallows the space after it is
	// caught rather than absorbed by the end of the command line.
	for value, i in cases {
		expect_round_trip(t, EXE, {"-before", value, "-after"}, tprint_case(group, i))
	}
}

@(private)
EXE :: `C:\tools\ffmpeg.exe`

@(private)
tprint_case :: proc(group: string, index: int) -> string {
	return fmt.tprintf("%s[%d]", group, index)
}

@(test)
plain_arguments_round_trip :: proc(t: ^testing.T) {
	expect_round_trip(t, EXE, {"-i", "in.mkv", "out.wav"}, "plain")
	expect_round_trip(t, EXE, {}, "no arguments at all")
	expect_round_trip(t, EXE, {"only"}, "a single argument")
}

// Whitespace is the whole reason quoting exists here, and the set is EXACTLY
// space and tab. Measured against CommandLineToArgvW: newline, carriage return,
// vertical tab, form feed, U+00A0 and U+3000 do NOT split an argument, and
// neither do any of cmd.exe's metacharacters -- there is no shell in this path,
// so `^ & | % > <` are ordinary text. They are here to pin that: a builder that
// "helpfully" quoted them would still be correct, but one that quoted them and
// got the escaping wrong would not.
@(private)
WHITESPACE_CASES :: []string {
	"C:\\Program Files\\ffmpeg\\bin\\ffmpeg.exe",
	"a b",
	" leading",
	"trailing ",
	"   ",
	"a\tb",
	"\ttab-led",
	"tab-tailed\t",
	"\t",
	"mixed \t \t spacing",
	"a\nb",
	"a\rb",
	"a\r\nb",
	"a\vb",
	"a\fb",
	"caret^and&ampersand|pipe",
	"percent%PATH%percent",
	"redirect>out<in",
	"\\\\server\\share with space\\file.mkv",
}

@(test)
whitespace_arguments_round_trip :: proc(t: ^testing.T) {
	expect_each_and_all(t, "whitespace", WHITESPACE_CASES)
}

// An empty argument survives as an argument.
//
// It is the one case where being wrong is worse than a mangled string. A dropped
// empty argument does not produce an empty value at the child -- it produces one
// FEWER argument, so every argument after it shifts down a place and the child
// reads the next flag as this one's value. `--language "" --model big.bin` with
// the empty dropped is a child told its language is `--model`.
//
// The count is asserted separately from the values, because that shift is a
// count failure first: measured, `x.exe  -flag` reaches CommandLineToArgvW as
// argc 2 and `x.exe "" -flag` as argc 3, and only the second one is what was
// asked for.
@(test)
an_empty_argument_is_emitted_rather_than_dropped :: proc(t: ^testing.T) {
	line, err := build(EXE, {"--language", "", "--model", "big.bin"}, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, err, Build_Error.None)

	argv := argv_of(t, line, context.allocator)
	defer free_argv(argv, context.allocator)
	testing.expect_value(t, len(argv), 5)
	if len(argv) == 5 {
		testing.expect_value(t, argv[2], "")
		// The flag AFTER the empty one is the thing that actually breaks, so it
		// is checked by name rather than left to the loop above.
		testing.expect_value(t, argv[3], "--model")
	}
}

@(test)
empty_arguments_round_trip_in_every_position :: proc(t: ^testing.T) {
	expect_round_trip(t, EXE, {""}, "empty alone")
	expect_round_trip(t, EXE, {"", "-after"}, "empty first")
	expect_round_trip(t, EXE, {"-before", ""}, "empty last")
	expect_round_trip(t, EXE, {"", "", ""}, "nothing but empties")
	expect_round_trip(t, EXE, {"-a", "", "-b", "", "-c"}, "empties between flags")
}

// The backslash-before-quote rule, which is the part of Windows quoting that
// people get wrong. A run of backslashes is literal UNLESS it meets a quote, and
// the closing quote counts -- so `C:\path with space\` quoted naively ends in
// `\"`, which is an escaped quote, and the argument runs on into the next one.
//
// This list is the one PR #25 verified its PowerShell quoter against, against a
// real CommandLineToArgvW dumper.
@(private)
BACKSLASH_CASES :: []string {
	`a"b`,
	`a\"b`,
	`a\\"b`,
	`a\\\"b`,
	`"`,
	`""`,
	`""""`,
	`"quoted"`,
	`\`,
	`\\`,
	`\\\`,
	`\\\\`,
	`C:\path with space\`,
	`C:\path\`,
	`C:\path\\`,
	`ends with backslash \`,
	`"leading quote`,
	`trailing quote"`,
	`-of:C:\cache\job "1"\`,
	`\"\"\"`,
}

@(test)
backslash_arguments_round_trip :: proc(t: ^testing.T) {
	expect_each_and_all(t, "backslash", BACKSLASH_CASES)
}

// Non-ASCII survives the trip, including outside the Basic Multilingual Plane,
// where one rune is a surrogate PAIR in UTF-16 and a builder that escaped
// rune-wise could split it.
//
// READ WHAT THIS DOES AND DOES NOT CLAIM. It says the builder produces a command
// line whose UTF-16 form Windows re-splits into exactly these arguments. It says
// NOTHING about whether the engine can then open the file. `whisper-cli` is
// `int main(int argc, char**argv)` under MSVC, so its argv arrives in the system
// ANSI code page and a non-ASCII path is mangled before the program sees it
// (ADR-0002) -- which is precisely why ADR-0002 keeps the engine's cache and
// model on an ASCII-only path instead. ffmpeg re-reads `GetCommandLineW()` and
// does not have that bug, so it is the child this actually buys something for.
// A correct command line is a precondition for that fix, never a substitute.
@(private)
NON_ASCII_CASES :: []string {
	"C:\\Users\\Иван\\recording.mkv",
	"C:\\Users\\Ivan Drenjanin\\Видео 2026\\zapis.mkv",
	"ü",
	"Ω",
	"日本語のファイル名.mp4",
	"emoji 😀 and 𝄞 outside the BMP",
	"𝄞",
	"\U0001F600\U0001F601\U0001F602",
	"combining a\u0301 e\u0301",
	"right-to-left \u05D0\u05D1\u05D2",
	"C:\\ø\\å\\æ\\file with space.wav",
	"trailing surrogate-pair then backslash 𝄞\\",
	"quote and 𝄞\" together",
}

@(test)
non_ascii_arguments_round_trip :: proc(t: ^testing.T) {
	expect_each_and_all(t, "non-ascii", NON_ASCII_CASES)
}

// argv[0] is parsed by a DIFFERENT rule, and this is the case where getting it
// wrong is silent in the way the ticket describes.
//
// Measured, every line of it: for argv[0] Windows skips the opening quote and
// copies to the next one, and NO backslash is special. So `"C:\dir\" one` gives
// argv[0] `C:\dir\` -- the trailing backslash needs no doubling, and a builder
// that reused the argument rule here would double it and hand the child a path
// with a second backslash that is not in the filesystem.
//
// The program path is checked as argv[0] by expect_round_trip on every case in
// this file; these are the paths whose SHAPE is the point.
@(private)
PROGRAM_CASES :: []string {
	`C:\tools\ffmpeg.exe`,
	`C:\Program Files\ffmpeg\bin\ffmpeg.exe`,
	`C:\dir with space\`,
	`C:\trailing\`,
	`C:\trailing\\`,
	`C:\trailing\\\`,
	`\\server\share with space\whisper-cli.exe`,
	`ffmpeg.exe`,
	`C:\Users\Иван\bin\ffmpeg.exe`,
	`C:\ö ü\𝄞\ffmpeg.exe`,
	"C:\\tab\tin\\path.exe",
	`C:\a^b&c\ffmpeg.exe`,
	`.\relative\ffmpeg.exe`,
	`C:/forward/slashes/ffmpeg.exe`,
}

@(test)
the_program_path_round_trips_under_its_own_rule :: proc(t: ^testing.T) {
	for program, i in PROGRAM_CASES {
		expect_round_trip(t, program, {}, tprint_case("program alone", i))
		expect_round_trip(t, program, {"-i", "a b.mkv", ""}, tprint_case("program", i))
	}
}

// A8: everything here arrives from outside, so a bad one is REFUSED through the
// error return rather than asserted. Each of these is a value that cannot be
// spelled on a Windows command line at all, so the honest answer is to say so
// and let the caller report it against the file that caused it.
//
// Rejection is checked to allocate nothing, which is the half that rots: a
// refusal that still returns a builder's buffer leaks on every bad input, and
// nothing about the error return says it did. The test runner's memory tracking
// is what actually catches that (ODIN_TEST_FAIL_ON_BAD_MEMORY).
@(test)
an_unspellable_program_path_is_refused :: proc(t: ^testing.T) {
	// Empty. `CommandLineToArgvW` measured on an EMPTY command line returns the
	// running executable's own path as argv[0] -- so a child handed one would
	// silently run against itself rather than fail.
	line, err := build("", {"-i", "a.mkv"}, context.allocator)
	testing.expect_value(t, err, Build_Error.Empty_Program)
	testing.expect_value(t, len(line), 0)

	// A quote. argv[0] has no escape mechanism at all: measured, `"a""b" one`
	// yields argv[0] `a`, argv[1] `b`, argv[2] `one`, so the path simply cannot
	// be expressed. Windows forbids `"` in a filename anyway -- a caller holding
	// one has a bug, not an exotic path.
	quoted, quote_err := build(`C:\a"b\ffmpeg.exe`, {}, context.allocator)
	testing.expect_value(t, quote_err, Build_Error.Quote_In_Program)
	testing.expect_value(t, len(quoted), 0)
}

// A NUL byte ends the command line where Windows reads it, so everything after
// it -- every remaining argument -- disappears without a diagnostic. Refused on
// both sides, because either side can carry one.
@(test)
an_embedded_nul_is_refused :: proc(t: ^testing.T) {
	line, err := build("C:\\a\x00b\\ffmpeg.exe", {"-i"}, context.allocator)
	testing.expect_value(t, err, Build_Error.Embedded_Nul)
	testing.expect_value(t, len(line), 0)

	in_argument, argument_err := build(EXE, {"-i", "a\x00b.mkv", "-y"}, context.allocator)
	testing.expect_value(t, argument_err, Build_Error.Embedded_Nul)
	testing.expect_value(t, len(in_argument), 0)
}

// The documented `CreateProcessW` ceiling: 32,767 characters INCLUDING the
// terminating null, counted in UTF-16 code units rather than bytes or runes.
//
// Counted in the unit Windows counts in, which is the whole point of the case.
// A rune outside the BMP is ONE rune, up to four UTF-8 bytes, and TWO UTF-16
// code units -- so a builder measuring `len(string)` refuses lines that fit, and
// one measuring runes accepts lines that do not and hands CreateProcessW an
// argument it truncates.
@(test)
a_command_line_past_the_windows_ceiling_is_refused :: proc(t: ^testing.T) {
	long := strings.repeat("a", MAX_COMMAND_LINE_UNITS, context.allocator)
	defer delete(long, context.allocator)

	line, err := build(EXE, {long}, context.allocator)
	testing.expect_value(t, err, Build_Error.Too_Long)
	testing.expect_value(t, len(line), 0)
}

@(test)
the_ceiling_is_counted_in_utf16_code_units :: proc(t: ^testing.T) {
	// Each rune is 4 UTF-8 bytes and 2 UTF-16 code units. Chosen so the line is
	// well under the ceiling in UTF-16 but over it if bytes were counted --
	// a builder measuring bytes refuses this, and it is perfectly legal.
	runes := MAX_COMMAND_LINE_UNITS / 4
	body := strings.repeat("\U0001F600", runes, context.allocator)
	defer delete(body, context.allocator)

	line, err := build(EXE, {body}, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, err, Build_Error.None)
	testing.expect(
		t,
		len(line) > MAX_COMMAND_LINE_UNITS,
		"the case no longer exceeds the ceiling in BYTES",
	)

	argv := argv_of(t, line, context.allocator)
	defer free_argv(argv, context.allocator)
	testing.expect_value(t, len(argv), 2)
	if len(argv) == 2 {
		testing.expect_value(t, argv[1], body)
	}
}

// The largest line that still fits, and the smallest that does not -- the two
// sides of the boundary, so an off-by-one in either direction is caught (A3).
@(test)
the_ceiling_admits_the_longest_line_that_fits :: proc(t: ^testing.T) {
	// `"x" ` is the quoted program plus the separating space: 4 units. The
	// terminating null Windows counts takes one more.
	overhead := len(`"x" `) + 1
	fits := strings.repeat("a", MAX_COMMAND_LINE_UNITS - overhead, context.allocator)
	defer delete(fits, context.allocator)

	line, err := build("x", {fits}, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, err, Build_Error.None)
	testing.expect_value(t, len(line), MAX_COMMAND_LINE_UNITS - 1)

	one_too_many := strings.concatenate({fits, "a"}, context.allocator)
	defer delete(one_too_many, context.allocator)
	over, over_err := build("x", {one_too_many}, context.allocator)
	testing.expect_value(t, over_err, Build_Error.Too_Long)
	testing.expect_value(t, len(over), 0)
}

// The rule the case above rests on, stated as a fact about Windows rather than
// about this package: a trailing backslash in argv[0] is NOT an escape, so the
// argument after it survives. Doubling it -- the argument rule, misapplied --
// would put a second backslash in the path instead.
//
// THE MUTANT THIS CASE HOLDS, written out because the measurement it rests on is
// the one a reader is most likely to get backwards. Make write_program double a
// trailing run the way write_argument does, and `C:\dir with space\` reaches the
// child as `C:\dir with space\\` -- a path carrying a second backslash that the
// filesystem does not have.
//
// MEASURED, and worth knowing before trusting the tests alone to catch it: that
// mutant never reaches an expectation in this file. write_program's own length
// assertion fires first ("the program path was not written whole"), and a
// maintainer who relaxes that one to match is stopped by build's second,
// independent one ("a command line with no arguments carries something anyway").
// Three separate checks have to be defeated before a wrong argv[0] can be
// observed rather than crashed on -- which is what A4's paired write-side and
// read-side assertions buy, stated here because the crash names the assertion
// and not the reason.
//
// The second half is the same rule read from the other end, and it is the half
// that catches a reader who "corrects" the first. A path that ALREADY ends in a
// doubled run keeps BOTH backslashes: `"C:\dir\\" one` yields argv[0]
// `C:\dir\\`, measured, not `C:\dir\`. Nothing in argv[0] collapses, because
// nothing in argv[0] was ever an escape -- so there is no doubling anywhere for
// write_program to compensate for.
@(test)
a_trailing_backslash_in_the_program_path_is_not_an_escape :: proc(t: ^testing.T) {
	line, err := build(`C:\dir with space\`, {"-after"}, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, err, Build_Error.None)
	testing.expect_value(t, line, `"C:\dir with space\" -after`)

	argv := argv_of(t, line, context.allocator)
	defer free_argv(argv, context.allocator)
	testing.expect_value(t, len(argv), 2)
	if len(argv) == 2 {
		testing.expect_value(t, argv[0], `C:\dir with space\`)
		testing.expect_value(t, argv[1], "-after")
	}

	doubled, doubled_err := build(`C:\dir\\`, {"one"}, context.allocator)
	defer delete(doubled, context.allocator)
	testing.expect_value(t, doubled_err, Build_Error.None)
	testing.expect_value(t, doubled, `"C:\dir\\" one`)

	doubled_argv := argv_of(t, doubled, context.allocator)
	defer free_argv(doubled_argv, context.allocator)
	testing.expect_value(t, len(doubled_argv), 2)
	if len(doubled_argv) == 2 {
		testing.expect_value(t, doubled_argv[0], `C:\dir\\`)
		testing.expect_value(t, doubled_argv[1], "one")
	}
}
