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
import "core:sync"
import "core:time"
import "transcibr:artifact"
import "transcibr:audio"
import "transcibr:child"
import "transcibr:doctor"
import "transcibr:engine"
import "transcibr:planning"
import "transcibr:transcript"

// The child executables a Batch names once, never resolved per Recording --
// `audio.Tools` and `engine.Tools` passed straight through to the two
// packages that actually spawn them, rather than unpacked into a third
// struct field-by-field, which is a silent-swap opportunity every time a
// caller builds one (PR #67's review, finding 6).
Tools :: struct {
	audio:  audio.Tools,
	engine: engine.Tools,
}

// The runtime half of ADR-0011's guard, threaded through every Recording_Job
// in a Batch so the ONE transcription Worker (ADR-0006) can check the first
// Recording it finishes and abort the rest. `checked` is read and written
// only from that single Worker, in strict sequence, so it needs no atomics of
// its own; `abort` is `sync.atomic_store`d because `run_batch`'s admission
// loop reads it from a different thread -- the identical `cancelled` flag a
// Ctrl+C press already sets (`src/cli/batch.odin`), reused rather than
// inventing a second way to stop a Batch early. Both nil is a real value:
// `--transcribe`'s Batch of one has no "first of several" to gate and no
// admission loop left to stop.
Health_Watch :: struct {
	checked: ^bool,
	abort:   ^bool,
}

// One Recording's share of a Batch: everything its two Stages need, borrowed
// from data the Batch itself outlives, plus the arena ADR-0010 asks for --
// created when this Job is built and destroyed by whichever Stage finishes
// it (extraction on failure, transcription either way, or the pipeline's own
// abandon/discard hooks when a Stage is never reached at all).
//
// `report` is the one field a Batch of many Recordings leaves at its zero
// value: several Recordings transcribing at once would tangle each other's
// carriage returns on one Terminal. `--transcribe`'s one-entry Batch is the
// exception -- it sets `on_progress` to watch the single Recording it owns.
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
	report:         engine.Report,
	health:         Health_Watch,
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

// One body for what `audio.error_message`, `engine.error_message` and
// `artifact.error_message` all hand back the same way: a message this
// procedure owns and must free. `/simplify`'s pass on PR #67 folded the three
// near-identical wrappers this used to be into their own call sites, which
// build the message and name which package's renderer built it.
@(private)
report_fault :: proc(message: string, allocator: mem.Allocator) {
	defer delete(message, allocator)
	fmt.eprintln(message)
}

@(require_results)
extract_recording :: proc(job: Recording_Job) -> (extracted: Recording_Extracted, ok: bool) {
	assert(job.arena != nil, "a Recording Job with no arena reached extraction")

	planned, unread := audio.read_source(job.source, job.allocator)
	if unread.fault != .None {
		report_fault(audio.error_message(unread, job.source, job.allocator), job.allocator)
		destroy_recording_arena(job)
		return {}, false
	}

	produced, unextracted := audio.extract(
		job.group,
		job.tools.audio,
		audio.Job{source = job.source, cache = job.cache, name = job.name, planned = planned},
		job.allocator,
	)
	if unextracted.fault != .None {
		report_fault(audio.error_message(unextracted, job.source, job.allocator), job.allocator)
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
		job.tools.engine,
		engine.Job {
			audio = extracted.extracted.audio,
			cache = job.cache,
			name = job.name,
			model = job.model.path,
			container_ms = extracted.extracted.container_ms,
			prompt = job.prompt,
		},
		job.report,
		job.allocator,
	)
	defer delete(produced.output, job.allocator)
	if job.report.on_progress != nil {
		fmt.eprintln()
	}
	if unfinished.fault != .None {
		report_fault(engine.error_message(unfinished, job.source, job.allocator), job.allocator)
		return false
	}
	checked_first_recording_health(job, extracted.extracted.container_ms, produced)
	return placed_from_engine_output(job, extracted, produced.output)
}

// Runs at most once per Batch, against whichever Recording is the first to
// finish transcribing successfully -- `job.health.checked` is this gate, and
// a Recording that fails before reaching here never sets it, so the check
// still runs against the first one that actually completes. A verdict this
// unhealthy does not fail THIS Recording, which already finished -- it stops
// the ones behind it, the same way ADR-0011 asks: abort the Batch rather
// than run overnight on the wrong device.
@(private)
checked_first_recording_health :: proc(
	job: Recording_Job,
	container_ms: i64,
	produced: engine.Transcribed,
) {
	assert(container_ms > 0, "a Recording nobody could time reached the health check")

	if job.health.checked == nil || job.health.checked^ {
		return
	}
	job.health.checked^ = true
	if produced.elapsed_ms <= 0 {
		return
	}

	json_bytes, unreadable := child.read_bounded(
		produced.output,
		child.READ_BOUND_MS,
		job.allocator,
	)
	if unreadable.fault != .None {
		return
	}
	defer delete(json_bytes, job.allocator)

	systeminfo := transcript.parse_systeminfo(string(json_bytes), job.allocator)
	defer delete(systeminfo, job.allocator)
	evidence := systeminfo
	if evidence == transcript.UNKNOWN {
		evidence = ""
	}

	factor := f64(container_ms) / f64(produced.elapsed_ms)
	fault := doctor.first_recording_health(evidence, factor, container_ms)
	if fault == .None {
		return
	}

	message := doctor.health_error_message(fault, factor, job.allocator)
	defer delete(message, job.allocator)
	fmt.eprintfln("%s: %s", job.source, message)
	if job.health.abort != nil {
		sync.atomic_store(job.health.abort, true)
	}
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
			model = artifact.model_display_name(job.model.path),
			profile = job.profile,
		},
		made,
		job.allocator,
	)
	defer artifact.destroy_names(placed, job.allocator)
	if unplaced.fault != .None {
		report_fault(artifact.error_message(unplaced, job.source, job.allocator), job.allocator)
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

// The derivation `src/cli` used to make ahead of planning, defaulting
// `Batch_Options.engine_version` to `transcript.UNKNOWN` before a flagless
// `--batch` ever reached `planning.plan_batch` -- the implicit string-to-
// `Maybe(string)` conversion at that call site then read as a NAMED Engine,
// so `planning.engine_of` compared the record against the literal word
// "unknown" instead of leaving the comparison to the record's own value
// (issue #70). Settling belongs here instead: after planning has already
// seen presence or absence exactly as `--plan` does, and only for the one
// string `recording_sidecar` actually writes.
@(require_results)
settled_engine_version :: proc(named: Maybe(string)) -> (version: string) {
	defer assert(len(version) > 0, "an Engine nobody named is UNKNOWN, never empty")

	if value, on_purpose := named.?; on_purpose {
		if len(value) > 0 {
			return value
		}
	}
	return transcript.UNKNOWN
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
	health:         Health_Watch,
}

// The one place a Recording_Job is actually built, for a Batch of many
// through `recording_job_of` below or for `--transcribe`'s Batch of one
// (`src/cli/transcribe.odin`) -- so the arena ADR-0010 asks for is opened
// the same way at both call sites and a mismatched `block_allocator` or
// `array_allocator` cannot drift between them.
@(require_results)
new_recording_job :: proc(
	source: string,
	name: string,
	group: ^child.Job_Object,
	tools: Tools,
	cache: string,
	model: artifact.Model,
	prompt: string,
	engine_version: string,
	profile: transcript.Merge_Profile,
	report: engine.Report,
	health: Health_Watch,
) -> Recording_Job {
	assert(len(source) > 0, "there is no Recording here to build a Job for")
	assert(len(name) > 0, "a Recording with no artifact stem has nowhere to put its output")

	arena := new(mem.Dynamic_Arena, runtime.heap_allocator())
	mem.dynamic_arena_init(
		arena,
		block_allocator = runtime.heap_allocator(),
		array_allocator = runtime.heap_allocator(),
	)

	return Recording_Job {
		source = source,
		name = name,
		group = group,
		tools = tools,
		cache = cache,
		model = model,
		prompt = prompt,
		engine_version = engine_version,
		profile = profile,
		report = report,
		health = health,
		arena = arena,
		allocator = mem.dynamic_arena_allocator(arena),
	}
}

@(private)
@(require_results)
recording_job_of :: proc(entry: planning.Entry, o: Batch_Options) -> Recording_Job {
	assert(len(entry.found.source) > 0, "there is no Recording here to build a Job for")

	return new_recording_job(
		entry.found.source,
		artifact.stem_of(entry.found.source),
		o.group,
		o.tools,
		o.cache,
		o.model,
		o.prompt,
		o.engine_version,
		o.profile,
		engine.Report{},
		o.health,
	)
}
