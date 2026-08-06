#+vet explicit-allocators
package pipeline

// run_recordings, above run_batch: a cancelled admission reported as
// `cancelled` rather than `failed` (finding 4 of PR #67's review), and
// acceptance criterion 1 -- "a folder of Recordings processes end to end and
// can be resumed after interruption" -- exercised through the pipeline's own
// fake Stages rather than left uncovered because Seam S5 needs a GPU (finding
// 8 of PR #67's review). `fake_resume_extract` and `fake_resume_transcribe`
// stand in for `extract_recording` and `transcribe_and_place`: the same real
// `artifact.complete` placement, the same real Sidecar, a planted Engine
// output in place of a real Engine run.

import "core:fmt"
import "core:os"
import "core:testing"
import "transcibr:artifact"
import "transcibr:audio"
import "transcibr:planning"
import "transcibr:testkit"
import "transcibr:transcript"

@(private)
RESUME_ENGINE_JSON :: #load("../transcript/fixtures/engine-output.json", string)

@(private)
RESUME_FIXTURE_MS :: i64(253_949)

@(private)
@(require_results)
fake_resume_extract :: proc(job: Recording_Job) -> (extracted: Recording_Extracted, ok: bool) {
	planned, unread := audio.read_source(job.source, job.allocator)
	if unread.fault != .None {
		destroy_recording_arena(job)
		return {}, false
	}
	return Recording_Extracted {
			job = job,
			planned = planned,
			extracted = audio.Extracted{container_ms = RESUME_FIXTURE_MS},
		},
		true
}

@(private)
@(require_results)
fake_resume_transcribe :: proc(extracted: Recording_Extracted) -> bool {
	job := extracted.job
	defer destroy_recording_arena(job)
	defer delete(extracted.extracted.audio, job.allocator)

	output := fmt.aprintf("%s\\%s.fakeengine.json", job.cache, job.name, allocator = job.allocator)
	defer delete(output, job.allocator)
	if os.write_entire_file(output, transmute([]u8)string(RESUME_ENGINE_JSON)) != nil {
		return false
	}
	return placed_from_engine_output(job, extracted, output)
}

@(private)
FAKE_RESUME_STAGES := Stages(Recording_Job, Recording_Extracted) {
	extract     = fake_resume_extract,
	transcribe  = fake_resume_transcribe,
	discard     = discard_recording_audio,
	abandon_job = abandon_recording_job,
}

@(private)
RESUME_ENGINE_VERSION :: "resume-test-engine"

// `recording_sidecar` always stamps `artifact.ENGINE_DEFAULT_BEAM` -- a
// Recording_Job carries no beam of its own -- so planning's own `current_-`
// `of` has to be told the same value, or every second pass sees a phantom
// `Change.Beam` and never resumes.
@(private)
@(require_results)
resume_settings :: proc() -> planning.Settings {
	return planning.Settings {
		engine_version = RESUME_ENGINE_VERSION,
		model = artifact.Model{path = "m.bin", digest = a_digest('r'), bytes = 1},
		beam = artifact.ENGINE_DEFAULT_BEAM,
		merge_profile = transcript.profile_name(transcript.DEFAULT_PROFILE),
	}
}

@(private)
@(require_results)
resume_options :: proc(tree: string, settings: planning.Settings) -> Batch_Options {
	return Batch_Options {
		cache = tree,
		model = settings.model,
		engine_version = RESUME_ENGINE_VERSION,
		profile = transcript.DEFAULT_PROFILE,
		config = Config{extract_workers = 1, queue_depth = 1, join_bound_ms = JOIN_BOUND_MS},
	}
}

// A cancelled Batch never even reaches admission for anything past the point
// it was asked to stop (run_batch's own `admit_jobs`), and finding 4 is that
// `run_recordings` used to fold every one of those `Terminal.Not_Admitted`
// results into `failed` -- indistinguishable, in the summary a Batch operator
// reads, from a Recording that genuinely failed.
@(test)
a_cancelled_batch_reports_unadmitted_recordings_as_cancelled_not_failed :: proc(t: ^testing.T) {
	settings := resume_settings()
	defer delete(string(settings.model.digest), context.allocator)
	o := resume_options("C:\\nowhere", settings)

	plan := planning.Plan {
		entries = []planning.Entry {
			{
				found = planning.Found{source = "C:\\clips\\a.mp4"},
				outcome = planning.Outcome{decision = .Transcribe},
			},
			{
				found = planning.Found{source = "C:\\clips\\b.mp4"},
				outcome = planning.Outcome{decision = .Transcribe},
			},
		},
	}

	cancelled := true
	summary := run_recordings(plan, o, context.allocator, &cancelled, RECORDING_STAGES)

	testing.expect_value(t, summary.cancelled, 2)
	testing.expect_value(t, summary.failed, 0)
	testing.expect_value(t, summary.transcribed, 0)
}

// The one policy decision issue #74 asks to be named where a user can
// dispute it: a Ctrl+C or an already-up-to-date Recording is not a Batch
// coming up short, so neither counts against `batch_succeeded`. Only
// `failed` and `refused` do.
@(test)
cancelled_and_skipped_recordings_do_not_fail_a_batch_only_failed_and_refused_do :: proc(
	t: ^testing.T,
) {
	testing.expect(t, batch_succeeded(Summary{}), "an empty Batch is not a failed one")
	testing.expect(
		t,
		batch_succeeded(Summary{transcribed = 3, rerendered = 1}),
		"a Batch that only transcribed and re-rendered failed nothing",
	)
	testing.expect(
		t,
		batch_succeeded(Summary{cancelled = 5}),
		"a cancelled Batch is an operator's decision, not a failure",
	)
	testing.expect(
		t,
		batch_succeeded(Summary{skipped = 5}),
		"a Batch that skipped up-to-date Recordings is not a failed one",
	)
	testing.expect(
		t,
		!batch_succeeded(Summary{failed = 1}),
		"a Batch with a genuinely failed Recording reads as succeeded",
	)
	testing.expect(
		t,
		!batch_succeeded(Summary{refused = 1}),
		"a Batch with a refused Recording reads as succeeded",
	)
	testing.expect(
		t,
		!batch_succeeded(Summary{failed = 1, cancelled = 5, skipped = 5}),
		"cancelled and skipped counts masked a genuine failure",
	)
}

@(private)
@(require_results)
resume_recording :: proc(t: ^testing.T, tree: string, name: string) -> string {
	path := fmt.aprintf("%s\\%s.wav", tree, name, allocator = context.allocator)
	testing.expectf(
		t,
		os.write_entire_file(
			path,
			transmute([]u8)string("not really audio, planning never opens it"),
		) ==
		nil,
		"could not write %s",
		path,
	)
	return path
}

@(private)
@(require_results)
planned_resume :: proc(
	t: ^testing.T,
	tree: string,
	settings: planning.Settings,
) -> (
	inventory: planning.Inventory,
	plan: planning.Plan,
) {
	inventory = planning.discover([]string{tree}, planning.Walk{}, context.allocator)
	runnable: bool
	plan, runnable = planning.plan_batch(inventory, settings, context.allocator)
	testing.expect(t, runnable, "a folder this case built itself was refused as unplannable")
	return
}

// Acceptance criterion 1: a folder of Recordings processes end to end, and
// resuming sees the work already done rather than redoing it. Nothing here
// touches ffmpeg or the Engine -- `FAKE_RESUME_STAGES` stands in for both --
// so this is coverage of the RESUME WIRING (planning's decision, run_-
// `recordings`' admission, and the real `artifact.complete` placement
// underneath both), not of the two Stages themselves, which is what Seam S5
// being local-only actually excuses.
@(test)
a_folder_processed_once_is_skipped_on_the_next_pass :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "pipeline", "resume", context.allocator)
	defer testkit.remove_cache(tree, context.allocator)
	defer delete(tree, context.allocator)

	one := resume_recording(t, tree, "one")
	defer delete(one, context.allocator)
	two := resume_recording(t, tree, "two")
	defer delete(two, context.allocator)

	settings := resume_settings()
	defer delete(string(settings.model.digest), context.allocator)
	o := resume_options(tree, settings)

	first_inventory, first_plan := planned_resume(t, tree, settings)
	defer planning.destroy_inventory(first_inventory, context.allocator)
	defer planning.destroy_plan(first_plan, context.allocator)
	for entry in first_plan.entries {
		testing.expectf(
			t,
			entry.outcome.decision == .Transcribe,
			"%s was not planned for transcription on a first pass: %v",
			entry.found.source,
			entry.outcome.decision,
		)
	}

	first_summary := run_recordings(first_plan, o, context.allocator, nil, FAKE_RESUME_STAGES)
	testing.expect_value(t, first_summary.transcribed, 2)
	testing.expect_value(t, first_summary.failed, 0)

	second_inventory, second_plan := planned_resume(t, tree, settings)
	defer planning.destroy_inventory(second_inventory, context.allocator)
	defer planning.destroy_plan(second_plan, context.allocator)
	for entry in second_plan.entries {
		testing.expectf(
			t,
			entry.outcome.decision == .Skip,
			"%s was not resumed as already done on a second pass: %v",
			entry.found.source,
			entry.outcome.decision,
		)
	}

	second_summary := run_recordings(second_plan, o, context.allocator, nil, FAKE_RESUME_STAGES)
	testing.expect_value(t, second_summary.skipped, 2)
	testing.expect_value(t, second_summary.transcribed, 0)
}

// The corpus-level claim issue #70 is about, pinned where both --batch and
// --plan actually converge: `settled_engine_version` (src/pipeline/recording.odin)
// runs AFTER `planning.plan_batch` decides, never before, so a flagless
// --batch's Maybe(string) reaches planning as nil and skips exactly where a
// flagless --plan does -- not as a Settings_Changed retranscribe caused by
// UNKNOWN leaking in ahead of the decision.
@(private)
@(require_results)
settled_options :: proc(tree: string, settings: planning.Settings) -> Batch_Options {
	o := resume_options(tree, settings)
	o.engine_version = settled_engine_version(settings.engine_version)
	return o
}

@(test)
a_flagless_batch_skips_a_recording_and_keeps_its_recorded_engine_version :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "pipeline", "provenance", context.allocator)
	defer testkit.remove_cache(tree, context.allocator)
	defer delete(tree, context.allocator)

	one := resume_recording(t, tree, "one")
	defer delete(one, context.allocator)

	named := resume_settings()
	defer delete(string(named.model.digest), context.allocator)

	first_inventory, first_plan := planned_resume(t, tree, named)
	defer planning.destroy_inventory(first_inventory, context.allocator)
	defer planning.destroy_plan(first_plan, context.allocator)
	first := run_recordings(
		first_plan,
		settled_options(tree, named),
		context.allocator,
		nil,
		FAKE_RESUME_STAGES,
	)
	testing.expect_value(t, first.transcribed, 1)

	unnamed := named
	unnamed.engine_version = nil
	second_inventory, second_plan := planned_resume(t, tree, unnamed)
	defer planning.destroy_inventory(second_inventory, context.allocator)
	defer planning.destroy_plan(second_plan, context.allocator)
	second := run_recordings(
		second_plan,
		settled_options(tree, unnamed),
		context.allocator,
		nil,
		FAKE_RESUME_STAGES,
	)
	testing.expect_value(t, second.skipped, 1)
	testing.expect_value(t, second.transcribed, 0)

	third_inventory, third_plan := planned_resume(t, tree, unnamed)
	defer planning.destroy_inventory(third_inventory, context.allocator)
	defer planning.destroy_plan(third_plan, context.allocator)
	for entry in third_plan.entries {
		recorded, known := entry.found.recorded.?
		testing.expect(t, known, "no Sidecar survived the flagless pass")
		testing.expect_value(t, recorded.engine_version, RESUME_ENGINE_VERSION)
	}
}

// Sensitivity check on the test above: naming transcript.UNKNOWN as if it
// were a real Engine -- exactly what a pre-fix `defaulted_batch` put into
// Settings before planning ever saw it -- makes the second pass retranscribe
// rather than skip, so the guard above is not passing regardless of what
// planning decided.
@(test)
a_batch_naming_unknown_as_its_engine_retranscribes_rather_than_skips :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "pipeline", "provenance-defect", context.allocator)
	defer testkit.remove_cache(tree, context.allocator)
	defer delete(tree, context.allocator)

	one := resume_recording(t, tree, "one")
	defer delete(one, context.allocator)

	named := resume_settings()
	defer delete(string(named.model.digest), context.allocator)

	first_inventory, first_plan := planned_resume(t, tree, named)
	defer planning.destroy_inventory(first_inventory, context.allocator)
	defer planning.destroy_plan(first_plan, context.allocator)
	first := run_recordings(
		first_plan,
		settled_options(tree, named),
		context.allocator,
		nil,
		FAKE_RESUME_STAGES,
	)
	testing.expect_value(t, first.transcribed, 1)

	defaulted := named
	defaulted.engine_version = transcript.UNKNOWN
	second_inventory, second_plan := planned_resume(t, tree, defaulted)
	defer planning.destroy_inventory(second_inventory, context.allocator)
	defer planning.destroy_plan(second_plan, context.allocator)
	second := run_recordings(
		second_plan,
		settled_options(tree, defaulted),
		context.allocator,
		nil,
		FAKE_RESUME_STAGES,
	)
	testing.expect_value(t, second.transcribed, 1)
	testing.expect_value(t, second.skipped, 0)
}
