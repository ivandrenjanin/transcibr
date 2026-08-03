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
//
// The Merge Profiles come from the package that holds them
// (transcript.PROFILE_CHOICE) and are never spelled here. Spelled here they were
// a copy of that table living where no compiler could compare the two: a third
// profile would go unmentioned, and a renamed one would be offered under a
// spelling the lookup refuses.
//
// Concatenated at COMPILE TIME and not printed through a verb. This block was a
// format string, with the profiles substituted in at every use -- which makes
// the first `%` a future line of prose carries into a bad verb, printed as
// `%!c(MISSING)` to a caller who asked for help. A usage block holds prose, and
// prose eventually holds a per cent sign.
USAGE ::
	`usage:
  transcibr-cli
      report the version and exit.

  transcibr-cli --from-json <path> [--profile ` +
	transcript.PROFILE_CHOICE +
	`]
                [--source <name>] [--model <name>] [--engine <version>]
      render the transcript for one piece of retained engine output and
      write it to standard output.

  transcibr-cli --help
      print this and exit.

--source, --model and --engine are what the transcript records about how it
was made. The engine's own output cannot settle them -- it carries no engine
version and reports every large model as "large" (ADR-0003) -- so anything
not given, or given empty, is recorded as "unknown" rather than guessed at.`

// The one thing this binary reads that takes no value.
//
// Answered BEFORE the loop that reads the rest, because that loop pairs a name
// off with the argument after it and cannot express a valueless flag at all: it
// told a caller who typed `--help` that `--help` takes a value. Spec story 45's
// plan flag is boolean by construction, and is what will make the pairing stop.
HELP :: "--help"

// What the exit code says. Two failures and not one: a command line this binary
// cannot read is the caller's to fix, and a Recording's output that will not
// render is a file to go and look at (ADR-0002).
USAGE_ERROR :: 2
OPERATING_ERROR :: 1

main :: proc() {
	// Every process is started with its own name in front of whatever else it
	// was given, so an empty argv is a broken loader rather than a bare command
	// line -- and the slice below would run off the end of it.
	assert(len(os.args) > 0, "a process started with no argv at all, not even its own name")

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

	// A caller who ASKED for the usage block gets it on standard output at exit
	// zero, which is where a script redirecting one expects it. A caller who
	// typed something this binary cannot read gets it on standard error at exit
	// two, which is where a script checking one expects it.
	if asks_for_help(arguments) {
		write_usage(os.stdout)
		return 0
	}

	options, ok := read_options(arguments)
	if !ok {
		return USAGE_ERROR
	}
	// The read side of what read_options promises on the way out (CLAUDE.md A4).
	// An empty path is not a file the read below can name in its report, so the
	// failure would arrive as `: Not_Exist` with nothing in front of the colon.
	assert(len(options.json_path) > 0, "accepted a command line with nothing to render")

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
	rc.language = transcript.parse_language(json_text, context.allocator)
	defer delete(rc.language, context.allocator)

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
	// The front matter fields the renderer refuses to write empty, checked HERE
	// so the diagnostic points at the shell that left one out rather than at the
	// procedure that noticed -- the argument version.banner makes about its own
	// preconditions (CLAUDE.md A4). Every one of them has a default, so an empty
	// field is this binary forgetting rather than a fact nobody had.
	assert(len(rc.source_display) > 0, "a transcript that names no source reached the renderer")
	assert(len(rc.language) > 0, "a language nobody settled is UNKNOWN, never empty")

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
	//
	// And the answer is READ, which is the other half of the same argument. A
	// write to a full disk, or into a pipe whose reader has already gone, stops
	// part-way -- and a caller told nothing about it holds a truncated Transcript
	// at exit 0, which is the one outcome ADR-0002's quarantine-and-re-run can
	// never fire on. Both halves checked (CLAUDE.md A3): an error, and a byte
	// count short of the document, because a platform reporting one without the
	// other still wrote less than the deliverable.
	written, write_err := os.write_string(os.stdout, markdown)
	if write_err != nil || written != len(markdown) {
		fmt.eprintfln(
			"%s: %d of %d bytes of the transcript reached standard output: %v",
			json_path,
			written,
			len(markdown),
			write_err,
		)
		return OPERATING_ERROR
	}
	return 0
}

// Whether the command line asks for the usage block.
//
// Scanned across the positions a NAME can stand in, and never across the whole
// command line. A scan of everything read `--from-json --help` as a request for
// usage -- and that command line asks to render a file called `--help` and names
// no output at all, so it went out on standard output at exit ZERO, which is a
// script told its render succeeded. A flag is a flag only where a flag can
// stand.
//
// Stepping by two from zero, which is how read_options walks the same argument
// list below: the two are one shape and a change to either is a change to both.
//
// Nothing asserted on the way in. The only precondition worth stating is that
// there are arguments at all, and re_render -- the one caller, three lines above
// the call -- states it on the same slice before doing anything else. A second
// copy on the same value in the same call chain is not A4's pairing, which wants
// one property enforced by two ROUTES; it is one route asserted twice, and the
// loop below is correct on an empty slice regardless.
@(private)
asks_for_help :: proc(arguments: []string) -> bool {
	for at := 0; at < len(arguments); at += 2 {
		if arguments[at] == HELP {
			return true
		}
	}
	return false
}

// Reads the command line, or says what is wrong with it.
//
// Nothing here asserts against what a caller typed. A command line is outside
// this program and nothing outside it may crash it (CLAUDE.md A8), so every
// refusal below is a message and an exit code.
read_options :: proc(arguments: []string) -> (o: Options, ok: bool) {
	// The write side of what re_render and write_transcript check on the way in
	// (CLAUDE.md A4): an accepted command line names something to render and
	// leaves no front matter field empty. Its negative space is the other half --
	// a refusal hands back nothing anybody should read.
	defer if ok {
		assert(len(o.json_path) > 0, "accepted a command line with nothing to render")
		assert(len(o.rc.source_display) > 0, "accepted a command line that names no source")
		assert(len(o.rc.model) > 0, "a model nobody named is UNKNOWN, never empty")
		assert(len(o.rc.engine_version) > 0, "an engine nobody named is UNKNOWN, never empty")
	} else {
		assert(len(o.json_path) == 0, "refused a command line and kept what it asked for")
	}

	// The Merge Profile a caller who chose none is merged under, read from the
	// package that holds the profiles rather than spelled here as a bare enum
	// member: the window ADR-0004 promises has to produce the same bytes from the
	// same input (spec story 44), and this shell is not where either binary's
	// default belongs.
	o.rc.profile = transcript.DEFAULT_PROFILE

	for at := 0; at < len(arguments); at += 2 {
		name := arguments[at]
		if at + 1 >= len(arguments) {
			// Every option below takes a value, so a name standing at the end of
			// the command line is either one of them missing its value or not an
			// option at all -- and telling those apart here needs a second copy of
			// the switch below, which is a list that goes stale. So this says what
			// it saw, and the usage block beneath it names every option there is.
			// `--help` is the one flag that takes no value, and it is settled
			// before this loop runs.
			return {}, refuse("%q stands at the end of the command line with no value after it.", name)
		}
		if !read_option(&o, name, arguments[at + 1]) {
			return {}, false
		}
	}

	if len(o.json_path) == 0 {
		return {}, refuse("nothing to render.")
	}
	// The Recording's own name is what a reader goes looking for, but this binary
	// is handed the Engine's output and not the Recording. Naming the file it
	// really rendered from is the honest default; --source is how a caller who
	// knows the Recording's name says so.
	if len(o.rc.source_display) == 0 {
		o.rc.source_display = o.json_path
	}
	// What a Transcript records where nobody could settle it, applied AFTER the
	// loop and not before it. Set only before, `--model ""` and `--engine ""`
	// overwrote the word with an empty field and tripped the assertions above --
	// a command line crashing this binary, which is exactly what CLAUDE.md A8
	// forbids: a command line is outside this program and nothing outside it may
	// crash it. A caller who named nothing named nothing, however they spelled
	// it, and absent provenance beats wrong provenance (ADR-0003).
	if len(o.rc.model) == 0 {
		o.rc.model = transcript.UNKNOWN
	}
	if len(o.rc.engine_version) == 0 {
		o.rc.engine_version = transcript.UNKNOWN
	}
	return o, true
}

// Applies one option to what the command line has said so far, or says what is
// wrong with it.
//
// A procedure of its own so read_options stays inside CLAUDE.md rule F1 -- and
// because this is the list of what a caller may type, which is one thing, while
// the loop around it is the shape of a command line, which is another.
@(private)
read_option :: proc(o: ^Options, name, value: string) -> (ok: bool) {
	assert(o != nil, "there is nothing here to read an option into")

	// The empty name is REFUSED and never asserted against, by the arm at the
	// bottom of this switch like every other spelling this binary cannot read.
	// `transcibr-cli "$FLAG" "$VALUE"` with `$FLAG` unset is an ordinary shell
	// invocation, and the loop above hands `os.args[1:][at]` over untouched -- so
	// an empty name is what the CALLER typed, not this program's own doing, and
	// nothing outside this program may crash it (CLAUDE.md A8).
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
			return refuse("no merge profile called %q.", value)
		}
		o.rc.profile = profile
	case:
		return refuse("unknown option %q.", name)
	}
	return true
}

// Says what is wrong with the command line, and what one looks like.
//
// Every refusal above goes through here, so none of them can forget the usage
// block and none of them writes it to the wrong stream. It hands back `false`
// so a caller can refuse in the one line it took to notice.
@(private)
refuse :: proc(complaint: string, args: ..any) -> (ok: bool) {
	// The complaint is this program's own words and never the caller's, so an
	// empty one is a refusal site that forgot to say anything -- a blank line, the
	// usage block, and exit two, which tells a caller their command line is wrong
	// and nothing whatever about which part of it.
	assert(len(complaint) > 0, "refused a command line without saying what was wrong with it")

	fmt.eprintf(complaint, ..args)
	fmt.eprint("\n\n")
	write_usage(os.stderr)
	return false
}

// Writes the usage block.
//
// fprintln and not fprintfln: the block is a constant with the Merge Profiles
// already in it, so there is no verb to fill and nothing here allocates. A
// caller who asked for help is often a caller whose command line this binary
// could not read, and a refusal that allocated to explain itself is one more
// thing that can fail at the moment least worth failing at.
@(private)
write_usage :: proc(to: ^os.File) {
	assert(to != nil, "there is nowhere to write the usage block")

	fmt.fprintln(to, USAGE)
}
