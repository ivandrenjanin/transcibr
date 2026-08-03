// transcibr-cli — the console-subsystem binary (ADR-0004).
//
// The command-line front end exists so a Batch can be planned or re-rendered
// from a script. Today it does one of those: `--from-json` renders a Transcript
// out of retained Engine output and writes it to standard output, without
// touching the GPU (spec story 46). With no arguments it reports its version,
// which is what the build's smoke test reads.
//
// Deliberately thin, and declared test-less in scripts/common.ps1 for that
// reason: everything worth testing lives in the pure core (ADR-0009). What is
// here is argument reading, one file read, one clock read, and a write.
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "transcibr:transcript"
import "transcibr:version"

PROGRAM :: "transcibr-cli"

// `banner` requires it, and it cannot vary at runtime (CLAUDE.md rule A5).
#assert(len(PROGRAM) > 0)

// What a caller gets told when the command line is not one this binary reads.
USAGE :: `usage:
  transcibr-cli
      report the version and exit.

  transcibr-cli --from-json <path> [--profile monologue|conversation]
                [--source <name>] [--model <name>] [--engine <version>]
      render the transcript for one piece of retained engine output and
      write it to standard output.

--source, --model and --engine are what the transcript records about how it
was made. The engine's own output cannot settle them -- it carries no engine
version and reports every large model as "large" (ADR-0003) -- so anything
not given is recorded as "unknown" rather than guessed at.`

// What the exit code says. Two failures and not one: a command line this binary
// cannot read is the caller's to fix, and a Recording's output that will not
// render is a file to go and look at (ADR-0002).
USAGE_ERROR :: 2
OPERATING_ERROR :: 1

main :: proc() {
	if len(os.args) == 1 {
		print_version()
		return
	}
	os.exit(re_render(os.args[1:]))
}

// Prints the line that identifies this binary.
print_version :: proc() {
	line := version.banner(PROGRAM, version.CURRENT, context.allocator)
	defer delete(line, context.allocator)

	// The read side of the four facts `banner` asserts on the way out (A4). A
	// script reading this binary's output splits the first line on its first
	// space, so the shape is the contract and not merely the length. Neither
	// side can fire while the other holds; a change to one of them is what this
	// pair is here to catch.
	assert(strings.has_prefix(line, PROGRAM), "banner does not name this program")
	assert(len(line) > len(PROGRAM), "banner carries no version after the program name")
	assert(line[len(PROGRAM)] == ' ', "banner does not separate the program name from the version")
	assert(strings.index_byte(line, '\n') == -1, "banner rendered more than one line")

	fmt.println(line)
}

// What the command line asked for.
Options :: struct {
	json_path: string,
	rc:        transcript.Render_Context,
}

// Renders one piece of retained Engine output to standard output.
re_render :: proc(arguments: []string) -> int {
	assert(
		len(arguments) > 0,
		"no arguments at all is the version banner, settled before this point",
	)

	options, ok := read_options(arguments)
	if !ok {
		return USAGE_ERROR
	}

	json_bytes, read_err := os.read_entire_file_from_path(options.json_path, context.allocator)
	defer delete(json_bytes, context.allocator)
	if read_err != nil {
		fmt.eprintfln("%s: %v", options.json_path, read_err)
		return OPERATING_ERROR
	}
	json_text := string(json_bytes)

	rc := options.rc
	// The two facts the core refuses to reach for (ADR-0009): the clock, read
	// here in the shell where reading it is allowed, and the language, which is
	// the one of them the Engine's own output can settle (ADR-0001).
	rc.now = time.now()
	language, said := transcript.parse_language(json_text, context.allocator)
	defer if said {
		delete(language, context.allocator)
	}
	rc.language = said ? language : transcript.UNKNOWN

	return write_transcript(options.json_path, json_text, rc)
}

// Renders and writes, or reports why it could not.
//
// The Recording's length is passed as NOTHING, and that is honest rather than
// lazy: it comes off the container with ffprobe (ADR-0009), this binary has no
// Recording in hand and only the Engine's output, and a length invented from the
// Cues is the circular measurement that ADR ruled out. The parser treats an
// unmeasured Recording as an unknown and declines to draw conclusions from it.
write_transcript :: proc(
	json_path: string,
	json_text: string,
	rc: transcript.Render_Context,
) -> int {
	assert(len(json_path) > 0, "a transcript must name the output it was rendered from")

	markdown, err := transcript.render_transcript(json_path, json_text, nil, rc, context.allocator)
	defer delete(markdown, context.allocator)

	if err.fault != .None {
		message := transcript.error_message(err, context.allocator)
		defer delete(message, context.allocator)
		fmt.eprintln(message)
		return OPERATING_ERROR
	}

	// os.write_string and not fmt.print: the document's bytes are the
	// deliverable, and a formatter between them and the handle is one more thing
	// that could put a byte in that the golden fixture never saw.
	os.write_string(os.stdout, markdown)
	return 0
}

// Reads the command line, or says what is wrong with it.
//
// Nothing here asserts against what a caller typed. A command line is outside
// this program and nothing outside it may crash it (CLAUDE.md A8), so every
// refusal below is a message and an exit code.
read_options :: proc(arguments: []string) -> (o: Options, ok: bool) {
	// What a Transcript records where nobody could settle it. Set BEFORE the
	// loop, so a flag left off is "unknown" rather than an empty field the
	// renderer would refuse.
	o.rc.model = transcript.UNKNOWN
	o.rc.engine_version = transcript.UNKNOWN
	o.rc.profile = .Monologue

	for at := 0; at < len(arguments); at += 2 {
		name := arguments[at]
		if at + 1 >= len(arguments) {
			fmt.eprintfln("%s takes a value.\n\n%s", name, USAGE)
			return {}, false
		}
		value := arguments[at + 1]

		switch name {
		case "--from-json":
			o.json_path = value
		case "--source":
			o.rc.source_display = value
		case "--model":
			o.rc.model = value
		case "--engine":
			o.rc.engine_version = value
		case "--profile":
			profile, known := transcript.profile_named(value)
			if !known {
				fmt.eprintfln("no merge profile called %q.\n\n%s", value, USAGE)
				return {}, false
			}
			o.rc.profile = profile
		case:
			fmt.eprintfln("unknown option %q.\n\n%s", name, USAGE)
			return {}, false
		}
	}

	if len(o.json_path) == 0 {
		fmt.eprintfln("nothing to render.\n\n%s", USAGE)
		return {}, false
	}
	// The Recording's own name is what a reader goes looking for, but this binary
	// is handed the Engine's output and not the Recording. Naming the file it
	// really rendered from is the honest default; --source is how a caller who
	// knows the Recording's name says so.
	if len(o.rc.source_display) == 0 {
		o.rc.source_display = o.json_path
	}
	return o, true
}
