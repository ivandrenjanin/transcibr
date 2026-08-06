#+vet explicit-allocators
package process

import "core:fmt"
import "core:mem"
import "core:strings"
import win32 "core:sys/windows"
import "core:testing"

// Every argument the real Windows parser found in a command line, as UTF-8,
// read through the same `argv_from_wide_command_line` production code
// `transcibr-cli` reads its own argv with (issue #35). The caller owns the
// slice and every string in it; `free_argv` returns both.
@(private)
@(require_results)
argv_of :: proc(t: ^testing.T, command_line: string, allocator: mem.Allocator) -> []string {
	wide := win32.utf8_to_utf16(command_line, allocator)
	defer delete(wide, allocator)
	if !testing.expect(t, wide != nil, "the command line is not convertible to UTF-16") {
		return nil
	}

	argv, ok := argv_from_wide_command_line(win32.wstring(raw_data(wide)), allocator)
	if !testing.expect(t, ok, "argv_from_wide_command_line refused the command line") {
		return nil
	}
	return argv
}

@(private)
free_argv :: proc(argv: []string, allocator: mem.Allocator) {
	delete_argv(argv, allocator)
}

@(private)
expect_round_trip :: proc(
	t: ^testing.T,
	executable: string,
	arguments: []string,
	name: string,
	loc := #caller_location,
) {
	line, err := build_command_line(executable, arguments, context.allocator)
	defer delete(line, context.allocator)
	testing.expectf(t, err.fault == .None, "%s: build refused with %v", name, err.fault, loc = loc)

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
		loc = loc,
	) {
		return
	}

	testing.expectf(
		t,
		argv[0] == executable,
		"%s: argv[0] came back <%s>",
		name,
		argv[0],
		loc = loc,
	)
	for want, i in arguments {
		testing.expectf(
			t,
			argv[i + 1] == want,
			"%s: argv[%d] came back <%s>, wanted <%s>",
			name,
			i + 1,
			argv[i + 1],
			want,
			loc = loc,
		)
	}
}

// Alone catches a case the builder mangles; together and flanked catch damage
// that only shows up as a neighbour's argument, which one argument cannot see.
@(private)
expect_each_and_all :: proc(t: ^testing.T, group: string, cases: []string) {
	for value, i in cases {
		expect_round_trip(t, EXE, {value}, tprint_case(group, i, "alone"))
	}
	expect_round_trip(t, EXE, cases, tprint_group(group, "all together"))
	for value, i in cases {
		expect_round_trip(t, EXE, {"-before", value, "-after"}, tprint_case(group, i, "flanked"))
	}
}

@(private)
EXE :: `C:\tools\ffmpeg.exe`

@(private)
@(require_results)
tprint_case :: proc(group: string, index: int, how: string) -> string {
	return fmt.tprintf("%s[%d] %s", group, index, how)
}

@(private)
@(require_results)
tprint_group :: proc(group: string, how: string) -> string {
	return fmt.tprintf("%s %s", group, how)
}

@(test)
plain_arguments_round_trip :: proc(t: ^testing.T) {
	expect_round_trip(t, EXE, {"-i", "in.mkv", "out.wav"}, "plain")
	expect_round_trip(t, EXE, {}, "no arguments at all")
	expect_round_trip(t, EXE, {"only"}, "a single argument")
}

// Measured; see ADR-0019.
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
	"\\\\server\\share with space\\file.mkv",
}

@(test)
whitespace_arguments_round_trip :: proc(t: ^testing.T) {
	expect_each_and_all(t, "whitespace", WHITESPACE_CASES)
}

// Measured; see ADR-0019.
@(private)
METACHARACTER_CASES :: []string {
	"caret^and&ampersand|pipe",
	"percent%PATH%percent",
	"redirect>out<in",
}

@(test)
metacharacter_arguments_round_trip :: proc(t: ^testing.T) {
	expect_each_and_all(t, "metacharacter", METACHARACTER_CASES)
}

@(test)
an_empty_argument_is_emitted_rather_than_dropped :: proc(t: ^testing.T) {
	line, err := build_command_line(
		EXE,
		{"--language", "", "--model", "big.bin"},
		context.allocator,
	)
	defer delete(line, context.allocator)
	testing.expect_value(t, err.fault, Build_Fault.None)

	argv := argv_of(t, line, context.allocator)
	defer free_argv(argv, context.allocator)
	testing.expect_value(t, len(argv), 5)
	if len(argv) == 5 {
		testing.expect_value(t, argv[2], "")
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

// Measured, and not the PowerShell quoter's corpus: ADR-0019.
@(private)
QUOTE_AND_BACKSLASH_CASES :: []string {
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
	`a"quoted"b`,
	`trailing\\`,
	`-define:NAME=a b"c`,
}

@(test)
quote_and_backslash_arguments_round_trip :: proc(t: ^testing.T) {
	expect_each_and_all(t, "quote-and-backslash", QUOTE_AND_BACKSLASH_CASES)
}

// A path that round-trips here can still be mangled by the child: whisper-cli's
// argv arrives in the system ANSI code page (ADR-0002).
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

// Measured; see ADR-0019.
@(private)
EXECUTABLE_CASES :: []string {
	EXE,
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
the_executable_path_round_trips_under_its_own_rule :: proc(t: ^testing.T) {
	for executable, i in EXECUTABLE_CASES {
		expect_round_trip(t, executable, {}, tprint_case("executable", i, "alone"))
		expect_round_trip(
			t,
			executable,
			{"-i", "a b.mkv", ""},
			tprint_case("executable", i, "with arguments"),
		)
	}
}

@(test)
an_unspellable_executable_path_is_refused :: proc(t: ^testing.T) {
	line, err := build_command_line("", {"-i", "a.mkv"}, context.allocator)
	testing.expect_value(t, err.fault, Build_Fault.Empty_Executable)
	testing.expect_value(t, len(line), 0)

	quoted, quote_err := build_command_line(`C:\a"b\ffmpeg.exe`, {}, context.allocator)
	testing.expect_value(t, quote_err.fault, Build_Fault.Quote_In_Executable)
	testing.expect_value(t, len(quoted), 0)
}

@(test)
an_embedded_nul_is_refused :: proc(t: ^testing.T) {
	line, err := build_command_line("C:\\a\x00b\\ffmpeg.exe", {"-i"}, context.allocator)
	testing.expect_value(t, err.fault, Build_Fault.Nul_In_Executable)
	testing.expect_value(t, len(line), 0)

	in_argument, argument_err := build_command_line(
		EXE,
		{"-i", "a\x00b.mkv", "-y"},
		context.allocator,
	)
	testing.expect_value(t, argument_err.fault, Build_Fault.Nul_In_Argument)
	testing.expect_value(t, len(in_argument), 0)
}

@(test)
a_refused_argument_is_reported_by_position :: proc(t: ^testing.T) {
	_, err := build_command_line(EXE, {"-i", "a\x00b.mkv", "-y"}, context.allocator)
	testing.expect_value(t, err.fault, Build_Fault.Nul_In_Argument)
	testing.expect_value(t, err.argument, 2)
	testing.expect_value(t, err.culprit, "a\x00b.mkv")

	_, executable_err := build_command_line(
		`C:\a"b\ffmpeg.exe`,
		{"-i", "in.mkv"},
		context.allocator,
	)
	testing.expect_value(t, executable_err.fault, Build_Fault.Quote_In_Executable)
	testing.expect_value(t, executable_err.argument, 0)
	testing.expect_value(t, executable_err.culprit, `C:\a"b\ffmpeg.exe`)
}

// A second copy on purpose: a test that read `NUL_SAYS` out of the source would
// agree with any edit to it by construction.
@(private)
NUL_SENTENCE :: "contains a NUL, which ends the command line where Windows reads it"

@(test)
a_refusal_renders_as_one_line_naming_its_input :: proc(t: ^testing.T) {
	_, nul_err := build_command_line("C:\\a\x00b\\ffmpeg.exe", {"-i"}, context.allocator)
	in_executable := error_message(nul_err, context.allocator)
	defer delete(in_executable, context.allocator)
	testing.expect_value(t, in_executable, `"C:\\a\x00b\\ffmpeg.exe": ` + NUL_SENTENCE)

	_, argument_err := build_command_line(EXE, {"-i", "a\x00b.mkv"}, context.allocator)
	named := error_message(argument_err, context.allocator)
	defer delete(named, context.allocator)
	testing.expect_value(t, named, `argument 2 ("a\x00b.mkv"): ` + NUL_SENTENCE)

	_, empty_err := build_command_line("", {"-i"}, context.allocator)
	nothing := error_message(empty_err, context.allocator)
	defer delete(nothing, context.allocator)
	testing.expect_value(t, nothing, "there is no executable to run")
}

// Takes the culprit's escaping from the same %q the renderer uses: checking that
// independently would mean writing a second quoter here, which is the thing
// argv_of exists to avoid.
@(private)
expect_refusal_renders :: proc(t: ^testing.T, err: Build_Error, loc := #caller_location) {
	message := error_message(err, context.allocator)
	defer delete(message, context.allocator)

	facts := FAULT[err.fault]
	opens: string
	switch facts.blames {
	case .An_Argument:
		opens = fmt.tprintf("argument %d (%q): ", err.argument, err.culprit)
	case .The_Executable:
		opens = fmt.tprintf("%q: ", err.culprit)
	case .Nothing:
		opens = ""
	case .Unset:
		testing.expectf(t, false, "%v reached the renderer blaming nothing", err.fault, loc = loc)
		return
	}

	want := fmt.tprintf("%s%s", opens, facts.says)
	testing.expectf(
		t,
		message == want,
		"%v rendered <%s>, wanted <%s>",
		err.fault,
		message,
		want,
		loc = loc,
	)
	testing.expectf(
		t,
		!strings.contains(message, "\n"),
		"%v rendered more than one line: <%s>",
		err.fault,
		message,
		loc = loc,
	)
}

@(test)
every_fault_renders_as_the_line_its_row_describes :: proc(t: ^testing.T) {
	over_the_ceiling := strings.repeat("a", MAX_COMMAND_LINE_UNITS, context.allocator)
	defer delete(over_the_ceiling, context.allocator)

	Refusal :: struct {
		executable: string,
		arguments:  []string,
	}
	cases := []Refusal {
		{"", {"-i"}},
		{`C:\a"b\ffmpeg.exe`, {}},
		{"C:\\a\x00b\\ffmpeg.exe", {"-i"}},
		{EXE, {"-i", "a\x00b.mkv"}},
		{"C:\\\xED\xA0\x80\\ffmpeg.exe", {}},
		{EXE, {"-i", "\xED\xA0\x80"}},
		{EXE, {over_the_ceiling}},
	}

	seen: [Build_Fault]bool
	for refusal, i in cases {
		line, err := build_command_line(refusal.executable, refusal.arguments, context.allocator)
		defer delete(line, context.allocator)
		if !testing.expectf(t, err.fault != .None, "refusal[%d] was accepted", i) {
			continue
		}
		seen[err.fault] = true
		expect_refusal_renders(t, err)
	}

	for fault in Build_Fault {
		if fault == .None {
			continue
		}
		testing.expectf(t, seen[fault], "%v is rendered by no case in this list", fault)
	}
}

@(test)
every_fault_says_whether_a_different_plan_would_help :: proc(t: ^testing.T) {
	for fault in Build_Fault {
		if fault == .None {
			continue
		}
		want := Disposition.Fail_The_Recording
		if fault == .Too_Long {
			want = .Shorten_And_Replan
		}
		got := disposition_of(fault)
		testing.expectf(t, got == want, "%v is %v, want %v", fault, got, want)
	}
}

// Reads FAULT directly rather than through disposition_of, exactly as
// src/audio/fault_test.odin reads its own table directly: a row written present
// and empty is not caught by the enumerated array or by an exhaustive switch, so
// nothing but a test that looks at the row itself catches it (see CLAUDE.md,
// Odin notes: enumerated arrays and switches).
@(test)
every_build_fault_names_a_disposition :: proc(t: ^testing.T) {
	for fault in Build_Fault {
		if fault == .None {
			continue
		}
		testing.expectf(
			t,
			FAULT[fault].disposition != .Unset,
			"%v has no disposition in FAULT",
			fault,
		)
	}
}

// Measured; see ADR-0019.
@(private)
UNENCODABLE_CASES :: []string {
	"\xED\xA0\x80",
	"\xED\xB0\x80",
	"\xFF",
	"\x80",
	"\xE2\x82",
	"\xF0\x9F\x98",
	"ok then \xED\xA0\x80 trailing",
}

// The accepting half of this contract is non_ascii_arguments_round_trip, which
// builds every NON_ASCII_CASES value and converts it with the same
// `utf8_to_utf16`; only the refusing half is here.
@(test)
what_the_builder_accepts_is_what_windows_can_encode :: proc(t: ^testing.T) {
	for value, i in UNENCODABLE_CASES {
		line, err := build_command_line(EXE, {value}, context.allocator)
		defer delete(line, context.allocator)
		testing.expectf(
			t,
			err.fault == .Invalid_Utf8_In_Argument,
			"unencodable[%d]: accepted with %v",
			i,
			err.fault,
		)
		testing.expectf(t, len(line) == 0, "unencodable[%d]: refused but returned a line", i)

		as_executable, executable_err := build_command_line(value, {"-i"}, context.allocator)
		defer delete(as_executable, context.allocator)
		testing.expectf(
			t,
			executable_err.fault == .Invalid_Utf8_In_Executable,
			"unencodable[%d] as an executable path: accepted with %v",
			i,
			executable_err.fault,
		)
	}
}

@(test)
a_command_line_past_the_windows_ceiling_is_refused :: proc(t: ^testing.T) {
	long := strings.repeat("a", MAX_COMMAND_LINE_UNITS, context.allocator)
	defer delete(long, context.allocator)

	line, err := build_command_line(EXE, {long}, context.allocator)
	testing.expect_value(t, err.fault, Build_Fault.Too_Long)
	testing.expect_value(t, len(line), 0)
}

@(test)
the_ceiling_is_counted_in_utf16_code_units :: proc(t: ^testing.T) {
	runes := MAX_COMMAND_LINE_UNITS / 4
	body := strings.repeat("\U0001F600", runes, context.allocator)
	defer delete(body, context.allocator)

	line, err := build_command_line(EXE, {body}, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, err.fault, Build_Fault.None)
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

// Measured; see ADR-0019.
@(test)
a_line_that_only_fits_when_runes_are_counted_is_refused :: proc(t: ^testing.T) {
	runes := 17_000
	body := strings.repeat("\U0001F600", runes, context.allocator)
	defer delete(body, context.allocator)

	line, err := build_command_line(EXE, {body}, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, err.fault, Build_Fault.Too_Long)
	testing.expect_value(t, len(line), 0)

	testing.expect(
		t,
		runes < MAX_COMMAND_LINE_UNITS,
		"the case no longer fits under the ceiling counted in RUNES",
	)
}

@(test)
the_ceiling_admits_the_longest_line_that_fits :: proc(t: ^testing.T) {
	overhead := len(`"x" `) + 1
	fits := strings.repeat("a", MAX_COMMAND_LINE_UNITS - overhead, context.allocator)
	defer delete(fits, context.allocator)

	line, err := build_command_line("x", {fits}, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, err.fault, Build_Fault.None)
	testing.expect_value(t, len(line), MAX_COMMAND_LINE_UNITS - 1)

	one_too_many := strings.concatenate({fits, "a"}, context.allocator)
	defer delete(one_too_many, context.allocator)
	over, over_err := build_command_line("x", {one_too_many}, context.allocator)
	testing.expect_value(t, over_err.fault, Build_Fault.Too_Long)
	testing.expect_value(t, len(over), 0)
}

// Measured; see ADR-0019.
@(test)
a_trailing_backslash_in_the_executable_path_is_not_an_escape :: proc(t: ^testing.T) {
	line, err := build_command_line(`C:\dir with space\`, {"-after"}, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, err.fault, Build_Fault.None)
	testing.expect_value(t, line, `"C:\dir with space\" -after`)

	argv := argv_of(t, line, context.allocator)
	defer free_argv(argv, context.allocator)
	testing.expect_value(t, len(argv), 2)
	if len(argv) == 2 {
		testing.expect_value(t, argv[0], `C:\dir with space\`)
		testing.expect_value(t, argv[1], "-after")
	}

	doubled, doubled_err := build_command_line(`C:\dir\\`, {"one"}, context.allocator)
	defer delete(doubled, context.allocator)
	testing.expect_value(t, doubled_err.fault, Build_Fault.None)
	testing.expect_value(t, doubled, `"C:\dir\\" one`)

	doubled_argv := argv_of(t, doubled, context.allocator)
	defer free_argv(doubled_argv, context.allocator)
	testing.expect_value(t, len(doubled_argv), 2)
	if len(doubled_argv) == 2 {
		testing.expect_value(t, doubled_argv[0], `C:\dir\\`)
		testing.expect_value(t, doubled_argv[1], "one")
	}
}

// This test binary's own argv, read the same way `transcibr-cli`'s `main`
// reads its (issue #35, ADR-0025): `GetCommandLineW` and not `os.args`, so
// the running process is the fixture and there is nothing to build.
@(test)
process_argv_reads_the_running_processs_own_command_line :: proc(t: ^testing.T) {
	argv, ok := process_argv(context.allocator)
	defer free_argv(argv, context.allocator)
	if !testing.expect(t, ok, "process_argv refused this test binary's own command line") {
		return
	}
	testing.expectf(t, len(argv) > 0, "argv came back with nothing in it, not even argv[0]")
	if len(argv) > 0 {
		testing.expectf(
			t,
			len(argv[0]) > 0,
			"argv[0] came back empty for a process that is plainly running",
		)
	}
}
