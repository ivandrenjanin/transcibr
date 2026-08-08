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
import "core:os"
import "core:sync"
import "core:time"
import "transcibr:artifact"
import "transcibr:audio"
import "transcibr:child"
import "transcibr:doctor"
import "transcibr:engine"
import "transcibr:planning"
import "transcibr:process"
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
// Recording it finishes and abort the rest. `checked` is read and written by
// that single Worker, at `checked_first_recording_health` below, and reset by
// the CLI between Batches (`run_the_batch`, `src/cli/batch.odin`) -- a
// different thread from the Worker's, so the reset's visibility is a real
// question rather than a sequential one. The one-Worker invariant itself is
// held mechanically, by the assert inside `bump` (`pipeline.odin`, commit
// 1c67c11), at the one place the live transcription count changes; the
// `sync.atomic_load`/`sync.atomic_store` pair at this flag's own site is that
// assert's A4 partner, making the cross-thread reset well-defined and keeping
// a second Worker -- if one is ever wired in -- a logic bug `bump` catches
// rather than a data race nothing does. `abort` is `sync.atomic_store`d
// because `run_batch`'s admission loop reads it from a different thread --
// the identical `cancelled` flag a Ctrl+C press already sets
// (`src/cli/batch.odin`), reused rather than inventing a second way to stop
// a Batch early. `unhealthy` is a SEPARATE flag, also `sync.atomic_store`d,
// set at the same moment as `abort` -- `abort` alone cannot tell a
// machine-detected fault apart from an operator's Ctrl+C once
// `pipeline.batch_succeeded` folds a cancelled Batch into success (a round-3
// adversarial review measured a Batch aborted for an unhealthy GPU exiting
// 0), so the CLI reads `unhealthy` after the Batch finishes to force a
// nonzero exit specifically for this reason, without touching what Ctrl+C
// itself still means. Both nil is a real value: `--transcribe`'s Batch of one
// has no "first of several" to gate and no admission loop left to stop.
Health_Watch :: struct {
	checked:   ^bool,
	abort:     ^bool,
	unhealthy: ^bool,
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
	// ADR-0041's seam: where a fault this Job's own Stages hit leaves
	// `src/pipeline` (`fire`, event.odin), and which `plan.entries` index it
	// names -- `new_recording_job` defaults `at` to `-1`, "no one Recording",
	// the value `--transcribe`'s Batch of one (which has no Plan at all)
	// keeps. A `Recording_Job` literal built directly, as every test in this
	// package but `new_recording_job`'s own callers does, leaves both fields
	// at their bare zero value (`Observer{}`, `at == 0`); `fire` treats a zero
	// Observer as "nobody is listening", not a crash, so that is still safe.
	observer:       Observer,
	at:             int,
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
//
// Exported (issue #78) so `src/cli` can call the one definition instead of
// hand-copying the `message := ...; defer delete(message); fmt.eprintln(message)`
// shape at every fault it reports -- six copies of it, at the ticket's count.
//
// ADR-0041: this no longer writes to stderr itself -- it builds the Event and
// hands it to `observer` (`fire`, event.odin), whose console sink
// (`CONSOLE_OBSERVER`) renders the identical bytes this procedure used to
// write directly. `message` is still freed here, exactly as before: the
// Event's own `message` field borrows it for the length of `fire`'s call and
// no longer.
report_fault :: proc(
	observer: Observer,
	kind: Event_Kind,
	at: int,
	message: string,
	allocator: mem.Allocator,
) {
	assert(len(message) > 0, "reported a fault with no message to show")

	defer delete(message, allocator)
	fire(observer, Event{kind = kind, at = at, message = message})
}

// report_fault's stdout sibling (issue #119): a line that belongs on standard
// output rather than standard error -- a dry run's plan rows -- but still
// follows the same build/delete/print shape report_fault owns for stderr.
report_line :: proc(message: string, allocator: mem.Allocator) {
	assert(len(message) > 0, "reported a line with no message to show")

	defer delete(message, allocator)
	fmt.println(message)
}

@(require_results)
extract_recording :: proc(job: Recording_Job) -> (extracted: Recording_Extracted, ok: bool) {
	assert(job.arena != nil, "a Recording Job with no arena reached extraction")
	assert(len(job.source) > 0, "an extraction reached with no Recording path to read")
	assert(len(job.cache) > 0, "an extraction reached with no cache directory to write into")

	planned, unread := audio.read_source(job.source, job.allocator)
	if unread.fault != .None {
		report_fault(
			job.observer,
			.Failed,
			job.at,
			audio.error_message(unread, job.source, job.allocator),
			job.allocator,
		)
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
		report_fault(
			job.observer,
			.Failed,
			job.at,
			audio.error_message(unextracted, job.source, job.allocator),
			job.allocator,
		)
		destroy_recording_arena(job)
		return {}, false
	}
	result := Recording_Extracted {
		job       = job,
		extracted = produced,
		planned   = planned,
	}
	return result, true
}

@(require_results)
transcribe_and_place :: proc(extracted: Recording_Extracted) -> bool {
	job := extracted.job
	assert(len(job.source) > 0, "a transcription reached with no Recording path to read")
	assert(len(job.cache) > 0, "a transcription reached with no cache directory to write into")
	defer destroy_recording_arena(job)
	defer delete(extracted.extracted.audio, job.allocator)

	produced, unfinished := engine.transcribe(
		job.group,
		job.tools.engine,
		engine.Job {
			audio = extracted.extracted.audio,
			cache = job.cache,
			name = job.name,
			source = job.source,
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
		report_fault(
			job.observer,
			.Failed,
			job.at,
			engine.error_message(unfinished, job.source, job.allocator),
			job.allocator,
		)
		discard_engine_output(job, unfinished.fault)
		discard_recording_wav(extracted.extracted.audio, unfinished.fault)
		return false
	}
	checked_first_recording_health(job, extracted.extracted.container_ms, produced)
	return placed_from_engine_output(job, extracted, produced.output)
}

// Issue #211: a `.Refused` or `.Output_Empty` Engine run leaves its output
// file sitting in the scratch cache -- `engine.transcribe`'s own `output`
// local (run.odin) is freed as a *string* on any fault, never as a file on
// disk, and nothing downstream ever revisits it once this Recording has
// already failed. Mirrors `discard_part` in src/audio/run.odin exactly:
// every fault removes the file except `.Not_Stopped`, whose own doc comment
// in src/engine/engine.odin already gives the reason -- the Engine may still
// be running and may still hold that file open, so this leaves it for the
// age-based sweep (ADR-0023) instead. Every other fault either leaves a real
// half-written or empty file (`.Did_Not_Finish`, `.Went_Silent`, `.Refused`,
// `.Output_Empty`) or leaves nothing to remove at all
// (`.Path_Not_Ascii`, `.Not_Started`, `.No_Output`) -- `os.remove` on a path
// that was never written is exactly the tolerated failure A8 asks for, the
// same as `discard_part`'s unconditional call.
//
// Exact-path delete of the one file this Recording's own Engine run could
// have written -- `job.cache` and `job.name` rebuild the identical prefix
// `engine.transcribe` used, and `process.engine_output_path` is the same
// exported name that built it there. Issue #275: the prefix itself is keyed
// through `process.cache_key_prefix`, the same seam `engine.transcribe`'s
// own `engine_output_prefix` keys against, rather than rebuilt as the plain
// `<cache>\<name>` this procedure used to compute on its own -- the exact
// drift #258/#268 already closed for the wav and probe intermediates. No
// enumeration of the cache directory, no wildcard, no `os.remove_all`
// (CLAUDE.md's Odin notes, issue #97/#105).
@(private)
discard_engine_output :: proc(job: Recording_Job, fault: engine.Fault) {
	assert(len(job.cache) > 0, "a Recording Job with no cache has nowhere to sweep")
	assert(len(job.name) > 0, "a Recording Job with no name has nowhere to sweep")
	assert(len(job.source) > 0, "a Recording Job with no source has nothing to key its sweep to")
	assert(fault != .None, "a Recording that came through has no output to sweep")

	if fault == .Not_Stopped {
		return
	}

	prefix := process.cache_key_prefix(job.cache, job.name, job.source, job.allocator)
	defer delete(prefix, job.allocator)
	output := process.engine_output_path(prefix, job.allocator)
	defer delete(output, job.allocator)

	os.remove(output)
}

// Issue #251: with no reuse path implemented anywhere in `audio.extract`
// (ADR-0023's addendum below), keeping a refused Recording's own extracted
// `<cache>\<name>.wav` around buys nothing but ~115 MB/hr of source per
// failed Recording, held until the next Batch-start age sweep -- up to seven
// days of it. `wav` is `extracted.extracted.audio`, the exact path
// `audio.extract` already handed back and `transcribe_and_place` already
// holds; no rebuilt prefix, unlike `discard_engine_output` above, because
// this Recording's own Job never needed to reconstruct it.
//
// The fault set is narrower than `discard_engine_output`'s: alongside
// `.Not_Stopped` (the Engine may still hold the file open, same reason as
// above), `.Did_Not_Finish` also keeps its wav. Its own `fault_says`
// sentence is "the Engine was stopped before it finished" -- a stop, not a
// refusal. Nothing in this Recording's audio was judged and rejected the way
// `.Refused` or `.Output_Empty` judge it; the run simply did not land inside
// its bound (`run_engine`'s `.Bound_Expired`/`.Drain_Failed`/`.None` reasons
// all collapse to this one fault in `engine.refused`). That is exactly the
// "Batch interrupted, resumed later" shape ADR-0023's own rationale
// describes, so this wav is the one worth keeping for it even though no
// caller reuses it yet. Every other fault -- `.Refused`, `.Output_Empty`,
// `.Went_Silent`, `.Path_Not_Ascii`, `.Not_Started`, `.No_Output` -- either
// judged this Recording's audio and rejected it or never touched the wav at
// all, so sweeping it loses nothing a retry could use.
@(private)
discard_recording_wav :: proc(wav: string, fault: engine.Fault) {
	assert(len(wav) > 0, "a Recording Job with no extracted audio has nowhere to sweep")
	assert(fault != .None, "a Recording that came through has no wav to sweep")

	if fault == .Not_Stopped {
		return
	}
	if fault == .Did_Not_Finish {
		return
	}

	os.remove(wav)
}

// Runs against every Recording that finishes transcribing successfully,
// until one of them actually settles a verdict -- `job.health.checked` is
// that gate, and a round-4 adversarial review found it being set on a
// Recording the check had explicitly declined to judge (too short for the
// speed half to carry a verdict, an unreadable read, or an unmeasurable
// elapsed time), which spent a Batch's one health check on nothing and left
// every Recording behind it unchecked. `checked^` is now written only once
// `doctor.first_recording_health` hands back a `conclusive` answer, so an
// inconclusive first Recording leaves the gate open for the next one. A
// verdict this unhealthy does not fail THIS Recording, which already
// finished -- it stops the ones behind it, the same way ADR-0011 asks: abort
// the Batch rather than run overnight on the wrong device.
//
// Issue #132: `container_ms > 0` below is internal, not a check on external
// input, for the same reason Issue #112 recorded at `read_probe`'s guard in
// src/process/ffmpeg.odin. `checked_first_recording_health`'s only
// production caller, `transcribe_and_place`, passes
// `extracted.extracted.container_ms` directly -- `audio.Extracted.container_ms`,
// which that same probe guarantees positive; recording_test.odin's cases
// call this procedure directly with a positive literal they choose
// themselves.
@(private)
checked_first_recording_health :: proc(
	job: Recording_Job,
	container_ms: i64,
	produced: engine.Transcribed,
) {
	assert(container_ms > 0, "a Recording nobody could time reached the health check")

	if job.health.checked == nil || sync.atomic_load(job.health.checked) {
		return
	}
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
	fault, conclusive := doctor.first_recording_health(evidence, factor, container_ms)
	if !conclusive {
		return
	}
	sync.atomic_store(job.health.checked, true)
	if fault == .None {
		return
	}

	message := doctor.health_error_message(fault, factor, job.allocator)
	defer delete(message, job.allocator)
	assert(len(job.source) > 0, "a Health event was about to fire with no source to name")
	assert(len(message) > 0, "a Health event was about to fire with no message to show")
	fire(
		job.observer,
		Event {
			kind = .Health,
			at = job.at,
			source = job.source,
			message = message,
			factor = factor,
			health = fault,
		},
	)
	if job.health.abort != nil {
		sync.atomic_store(job.health.abort, true)
	}
	if job.health.unhealthy != nil {
		sync.atomic_store(job.health.unhealthy, true)
	}
}

// The one place `artifact.complete` is actually called, from both the
// transcribe path (`placed_from_engine_output`, `duration` a real `Millis`)
// and the re-render path (`pipeline.re_rendered_and_placed` in batch.odin,
// `duration` nil because a re-render never re-measures the container). #73's
// review measured the two callers sharing 12 of 21 body lines before this
// fold; the 9 that differed were only which local filled `duration`,
// `engine_version` and `model` -- callers still settle those, this only
// shares the placement and the fault report that follows it.
@(private)
@(require_results)
placed_and_reported :: proc(
	source: string,
	output: string,
	duration: Maybe(transcript.Millis),
	rc: transcript.Render_Context,
	made: artifact.Sidecar,
	observer: Observer,
	at: int,
	allocator: mem.Allocator,
) -> bool {
	assert(len(source) > 0, "there is no Recording here to place artifacts beside")
	assert(len(output) > 0, "there is no Engine output here to make a Transcript from")

	placed, unplaced := artifact.complete(source, output, duration, rc, made, allocator)
	defer artifact.destroy_names(placed, allocator)
	if unplaced.fault != .None {
		report_fault(
			observer,
			.Failed,
			at,
			artifact.error_message(unplaced, source, allocator),
			allocator,
		)
		return false
	}
	assert(len(placed[.Transcript]) > 0, "placement succeeded with no Transcript name to report")
	fmt.println(placed[.Transcript])
	return true
}

// Issue #132: `extracted.extracted.container_ms > 0` below is internal, not
// a check on external input, for the same reason Issue #112 recorded at
// `read_probe`'s guard in src/process/ffmpeg.odin.
// `placed_from_engine_output`'s only production caller,
// `transcribe_and_place`, passes the same `extracted` that
// `checked_first_recording_health` above already asserted this exact field
// positive on, itself traced to `audio.Extracted.container_ms`;
// batch_test.odin's fake_resume_extract feeds this path RESUME_FIXTURE_MS,
// itself a positive literal.
@(private)
@(require_results)
placed_from_engine_output :: proc(
	job: Recording_Job,
	extracted: Recording_Extracted,
	output: string,
) -> bool {
	assert(len(output) > 0, "there is no Engine output here to place from")
	assert(
		extracted.extracted.container_ms > 0,
		"placement reached with no measured container duration",
	)

	made := recording_sidecar(job, extracted)
	return placed_and_reported(
		job.source,
		output,
		transcript.Millis(extracted.extracted.container_ms),
		transcript.Render_Context {
			now = time.now(),
			source_display = job.source,
			engine_version = artifact.engine_display_name(job.tools.engine.engine),
			model = artifact.model_display_name(job.model.path),
			profile = job.profile,
		},
		made,
		job.observer,
		job.at,
		job.allocator,
	)
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
	assert(len(job.engine_version) > 0, "a Sidecar was built with no Engine version settled")
	assert(len(job.tools.engine.engine) > 0, "a Sidecar was built with no Engine path settled")

	return artifact.sidecar_of(
		job.tools.engine.engine,
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
	// ADR-0041: the seam every fault reported for this Batch reaches --
	// `src/cli/batch.odin` wires its own console-plus-trail fan-out here.
	// Left at its zero value (`Observer{}`) by every test in this package
	// that builds a `Batch_Options` literal directly, which `fire` treats as
	// "nobody is listening", not a crash.
	observer:       Observer,
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
	observer: Observer = {},
	at: int = -1,
) -> Recording_Job {
	assert(len(source) > 0, "there is no Recording here to build a Job for")
	assert(len(name) > 0, "a Recording with no artifact stem has nowhere to put its output")
	assert(len(tools.engine.engine) > 0, "a Recording Job was built with no Engine to spawn")

	arena := new(mem.Dynamic_Arena, runtime.heap_allocator())
	mem.dynamic_arena_init(
		arena,
		block_allocator = runtime.heap_allocator(),
		array_allocator = runtime.heap_allocator(),
	)

	result := Recording_Job {
		source         = source,
		name           = name,
		group          = group,
		tools          = tools,
		cache          = cache,
		model          = model,
		prompt         = prompt,
		engine_version = engine_version,
		profile        = profile,
		report         = report,
		health         = health,
		arena          = arena,
		allocator      = mem.dynamic_arena_allocator(arena),
		observer       = observer,
		at             = at,
	}
	return result
}

@(private)
@(require_results)
recording_job_of :: proc(entry: planning.Entry, o: Batch_Options, at: int) -> Recording_Job {
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
		o.observer,
		at,
	)
}
