package planning

import "core:testing"
import "transcibr:artifact"

@(private)
A_DIGEST :: artifact.Digest("a1b2c3d4e5f60718293a4b5c6d7e8f901a2b3c4d5e6f708192a3b4c5d6e7f801")

@(private)
settings :: proc() -> Settings {
	return Settings {
		engine_version = "whisper.cpp 1.9.1",
		model = artifact.Model {
			path = "C:\\models\\ggml-large-v3-turbo.bin",
			digest = A_DIGEST,
			bytes = 1_624_555_275,
		},
		beam = artifact.ENGINE_DEFAULT_BEAM,
		merge_profile = "monologue",
		prompt = "",
	}
}

// What the Batch above would have written for this Recording last time.
@(private)
matching_sidecar :: proc(found: Found) -> artifact.Sidecar {
	s := settings()
	return artifact.sidecar_of(
		s.engine_version,
		s.model,
		s.beam,
		s.merge_profile,
		s.prompt,
		found.bytes,
		found.modified_ns,
		244_000,
	)
}

@(private)
expect_decided :: proc(
	t: ^testing.T,
	says: string,
	outcome: Outcome,
	decision: Decision,
	reason: Reason,
) {
	testing.expectf(
		t,
		outcome.decision == decision,
		"%s was %v rather than %v",
		says,
		outcome.decision,
		decision,
	)
	testing.expectf(
		t,
		outcome.reason == reason,
		"%s was decided for %v rather than for %v",
		says,
		outcome.reason,
		reason,
	)
}

@(private)
a_recording :: proc() -> Found {
	return Found {
		source = "C:\\clips\\talk.mp4",
		bytes = 412_998_144,
		modified_ns = 1_754_000_000_000_000_000,
		directory_writable = true,
	}
}

@(test)
a_recording_nothing_has_been_done_to_is_transcribed :: proc(t: ^testing.T) {
	outcome := decide(a_recording(), settings())

	testing.expect_value(t, outcome.decision, Decision.Transcribe)
	testing.expect_value(t, outcome.reason, Reason.Nothing_Recorded)
}

// Four ways a Recording is refused before a Batch spends anything on it. Each
// is checked against a Recording that would otherwise be SKIPPED, so a refusal
// that failed to fire would be visible as a skip rather than as a re-run.
@(test)
a_recording_a_batch_cannot_honour_is_refused_before_any_gpu_time :: proc(t: ^testing.T) {
	Case :: struct {
		says:   string,
		spoil:  proc(found: ^Found),
		reason: Reason,
	}

	for c in ([?]Case {
			{
				"a hand-authored notes.md beside notes.mp4",
				proc(f: ^Found) {f.transcript = .Foreign},
				.Foreign_Transcript,
			},
			{
				"a Recording in a directory nothing may be written to",
				proc(f: ^Found) {f.directory_writable = false},
				.Directory_Not_Writable,
			},
			{
				"a path that names no file to make artifacts from",
				proc(f: ^Found) {f.source = "C:\\clips\\"},
				.Names_No_File,
			},
			{
				"a Recording the filesystem dates before 1970",
				proc(f: ^Found) {f.modified_ns = -86_400_000_000_000},
				.Dated_Before_1970,
			},
		}) {
		found := a_recording()
		found.transcript = .Transcibrs
		found.engine_output = true
		found.recorded = matching_sidecar(found)
		c.spoil(&found)

		expect_decided(t, c.says, decide(found, settings()), .Refuse, c.reason)
	}
}

// The Engine's retained output is what makes re-rendering possible at all, so
// every reason to render again splits on whether it is still there.
@(test)
what_only_needs_rendering_again_is_rendered_from_the_retained_engine_output :: proc(
	t: ^testing.T,
) {
	Case :: struct {
		says:          string,
		transcript:    Transcript_State,
		engine_output: bool,
		profile:       string,
		decision:      Decision,
		reason:        Reason,
	}

	for c in ([?]Case {
			{
				"a Transcript deleted with its Engine output still beside it",
				.Absent,
				true,
				"monologue",
				.Re_Render,
				.Transcript_Missing,
			},
			{
				"a Transcript deleted with nothing left to render from",
				.Absent,
				false,
				"monologue",
				.Transcribe,
				.Transcript_Missing,
			},
			{
				"a Batch re-run on another Merge Profile",
				.Transcibrs,
				true,
				"conversation",
				.Re_Render,
				.Settings_Changed,
			},
			{
				"another Merge Profile with no retained Engine output",
				.Transcibrs,
				false,
				"conversation",
				.Transcribe,
				.Settings_Changed,
			},
		}) {
		found := a_recording()
		found.transcript = c.transcript
		found.engine_output = c.engine_output
		recorded := matching_sidecar(found)
		recorded.merge_profile = c.profile
		found.recorded = recorded

		expect_decided(t, c.says, decide(found, settings()), c.decision, c.reason)
	}
}

// ADR-0003: unknown provenance means re-do it. Re-rendering Engine output whose
// settings nothing recorded would stamp the CURRENTLY installed Engine version
// onto cues some other one decoded, which that decision calls worse than absent.
@(test)
engine_output_no_sidecar_vouches_for_is_transcribed_again_and_never_re_rendered :: proc(
	t: ^testing.T,
) {
	found := a_recording()
	found.engine_output = true

	outcome := decide(found, settings())

	testing.expect_value(t, outcome.decision, Decision.Transcribe)
	testing.expect_value(t, outcome.reason, Reason.Provenance_Unknown)
}

// Every setting `artifact.changed` can name, and the disposition each of them
// earns. A Batch re-run on a different Model is what ADR-0003 exists for.
@(test)
a_transcript_whose_recorded_settings_differ_is_done_again :: proc(t: ^testing.T) {
	Case :: struct {
		says:   string,
		spoil:  proc(recorded: ^artifact.Sidecar),
		change: artifact.Change,
	}

	for c in ([?]Case {
			{
				"a Recording that has been re-cut since",
				proc(r: ^artifact.Sidecar) {r.source_bytes -= 4096},
				.Source,
			},
			{
				"a Recording touched since",
				proc(r: ^artifact.Sidecar) {r.source_modified_ns += 1},
				.Source,
			},
			{
				"an Engine upgraded since",
				proc(r: ^artifact.Sidecar) {r.engine_version = "whisper.cpp 1.8.0"},
				.Engine_Version,
			},
			{
				"a Model selected by another path",
				proc(r: ^artifact.Sidecar) {r.model = "C:\\models\\ggml-large-v3.bin"},
				.Model,
			},
			{"a Model file replaced under the same name", proc(r: ^artifact.Sidecar) {
					r.model_digest = artifact.Digest(
						"0000000000000000000000000000000000000000000000000000000000000000",
					)
				}, .Model},
			{"a Model of another size", proc(r: ^artifact.Sidecar) {r.model_bytes += 1}, .Model},
			{"a beam width set since", proc(r: ^artifact.Sidecar) {r.beam = 5}, .Beam},
			{
				"a vocabulary prompt supplied since",
				proc(r: ^artifact.Sidecar) {r.prompt = "Kubernetes, etcd"},
				.Prompt,
			},
		}) {
		found := a_recording()
		found.transcript = .Transcibrs
		found.engine_output = true
		recorded := matching_sidecar(found)
		c.spoil(&recorded)
		found.recorded = recorded

		outcome := decide(found, settings())

		expect_decided(t, c.says, outcome, .Transcribe, .Settings_Changed)
		testing.expectf(
			t,
			outcome.change == c.change,
			"%s was reported as %v changing rather than %v",
			c.says,
			outcome.change,
			c.change,
		)
	}
}

@(test)
a_transcript_whose_recorded_settings_still_match_is_skipped :: proc(t: ^testing.T) {
	found := a_recording()
	found.transcript = .Transcibrs
	found.engine_output = true
	found.recorded = matching_sidecar(found)

	outcome := decide(found, settings())

	testing.expect_value(t, outcome.decision, Decision.Skip)
	testing.expect_value(t, outcome.reason, Reason.Up_To_Date)
}
