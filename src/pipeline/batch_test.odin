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

// A digest-shaped placeholder, not a real hash of anything: identifying the
// Engine for real is `artifact.identify_engine`'s job (src/artifact/engine.odin),
// exercised by that package's own tests. This package only needs a value the
// same length a real digest is, since `planning.current_of` now asserts that
// (issue #50).
@(private)
RESUME_ENGINE_DIGEST :: artifact.Digest(
	"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
)

@(private)
RESUME_ENGINE_DIGEST_REPLACED :: artifact.Digest(
	"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
)

// `recording_sidecar` always stamps `artifact.ENGINE_DEFAULT_BEAM` -- a
// Recording_Job carries no beam of its own -- so planning's own `current_-`
// `of` has to be told the same value, or every second pass sees a phantom
// `Change.Beam` and never resumes.
@(private)
@(require_results)
resume_settings :: proc() -> planning.Settings {
	return planning.Settings {
		engine_version = RESUME_ENGINE_DIGEST,
		model = artifact.Model{path = "m.bin", digest = a_digest('r'), bytes = 1},
		beam = artifact.ENGINE_DEFAULT_BEAM,
		merge_profile = transcript.profile_name(transcript.DEFAULT_PROFILE),
	}
}

// The Engine's digest is computed once, the same way `--batch` computes it
// once and hands it to both `planning.Settings` and `Batch_Options`
// (src/cli/batch.odin) -- so a test that wants a Batch to see a DIFFERENT
// Engine changes `settings.engine_version` and rebuilds these options from
// it, rather than editing the two independently and risking exactly the
// drift issue #70 found between `--plan` and `--batch`.
@(private)
@(require_results)
resume_options :: proc(tree: string, settings: planning.Settings) -> Batch_Options {
	return Batch_Options {
		cache = tree,
		model = settings.model,
		engine_version = string(settings.engine_version),
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

// The round-4 finding: a Batch aborted for an unhealthy GPU used to be told
// apart from a genuine success by a second, untested check living in
// `src/cli` -- mutation-tested by deleting it and finding the full suite
// still green. `unhealthy` now lives in the Summary itself, exactly where
// `failed` and `refused` already do, so `batch_succeeded` alone holds it.
@(test)
an_unhealthy_gpu_fails_a_batch_even_with_nothing_else_wrong :: proc(t: ^testing.T) {
	testing.expect(
		t,
		!batch_succeeded(Summary{unhealthy = true}),
		"an unhealthy GPU read as a succeeded Batch",
	)
	testing.expect(
		t,
		!batch_succeeded(Summary{transcribed = 3, unhealthy = true}),
		"transcribed work masked an unhealthy GPU",
	)
}

// `run_recordings` is where `Batch_Options.health.unhealthy` actually reaches
// the `Summary` a Batch's exit code is decided from -- pinning this against
// the real procedure, not only against `batch_succeeded`'s own pure logic,
// is what would have caught the round-4 finding at the seam it lived in.
@(test)
review_run_recordings_carries_an_unhealthy_gpu_into_its_own_summary :: proc(t: ^testing.T) {
	settings := resume_settings()
	defer delete(string(settings.model.digest), context.allocator)
	o := resume_options("C:\\nowhere", settings)
	unhealthy := true
	o.health = Health_Watch {
		unhealthy = &unhealthy,
	}

	cancelled := false
	summary := run_recordings(planning.Plan{}, o, context.allocator, &cancelled, RECORDING_STAGES)

	testing.expect_value(t, summary.unhealthy, true)
	testing.expect(t, !batch_succeeded(summary), "an unhealthy Batch read as succeeded")
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

@(private)
ZERO_OFFSET_ENGINE_JSON :: `{"transcription": [{"offsets": {"from": 0, "to": 0}, "text": " zero"}]}`

@(private)
NONZERO_OFFSET_ENGINE_JSON :: `{"transcription": [{"offsets": {"from": 0, "to": 500}, "text": " zero"}]}`

@(private)
@(require_results)
fake_zero_offset_transcribe :: proc(extracted: Recording_Extracted) -> bool {
	job := extracted.job
	defer destroy_recording_arena(job)
	defer delete(extracted.extracted.audio, job.allocator)

	output := fmt.aprintf("%s\\%s.fakeengine.json", job.cache, job.name, allocator = job.allocator)
	defer delete(output, job.allocator)
	if os.write_entire_file(output, transmute([]u8)string(ZERO_OFFSET_ENGINE_JSON)) != nil {
		return false
	}
	return placed_from_engine_output(job, extracted, output)
}

@(private)
FAKE_ZERO_OFFSET_STAGES := Stages(Recording_Job, Recording_Extracted) {
	extract     = fake_resume_extract,
	transcribe  = fake_zero_offset_transcribe,
	discard     = discard_recording_audio,
	abandon_job = abandon_recording_job,
}

@(private)
@(require_results)
fake_nonzero_offset_transcribe :: proc(extracted: Recording_Extracted) -> bool {
	job := extracted.job
	defer destroy_recording_arena(job)
	defer delete(extracted.extracted.audio, job.allocator)

	output := fmt.aprintf("%s\\%s.fakeengine.json", job.cache, job.name, allocator = job.allocator)
	defer delete(output, job.allocator)
	if os.write_entire_file(output, transmute([]u8)string(NONZERO_OFFSET_ENGINE_JSON)) != nil {
		return false
	}
	return placed_from_engine_output(job, extracted, output)
}

@(private)
FAKE_NONZERO_OFFSET_STAGES := Stages(Recording_Job, Recording_Extracted) {
	extract     = fake_resume_extract,
	transcribe  = fake_nonzero_offset_transcribe,
	discard     = discard_recording_audio,
	abandon_job = abandon_recording_job,
}

// The property #78's fold had to preserve: `placed_from_engine_output` passes
// the transcribe path's own measured `container_ms` through as `duration`, so
// an Engine output whose cues never advance past zero over a non-empty
// Recording is caught by `transcript.check_cue_set` and reported as an
// operating error, never asserted (A8) -- `fake_resume_extract` hands the
// same nonzero `RESUME_FIXTURE_MS` `a_folder_processed_once_is_skipped_on_-`
// `the_next_pass` uses. Dropping that duration in favor of `nil` (the exact
// mutation the fold's own review made to prove this gap) makes
// `check_cue_set` skip the check outright and this test go red.
//
// A round-2 adversarial review proved `summary.failed == 1` alone is not an
// oracle for this property: mutating `ZERO_OFFSET_ENGINE_JSON` into text that
// is not JSON at all still failed with `summary.failed == 1`, on a wholly
// different fault, and the test stayed green. The direct `transcript.parse_cues`
// call below pins WHICH fault the fixture produces, and
// `placed_from_engine_output_places_a_final_cue_offset_that_advances` is the
// positive control CLAUDE.md A3 asks for: the identical fixture and duration
// with only the final offset changed, which must place rather than fail.
@(test)
placed_from_engine_output_refuses_a_final_cue_offset_of_zero :: proc(t: ^testing.T) {
	_, direct_err := transcript.parse_cues(
		"zero-offset-oracle",
		ZERO_OFFSET_ENGINE_JSON,
		transcript.Millis(RESUME_FIXTURE_MS),
		context.allocator,
	)
	testing.expect_value(t, direct_err.fault, transcript.Parse_Fault.Final_Offset_Is_Zero)

	tree := testkit.made_scratch_cache(t, "pipeline", "zero-offset", context.allocator)
	defer testkit.remove_cache(tree, context.allocator)
	defer delete(tree, context.allocator)

	one := resume_recording(t, tree, "one")
	defer delete(one, context.allocator)

	settings := resume_settings()
	defer delete(string(settings.model.digest), context.allocator)
	o := resume_options(tree, settings)

	inventory, plan := planned_resume(t, tree, settings)
	defer planning.destroy_inventory(inventory, context.allocator)
	defer planning.destroy_plan(plan, context.allocator)

	summary := run_recordings(plan, o, context.allocator, nil, FAKE_ZERO_OFFSET_STAGES)

	testing.expect_value(t, summary.transcribed, 0)
	testing.expect_value(t, summary.failed, 1)
}

@(test)
placed_from_engine_output_places_a_final_cue_offset_that_advances :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "pipeline", "nonzero-offset", context.allocator)
	defer testkit.remove_cache(tree, context.allocator)
	defer delete(tree, context.allocator)

	one := resume_recording(t, tree, "one")
	defer delete(one, context.allocator)

	settings := resume_settings()
	defer delete(string(settings.model.digest), context.allocator)
	o := resume_options(tree, settings)

	inventory, plan := planned_resume(t, tree, settings)
	defer planning.destroy_inventory(inventory, context.allocator)
	defer planning.destroy_plan(plan, context.allocator)

	summary := run_recordings(plan, o, context.allocator, nil, FAKE_NONZERO_OFFSET_STAGES)

	testing.expect_value(t, summary.transcribed, 1)
	testing.expect_value(t, summary.failed, 0)
}

// Issue #50, at the corpus level where --batch and --plan actually converge:
// a Batch always identifies its Engine now (planning.Settings.engine_version
// is no longer Maybe), so the resume rule this pins is that a matching
// digest skips and a CHANGED one -- an Engine binary replaced under the same
// name is exactly this, since a path alone cannot notice it -- retranscribes.
// This is the failure ADR-0027 accepted and issue #50 closes: it used to
// take a hand-typed `--engine-version` matching byte for byte to notice, and
// a flagless Batch skipped every corpus in existence, upgraded Engine or not.
@(test)
a_batch_whose_engine_digest_changed_since_re_transcribes_rather_than_skips :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "pipeline", "engine-replaced", context.allocator)
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
		resume_options(tree, named),
		context.allocator,
		nil,
		FAKE_RESUME_STAGES,
	)
	testing.expect_value(t, first.transcribed, 1)

	unchanged_inventory, unchanged_plan := planned_resume(t, tree, named)
	defer planning.destroy_inventory(unchanged_inventory, context.allocator)
	defer planning.destroy_plan(unchanged_plan, context.allocator)
	unchanged := run_recordings(
		unchanged_plan,
		resume_options(tree, named),
		context.allocator,
		nil,
		FAKE_RESUME_STAGES,
	)
	testing.expect_value(t, unchanged.skipped, 1)
	testing.expect_value(t, unchanged.transcribed, 0)

	replaced := named
	replaced.engine_version = RESUME_ENGINE_DIGEST_REPLACED
	second_inventory, second_plan := planned_resume(t, tree, replaced)
	defer planning.destroy_inventory(second_inventory, context.allocator)
	defer planning.destroy_plan(second_plan, context.allocator)
	second := run_recordings(
		second_plan,
		resume_options(tree, replaced),
		context.allocator,
		nil,
		FAKE_RESUME_STAGES,
	)
	testing.expect_value(t, second.transcribed, 1)
	testing.expect_value(t, second.skipped, 0)
}

// #88: `re_rendered_and_placed` (batch.odin) was executed by no test at all
// -- mutating its return value in a disposable worktree left the full suite
// green. Planting a Sidecar that differs from current Settings only in
// `merge_profile` is the one recipe `resumed` (src/planning/plan.odin) reads
// as `.Re_Render` rather than `.Transcribe`, so this drives the real
// procedure end to end: `re_render_recording` calls it, it calls the shared
// `placed_and_reported` with a nil duration -- the implication arm of
// `artifact.complete`'s `assert_agree` #73's AC2 proved only by construction,
// reached here by execution -- and the Transcript is re-rendered, placed, and
// the Sidecar rewritten. `second.rerendered == 1` is the oracle a `return
// false` mutation cannot survive: it would report `second.failed == 1`
// instead.
@(test)
a_merge_profile_change_alone_drives_the_real_re_render_and_placement :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "pipeline", "re-render", context.allocator)
	defer testkit.remove_cache(tree, context.allocator)
	defer delete(tree, context.allocator)

	one := resume_recording(t, tree, "one")
	defer delete(one, context.allocator)

	settings := resume_settings()
	defer delete(string(settings.model.digest), context.allocator)
	o := resume_options(tree, settings)

	first_inventory, first_plan := planned_resume(t, tree, settings)
	defer planning.destroy_inventory(first_inventory, context.allocator)
	defer planning.destroy_plan(first_plan, context.allocator)
	first := run_recordings(first_plan, o, context.allocator, nil, FAKE_RESUME_STAGES)
	testing.expect_value(t, first.transcribed, 1)
	testing.expect_value(t, first.failed, 0)

	reprofiled := settings
	reprofiled.merge_profile = transcript.profile_name(transcript.Merge_Profile.Conversation)

	second_inventory, second_plan := planned_resume(t, tree, reprofiled)
	defer planning.destroy_inventory(second_inventory, context.allocator)
	defer planning.destroy_plan(second_plan, context.allocator)
	for entry in second_plan.entries {
		testing.expectf(
			t,
			entry.outcome.decision == .Re_Render,
			"%s was not planned for a re-render after only its Merge Profile changed: %v",
			entry.found.source,
			entry.outcome.decision,
		)
	}

	reprofiled_options := o
	reprofiled_options.profile = .Conversation
	second := run_recordings(
		second_plan,
		reprofiled_options,
		context.allocator,
		nil,
		FAKE_RESUME_STAGES,
	)
	testing.expect_value(t, second.rerendered, 1)
	testing.expect_value(t, second.failed, 0)
	testing.expect_value(t, second.transcribed, 0)

	third_inventory, third_plan := planned_resume(t, tree, reprofiled)
	defer planning.destroy_inventory(third_inventory, context.allocator)
	defer planning.destroy_plan(third_plan, context.allocator)
	for entry in third_plan.entries {
		testing.expectf(
			t,
			entry.outcome.decision == .Skip,
			"%s was not resumed as settled after the re-render placed its new Merge Profile: %v",
			entry.found.source,
			entry.outcome.decision,
		)
	}
}
