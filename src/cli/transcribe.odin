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

// The Refusal-consuming sibling ADR-0038 calls for (its refuse shape
// paragraph): fed a Refusal by value instead of a pre-built format string
// and inline `any` arguments, it feeds the identical `fmt.eprintf` path
// `refuse` (main.odin) still uses for every other command's own reader,
// through two fixed backing arrays sized to `cliargs.MAX_REFUSAL_ARGS` and
// never an allocation -- `refuse`'s own arity stays untouched. Its own call
// sites number 15 on this tree (deposit #3 of the stage-3 review, PR #201,
// already found the ADR's original "22" stale at 20; this stage's batch
// migration retires `read_common_option`'s two and `read_batch_option`'s
// family of five, leaving `--plan` (5), `main`'s `--from-json` (4) and
// `--crash-drill` (3), plus `--doctor`'s own 3) -- `--plan` and `--doctor`
// are this ticket's remaining migration sites (#75), not this one's.
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
