#+vet explicit-allocators
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

// The one command that spends GPU time: one Recording, end to end, into a
// Transcript and a Sidecar beside it. Every path -- ffmpeg's, the Engine's, the
// cache's -- is named on the command line, and nothing here resolves a tool.

Transcribe_Options :: struct {
	source:         string,
	model:          string,
	engine:         string,
	cache:          string,
	engine_version: string,
	profile:        transcript.Merge_Profile,
	tools:          audio.Tools,
}

TRANSCRIBE :: "--transcribe"

// Bare names, which is what asks CreateProcessW to search PATH -- and safely,
// because argv[0] is always quoted by the Process contract. A bundled build names
// the paths instead.
FFMPEG :: "ffmpeg.exe"
FFPROBE :: "ffprobe.exe"

@(require_results)
transcribe_one :: proc(arguments: []string) -> int {
	assert(len(arguments) > 0, "no arguments at all is the version banner, settled before this")

	o, ok := read_transcribe_options(arguments)
	if !ok {
		return USAGE_ERROR
	}

	group, opening := child.job_object_open()
	defer child.job_object_close(&group)
	if opening.fault != .None {
		reason := child.error_message(opening, context.allocator)
		defer delete(reason, context.allocator)
		fmt.eprintln(reason)
		return OPERATING_ERROR
	}

	if refused := audio.open_cache(o.cache, context.allocator); refused != .None {
		message := audio.cache_error_message(refused, o.cache, context.allocator)
		defer delete(message, context.allocator)
		fmt.eprintln(message)
		return OPERATING_ERROR
	}

	identified, named := model_identified(o.model)
	defer artifact.destroy_model(identified, context.allocator)
	if !named {
		return OPERATING_ERROR
	}
	return run_one(&group, o, identified)
}

@(private)
@(require_results)
run_one :: proc(
	group: ^child.Job_Object,
	o: Transcribe_Options,
	identified: artifact.Model,
) -> int {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(o.source) > 0, "there is no Recording here to transcribe")

	name := artifact.stem_of(o.source)
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

@(private)
@(require_results)
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

@(private)
@(require_results)
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

	produced, unfinished := engine.transcribe(
		group,
		engine.Tools{engine = o.engine},
		engine.Job {
			audio = extracted.audio,
			cache = o.cache,
			name = name,
			model = identified.path,
			container_ms = extracted.container_ms,
		},
		engine.Report{on_progress = show},
		context.allocator,
	)
	defer delete(produced.output, context.allocator)

	fmt.eprintln()
	if unfinished.fault != .None {
		message := engine.error_message(unfinished, o.source, context.allocator)
		defer delete(message, context.allocator)
		fmt.eprintln(message)
		return OPERATING_ERROR
	}

	assert(len(produced.output) > 0, "a Recording that came through named no output at all")

	fmt.eprintfln("%s: %d ms as the Engine timed it", name, produced.duration_ms)
	return place_artifacts(o, produced.output, extracted, planned, identified)
}

@(private)
@(require_results)
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
		transcript.Render_Context {
			now = time.now(),
			source_display = o.source,
			engine_version = o.engine_version,
			model = model_named(identified.path),
			profile = o.profile,
		},
		artifact.sidecar_of(
			engine_version = o.engine_version,
			model = identified,
			beam = artifact.ENGINE_DEFAULT_BEAM,
			merge_profile = transcript.profile_name(o.profile),
			prompt = "",
			source_bytes = planned.bytes,
			source_modified_ns = planned.modified_ns,
			container_ms = extracted.container_ms,
		),
		context.allocator,
	)
	defer artifact.destroy_names(placed, context.allocator)

	if unplaced.fault != .None {
		message := artifact.error_message(unplaced, o.source, context.allocator)
		defer delete(message, context.allocator)
		fmt.eprintln(message)
		return OPERATING_ERROR
	}

	fmt.println(placed[.Transcript])
	return 0
}

@(private)
@(require_results)
model_named :: proc(path: string) -> string {
	assert(len(path) > 0, "there is no Model here to name")

	named := filepath.stem(path)
	if len(named) == 0 {
		return transcript.UNKNOWN
	}
	return named
}

// A carriage return and no newline, on standard error: the display rewrites
// itself in place, and the deliverable on standard output stays exactly the bytes
// a script asked for.
// See CLAUDE.md, Odin notes: core:fmt integer padding.
@(private)
show :: proc(shown: process.Progress, user: rawptr) {
	assert(
		strings.index_byte(process.progress_says(shown.from), '\n') < 0,
		"an annotation carrying a newline walks the display down the screen",
	)

	fmt.eprintf(
		"\r  transcribing %d%% %s            ",
		shown.percent,
		process.progress_says(shown.from),
	)
}

@(private)
@(require_results)
read_transcribe_options :: proc(arguments: []string) -> (o: Transcribe_Options, ok: bool) {
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
		assert(len(o.engine_version) > 0, "an Engine nobody named is UNKNOWN, never empty")
	} else {
		assert(len(o.source) == 0, "refused a command line and kept what it asked for")
	}

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

// Called AFTER the loop that reads the command line and not only before it:
// `--ffmpeg ""` is an ordinary shell invocation with an unset variable in it, and
// a default set only before the loop is overwritten by the empty value.
@(private)
defaulted :: proc(o: ^Transcribe_Options) {
	assert(o != nil, "there is nothing here to put a default into")
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
	if len(o.engine_version) == 0 {
		o.engine_version = transcript.UNKNOWN
	}
}

// `--model-file` and `--engine-exe`, because `--model` and `--engine` are already
// the provenance fields a Transcript records next door -- one spelling meaning a
// path here and a name there ends up recorded as the model it was made with.
@(private)
@(require_results)
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
