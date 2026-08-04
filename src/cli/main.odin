// transcibr-cli — the console-subsystem binary: argument reading, one file read,
// one clock read, and a write. Nothing in this package is covered by a test and
// nothing in it can be (ADR-0009).
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "transcibr:artifact"
import "transcibr:transcript"
import "transcibr:version"

PROGRAM :: "transcibr-cli"

#assert(len(PROGRAM) > 0)

// Concatenated at COMPILE TIME and never printed through a verb: a usage block
// holds prose, prose eventually holds a per cent sign, and as a format string it
// reached a caller who asked for help as `%!c(MISSING)`.
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

  transcibr-cli --transcribe <recording> --model-file <path>
                --engine-exe <path> --cache <directory>
                [--profile ` +
	transcript.PROFILE_CHOICE +
	`] [--engine-version <version>]
                [--ffmpeg <path>] [--ffprobe <path>]
      transcribe one recording, write its transcript, its retained engine
      output and its sidecar beside the recording, and print the transcript's
      path. Spends GPU time.

  transcibr-cli --plan <folder> --model-file <path>
                [--profile ` +
	transcript.PROFILE_CHOICE +
	`] [--engine-version <version>] [--prompt <text>]
                [--follow-reparse-points yes]
      walk the folder and print what each recording found under it would get,
      and why. Spends no GPU time and writes nothing beside any recording.
      --engine-version left out means "not asked", not "unknown": a plan that
      cannot name its engine never reports the engine as having changed.

  transcibr-cli --help
      print this and exit.

--source, --model and --engine are what the transcript records about how it
was made. The engine's own output cannot settle them -- it carries no engine
version and reports every large model as "large" (ADR-0003) -- so anything
not given, or given empty, is recorded as "unknown" rather than guessed at.`

// The one thing this binary reads that takes no value, so the loop that pairs a
// name off with the argument after it cannot express it and it is answered before
// that loop runs.
HELP :: "--help"

// Two failures and not one: a command line the caller must fix, and a Recording's
// output that will not render, which is a file to go and look at.
USAGE_ERROR :: 2
OPERATING_ERROR :: 1

// Why this binary's own argv arrives mangled: ADR-0025, issue #35.
main :: proc() {
	assert(len(os.args) > 0, "a process started with no argv at all, not even its own name")

	if len(os.args) == 1 {
		print_version()
		return
	}
	if asks_for_help(os.args[1:]) {
		write_usage(os.stdout)
		return
	}
	if os.args[1] == TRANSCRIBE {
		os.exit(transcribe_one(os.args[1:]))
	}
	if os.args[1] == PLAN {
		os.exit(plan_batch(os.args[1:]))
	}
	os.exit(re_render(os.args[1:]))
}

print_version :: proc() {
	line := version.banner(PROGRAM, version.CURRENT, context.allocator)
	defer delete(line, context.allocator)

	assert(strings.has_prefix(line, PROGRAM), "banner does not name this program")
	assert(len(line) > len(PROGRAM), "banner carries no version after the program name")
	assert(line[len(PROGRAM)] == ' ', "banner does not separate the program name from the version")
	assert(strings.index_byte(line, '\n') == -1, "banner rendered more than one line")

	fmt.println(line)
}

Options :: struct {
	json_path: string,
	rc:        transcript.Render_Context,
}

re_render :: proc(arguments: []string) -> int {
	assert(
		len(arguments) > 0,
		"no arguments at all is the version banner, settled before this point",
	)

	options, ok := read_options(arguments)
	if !ok {
		return USAGE_ERROR
	}
	assert(len(options.json_path) > 0, "accepted a command line with nothing to render")

	json_bytes, read_err := os.read_entire_file_from_path(options.json_path, context.allocator)
	defer delete(json_bytes, context.allocator)
	if read_err != nil {
		fmt.eprintfln("%s: %v", options.json_path, read_err)
		return OPERATING_ERROR
	}
	json_text := string(json_bytes)

	rc := options.rc
	rc.now = time.now()
	rc.language = transcript.parse_language(json_text, context.allocator)
	defer delete(rc.language, context.allocator)

	return write_transcript(options.json_path, json_text, rc)
}

// The Recording's length is passed as nothing: this binary holds the Engine's
// output and no Recording, and a length invented from the Cues is the circular
// measurement ADR-0009 ruled out.
write_transcript :: proc(
	json_path: string,
	json_text: string,
	rc: transcript.Render_Context,
) -> int {
	assert(len(json_path) > 0, "a transcript must name the output it was rendered from")
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

// Scanned across the positions a NAME can stand in, stepping by two as
// read_options walks the same list: a scan of everything read `--from-json
// --help` as a request for usage and reported success on a render that never
// happened.
@(private)
asks_for_help :: proc(arguments: []string) -> bool {
	for at := 0; at < len(arguments); at += 2 {
		if arguments[at] == HELP {
			return true
		}
	}
	return false
}

read_options :: proc(arguments: []string) -> (o: Options, ok: bool) {
	defer if ok {
		assert(len(o.json_path) > 0, "accepted a command line with nothing to render")
		assert(len(o.rc.source_display) > 0, "accepted a command line that names no source")
		assert(len(o.rc.model) > 0, "a model nobody named is UNKNOWN, never empty")
		assert(len(o.rc.engine_version) > 0, "an engine nobody named is UNKNOWN, never empty")
	} else {
		assert(len(o.json_path) == 0, "refused a command line and kept what it asked for")
	}

	o.rc.profile = transcript.DEFAULT_PROFILE

	for at := 0; at < len(arguments); at += 2 {
		name := arguments[at]
		if at + 1 >= len(arguments) {
			return {}, refuse("%q stands at the end of the command line with no value after it.", name)
		}
		if !read_option(&o, name, arguments[at + 1]) {
			return {}, false
		}
	}

	if len(o.json_path) == 0 {
		return {}, refuse("nothing to render.")
	}
	if len(o.rc.source_display) == 0 {
		o.rc.source_display = o.json_path
	}
	if len(o.rc.model) == 0 {
		o.rc.model = transcript.UNKNOWN
	}
	if len(o.rc.engine_version) == 0 {
		o.rc.engine_version = transcript.UNKNOWN
	}
	return o, true
}

@(private)
read_option :: proc(o: ^Options, name, value: string) -> (ok: bool) {
	assert(o != nil, "there is nothing here to read an option into")

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

// The Model, identified once per run, with its refusal already reported. Both
// commands that spend a Model do exactly this and nothing else with the fault.
//
// The Model comes back either way and the CALLER frees it: destroying it has to
// be deferred where it is used and not where it was read, and a procedure that
// owned the defer would free it before the run that needs it.
@(private)
model_identified :: proc(path: string) -> (identified: artifact.Model, ok: bool) {
	assert(len(path) > 0, "there is no Model here to identify")

	unidentified: artifact.Model_Fault
	identified, unidentified = artifact.identify_model(path, context.allocator)
	if unidentified == .None {
		return identified, true
	}

	message := artifact.model_error_message(unidentified, path, context.allocator)
	defer delete(message, context.allocator)
	assert(len(message) > 0, "a Model was refused and nothing said why")
	fmt.eprintln(message)
	return identified, false
}

// Hands back `false` so a caller can refuse in the one line it took to notice.
@(private)
refuse :: proc(complaint: string, args: ..any) -> (ok: bool) {
	assert(len(complaint) > 0, "refused a command line without saying what was wrong with it")

	fmt.eprintf(complaint, ..args)
	fmt.eprint("\n\n")
	write_usage(os.stderr)
	return false
}

// fprintln and not fprintfln, so nothing here allocates: a refusal that allocated
// to explain itself is one more thing that can fail at the moment least worth
// failing at.
@(private)
write_usage :: proc(to: ^os.File) {
	assert(to != nil, "there is nowhere to write the usage block")

	fmt.fprintln(to, USAGE)
}
