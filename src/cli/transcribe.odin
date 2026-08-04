package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "transcibr:artifact"
import "transcibr:audio"
import "transcibr:child"
import "transcibr:engine"
import "transcibr:process"
import "transcibr:transcript"

// This file holds the one command that spends GPU time: it turns a single
// Recording into a Transcript and a Sidecar beside it, printing a percentage on
// the way.
//
// A WALKING PATH AND NOT THE PIPELINE. Issue #12 owns the Batch -- discovery,
// planning, resume, two extraction workers feeding one GPU worker through a
// bounded channel (ADR-0006) -- and none of that is here. What is here is one
// Recording, end to end, so that "one Recording in, Transcript and Sidecar out"
// is something a person can run rather than something a comment claims.
//
// THE TWO BATCH-LEVEL CHECKS HAPPEN HERE, ONCE, before anything starts: the
// scratch cache is opened and the Model is identified. Both are ADR-0002's
// `doctor` standing in for a `doctor` that does not exist yet (issue #13), both
// refuse in a vocabulary that names the DIRECTORY or the FILE rather than a
// Recording, and both stop this command rather than failing one Recording N
// times over.
//
// EVERY PATH IS NAMED ON THE COMMAND LINE, including ffmpeg's and the Engine's.
// Nothing here resolves a tool, chooses a cache directory or invents an artifact
// name beyond the source's own stem: bundling ffmpeg is ADR-0013's, fetching the
// Engine is ADR-0014's, the cache's location is the settings module's, and
// ADR-0008's injectivity check over artifact names belongs to planning. A shell
// that guessed any of them would be a second place those answers live.
//
// The same bill ADR-0009 spells out for the rest of this package applies: the
// sweep requires `src/cli` to collect zero tests, so nothing below is covered by
// one. Every decision it needs is next door and has a suite there -- the
// argument lists, the progress reading, the fallback, the watchdog, the
// annotation printed beside the percentage.

// What this command was asked to do.
Transcribe_Options :: struct {
	source:         string,
	model:          string,
	engine:         string,
	cache:          string,
	// What the Sidecar records about the Engine that ran (ADR-0003). The Engine's
	// own output cannot settle it -- it carries no version at all -- so anything
	// not given is recorded as `unknown` rather than guessed at.
	engine_version: string,
	// Which Merge Profile the Transcript is rendered under, which the Sidecar also
	// records: changing it is a change of settings, and one a re-render answers.
	profile:        transcript.Merge_Profile,
	tools:          audio.Tools,
}

// The name that starts this command, checked before the pairing loop that reads
// the rest.
TRANSCRIBE :: "--transcribe"

// Found on PATH rather than spelled absolutely, which is what a bare name asks
// CreateProcessW to do -- and safely, because argv[0] is always quoted by the
// Process contract. A caller with a bundled build names it instead.
FFMPEG :: "ffmpeg.exe"
FFPROBE :: "ffprobe.exe"

// Transcribes one Recording and says where the Engine's output landed.
//
// A8: everything below arrives from outside -- a command line, a Recording, a
// Model file, two tools -- so every refusal is a message and an exit code, and
// none of it reaches an assertion.
transcribe_one :: proc(arguments: []string) -> int {
	assert(len(arguments) > 0, "no arguments at all is the version banner, settled before this")

	o, ok := read_transcribe_options(arguments)
	if !ok {
		return USAGE_ERROR
	}

	// The kill switch every child is started into, opened once and closed last:
	// closing it terminates anything still in it, which is what stops an Engine
	// surviving this process with the Model resident in video memory (ADR-0004).
	group, opening := child.job_object_open()
	defer child.job_object_close(&group)
	if opening.fault != .None {
		reason := child.error_message(opening, context.allocator)
		defer delete(reason, context.allocator)
		fmt.eprintln(reason)
		return OPERATING_ERROR
	}

	// Once, before any Recording, and in the vocabulary that names the DIRECTORY
	// rather than a Recording: a cache that will not open has nowhere to put any
	// Recording's audio, so nothing starts.
	if refused := audio.open_cache(o.cache, context.allocator); refused != .None {
		message := audio.cache_error_message(refused, o.cache, context.allocator)
		defer delete(message, context.allocator)
		fmt.eprintln(message)
		return OPERATING_ERROR
	}

	// The Model, settled ONCE and before any GPU time: this both refuses a path
	// the Engine cannot open (ADR-0002) and produces the identity the Sidecar
	// records (ADR-0003). Hashing it costs a pass over a gigabyte-and-a-half file
	// and it is paid here rather than per Recording.
	identified, unidentified := artifact.identify_model(o.model, context.allocator)
	defer artifact.destroy_model(identified, context.allocator)
	if unidentified != .None {
		message := artifact.model_error_message(unidentified, o.model, context.allocator)
		defer delete(message, context.allocator)
		fmt.eprintln(message)
		return OPERATING_ERROR
	}
	return run_one(&group, o, identified)
}

// The two children, in order: ffmpeg for the audio, then the Engine -- and then
// the artifacts.
@(private)
run_one :: proc(
	group: ^child.Job_Object,
	o: Transcribe_Options,
	identified: artifact.Model,
) -> int {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(o.source) > 0, "there is no Recording here to transcribe")

	// The stem every artifact of this Recording is named from. `filepath.stem` and
	// not a scan written here: ADR-0008's rule is that the extension is replaced,
	// and the check that the mapping is injective is planning's -- over one
	// Recording there is no pair for it to be about.
	name := filepath.stem(o.source)
	if len(name) == 0 {
		fmt.eprintfln("%q: names no file to make artifacts from.", o.source)
		return OPERATING_ERROR
	}

	extracted, planned, unextracted := extract_one(group, o, name)
	defer delete(extracted.audio, context.allocator)
	if unextracted.fault != .None {
		message := audio.error_message(unextracted, o.source, context.allocator)
		defer delete(message, context.allocator)
		fmt.eprintln(message)
		return OPERATING_ERROR
	}

	fmt.eprintfln("%s: %d ms of audio", name, extracted.container_ms)
	return transcribe_extracted(group, o, name, extracted, planned, identified)
}

// The extraction, with the Recording read once so it can be checked for still
// being written to (spec story 52).
//
// THE READING IS HANDED BACK NOW, and it used to be discarded. It is what the
// Sidecar records about the Recording itself -- its size and its modification
// time (ADR-0003) -- and reading it a second time afterwards would record a
// different reading from the one the extraction was checked against.
@(private)
extract_one :: proc(
	group: ^child.Job_Object,
	o: Transcribe_Options,
	name: string,
) -> (
	produced: audio.Extracted,
	planned: audio.Reading,
	err: audio.Error,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(name) > 0, "a Recording with no artifact stem has nowhere to put its audio")
	// The read side (CLAUDE.md A4) of what `Extracted` promises on the way out,
	// checked here because this is where a caller starts believing it: the length
	// below is carried into the Engine and into the Sidecar, and a zero one would
	// make every duration comparison downstream agree with anything at all.
	defer if err.fault == .None {
		assert(len(produced.audio) > 0, "an extraction that came through produced no audio")
		assert(produced.container_ms > 0, "an extraction that came through timed nothing")
	}

	planned, err = audio.read_source(o.source, context.allocator)
	if err.fault != .None {
		return {}, {}, err
	}
	produced, err = audio.extract(
		group,
		o.tools,
		audio.Job{source = o.source, cache = o.cache, name = name, planned = planned},
		context.allocator,
	)
	return produced, planned, err
}

// The Engine itself, with the console display behind it.
@(private)
transcribe_extracted :: proc(
	group: ^child.Job_Object,
	o: Transcribe_Options,
	name: string,
	extracted: audio.Extracted,
	planned: audio.Reading,
	identified: artifact.Model,
) -> int {
	assert(len(extracted.audio) > 0, "there is no audio here for the Engine to read")
	assert(len(name) > 0, "a Recording with no artifact stem has nowhere to put its output")

	// The RESOLVED Model path, which is what identify_model settled and what the
	// Sidecar records: the Engine and the record must be about one file spelled
	// one way, or a re-run reports a Model change nobody made.
	produced, unfinished := engine.transcribe(
		group,
		engine.Tools{engine = o.engine},
		engine.Job {
			audio        = extracted.audio,
			cache        = o.cache,
			name         = name,
			model        = identified.path,
			// The container probe's answer and never the scratch audio's header,
			// which the type system already refuses: `Extracted.measured_ms` is a
			// distinct type and cannot be handed in here at all (spec).
			container_ms = extracted.container_ms,
		},
		engine.Report{on_progress = show},
		context.allocator,
	)
	defer delete(produced.output, context.allocator)

	// The display's last line is left where it was, so whatever comes next starts
	// on one of its own rather than half over a percentage.
	fmt.eprintln()
	if unfinished.fault != .None {
		message := engine.error_message(unfinished, o.source, context.allocator)
		defer delete(message, context.allocator)
		fmt.eprintln(message)
		return OPERATING_ERROR
	}

	// The read side (A4) of what `Transcribed` promises: everything below reads
	// this path, and an empty one would send the artifact placement looking at the
	// current directory.
	assert(len(produced.output) > 0, "a Recording that came through named no output at all")

	fmt.eprintfln("%s: %d ms as the Engine timed it", name, produced.duration_ms)
	return place_artifacts(o, produced.output, extracted, planned, identified)
}

// What the Engine left, validated and moved into place beside the Recording,
// with the Sidecar last (ADR-0002).
//
// NOTHING HERE DECIDES ANYTHING. The validation, the two dispositions, the
// atomic placement and the ordering are all `transcibr:artifact`'s, which has a
// suite; what is in this procedure is the Sidecar's contents, which is the shell
// saying what settings this run was made under.
@(private)
place_artifacts :: proc(
	o: Transcribe_Options,
	output: string,
	extracted: audio.Extracted,
	planned: audio.Reading,
	identified: artifact.Model,
) -> int {
	assert(len(output) > 0, "there is no Engine output here to make artifacts from")
	assert(extracted.container_ms > 0, "a Recording nobody could time reached the Sidecar")

	placed, unplaced := artifact.complete(
		o.source,
		output,
		transcript.Millis(extracted.container_ms),
		// The clock is read HERE, in the shell, which is the one place ADR-0009
		// allows it -- and the language is deliberately left out, because it is the
		// one front matter fact the Engine's own output can settle and `complete`
		// is what holds that output.
		transcript.Render_Context {
			now            = time.now(),
			source_display = o.source,
			engine_version = o.engine_version,
			// The Model's NAME in the front matter and its resolved PATH in the
			// Sidecar, which is the same distinction `--model` and `--model-file`
			// already draw in this binary. The front matter is read by a person, and
			// this file's own comment on those two options is about exactly this: a
			// Transcript recording `C:\models\...` as the model it was made with is
			// the thing nobody notices. What must be exact is the Sidecar, and that
			// carries the path and the hash.
			model          = model_named(identified.path),
			profile        = o.profile,
		},
		artifact.Sidecar {
			engine_version = o.engine_version,
			model = identified.path,
			model_digest = identified.digest,
			model_bytes = identified.bytes,
			beam = artifact.ENGINE_DEFAULT_BEAM,
			merge_profile = transcript.profile_name(o.profile),
			source_bytes = planned.bytes,
			source_modified_ns = planned.modified_ns,
			container_ms = extracted.container_ms,
		},
		context.allocator,
	)
	defer artifact.destroy_names(placed, context.allocator)

	if unplaced.fault != .None {
		message := artifact.error_message(unplaced, o.source, context.allocator)
		defer delete(message, context.allocator)
		fmt.eprintln(message)
		return OPERATING_ERROR
	}

	// The Transcript's path is this command's deliverable on standard output, and
	// the Sidecar's presence beside it is what says the Recording is finished.
	fmt.println(placed.transcript)
	return 0
}

// The Model as a reader would name it: the weights file's own stem.
//
// A path that somehow names no file answers UNKNOWN rather than an empty field,
// which is ADR-0003's rule and which the renderer refuses outright -- and
// `identify_model` resolved this path off a file it opened, so an empty stem
// here would be this program losing it rather than anything a user typed.
@(private)
model_named :: proc(path: string) -> string {
	assert(len(path) > 0, "there is no Model here to name")

	named := filepath.stem(path)
	if len(named) == 0 {
		return transcript.UNKNOWN
	}
	return named
}

// One reading of the progress display.
//
// A CARRIAGE RETURN AND NO NEWLINE, so the line is rewritten in place rather
// than a Recording leaving four hundred lines behind it. On STANDARD ERROR, so
// the deliverable this binary writes to standard output stays exactly the
// bytes a script asked for.
//
// The annotation comes from `transcibr:process` and is not spelled here, for the
// reason at the head of this file: nothing in this package can be held to
// account by a test, including a table that quietly went empty.
@(private)
show :: proc(shown: process.Progress, user: rawptr) {
	// The read side (A4) of what progress_says promises, checked where it is
	// printed: a newline in the annotation would end the line the carriage return
	// is about to rewrite, and one Recording would walk its progress down the
	// screen a reading at a time. Not a check on anything external -- the
	// annotation is transcibr's own constant.
	assert(
		strings.index_byte(process.progress_says(shown.from), '\n') < 0,
		"an annotation carrying a newline walks the display down the screen",
	)

	// NO WIDTH VERB ANYWHERE IN THIS LINE, and that is measured rather than
	// stylistic: Odin's `fmt` pads an integer's width with ZEROS and not spaces.
	// `%3d` of 0 prints `000`, and `%-3d` of 7 prints `700` -- so a padded
	// percentage does not read as a padded percentage, it reads as a different
	// number. This printed `transcribing 000%` at the start of a real run before
	// the padding came out.
	//
	// The trailing run of spaces is what a width would have bought: the reading
	// only ever grows, so the number cannot leave a digit behind, but the
	// annotation can go from eleven characters to none, and without this the
	// carriage return would leave the old one sitting after the new line.
	fmt.eprintf(
		"\r  transcribing %d%% %s            ",
		shown.percent,
		process.progress_says(shown.from),
	)
}

// Reads this command's own arguments.
//
// The same pair-stepping shape read_options uses next door -- a name and the
// value after it -- because every option here takes a value and `--transcribe`
// is the first of them.
@(private)
read_transcribe_options :: proc(arguments: []string) -> (o: Transcribe_Options, ok: bool) {
	// The write side of what run_one and the two procedures under it check on the
	// way in (A4), and the shape read_options next door already uses. Its negative
	// space is the other half: a refusal hands back nothing anybody should read,
	// and a caller that acted on a half-filled record would start ffmpeg against
	// a Recording it had already refused to accept.
	defer if ok {
		assert(len(o.source) > 0, "accepted a command line with no Recording to transcribe")
		assert(len(o.model) > 0, "accepted a command line naming no Model")
		assert(len(o.engine) > 0, "accepted a command line naming no Engine")
		assert(len(o.cache) > 0, "accepted a command line naming no scratch cache")
		assert(len(o.tools.ffmpeg) > 0, "accepted a command line that unset ffmpeg's own default")
		assert(
			len(o.tools.ffprobe) > 0,
			"accepted a command line that unset ffprobe's own default",
		)
		// The Sidecar refuses an empty field for the same reason the front matter
		// does: an empty one reads as transcibr forgetting, where the word for
		// nobody knowing reads as nobody knowing (ADR-0003).
		assert(len(o.engine_version) > 0, "an Engine nobody named is UNKNOWN, never empty")
	} else {
		assert(len(o.source) == 0, "refused a command line and kept what it asked for")
	}

	o.tools = audio.Tools {
		ffmpeg  = FFMPEG,
		ffprobe = FFPROBE,
	}
	// Read from the package that holds the profiles rather than spelled here as a
	// bare enum member: the window ADR-0004 promises has to produce the same bytes
	// from the same input (spec story 44), and this shell is not where either
	// binary's default belongs.
	o.profile = transcript.DEFAULT_PROFILE

	for at := 0; at < len(arguments); at += 2 {
		name := arguments[at]
		if at + 1 >= len(arguments) {
			return {}, refuse("%q stands at the end of the command line with no value after it.", name)
		}
		if !read_transcribe_option(&o, name, arguments[at + 1]) {
			return {}, false
		}
	}

	defaulted(&o)

	// Named one at a time rather than as "some options are missing", because a
	// caller who forgot one wants to be told which.
	for missing in ([?][2]string {
			{o.source, TRANSCRIBE},
			{o.model, "--model-file"},
			{o.engine, "--engine-exe"},
			{o.cache, "--cache"},
		}) {
		if len(missing[0]) == 0 {
			return {}, refuse("%s names nothing.", missing[1])
		}
	}
	return o, true
}

// Every default this command has, put back AFTER the loop that reads the command
// line and not only before it.
//
// THAT ORDER IS main.odin's OWN RECORDED BUG, applied here before it could be
// made again: `--ffmpeg ""` is an ordinary shell invocation with an unset
// variable in it, it overwrites the default with an empty path, and the
// assertions in read_transcribe_options would then be a COMMAND LINE crashing
// this binary -- which is precisely what CLAUDE.md rule A8 forbids. A caller who
// named nothing named nothing, however they spelled it.
//
// A procedure of its own so read_transcribe_options stays inside rule F1, and
// along the line that made the split honest: this is the list of what a caller
// gets for saying nothing, and the loop around it is the shape of a command
// line.
@(private)
defaulted :: proc(o: ^Transcribe_Options) {
	assert(o != nil, "there is nothing here to put a default into")
	// The write side of what read_transcribe_options asserts on the way out (A4),
	// stated where the values are actually settled: after this, no field that has
	// a default is empty, whatever the command line said.
	defer {
		assert(len(o.tools.ffmpeg) > 0, "a default that was put back is still empty")
		assert(len(o.tools.ffprobe) > 0, "a default that was put back is still empty")
		assert(len(o.engine_version) > 0, "a default that was put back is still empty")
	}

	if len(o.tools.ffmpeg) == 0 {
		o.tools.ffmpeg = FFMPEG
	}
	if len(o.tools.ffprobe) == 0 {
		o.tools.ffprobe = FFPROBE
	}
	// Absent provenance beats wrong provenance (ADR-0003), and `--engine-version
	// ""` is an ordinary shell invocation with an unset variable in it.
	if len(o.engine_version) == 0 {
		o.engine_version = transcript.UNKNOWN
	}
}

// Applies one of this command's options.
//
// `--model-file` and `--engine-exe` rather than `--model` and `--engine`, which
// this binary already reads as the two provenance fields a Transcript records
// (ADR-0003). One spelling meaning a path in one command and a NAME in another
// is the kind of thing nobody notices until a Transcript records `C:\models\...`
// as the model it was made with.
@(private)
read_transcribe_option :: proc(o: ^Transcribe_Options, name, value: string) -> (ok: bool) {
	assert(o != nil, "there is nothing here to read an option into")

	switch name {
	case TRANSCRIBE:
		o.source = value
	case "--model-file":
		o.model = value
	case "--engine-exe":
		o.engine = value
	case "--cache":
		o.cache = value
	case "--ffmpeg":
		o.tools.ffmpeg = value
	case "--ffprobe":
		o.tools.ffprobe = value
	case "--engine-version":
		o.engine_version = value
	case "--profile":
		profile, known := transcript.profile_named(value)
		if !known {
			return refuse("no merge profile called %q.", value)
		}
		o.profile = profile
	case:
		return refuse("unknown option %q.", name)
	}
	return true
}
