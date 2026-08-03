package command_line

import "core:mem"
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

@(test)
plain_arguments_round_trip :: proc(t: ^testing.T) {
	expect_round_trip(t, `C:\tools\ffmpeg.exe`, {"-i", "in.mkv", "out.wav"}, "plain")
}
