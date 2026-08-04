package main

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "transcibr:audio"
import "transcibr:child"
import "transcibr:engine"
import "transcibr:process"

// The one command that spends GPU time: one Recording, end to end, into the
// Engine's output in a scratch cache. Every path -- ffmpeg's, the Engine's, the
// cache's -- is named on the command line, and nothing here resolves a tool.

Transcribe_Options :: struct {
	source: string,
	model:  string,
	engine: string,
	cache:  string,
	tools:  audio.Tools,
}

TRANSCRIBE :: "--transcribe"

// Bare names, which is what asks CreateProcessW to search PATH -- and safely,
// because argv[0] is always quoted by the Process contract. A bundled build names
// the paths instead.
FFMPEG :: "ffmpeg.exe"
FFPROBE :: "ffprobe.exe"

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
	return run_one(&group, o)
}

@(private)
run_one :: proc(group: ^child.Job_Object, o: Transcribe_Options) -> int {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(o.source) > 0, "there is no Recording here to transcribe")

	name := filepath.stem(o.source)
	if len(name) == 0 {
		fmt.eprintfln("%q: names no file to make artifacts from.", o.source)
		return OPERATING_ERROR
	}

	extracted, unextracted := extract_one(group, o, name)
	defer delete(extracted.audio, context.allocator)
	if unextracted.fault != .None {
		message := audio.error_message(unextracted, o.source, context.allocator)
		defer delete(message, context.allocator)
		fmt.eprintln(message)
		return OPERATING_ERROR
	}

	fmt.eprintfln("%s: %d ms of audio", name, extracted.container_ms)
	return transcribe_extracted(group, o, name, extracted)
}

@(private)
extract_one :: proc(
	group: ^child.Job_Object,
	o: Transcribe_Options,
	name: string,
) -> (
	produced: audio.Extracted,
	err: audio.Error,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(name) > 0, "a Recording with no artifact stem has nowhere to put its audio")
	defer if err.fault == .None {
		assert(len(produced.audio) > 0, "an extraction that came through produced no audio")
		assert(produced.container_ms > 0, "an extraction that came through timed nothing")
	}

	planned, unreadable := audio.read_source(o.source, context.allocator)
	if unreadable.fault != .None {
		return {}, unreadable
	}
	return audio.extract(
		group,
		o.tools,
		audio.Job{source = o.source, cache = o.cache, name = name, planned = planned},
		context.allocator,
	)
}

@(private)
transcribe_extracted :: proc(
	group: ^child.Job_Object,
	o: Transcribe_Options,
	name: string,
	extracted: audio.Extracted,
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
			model = o.model,
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
	fmt.println(produced.output)
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

@(private)
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

	o.tools = audio.Tools {
		ffmpeg  = FFMPEG,
		ffprobe = FFPROBE,
	}

	for at := 0; at < len(arguments); at += 2 {
		name := arguments[at]
		if at + 1 >= len(arguments) {
			return {}, refuse("%q stands at the end of the command line with no value after it.", name)
		}
		if !read_transcribe_option(&o, name, arguments[at + 1]) {
			return {}, false
		}
	}

	if len(o.tools.ffmpeg) == 0 {
		o.tools.ffmpeg = FFMPEG
	}
	if len(o.tools.ffprobe) == 0 {
		o.tools.ffprobe = FFPROBE
	}

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
	case:
		return refuse("unknown option %q.", name)
	}
	return true
}
