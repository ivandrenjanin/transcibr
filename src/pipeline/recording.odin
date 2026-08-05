#+vet explicit-allocators
package pipeline

// The Stages issue #12's pipeline actually runs against a folder of
// Recordings: extraction through transcibr:audio, transcription through
// transcibr:engine, and placement through transcibr:artifact, wired to
// run_batch's generic topology exactly the way topology_test.odin wires a
// pair of fakes to it.

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:path/filepath"
import "core:time"
import "transcibr:artifact"
import "transcibr:audio"
import "transcibr:child"
import "transcibr:engine"
import "transcibr:planning"
import "transcibr:transcript"

// The three child executables a Batch names once, never resolved per
// Recording.
Tools :: struct {
	ffmpeg:  string,
	ffprobe: string,
	engine:  string,
}

// One Recording's share of a Batch: everything its two Stages need, borrowed
// from data the Batch itself outlives, plus the arena ADR-0010 asks for --
// created when this Job is built and destroyed by whichever Stage finishes
// it (extraction on failure, transcription either way, or the pipeline's own
// abandon/discard hooks when a Stage is never reached at all).
Recording_Job :: struct {
	source:         string,
	name:           string,
	group:          ^child.Job_Object,
	tools:          Tools,
	cache:          string,
	model:          artifact.Model,
	prompt:         string,
	engine_version: string,
	profile:        transcript.Merge_Profile,
	arena:          ^mem.Dynamic_Arena,
	allocator:      mem.Allocator,
}

Recording_Extracted :: struct {
	job:       Recording_Job,
	extracted: audio.Extracted,
	planned:   audio.Reading,
}

@(private)
destroy_recording_arena :: proc(job: Recording_Job) {
	assert(job.arena != nil, "a Recording Job with no arena reached its own cleanup")

	mem.dynamic_arena_destroy(job.arena)
	free(job.arena, runtime.heap_allocator())
}

@(private)
report_audio_fault :: proc(source: string, err: audio.Error, allocator: mem.Allocator) {
	message := audio.error_message(err, source, allocator)
	defer delete(message, allocator)
	fmt.eprintln(message)
}

@(private)
report_engine_fault :: proc(source: string, err: engine.Error, allocator: mem.Allocator) {
	message := engine.error_message(err, source, allocator)
	defer delete(message, allocator)
	fmt.eprintln(message)
}

@(private)
report_artifact_fault :: proc(source: string, err: artifact.Error, allocator: mem.Allocator) {
	message := artifact.error_message(err, source, allocator)
	defer delete(message, allocator)
	fmt.eprintln(message)
}

@(require_results)
extract_recording :: proc(job: Recording_Job) -> (extracted: Recording_Extracted, ok: bool) {
	assert(job.arena != nil, "a Recording Job with no arena reached extraction")

	planned, unread := audio.read_source(job.source, job.allocator)
	if unread.fault != .None {
		report_audio_fault(job.source, unread, job.allocator)
		destroy_recording_arena(job)
		return {}, false
	}

	produced, unextracted := audio.extract(
		job.group,
		audio.Tools{ffmpeg = job.tools.ffmpeg, ffprobe = job.tools.ffprobe},
		audio.Job{source = job.source, cache = job.cache, name = job.name, planned = planned},
		job.allocator,
	)
	if unextracted.fault != .None {
		report_audio_fault(job.source, unextracted, job.allocator)
		destroy_recording_arena(job)
		return {}, false
	}
	return Recording_Extracted{job = job, extracted = produced, planned = planned}, true
}

@(require_results)
transcribe_and_place :: proc(extracted: Recording_Extracted) -> bool {
	job := extracted.job
	defer destroy_recording_arena(job)
	defer delete(extracted.extracted.audio, job.allocator)

	produced, unfinished := engine.transcribe(
		job.group,
		engine.Tools{engine = job.tools.engine},
		engine.Job {
			audio = extracted.extracted.audio,
			cache = job.cache,
			name = job.name,
			model = job.model.path,
			container_ms = extracted.extracted.container_ms,
		},
		engine.Report{},
		job.allocator,
	)
	defer delete(produced.output, job.allocator)
	if unfinished.fault != .None {
		report_engine_fault(job.source, unfinished, job.allocator)
		return false
	}
	return placed_from_engine_output(job, extracted, produced.output)
}

@(private)
@(require_results)
placed_from_engine_output :: proc(
	job: Recording_Job,
	extracted: Recording_Extracted,
	output: string,
) -> bool {
	made := recording_sidecar(job, extracted)
	placed, unplaced := artifact.complete(
		job.source,
		output,
		transcript.Millis(extracted.extracted.container_ms),
		transcript.Render_Context {
			now = time.now(),
			source_display = job.source,
			engine_version = job.engine_version,
			model = model_display_name(job.model.path),
			profile = job.profile,
		},
		made,
		job.allocator,
	)
	defer artifact.destroy_names(placed, job.allocator)
	if unplaced.fault != .None {
		report_artifact_fault(job.source, unplaced, job.allocator)
		return false
	}
	fmt.println(placed[.Transcript])
	return true
}

// The Sidecar this run actually earns -- ADR-0027's warning at `current_of`
// (src/planning/plan.odin), answered. Nothing here reads a Sidecar
// `planning` already recorded: every field is either what THIS Batch named
// (`engine_version`, `model`, `profile`, `prompt`) or what THIS run measured
// (`planned`, `extracted.container_ms`). A worker that reused the record's
// own Sidecar to write a fresh one would stamp the PREVIOUS Engine's version
// onto cues the currently installed one decoded -- the wrong provenance
// ADR-0003 forbids and ADR-0027 names by exact location. `recording_-`
// `sidecar_never_carries_a_stale_recorded_engine_version` in
// recording_test.odin is what pins this.
@(private)
@(require_results)
recording_sidecar :: proc(job: Recording_Job, extracted: Recording_Extracted) -> artifact.Sidecar {
	return artifact.sidecar_of(
		job.engine_version,
		job.model,
		artifact.ENGINE_DEFAULT_BEAM,
		transcript.profile_name(job.profile),
		job.prompt,
		extracted.planned.bytes,
		extracted.planned.modified_ns,
		extracted.extracted.container_ms,
	)
}

@(private)
@(require_results)
model_display_name :: proc(path: string) -> string {
	assert(len(path) > 0, "there is no Model here to name")

	named := filepath.stem(path)
	if len(named) == 0 {
		return transcript.UNKNOWN
	}
	return named
}

discard_recording_audio :: proc(extracted: Recording_Extracted) {
	delete(extracted.extracted.audio, extracted.job.allocator)
	destroy_recording_arena(extracted.job)
}

abandon_recording_job :: proc(job: Recording_Job) {
	destroy_recording_arena(job)
}

RECORDING_STAGES := Stages(Recording_Job, Recording_Extracted) {
	extract     = extract_recording,
	transcribe  = transcribe_and_place,
	discard     = discard_recording_audio,
	abandon_job = abandon_recording_job,
}

// Everything a Batch settles once, shared by every Recording it runs.
Batch_Options :: struct {
	group:          ^child.Job_Object,
	tools:          Tools,
	cache:          string,
	model:          artifact.Model,
	prompt:         string,
	engine_version: string,
	profile:        transcript.Merge_Profile,
	config:         Config,
}

@(private)
@(require_results)
recording_job_of :: proc(entry: planning.Entry, o: Batch_Options) -> Recording_Job {
	assert(len(entry.found.source) > 0, "there is no Recording here to build a Job for")

	arena := new(mem.Dynamic_Arena, runtime.heap_allocator())
	mem.dynamic_arena_init(
		arena,
		block_allocator = runtime.heap_allocator(),
		array_allocator = runtime.heap_allocator(),
	)

	return Recording_Job {
		source = entry.found.source,
		name = artifact.stem_of(entry.found.source),
		group = o.group,
		tools = o.tools,
		cache = o.cache,
		model = o.model,
		prompt = o.prompt,
		engine_version = o.engine_version,
		profile = o.profile,
		arena = arena,
		allocator = mem.dynamic_arena_allocator(arena),
	}
}
