#+vet explicit-allocators
package main

import "core:fmt"
import "core:strings"
import "transcibr:artifact"
import "transcibr:audio"
import "transcibr:child"
import "transcibr:engine"
import "transcibr:pipeline"
import "transcibr:process"
import "transcibr:transcript"

// The one command that spends GPU time: one Recording, end to end, into a
// Transcript and a Sidecar beside it. Every path -- ffmpeg's, the Engine's, the
// cache's -- is named on the command line, and nothing here resolves a tool.
// `run_one` builds `--transcribe`'s Batch of one and runs it through
// `transcibr:pipeline`'s two Stages -- the same extraction, transcription and
// placement `--batch` runs many of, so a Recording transcribed on either
// command line is recorded from the same code (PR #67's review, finding 1).

Transcribe_Options :: struct {
	source:         string,
	model:          string,
	engine:         string,
	cache:          string,
	engine_version: Maybe(string),
	prompt:         string,
	profile:        transcript.Merge_Profile,
	tools:          audio.Tools,
}

TRANSCRIBE :: "--transcribe"

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
		pipeline.report_fault(child.error_message(opening, context.allocator), context.allocator)
		return OPERATING_ERROR
	}

	if refused := audio.open_cache(o.cache, context.allocator); refused != .None {
		pipeline.report_fault(
			audio.cache_error_message(refused, o.cache, context.allocator),
			context.allocator,
		)
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

	job := pipeline.new_recording_job(
		o.source,
		name,
		group,
		pipeline.Tools{audio = o.tools, engine = engine.Tools{engine = o.engine}},
		o.cache,
		identified,
		o.prompt,
		pipeline.settled_engine_version(o.engine_version),
		o.profile,
		engine.Report{on_progress = show},
		pipeline.Health_Watch{},
	)

	extracted, extracted_ok := pipeline.extract_recording(job)
	if !extracted_ok {
		return OPERATING_ERROR
	}
	fmt.eprintfln("%s: %d ms of audio", name, extracted.extracted.container_ms)

	if !pipeline.transcribe_and_place(extracted) {
		return OPERATING_ERROR
	}
	return 0
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

// `audio.defaulted_tools` runs AFTER the loop below, not before it:
// `--ffmpeg ""` is an ordinary shell invocation with an unset variable in it,
// and a default set only before the loop is overwritten by the empty value.
// `engine_version` is never defaulted here at all -- it stays `Maybe(string)`,
// absent where the command line named none, and forwarded that way into
// planning, where `pipeline.settled_engine_version` is what decides UNKNOWN,
// and only for the Sidecar this run actually records (issue #70).
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

	audio.defaulted_tools(&o.tools)

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

// `--model-file` and `--engine-exe`, because `--model` and `--engine` are already
// the provenance fields a Transcript records next door -- one spelling meaning a
// path here and a name there ends up recorded as the model it was made with.
//
// `--transcribe`'s own case is TRANSCRIBE alone; everything else falls
// through to `read_common_option`, the grammar `--batch` reads the identical
// way (PR #67's review, finding 2).
@(private)
@(require_results)
read_transcribe_option :: proc(o: ^Transcribe_Options, name, value: string) -> (ok: bool) {
	assert(o != nil, "there is nothing here to read an option into")

	switch name {
	case TRANSCRIBE:
		o.source = value
	case:
		return read_common_option(
			&o.model,
			&o.engine,
			&o.cache,
			&o.tools,
			&o.engine_version,
			&o.prompt,
			&o.profile,
			name,
			value,
		)
	}
	return true
}

// `--model-file`, `--engine-exe`, `--cache`, `--ffmpeg`, `--ffprobe`,
// `--engine-version`, `--prompt` and `--profile`: the whole of what
// `--transcribe` and `--batch` read identically, once `--prompt` closed PR
// #67's review finding 1 and made the two grammars agree on an eighth case
// as well as the first seven. `--plan` shares only a few of these fields --
// it names no Engine path, no scratch cache and no ffmpeg -- and keeps its
// own smaller switch rather than pass nil pointers through here for options
// its own grammar must still refuse (A8).
@(private)
@(require_results)
read_common_option :: proc(
	model: ^string,
	engine_exe: ^string,
	cache: ^string,
	tools: ^audio.Tools,
	engine_version: ^Maybe(string),
	prompt: ^string,
	profile: ^transcript.Merge_Profile,
	name: string,
	value: string,
) -> (
	ok: bool,
) {
	assert(model != nil, "there is nowhere here to read a Model path into")
	assert(engine_exe != nil, "there is nowhere here to read an Engine path into")

	switch name {
	case "--model-file":
		model^ = value
	case "--engine-exe":
		engine_exe^ = value
	case "--cache":
		cache^ = value
	case "--ffmpeg":
		tools.ffmpeg = value
	case "--ffprobe":
		tools.ffprobe = value
	case "--engine-version":
		engine_version^ = value
	case "--prompt":
		prompt^ = value
	case "--profile":
		named, known := transcript.profile_named(value)
		if !known {
			return refuse("no merge profile called %q.", value)
		}
		profile^ = named
	case:
		return refuse("unknown option %q.", name)
	}
	return true
}
