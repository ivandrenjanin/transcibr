#+vet explicit-allocators
// transcibr-cli — the console-subsystem binary: argument reading, one file read,
// one clock read, and a write. Nothing in this package is covered by a test and
// nothing in it can be (ADR-0009).
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "transcibr:artifact"
import "transcibr:audio"
import "transcibr:child"
import "transcibr:cliargs"
import "transcibr:crashlog"
import "transcibr:pipeline"
import "transcibr:process"
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
	`] [--prompt <text>]
                [--ffmpeg <path>] [--ffprobe <path>]
      transcribe one recording, write its transcript, its retained engine
      output and its sidecar beside the recording, and print the transcript's
      path. Spends GPU time.

  transcibr-cli --plan <folder> --model-file <path> --engine-exe <path>
                [--profile ` +
	transcript.PROFILE_CHOICE +
	`] [--prompt <text>]
                [--follow-reparse-points ` +
	cliargs.FOLLOW_CHOICE +
	`]
      walk the folder and print what each recording found under it would get,
      and why. Spends no GPU time and writes nothing beside any recording.
      The engine is identified by hashing --engine-exe, the same way the
      model is: a recorded transcript made with a since-replaced engine
      binary is reported as changed even though its path is unchanged.

  transcibr-cli --batch <folder> --model-file <path>
                --engine-exe <path> --cache <directory>
                [--profile ` +
	transcript.PROFILE_CHOICE +
	`] [--prompt <text>]
                [--follow-reparse-points ` +
	cliargs.FOLLOW_CHOICE +
	`] [--ffmpeg <path>] [--ffprobe <path>]
                [--extract-workers <n>] [--queue-depth <n>]
      transcribe every recording under the folder that needs it, resuming
      what an earlier run already finished. One or two extraction workers
      feed exactly one transcription worker through a bounded queue, so the
      GPU is never idle waiting on disk and never runs two transcriptions at
      once. Ctrl+C stops admitting new recordings; whatever the queue already
      holds still finishes. Spends GPU time.

  transcibr-cli --doctor --model-file <path> --engine-exe <path>
                [--ffmpeg <path>] [--ffprobe <path>]
      check that ffmpeg, ffprobe, the engine and the model are actually
      usable before a batch spends any of them, and print a gpu diagnostic.
      Actually spawns the engine and loads the model through it rather than
      checking that their files exist, so it spends a few seconds of GPU
      time. The model is skipped, never failed, where the engine check did
      not pass. Exits nonzero if any check failed.

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

// Why this binary cannot read `os.args`: ADR-0025, issue #35 -- Odin's Windows
// entry point hands `main` the C runtime's ANSI argv, which has already lost
// any byte outside the system code page by the time it gets here. The fix is
// `process.process_argv`: `GetCommandLineW` plus `CommandLineToArgvW`, the same
// route ffmpeg takes and ADR-0025 names as what retires the wrong-reason
// refusal. `src/cli` carries no test (ADR-0009); `process.process_argv` and
// the parser under it are what `src/process/command_line_test.odin` covers.
//
// Crash capture (issue #76) installs here, before anything else can assert
// or fault, and inline rather than through a helper: Odin's implicit
// `context` propagates forward into what a scope calls next, never back out
// of a call that already returned, so `context.assertion_failure_proc =
// crashlog.assertion_hook` set inside a helper `main` merely called would
// vanish the moment that helper returned. The SAME rule is why that
// assignment sits at `main`'s own top level rather than inside the `if` that
// decides whether the log actually opened: a block is a scope too, so an
// assignment written inside the `if`'s braces reverts the instant that block
// closes and `main`'s own copy of the context never carries the hook at all
// (fix round 5, issue #76's PR #166). Setting the hook unconditionally means
// `assertion_hook` has to tolerate a log that never opened --
// `hooks.odin`'s `assertion_hook` skips the write rather than asserting on a
// closed handle, and still mirrors the failure to stderr. Best-effort and
// silent either way (spec story 57: nothing here phones home, and a machine
// with no usable %LOCALAPPDATA% still has to transcribe recordings).
// `--crash-drill` installs a second time, over the directory it was given --
// the second call just overwrites where the exception filter points.
main :: proc() {
	args, acquired := process.process_argv(context.allocator)
	assert(acquired, "the operating system did not hand this process its own command line")
	assert(len(args) > 0, "a process started with no argv at all, not even its own name")

	crash_dir, crash_dir_ok := crashlog.default_directory(context.allocator)
	if crash_dir_ok {
		_ = crashlog.install(crash_dir, context.allocator)
	}
	context.assertion_failure_proc = crashlog.assertion_hook

	if len(args) == 1 {
		print_version()
		return
	}
	if asks_for_help(args[1:]) {
		write_usage(os.stdout)
		return
	}
	if args[1] == cliargs.TRANSCRIBE {
		os.exit(transcribe_one(args[1:]))
	}
	if args[1] == cliargs.PLAN {
		os.exit(plan_batch(args[1:]))
	}
	if args[1] == cliargs.BATCH {
		os.exit(run_batch_command(args[1:]))
	}
	if args[1] == cliargs.DOCTOR {
		os.exit(run_doctor(args[2:]))
	}
	if args[1] == CRASH_DRILL {
		os.exit(run_crash_drill(args[2:]))
	}
	os.exit(re_render(args[1:]))
}


print_version :: proc() {
	line := version.banner(PROGRAM, version.CURRENT, context.allocator)

	assert(strings.has_prefix(line, PROGRAM), "banner does not name this program")
	assert(len(line) > len(PROGRAM), "banner carries no version after the program name")
	assert(line[len(PROGRAM)] == ' ', "banner does not separate the program name from the version")
	assert(strings.index_byte(line, '\n') == -1, "banner rendered more than one line")

	pipeline.report_line(line, context.allocator)
}

// `--from-json` is typed, pasted or scripted, so `options.json_path` is the
// one path this whole binary opens that it did not construct itself --
// including a reserved Windows device name such as `CON`, which opens fine
// and then reads forever even with stdin from the null device. The read is
// bounded for exactly that reason (issue #27); `child.READ_BOUND_MS` is the
// same ceiling `transcibr-cli --transcribe` reads the Engine's own output
// under.
//
// Issue #75 Stage 6 (the contraction): `--from-json`'s grammar (the old
// `Options`, `read_options`, `read_option`) moved to
// `cliargs.Render_Options`/`cliargs.read_render_options`, the fifth and last
// of ADR-0038's migration sites. Nothing left here decides anything --
// `render_context_of` below is a field-for-field copy from what the grammar
// already settled, never a second place `--source`, `--model` or `--engine`
// could be defaulted differently than `src/cliargs` already did.
@(require_results)
re_render :: proc(arguments: []string) -> int {
	assert(
		len(arguments) > 0,
		"no arguments at all is the version banner, settled before this point",
	)

	options, ok, refusal := cliargs.read_render_options(arguments)
	if !ok {
		_ = refuse(refusal.complaint, refusal.args[:refusal.arg_count])
		return USAGE_ERROR
	}
	assert(len(options.json_path) > 0, "accepted a command line with nothing to render")

	json_bytes, read_err := child.read_bounded(
		options.json_path,
		child.READ_BOUND_MS,
		context.allocator,
	)
	defer delete(json_bytes, context.allocator)
	if read_err.fault != .None {
		pipeline.report_fault(
			child.read_error_message(read_err, options.json_path, context.allocator),
			context.allocator,
		)
		return OPERATING_ERROR
	}
	json_text := string(json_bytes)

	rc := render_context_of(options)
	rc.now = time.now()
	rc.language = transcript.parse_language(json_text, context.allocator)
	defer delete(rc.language, context.allocator)

	return write_transcript(options.json_path, json_text, rc)
}

// Plumbing, not a decision: every field here was already settled by
// `cliargs.read_render_options` (the source fallback, the model/engine
// "unknown" settling) -- this only reshapes the grammar's own verdict into
// the wider `transcript.Render_Context` `write_transcript` takes, which also
// carries `now` and `language`, neither of which the grammar could settle
// (issue #27, ADR-0038's own "what stays in src/cli" list: model and engine
// identification I/O and pipeline wiring, not grammar).
@(private)
@(require_results)
render_context_of :: proc(o: cliargs.Render_Options) -> transcript.Render_Context {
	assert(len(o.json_path) > 0, "a render context was built from nothing to render")
	assert(len(o.source) > 0, "a render context was built with no source settled")
	assert(len(o.model) > 0, "a render context was built with no model settled")
	assert(len(o.engine) > 0, "a render context was built with no engine settled")

	rc: transcript.Render_Context
	rc.source_display = o.source
	rc.model = o.model
	rc.engine_version = o.engine
	rc.profile = o.profile
	return rc
}

// The Recording's length is passed as nothing: this binary holds the Engine's
// output and no Recording, and a length invented from the Cues is the circular
// measurement ADR-0009 ruled out.
@(require_results)
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
		pipeline.report_fault(transcript.error_message(err, context.allocator), context.allocator)
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
@(require_results)
asks_for_help :: proc(arguments: []string) -> bool {
	for at := 0; at < len(arguments); at += 2 {
		if arguments[at] == HELP {
			return true
		}
	}
	return false
}

// The Model, identified once per run, with its refusal already reported. Both
// commands that spend a Model do exactly this and nothing else with the fault.
//
// The Model comes back either way and the CALLER frees it: destroying it has to
// be deferred where it is used and not where it was read, and a procedure that
// owned the defer would free it before the run that needs it.
@(private)
@(require_results)
model_identified :: proc(path: string) -> (identified: artifact.Model, ok: bool) {
	assert(len(path) > 0, "there is no Model here to identify")

	unidentified: artifact.Model_Fault
	identified, unidentified = artifact.identify_model(path, context.allocator)
	if unidentified == .None {
		return identified, true
	}

	message := artifact.model_error_message(unidentified, path, context.allocator)
	assert(len(message) > 0, "a Model was refused and nothing said why")
	pipeline.report_fault(message, context.allocator)
	return identified, false
}

// The Engine, identified by its own SHA-256 once per run, exactly like the
// Model above -- ADR-0027's reopening clause, closed by issue #50. Every
// command that spends an Engine (`--transcribe`, `--plan`, `--batch`) does
// this and nothing else with the fault: an unreadable Engine binary is
// reported against that file and the run stops (A8), never a silent
// `unknown`. The caller frees the digest with `delete`, same as a Model's.
@(private)
@(require_results)
engine_identified :: proc(path: string) -> (identified: artifact.Digest, ok: bool) {
	assert(len(path) > 0, "there is no Engine here to identify")

	unidentified: artifact.Engine_Fault
	identified, unidentified = artifact.identify_engine(path, context.allocator)
	if unidentified == .None {
		return identified, true
	}

	message := artifact.engine_error_message(unidentified, path, context.allocator)
	assert(len(message) > 0, "an Engine was refused and nothing said why")
	pipeline.report_fault(message, context.allocator)
	return identified, false
}

// The shared Job Object every command that spawns children opens, with its
// refusal already reported (issue #119: transcribe_one, run_batch_command and
// run_doctor each hand-copied this open/report/return shape). The caller
// still writes its own `defer child.job_object_close(&group)`: the object has
// to outlive this procedure, the same reason `transcibr:child`'s own test
// helper's does (child_test.odin's open_group).
@(private)
@(require_results)
job_object_opened :: proc() -> (group: child.Job_Object, ok: bool) {
	defer assert(
		ok == (group.handle != nil),
		"a Job Object's ok must agree with whether its handle is live",
	)

	opened, opening := child.job_object_open()
	if opening.fault == .None {
		return opened, true
	}
	pipeline.report_fault(child.error_message(opening, context.allocator), context.allocator)
	return opened, false
}

// Issue #75 Stage 6 (the contraction): the ADR-0038 refuse-shape paragraph's
// own letter -- `refuse(complaint: string, args: []Refusal_Arg) -> bool`,
// taking the union slice directly rather than a pre-built `[]any` -- adopted
// here in place of the two siblings expand-contract had left standing: this
// procedure's own former `..any` form (which every src/cliargs-backed
// command had already stopped calling) and `refuse_cliargs`
// (`transcribr.odin`), which existed only because this one had not yet made
// the move. `refuse_cliargs` is deleted; every one of its five call sites
// and every one of `refuse`'s surviving three (`crash_drill.odin`) now
// reach this same procedure. Nothing here allocates: `strs`, `ints` and
// `built` are fixed arrays on this call's own stack, sized to
// `cliargs.MAX_REFUSAL_ARGS`, and the `any` values `fmt.eprintf` receives
// point at them and never at `args`' own backing bytes.
@(private)
@(require_results)
refuse :: proc(complaint: string, args: []cliargs.Refusal_Arg) -> (ok: bool) {
	assert(len(complaint) > 0, "refused a command line without saying what was wrong with it")
	assert(
		len(args) <= cliargs.MAX_REFUSAL_ARGS,
		"a refusal carries more arguments than refuse can print",
	)

	strs: [cliargs.MAX_REFUSAL_ARGS]string
	ints: [cliargs.MAX_REFUSAL_ARGS]int
	built: [cliargs.MAX_REFUSAL_ARGS]any
	for arg, i in args {
		switch v in arg {
		case string:
			strs[i] = v
			built[i] = strs[i]
		case int:
			ints[i] = v
			built[i] = ints[i]
		}
	}

	fmt.eprintf(complaint, ..built[:len(args)])
	fmt.eprint("\n\n")
	write_usage(os.stderr)
	return false
}

// The third copy of `audio.Tools{ffmpeg = ..., ffprobe = ...}` this package
// carried (s5b review deposit 7): `--batch`, `--doctor` and `--transcribe`
// each built one by hand from their own `parsed.tools`. One shared
// procedure, called from all three.
@(private)
@(require_results)
audio_tools_of :: proc(tools: cliargs.Tools) -> audio.Tools {
	return audio.Tools{ffmpeg = tools.ffmpeg, ffprobe = tools.ffprobe}
}

// fprintln and not fprintfln, so nothing here allocates: a refusal that allocated
// to explain itself is one more thing that can fail at the moment least worth
// failing at.
@(private)
write_usage :: proc(to: ^os.File) {
	assert(to != nil, "there is nowhere to write the usage block")

	fmt.fprintln(to, USAGE)
}
