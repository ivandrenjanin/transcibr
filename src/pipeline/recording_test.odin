#+vet explicit-allocators
package pipeline

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "transcibr:artifact"
import "transcibr:audio"
import "transcibr:engine"
import "transcibr:planning"
import "transcibr:testkit"
import "transcibr:transcript"

// Freed by the caller with `delete` and the same allocator, exactly like a
// real `identify_model` answer -- `Sidecar` does not own the strings a caller
// builds it out of (see artifact.Sidecar's own doc comment), so `made.model_-`
// `digest` below stays valid only as long as this does.
@(private)
@(require_results)
a_digest :: proc(fill: u8) -> artifact.Digest {
	one := [1]u8{fill}
	return artifact.Digest(
		strings.repeat(string(one[:]), artifact.DIGEST_CHARS, context.allocator),
	)
}

// The landmine ADR-0027 names at `current_of` (src/planning/plan.odin): a
// worker that reused a RECORDED Sidecar to write a fresh one after a real
// transcribe would stamp the previous Engine's version onto cues the
// currently installed one decoded. `recording_sidecar` cannot do that even by
// accident -- its signature carries no recorded Sidecar at all, only what
// this Batch named and what this run measured -- and this pins the answer
// rather than the signature.
@(test)
recording_sidecar_never_carries_a_stale_recorded_engine_version :: proc(t: ^testing.T) {
	digest := a_digest('a')
	defer delete(string(digest), context.allocator)
	job := Recording_Job {
		source = "C:\\clips\\talk.mp4",
		engine_version = "whisper.cpp 1.9.9",
		model = artifact.Model{path = "C:\\models\\large.bin", digest = digest, bytes = 500},
		prompt = "names and jargon",
		profile = transcript.Merge_Profile.Conversation,
	}
	extracted := Recording_Extracted {
		planned = audio.Reading{bytes = 12_345, modified_ns = 67_890},
		extracted = audio.Extracted{container_ms = 30_000},
	}

	made := recording_sidecar(job, extracted)

	testing.expect_value(t, made.engine_version, "whisper.cpp 1.9.9")
	testing.expect_value(t, made.model, "C:\\models\\large.bin")
	testing.expect_value(t, made.merge_profile, "conversation")
	testing.expect_value(t, made.prompt, "names and jargon")
	testing.expect_value(t, made.source_bytes, i64(12_345))
	testing.expect_value(t, made.source_modified_ns, i64(67_890))
	testing.expect_value(t, made.container_ms, i64(30_000))
}

// The same proof from the other side: two Jobs built for the identical
// Recording but naming different Engines produce Sidecars that disagree on
// exactly that field -- there is no shared, cached "current" value a second
// call could leak from the first.
@(test)
recording_sidecar_reflects_whichever_engine_its_own_job_named :: proc(t: ^testing.T) {
	extracted := Recording_Extracted {
		planned = audio.Reading{bytes = 1, modified_ns = 1},
		extracted = audio.Extracted{container_ms = 1_000},
	}
	digest := a_digest('b')
	defer delete(string(digest), context.allocator)
	model := artifact.Model {
		path   = "m.bin",
		digest = digest,
		bytes  = 1,
	}

	first := recording_sidecar(
		Recording_Job {
			engine_version = "engine-one",
			model = model,
			profile = transcript.DEFAULT_PROFILE,
		},
		extracted,
	)
	second := recording_sidecar(
		Recording_Job {
			engine_version = "engine-two",
			model = model,
			profile = transcript.DEFAULT_PROFILE,
		},
		extracted,
	)

	testing.expect_value(t, first.engine_version, "engine-one")
	testing.expect_value(t, second.engine_version, "engine-two")
}

// The derivation issue #70 hoists out of `src/cli`: absent (no
// `--engine-version` on the command line) settles to `transcript.UNKNOWN`
// only here, at the record site -- never earlier, where it would leak into
// `planning.Settings` as a SET value and make a flagless `--batch` see an
// Engine changed that a flagless `--plan` never did.
@(test)
settled_engine_version_defaults_to_unknown_only_when_the_command_line_named_none :: proc(
	t: ^testing.T,
) {
	testing.expect_value(t, settled_engine_version(nil), transcript.UNKNOWN)
	testing.expect_value(t, settled_engine_version("whisper.cpp 1.9.9"), "whisper.cpp 1.9.9")
	testing.expect_value(t, settled_engine_version(""), transcript.UNKNOWN)
}

// The three outcomes `sort_entry` settles without ever building a Recording
// Job: nothing here should reach the GPU-serialising pipeline at all, which
// this proves by checking that `jobs` stays empty rather than by mocking
// run_batch.
@(test)
sort_entry_counts_skip_and_refuse_without_building_a_job :: proc(t: ^testing.T) {
	o := Batch_Options {
		profile = transcript.DEFAULT_PROFILE,
	}
	summary: Summary
	jobs := make([dynamic]Recording_Job, 0, 2, context.allocator)
	defer delete(jobs)

	skipped := planning.Entry {
		found = planning.Found{source = "C:\\clips\\done.mp4"},
		outcome = planning.Outcome{decision = .Skip, reason = .Up_To_Date},
	}
	refused := planning.Entry {
		found = planning.Found{source = "C:\\clips\\bad"},
		outcome = planning.Outcome{decision = .Refuse, reason = .Names_No_File},
	}

	sort_entry(&summary, skipped, o, context.allocator, &jobs)
	sort_entry(&summary, refused, o, context.allocator, &jobs)

	testing.expect_value(t, summary.skipped, 1)
	testing.expect_value(t, summary.refused, 1)
	testing.expect_value(t, summary.transcribed, 0)
	testing.expect_value(t, len(jobs), 0)
}

// The one entry sort_entry hands to the pipeline: a Job that carries the
// Recording forward and an arena of its own, freed by whichever Stage
// finishes it -- never freed here, because a Job that has not yet reached a
// Stage still owns it.
@(test)
sort_entry_builds_exactly_one_job_for_a_transcribe_decision :: proc(t: ^testing.T) {
	digest := a_digest('c')
	defer delete(string(digest), context.allocator)
	o := Batch_Options {
		model = artifact.Model{path = "m.bin", digest = digest, bytes = 1},
		profile = transcript.DEFAULT_PROFILE,
	}
	summary: Summary
	jobs := make([dynamic]Recording_Job, 0, 1, context.allocator)
	defer delete(jobs)

	entry := planning.Entry {
		found = planning.Found{source = "C:\\clips\\talk.mp4"},
		outcome = planning.Outcome{decision = .Transcribe, reason = .Nothing_Recorded},
	}
	sort_entry(&summary, entry, o, context.allocator, &jobs)
	defer abandon_recording_job(jobs[0])

	if !testing.expect_value(t, len(jobs), 1) {
		return
	}
	testing.expect_value(t, jobs[0].source, "C:\\clips\\talk.mp4")
	testing.expect_value(t, jobs[0].name, "talk")
	testing.expect(t, jobs[0].arena != nil, "a Job built for the pipeline carries no arena")
}

@(private)
@(require_results)
health_check_job :: proc(
	t: ^testing.T,
	tag: string,
	output_json: string,
	container_ms := i64(60_000),
	duration_ms := i64(3_000),
	elapsed_ms := i64(3_000),
) -> (
	job: Recording_Job,
	checked, abort, unhealthy: bool,
) {
	dir := testkit.made_scratch_cache(t, "Pipeline", tag, context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	output := fmt.aprintf("%s\\engine-output.json", dir, allocator = context.allocator)
	handle, unopenable := os.open(output, {.Write, .Create, .Trunc})
	testing.expect(t, unopenable == nil, "the case could not write its own fixture")
	_, unwritable := os.write(handle, transmute([]u8)output_json)
	testing.expect(t, unwritable == nil, "the case could not write its own fixture")
	os.close(handle)

	job = new_recording_job(
		"C:\\clips\\talk.mp4",
		"talk",
		nil,
		Tools{},
		dir,
		artifact.Model{},
		"",
		"whisper.cpp 1.9.9",
		transcript.DEFAULT_PROFILE,
		engine.Report{},
		Health_Watch{checked = &checked, abort = &abort, unhealthy = &unhealthy},
	)
	defer abandon_recording_job(job)
	defer delete(output, context.allocator)

	checked_first_recording_health(
		job,
		container_ms,
		engine.Transcribed{output = output, duration_ms = duration_ms, elapsed_ms = elapsed_ms},
	)
	return
}

@(test)
a_healthy_first_recording_is_checked_once_and_never_aborts_the_batch :: proc(t: ^testing.T) {
	_, checked, abort, unhealthy := health_check_job(
		t,
		"healthy",
		`{"systeminfo": "WHISPER : CUDA : ARCHS = 500,610,700"}`,
	)
	testing.expect_value(t, checked, true)
	testing.expect_value(t, abort, false)
	testing.expect_value(t, unhealthy, false)
}

// The finding this pins: `abort` alone is the identical pointer a Ctrl+C
// press sets, and `pipeline.batch_succeeded` reads a cancelled Batch as a
// success -- correct for an operator's own Ctrl+C, wrong for a Batch stopped
// because the GPU is not being used. `unhealthy` is the SEPARATE signal the
// CLI reads to answer a nonzero exit code specifically for this case, without
// changing what Ctrl+C itself still means.
@(test)
an_unhealthy_first_recording_sets_both_the_shared_abort_flag_and_its_own_unhealthy_flag :: proc(
	t: ^testing.T,
) {
	_, checked, abort, unhealthy := health_check_job(
		t,
		"unhealthy",
		`{"systeminfo": "WHISPER : no gpu backend at all"}`,
	)
	testing.expect_value(t, checked, true)
	testing.expect_value(t, abort, true)
	testing.expect_value(t, unhealthy, true)
}

@(test)
review_engine_output_with_no_systeminfo_field_must_not_abort_the_batch :: proc(t: ^testing.T) {
	_, checked, abort, unhealthy := health_check_job(
		t,
		"nosysteminfo",
		`{"result": {"language": "en"}}`,
	)
	testing.expect_value(t, checked, true)
	testing.expect_value(t, abort, false)
	testing.expect_value(t, unhealthy, false)
}

@(test)
review_unparseable_engine_output_must_not_abort_the_batch :: proc(t: ^testing.T) {
	_, checked, abort, unhealthy := health_check_job(t, "unparseable", `not json at all`)
	testing.expect_value(t, checked, true)
	testing.expect_value(t, abort, false)
	testing.expect_value(t, unhealthy, false)
}

// The exact shape a healthy `--batch` reaches on real hardware: the Engine's
// own reported audio duration equals the Recording's container length on
// every healthy run (both name the same audio), so a factor computed against
// `duration_ms` is always ~1.0x and always aborts. `elapsed_ms` here is the
// wall clock a fast GPU run actually takes for a 10-second clip -- the
// quantity the factor must be computed against instead.
@(test)
review_a_real_engine_duration_reading_must_not_abort_a_healthy_batch :: proc(t: ^testing.T) {
	_, checked, abort, unhealthy := health_check_job(
		t,
		"realengine",
		`{"systeminfo": "WHISPER : CUDA : ARCHS = 500,610,700"}`,
		container_ms = 10_000,
		duration_ms = 10_000,
		elapsed_ms = 600,
	)
	testing.expect_value(t, checked, true)
	testing.expect_value(t, abort, false)
	testing.expect_value(t, unhealthy, false)
}
