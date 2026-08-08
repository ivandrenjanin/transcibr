#+vet explicit-allocators
package main

import "core:fmt"
import "core:strings"
import "transcibr:artifact"
import "transcibr:audio"
import "transcibr:child"
import "transcibr:cliargs"
import "transcibr:engine"
import "transcibr:pipeline"
import "transcibr:process"

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
//
// Issue #75 Stage 6 ("two-tools convergence"): `transcribe_one` zeroes the
// promoted `tools` field right after `audio_tools` is built from it -- see
// `batch.odin`'s own `Batch_Options` comment for why.
Transcribe_Options :: struct {
	using parsed: cliargs.Transcribe_Options,
	audio_tools:  audio.Tools,
}

// Issue #216, item 1: `--transcribe` used to identify the Engine through
// `main.odin`'s shared `engine_identified`, which built its refusal by
// calling `artifact.engine_error_message` with no framing of its own -- so
// an unreadable Engine told a `--transcribe` user "the Batch cannot start"
// when no Batch was ever asked for (measured byte-identical to merge-base at
// the #237 review). Below `engine_identified_framed` (src/cli/engine_identify.odin)
// is called with `--transcribe`'s own framing rather than inheriting the
// Batch's. `main.odin` is fenced under #75-s5b, so this reuses a second call
// site rather than a parameter added to the shared one.
TRANSCRIBE_ENGINE_REFUSAL_FRAMING :: "--transcribe cannot verify this Engine"

// Fix round 1 (PR #245's review, finding 1): `transcribe_one` opens the
// scratch cache before it ever touches the Engine, and that refusal told the
// user "the Batch cannot start" too -- issue #216's headline defect, in this
// same file, one line from `TRANSCRIBE_ENGINE_REFUSAL_FRAMING` above. Named
// the same way: `--transcribe cannot <verb> this <noun>`.
TRANSCRIBE_CACHE_REFUSAL_FRAMING :: "--transcribe cannot open this cache"

// Fix round 2 (PR #245's review): the Model refusal below used to call
// `main.odin`'s shared, unparametrized `model_identified`, which always
// reported "the Batch cannot start" -- issue #216's own headline defect,
// live on `--transcribe`. Named the same way as the framings above.
TRANSCRIBE_MODEL_REFUSAL_FRAMING :: "--transcribe cannot verify this Model"

@(require_results)
transcribe_one :: proc(arguments: []string) -> int {
	assert(len(arguments) > 0, "no arguments at all is the version banner, settled before this")

	parsed, parsed_ok, refusal := cliargs.read_transcribe_options(arguments)
	if !parsed_ok {
		_ = refuse(refusal)
		return USAGE_ERROR
	}

	o := Transcribe_Options {
		parsed      = parsed,
		audio_tools = audio_tools_of(parsed.tools),
	}
	o.tools = {}
	audio.defaulted_tools(&o.audio_tools)
	assert(
		len(o.audio_tools.ffmpeg) > 0,
		"accepted a command line that unset ffmpeg's own default",
	)
	assert(
		len(o.audio_tools.ffprobe) > 0,
		"accepted a command line that unset ffprobe's own default",
	)

	group, opened := job_object_opened()
	defer child.job_object_close(&group)
	if !opened {
		return OPERATING_ERROR
	}

	if refused := audio.open_cache(o.cache, context.allocator); refused != .None {
		pipeline.report_fault(
			pipeline.FAULT_OBSERVER,
			.Failed,
			-1,
			audio.cache_error_message(
				refused,
				o.cache,
				context.allocator,
				TRANSCRIBE_CACHE_REFUSAL_FRAMING,
			),
			context.allocator,
		)
		return OPERATING_ERROR
	}

	identified, named := model_identified_framed(o.model, TRANSCRIBE_MODEL_REFUSAL_FRAMING)
	defer artifact.destroy_model(identified, context.allocator)
	if !named {
		return OPERATING_ERROR
	}

	engine_digest, engine_named := engine_identified_framed(
		o.engine,
		TRANSCRIBE_ENGINE_REFUSAL_FRAMING,
	)
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

	gpu_health_checked, gpu_health_abort, gpu_health_unhealthy := false, false, false
	health := pipeline.Health_Watch {
		checked   = &gpu_health_checked,
		abort     = &gpu_health_abort,
		unhealthy = &gpu_health_unhealthy,
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
		health,
		pipeline.FAULT_OBSERVER,
	)
	assert(
		job.health != pipeline.Health_Watch{},
		"a single Recording is its own first Recording (#113) -- the watch it runs under must not be empty",
	)

	extracted, extracted_ok := pipeline.extract_recording(job)
	if !extracted_ok {
		return OPERATING_ERROR
	}
	fmt.eprintfln("%s: %d ms of audio", name, extracted.extracted.container_ms)

	if !pipeline.transcribe_and_place(extracted) {
		return OPERATING_ERROR
	}
	if gpu_health_unhealthy {
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
