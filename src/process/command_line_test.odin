package process

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
// child that does not roll its own -- and what comes back is compared against
// what went in.
//
// The builder stays pure (ADR-0009); this does not. That asymmetry is deliberate
// and is the only reason the criterion can be met at all: purity is a property of
// `build_command_line`, not of the harness that checks it.
//
// AND IT COSTS THE SHIPPED BINARY NOTHING, which is worth writing down because
// the opposite is a reasonable thing to fear and acting on the fear would mean
// giving up the real parser. Odin DOES type-check `_test.odin` files in an
// ordinary build, including for an imported package -- plant a broken one and
// `odin build` of a main package that imports this fails. The link-time
// conclusion does not follow from that. Measured, A/B: a main package importing
// this one carries no SHELL32 import and no `CommandLineToArgvW` anywhere in the
// image, while a binary that really calls the API carries both. Nothing here
// reaches ADR-0004's GUI binary.
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
//
// #caller_location, the mechanism render_test.odin already uses: without it every
// failure in this file is reported against a line inside this procedure, which is
// the one line that is the same for all of them. With it the report names the run
// that failed, which for a table case is the difference between the standalone
// loop and the flanked one.
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

// Every argument in one table is round-tripped on its own AND with the whole
// table passed as one argument list. Alone catches a case the builder mangles;
// together catches a case whose damage only shows up as a neighbour's argument
// -- a lost quote runs two of them into one, which a single-argument case cannot
// see because there is no neighbour to run into.
@(private)
expect_each_and_all :: proc(t: ^testing.T, group: string, cases: []string) {
	for value, i in cases {
		expect_round_trip(t, EXE, {value}, tprint_case(group, i, "alone"))
	}
	expect_round_trip(t, EXE, cases, tprint_group(group, "all together"))
	// A neighbour on each side, so a case that swallows the space after it is
	// caught rather than absorbed by the end of the command line.
	for value, i in cases {
		expect_round_trip(t, EXE, {"-before", value, "-after"}, tprint_case(group, i, "flanked"))
	}
}

@(private)
EXE :: `C:\tools\ffmpeg.exe`

// The label one case is reported under, and `how` is not decoration: every value
// in a table is round-tripped more than once -- alone, and again flanked by
// neighbours -- so the group and the index together do not identify a run.
// Measured on a deliberately broken builder, both runs reported `backslash[12]`,
// and the two say different things: alone means the value itself is mangled,
// flanked means the damage only shows as a neighbour's argument.
@(private)
tprint_case :: proc(group: string, index: int, how: string) -> string {
	return fmt.tprintf("%s[%d] %s", group, index, how)
}

// The same label for a run that is about a whole table rather than one case.
@(private)
tprint_group :: proc(group: string, how: string) -> string {
	return fmt.tprintf("%s %s", group, how)
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
// THIS IS NOT THE POWERSHELL QUOTER'S LIST, and the difference is worth stating
// because the two are easy to assume into one. There are two quoters -- this one
// and ConvertTo-NativeArgument in scripts/common.ps1 -- and they have separate
// corpora: the PowerShell side pins seven values in scripts/selftest.ps1, under
// `every argument survives the trip through a native command line`, against a
// dumper that prints the argv it received. Nothing keeps the two lists in step,
// so a case added here to pin a newly-found bug does not protect that side, and
// a case added there does not protect this one.
//
// What IS true, and the reason the last three entries below are here: every one
// of those seven values is now covered on this side. Three are covered by shape
// rather than by literal -- `''` by empty_arguments_round_trip_in_every_position,
// `plain` by plain_arguments_round_trip, `two words` by WHITESPACE_CASES -- and
// the remaining four appear verbatim in the table below. Covered is all that
// says; it does NOT make either list the other's source, and adding to one still
// does nothing for the other.
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
	// The three shapes the PowerShell corpus pins that nothing here covered: a
	// quoted run inside a word, a bare word ending in a doubled run, and a flag
	// whose value carries both a space and a quote.
	`a"quoted"b`,
	`trailing\\`,
	`-define:NAME=a b"c`,
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
// ANSI code page and a non-ASCII path is mangled before the executable sees it
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
// The executable path is checked as argv[0] by expect_round_trip on every case in
// this file; these are the paths whose SHAPE is the point.
@(private)
EXECUTABLE_CASES :: []string {
	// The ordinary path every other test in this file already runs as argv[0],
	// named once rather than spelled a second time here.
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
an_unspellable_executable_path_is_refused :: proc(t: ^testing.T) {
	// Empty. `CommandLineToArgvW` measured on an EMPTY command line returns the
	// running executable's own path as argv[0] -- so a child handed one would
	// silently run against itself rather than fail.
	line, err := build_command_line("", {"-i", "a.mkv"}, context.allocator)
	testing.expect_value(t, err.fault, Build_Fault.Empty_Executable)
	testing.expect_value(t, len(line), 0)

	// A quote. argv[0] has no escape mechanism at all: measured, `"a""b" one`
	// yields argv[0] `a`, argv[1] `b`, argv[2] `one`, so the path simply cannot
	// be expressed. Windows forbids `"` in a filename anyway -- a caller holding
	// one has a bug, not an exotic path.
	quoted, quote_err := build_command_line(`C:\a"b\ffmpeg.exe`, {}, context.allocator)
	testing.expect_value(t, quote_err.fault, Build_Fault.Quote_In_Executable)
	testing.expect_value(t, len(quoted), 0)
}

// A NUL byte ends the command line where Windows reads it, so everything after
// it -- every remaining argument -- disappears without a diagnostic. Refused on
// both sides, because either side can carry one.
//
// The two sides are DIFFERENT faults rather than one. A8's promise is that the
// caller can report a refusal against the input that caused it, and one fault
// returned from two scans cannot keep it: `a NUL somewhere` names no file.
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

// Which argument, and not merely that one of them was bad. The scan already has
// the index in hand, and a caller that has to find the NUL again to say which
// file to fix is a caller re-deriving what this procedure already knew.
@(test)
a_refused_argument_is_reported_by_position :: proc(t: ^testing.T) {
	// 1-based, and the SECOND argument carries it -- so a report that is off by
	// one names `-i` and sends a reader to the wrong place entirely.
	_, err := build_command_line(EXE, {"-i", "a\x00b.mkv", "-y"}, context.allocator)
	testing.expect_value(t, err.fault, Build_Fault.Nul_In_Argument)
	testing.expect_value(t, err.argument, 2)
	testing.expect_value(t, err.culprit, "a\x00b.mkv")

	// A fault about the executable blames no argument, which is the negative space
	// of the same rule (A3): an ordinal left set would print `argument 2` over a
	// fault that has nothing to do with the argument list.
	_, executable_err := build_command_line(
		`C:\a"b\ffmpeg.exe`,
		{"-i", "in.mkv"},
		context.allocator,
	)
	testing.expect_value(t, executable_err.fault, Build_Fault.Quote_In_Executable)
	testing.expect_value(t, executable_err.argument, 0)
	testing.expect_value(t, executable_err.culprit, `C:\a"b\ffmpeg.exe`)
}

// The sentence both NUL faults carry, spelled out on this side so the two
// expectations below are EXACT lines. The source keeps its own copy: a test that
// read FAULT would agree with the rendering by construction and could never
// disagree with it.
@(private)
NUL_SAYS :: "contains a NUL, which ends the command line where Windows reads it"

// Every refusal renders as ONE line the caller can print, which is the whole
// reason the fault carries what it does. The alternative is every consumer
// hand-rolling a switch over the enumeration, which is what engine_json.odin
// argues against at length -- and this package would be the second copy of it.
//
// EXACT lines, one per branch of error_message, and NOT a substring search --
// because a substring search is what let two branches of a 28-line procedure
// drift apart unnoticed. The argument branch printed its culprit with %q and the
// executable branch with %s, and `contains(culprit)` is satisfied by both.
//
// MEASURED, what %s cost on the two faults this package added so that a refusal
// could name its cause: `.Nul_In_Executable` rendered the culprit's raw NUL into
// the report, so MessageBoxW, SetWindowTextW, a UTF-16 log or any C-string
// consumer shows `C:` and stops -- the one message whose entire job is naming the
// path that carries a NUL. `.Invalid_Utf8_In_Executable` rendered bytes that are
// not valid UTF-8, so `utf8_to_utf16` answers nil for the report about a path it
// answers nil for. %q escapes both into printable text.
//
// So the expectations below no longer see that mutant, and it is worth knowing
// before trusting them to catch it: `deliverable`'s postcondition now fires
// first, and the first case here is the one that trips it. Measured, under
// -define:ODIN_TEST_THREADS=1 -- which is how a mutant is run in this package at
// all, since the runner hangs when two tests assert at once.
@(test)
a_refusal_renders_as_one_line_naming_its_input :: proc(t: ^testing.T) {
	// The executable branch, on the path an_embedded_nul_is_refused already uses.
	_, nul_err := build_command_line("C:\\a\x00b\\ffmpeg.exe", {"-i"}, context.allocator)
	in_executable := error_message(nul_err, context.allocator)
	defer delete(in_executable, context.allocator)
	testing.expect_value(t, in_executable, `"C:\\a\x00b\\ffmpeg.exe": ` + NUL_SAYS)

	// The argument branch, which carries the ordinal as well.
	_, argument_err := build_command_line(EXE, {"-i", "a\x00b.mkv"}, context.allocator)
	named := error_message(argument_err, context.allocator)
	defer delete(named, context.allocator)
	testing.expect_value(t, named, `argument 2 ("a\x00b.mkv"): ` + NUL_SAYS)

	// The branch that names nothing, and the only one that CLONES rather than
	// formatting -- so it is also the one that checks the caller is handed memory
	// it can hand back (ODIN_TEST_FAIL_ON_BAD_MEMORY).
	_, empty_err := build_command_line("", {"-i"}, context.allocator)
	nothing := error_message(empty_err, context.allocator)
	defer delete(nothing, context.allocator)
	testing.expect_value(t, nothing, "there is no executable to run")
}

// One refusal's rendered line, against the row its fault carries.
//
// The three EXACT lines above are the independent check on the grammar, one per
// branch of error_message. This is what says the other four faults are rendered
// the same way -- which the `says` column had nothing at all standing behind it.
// MEASURED: dropping `facts.says` from error_message's executable branch left all
// seventeen tests green before this existed.
//
// It takes the culprit's escaping from the same %q the renderer uses, because
// checking that independently would mean writing a second quoter here -- the
// exact thing argv_of exists to avoid. What it does NOT take from the renderer is
// which sentence, which branch, the ordinal, or the separators, and a mutant in
// any of those disagrees with it.
@(private)
expect_refusal_renders :: proc(t: ^testing.T, err: Build_Error, loc := #caller_location) {
	message := error_message(err, context.allocator)
	defer delete(message, context.allocator)

	facts := FAULT[err.fault]
	// What the line OPENS with is the whole of what the blame decides.
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
	// ONE line, which the test above has claimed by name since it was written and
	// nothing checked. This is the half of it that is about the TABLE rather than
	// the renderer: a sentence with a newline in it is a report that a single-line
	// status field shows the first half of.
	testing.expectf(
		t,
		!strings.contains(message, "\n"),
		"%v rendered more than one line: <%s>",
		err.fault,
		message,
		loc = loc,
	)
}

// Every fault renders, and the list that proves it is walked against the
// enumeration rather than trusted to be complete.
//
// Seven faults, one refusal each, all produced through the public entry point
// rather than by hand -- so this is also the case that says every fault the
// builder can return is one a caller can actually print.
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

	// The half that rots: a fault added to Build_Fault gets a row in FAULT because
	// the compiler insists, and gets no case here because nothing does.
	for fault in Build_Fault {
		if fault == .None {
			continue
		}
		testing.expectf(t, seen[fault], "%v is rendered by no case in this list", fault)
	}
}

// Every fault has a row, and the two kinds of refusal are told apart.
//
// `.Too_Long` is the one that a different plan fixes: ADR-0002 puts the Engine's
// output under a cache path transcibr chooses, so a shorter one makes the same
// job fit. The other four are inputs that cannot be spelled on a Windows command
// line at all, and re-running with them changes nothing. A caller that treated
// all five alike would either retry the unfixable forever or fail a job that one
// shorter path would have run.
//
// Walked over the whole enumeration rather than case by case, so a fault added
// without a row in FAULT is caught by the assertions inside fault_facts.
@(test)
every_fault_says_whether_a_different_plan_would_help :: proc(t: ^testing.T) {
	for fault in Build_Fault {
		if fault == .None {
			continue
		}
		want := Disposition.Fail_The_Job
		if fault == .Too_Long {
			want = .Shorten_And_Replan
		}
		got := disposition_of(fault)
		testing.expectf(t, got == want, "%v is %v, want %v", fault, got, want)
	}
}

// Bytes that are not valid UTF-8, and are therefore not convertible to the UTF-16
// `CreateProcessW` actually takes.
//
// NOT a fuzzer's inventions. NTFS permits unpaired surrogates in a name, and
// `win32.wstring_to_utf8` hands one back as WTF-8 -- so the first two arrive
// from the filesystem, on the exact path this package is built to serve. The
// rest are the other shapes CP_UTF8 refuses, kept together because they are one
// rule.
@(private)
UNENCODABLE_CASES :: []string {
	"\xED\xA0\x80", // unpaired high surrogate
	"\xED\xB0\x80", // unpaired low surrogate
	"\xFF", // never a UTF-8 byte
	"\x80", // a continuation byte with nothing in front of it
	"\xE2\x82", // three-byte sequence cut short
	"\xF0\x9F\x98", // four-byte sequence cut short
	"ok then \xED\xA0\x80 trailing", // buried in otherwise valid text
}

// THE CONTRACT IN BOTH DIRECTIONS, measured against the real conversion rather
// than reasoned about.
//
// `build_command_line` returns UTF-8 and the spawner converts it with `utf8_to_utf16`, which
// passes MB_ERR_INVALID_CHARS and answers nil rather than substituting anything.
// So a line this accepts but Windows cannot encode fails LATER, in the shell,
// with no Build_Error naming the argument that caused it -- and ADR-0009 says
// that layer will never have a unit test. Measured before this was fixed: 9,790
// accepted lines across a fuzz run were unconvertible.
//
// The refusal lives here for exactly the reason MAX_COMMAND_LINE_UNITS does: only
// this package can name which argument was at fault, and a user-reachable refusal
// pushed into the shell is one nothing tests.
//
// Both halves are checked, because either alone can rot. Refusing everything
// would satisfy the first and is caught by the second.
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

		// The executable path carries the same bytes on the same terms.
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

	// The other direction, and the one that stops "refuse everything" from
	// passing: every case the rest of this file round-trips is still accepted,
	// and the line it produces really does convert. argv_of asserts exactly that
	// on every case in this file, so the suite as a whole is the second half --
	// this pins the non-ASCII table, which is where a check that was too strict
	// would bite first.
	for value, i in NON_ASCII_CASES {
		line, err := build_command_line(EXE, {value}, context.allocator)
		defer delete(line, context.allocator)
		testing.expectf(t, err.fault == .None, "non-ascii[%d]: refused with %v", i, err.fault)

		wide := win32.utf8_to_utf16(line, context.allocator)
		defer delete(wide, context.allocator)
		testing.expectf(t, wide != nil, "non-ascii[%d]: accepted a line Windows cannot encode", i)
	}
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

	line, err := build_command_line(EXE, {long}, context.allocator)
	testing.expect_value(t, err.fault, Build_Fault.Too_Long)
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

// The other direction of the same rule, and the DANGEROUS one.
//
// The case above pins the SAFE mistake: count bytes, and a line that fits is
// refused -- loudly, with a Build_Error naming the fault, and nothing is lost.
// This pins the mistake MAX_COMMAND_LINE_UNITS actually warns about, which
// nothing held: "counting runes accepts ones that do not [fit], and Windows
// truncates rather than complaining". Every other ceiling case in this file is
// pure ASCII, where runes, bytes and units are the same number and a rune count
// cannot be told apart from a unit count.
//
// MEASURED on a builder counting one unit per rune: a 20,000-emoji argument
// builds a 40,027-unit line, `build_command_line` accepts it, CreateProcessW
// truncates it at 32,767, and the child receives argc 2 where 4 went in --
// `--output` and the file after it silently gone. No error anywhere, which is
// the whole point: the safe direction fails a job, this one runs the wrong one.
@(test)
a_line_that_only_fits_when_runes_are_counted_is_refused :: proc(t: ^testing.T) {
	// Past the BMP: one rune, four UTF-8 bytes, TWO UTF-16 code units. 17,000 of
	// them is 34,000 units and over the ceiling, while the rune count is half of
	// that and comfortably under it.
	runes := 17_000
	body := strings.repeat("\U0001F600", runes, context.allocator)
	defer delete(body, context.allocator)

	line, err := build_command_line(EXE, {body}, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, err.fault, Build_Fault.Too_Long)
	testing.expect_value(t, len(line), 0)

	// Load-bearing only while the RUNE count stays under the ceiling: a body long
	// enough to be refused on runes as well would pass here for the wrong reason
	// and stop killing the mutant it exists for.
	testing.expect(
		t,
		runes < MAX_COMMAND_LINE_UNITS,
		"the case no longer fits under the ceiling counted in RUNES",
	)
}

// The largest line that still fits, and the smallest that does not -- the two
// sides of the boundary, so an off-by-one in either direction is caught (A3).
@(test)
the_ceiling_admits_the_longest_line_that_fits :: proc(t: ^testing.T) {
	// `"x" ` is the quoted executable plus the separating space: 4 units. The
	// terminating null Windows counts takes one more.
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

// The rule the case above rests on, stated as a fact about Windows rather than
// about this package: a trailing backslash in argv[0] is NOT an escape, so the
// argument after it survives. Doubling it -- the argument rule, misapplied --
// would put a second backslash in the path instead.
//
// THE MUTANT THIS CASE HOLDS, written out because the measurement it rests on is
// the one a reader is most likely to get backwards. Make write_executable double a
// trailing run the way write_argument does, and `C:\dir with space\` reaches the
// child as `C:\dir with space\\` -- a path carrying a second backslash that the
// filesystem does not have.
//
// MEASURED, and worth knowing before trusting the tests alone to catch it: that
// mutant never reaches an expectation in this file. write_executable's own length
// assertion fires first ("the executable path was not written whole"), and a
// maintainer who relaxes that one to match is stopped by build_command_line's second,
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
// write_executable to compensate for.
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
