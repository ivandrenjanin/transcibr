#+vet explicit-allocators
package pipeline

// Turns a Plan into work: `.Transcribe` entries go through run_batch, the one
// GPU-serialising path; `.Re_Render` entries never touch the GPU at all and
// are rendered here, directly, from the retained Engine output; `.Refuse` and
// `.Skip` are reported and counted. `planning.plan_batch` already decided
// which is which -- nothing here re-decides it.

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:time"
import "transcibr:artifact"
import "transcibr:planning"
import "transcibr:transcript"

// What a whole Batch came to, once every entry in its Plan has been acted on.
Summary :: struct {
	transcribed: int,
	rerendered:  int,
	failed:      int,
	refused:     int,
	skipped:     int,
	// A Recording queued for transcription but never admitted because the
	// Batch was cancelled first (`Terminal.Not_Admitted`) -- never folded into
	// `failed`, the same way `planning.Inventory.cancelled` keeps a stopped
	// walk apart from one that actually failed (finding 4 of PR #67's review).
	cancelled:   int,
}

@(private)
@(require_results)
engine_output_path :: proc(source: string, allocator: mem.Allocator) -> (path: string, ok: bool) {
	names, namable := artifact.names_of(source, allocator)
	defer artifact.destroy_names(names, allocator)
	if !namable {
		return "", false
	}
	return strings.clone(names[.Engine_Output], allocator), true
}

// A Re_Render decision is only ever reached when `artifact.changed` found
// every field but the Merge Profile already matching the record (planning's
// `resumed`), so the Sidecar to write is the recorded one with that one field
// replaced -- never `current_of`'s comparison value, which planning keeps
// private for exactly this reason.
@(private)
@(require_results)
re_render_recording :: proc(
	entry: planning.Entry,
	o: Batch_Options,
	allocator: mem.Allocator,
) -> bool {
	assert(
		entry.outcome.decision == .Re_Render,
		"a Recording not decided Re_Render reached re-rendering",
	)

	recorded, known := entry.found.recorded.?
	assert(known, "a Re_Render decision was made with no recorded Sidecar to re-render from")
	made := recorded
	made.merge_profile = transcript.profile_name(o.profile)

	output, namable := engine_output_path(entry.found.source, allocator)
	defer delete(output, allocator)
	if !namable {
		return false
	}

	return re_rendered_and_placed(entry.found.source, output, made, o, allocator)
}

@(private)
@(require_results)
re_rendered_and_placed :: proc(
	source: string,
	output: string,
	made: artifact.Sidecar,
	o: Batch_Options,
	allocator: mem.Allocator,
) -> bool {
	placed, unplaced := artifact.complete(
		source,
		output,
		nil,
		transcript.Render_Context {
			now = time.now(),
			source_display = source,
			engine_version = made.engine_version,
			model = model_display_name(made.model),
			profile = o.profile,
		},
		made,
		allocator,
	)
	defer artifact.destroy_names(placed, allocator)
	if unplaced.fault != .None {
		report_fault(artifact.error_message(unplaced, source, allocator), allocator)
		return false
	}
	fmt.println(placed[.Transcript])
	return true
}

@(private)
report_refusal :: proc(entry: planning.Entry, allocator: mem.Allocator) {
	line := planning.plan_line(entry, allocator)
	defer delete(line, allocator)
	fmt.eprintln(line)
}

@(private)
sort_entry :: proc(
	summary: ^Summary,
	entry: planning.Entry,
	o: Batch_Options,
	allocator: mem.Allocator,
	jobs: ^[dynamic]Recording_Job,
) {
	assert(summary != nil, "there is nowhere here to record what this entry came to")

	switch entry.outcome.decision {
	case .Transcribe:
		append(jobs, recording_job_of(entry, o))
	case .Re_Render:
		if re_render_recording(entry, o, allocator) {
			summary.rerendered += 1
		} else {
			summary.failed += 1
		}
	case .Skip:
		summary.skipped += 1
	case .Refuse:
		report_refusal(entry, allocator)
		summary.refused += 1
	}
}

// A folder of Recordings, processed end to end: `.Transcribe` entries run
// through the one GPU-serialising pipeline, everything else is settled
// without it, and `cancelled` -- checked between admissions, never inside a
// Stage already running -- is what makes interrupting mid-Batch stop
// admitting new work rather than abandon what the bounded queue already
// holds (see run_batch's own admit_jobs).
//
// `stages` is a real parameter and not a default of `RECORDING_STAGES`
// baked in here, so a test can drive the exact same folder-to-artifacts
// wiring with the pipeline's own fake Stages and no GPU (finding 8 of PR
// #67's review) -- `src/cli/batch.odin` is the one production caller and
// always passes `RECORDING_STAGES`.
@(require_results)
run_recordings :: proc(
	plan: planning.Plan,
	o: Batch_Options,
	allocator: mem.Allocator,
	cancelled: ^bool,
	stages: Stages(Recording_Job, Recording_Extracted),
) -> (
	summary: Summary,
) {
	assert(o.config.extract_workers > 0, "a Batch with no extraction workers admits nothing")
	assert(
		o.config.extract_workers <= MAX_EXTRACT_WORKERS,
		"ADR-0006 bounds a Batch to one or two extraction Workers, asserted rather than merely intended",
	)
	assert(
		o.config.queue_depth <= MAX_QUEUE_DEPTH,
		"ADR-0006 bounds a Batch's queue to a depth of one or two, asserted rather than merely intended",
	)

	jobs := make([dynamic]Recording_Job, 0, len(plan.entries), allocator)
	defer delete(jobs)
	for entry in plan.entries {
		sort_entry(&summary, entry, o, allocator, &jobs)
	}
	if len(jobs) == 0 {
		return
	}

	results, _ := run_batch(jobs[:], stages, o.config, allocator, cancelled)
	defer delete(results, allocator)
	for status in results {
		switch status {
		case .Transcribed:
			summary.transcribed += 1
		case .Not_Admitted:
			summary.cancelled += 1
		case .Unset,
		     .Extraction_Failed,
		     .Transcription_Failed,
		     .Extract_Queue_Send_Failed,
		     .Transcribe_Queue_Send_Failed,
		     .Stage_Abandoned:
			summary.failed += 1
		}
	}
	return
}
