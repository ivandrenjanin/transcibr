#+vet explicit-allocators
package main

import "core:fmt"
import "core:os"
import "core:strings"
import "transcibr:artifact"
import "transcibr:audio"
import "transcibr:child"
import "transcibr:cliargs"
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

// A single pairing (audio.Tools's own two fields) instead of a seven-field
// hand copy: `using parsed: cliargs.Transcribe_Options` promotes source,
// model, engine, cache, prompt and profile straight through, so there is
// nothing left here to drop or swap by hand (fix round 1, PR #201 finding 3).
Transcribe_Options :: struct {
	using parsed: cliargs.Transcribe_Options,
	audio_tools:  audio.Tools,
}

@(require_results)
transcribe_one :: proc(arguments: []string) -> int {
	assert(len(arguments) > 0, "no arguments at all is the version banner, settled before this")

	parsed, parsed_ok, refusal := cliargs.read_transcribe_options(arguments)
	if !parsed_ok {
		_ = refuse_cliargs(refusal)
		return USAGE_ERROR
	}

	o := Transcribe_Options {
		parsed = parsed,
		audio_tools = audio.Tools{ffmpeg = parsed.tools.ffmpeg, ffprobe = parsed.tools.ffprobe},
	}
	audio.defaulted_tools(&o.audio_tools)

	group, opened := job_object_opened()
	defer child.job_object_close(&group)
	if !opened {
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

	engine_digest, engine_named := engine_identified(o.engine)
	defer delete(string(engine_digest), context.allocator)
	if !engine_named {
		return OPERATING_ERROR
	}
	return run_one(&group, o, identified, engine_digest)
}

@(private)
@(require_results)
run_one :: proc(
	group: ^child.Job_Object,
	o: Transcribe_Options,
	identified: artifact.Model,
	engine_digest: artifact.Digest,
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
		pipeline.Tools{audio = o.audio_tools, engine = engine.Tools{engine = o.engine}},
		o.cache,
		identified,
		o.prompt,
		string(engine_digest),
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

// The Refusal-consuming sibling ADR-0038 calls for (its refuse shape
// paragraph): fed a Refusal by value instead of a pre-built format string
// and inline `any` arguments, it feeds the identical `fmt.eprintf` path
// `refuse` below still uses for every other command's own reader, through
// two fixed backing arrays sized to `cliargs.MAX_REFUSAL_ARGS` and never an
// allocation -- `refuse`'s own arity stays untouched, and its 22 call sites
// stay exactly as they are (only `--transcribe`'s path is migrated here).
@(private)
@(require_results)
refuse_cliargs :: proc(r: cliargs.Refusal) -> (ok: bool) {
	assert(len(r.complaint) > 0, "refused a command line without saying what was wrong with it")
	assert(
		r.arg_count <= cliargs.MAX_REFUSAL_ARGS,
		"a refusal carries more arguments than refuse can print",
	)

	strs: [cliargs.MAX_REFUSAL_ARGS]string
	ints: [cliargs.MAX_REFUSAL_ARGS]int
	built: [cliargs.MAX_REFUSAL_ARGS]any
	for i in 0 ..< r.arg_count {
		switch v in r.args[i] {
		case string:
			strs[i] = v
			built[i] = strs[i]
		case int:
			ints[i] = v
			built[i] = ints[i]
		}
	}

	fmt.eprintf(r.complaint, ..built[:r.arg_count])
	fmt.eprint("\n\n")
	write_usage(os.stderr)
	return false
}

// `--model-file`, `--engine-exe`, `--cache`, `--ffmpeg`, `--ffprobe`,
// `--prompt` and `--profile`: what `--batch` still reads through this
// procedure. `--transcribe` reads the identical set through
// `cliargs.read_transcribe_options` now (ADR-0038 Stage 3); this reader
// stays because `--batch`'s own migration has not landed yet, and its last
// caller here is `read_batch_option`. There is no `--engine-version` case
// any more -- the version-string flag ADR-0027's supersession retires (issue
// #50); the Engine is identified from `--engine-exe`'s own bytes, the same
// as the Model, and a caller who still passes `--engine-version` is refused
// as an unknown option like any other retired flag. `--plan` shares only a
// few of these fields -- it names no scratch cache and no ffmpeg -- and
// keeps its own smaller switch rather than pass nil pointers through here
// for options its own grammar must still refuse (A8).
@(private)
@(require_results)
read_common_option :: proc(
	model: ^string,
	engine_exe: ^string,
	cache: ^string,
	tools: ^audio.Tools,
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
