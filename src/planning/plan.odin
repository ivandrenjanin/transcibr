#+vet explicit-allocators
package planning

import "transcibr:artifact"
import "transcibr:transcript"

// What one Recording's Transcript is, if it is there at all. The Sidecar answers
// staleness and never ownership: ADR-0026.
Transcript_State :: enum u8 {
	Absent = 0,
	Transcibrs,
	Foreign,
}

// One Recording as discovery found it. Everything a decision rests on is HERE:
// nothing in this file reads a clock, a file or an environment (ADR-0009).
Found :: struct {
	source:             string,
	bytes:              i64,
	modified_ns:        i64,
	transcript:         Transcript_State,
	engine_output:      bool,
	recorded:           Maybe(artifact.Sidecar),
	directory_writable: bool,
}

// Everything a Batch settles once, against which every Recording is measured.
Settings :: struct {
	// NOTHING where the Batch does not name an Engine, which is the ordinary
	// command line: `--engine-version` is optional. See `engine_of`.
	engine_version: Maybe(string),
	model:          artifact.Model,
	beam:           u32,
	merge_profile:  string,
	prompt:         string,
}

Decision :: enum u8 {
	Transcribe = 0,
	Re_Render,
	Skip,
	Refuse,
}

Reason :: enum u8 {
	Nothing_Recorded = 0,
	Up_To_Date,
	Settings_Changed,
	Transcript_Missing,
	Provenance_Unknown,
	Names_No_File,
	Foreign_Transcript,
	Dated_Before_1970,
	Directory_Not_Writable,
}

Outcome :: struct {
	decision: Decision,
	reason:   Reason,
	// Set for `.Settings_Changed` and for nothing else: which recorded setting
	// differs from the Batch's own.
	change:   artifact.Change,
}

@(require_results)
decide :: proc(found: Found, settings: Settings) -> (outcome: Outcome) {
	assert(len(found.source) > 0, "there is no Recording here to decide anything about")
	assert(len(settings.merge_profile) > 0, "a Batch naming no Merge Profile decides nothing")
	defer assert(
		(outcome.change != .None) == (outcome.reason == .Settings_Changed),
		"a decision names a changed setting it was not made for, or hides the one it was",
	)
	defer if outcome.decision == .Skip {
		assert(
			outcome.reason == .Up_To_Date,
			"a Recording was skipped for a reason that is not that it is done",
		)
	}

	recorded, known := found.recorded.?
	current := current_of(found, settings, recorded, known)
	if refusal, refused := refused(found, current); refused {
		return refusal
	}
	if !known {
		return writable(found, unrecorded(found))
	}
	return writable(found, resumed(found, recorded, current, settings))
}

// Checked AGAINST the decision and never ahead of it: nothing is written for a
// Recording that is already done, so a read-only archive of finished work
// reports itself finished rather than refusing every Recording in it. Criterion
// two and criterion eight meet here, and this is the resolution.
@(private)
@(require_results)
writable :: proc(found: Found, wanted: Outcome) -> Outcome {
	assert(len(found.source) > 0, "there is no Recording here to decide anything about")
	assert(wanted.decision != .Refuse, "a Recording refused twice, for two different reasons")

	if wanted.decision == .Skip {
		return wanted
	}
	if found.directory_writable {
		return wanted
	}
	return Outcome{decision = .Refuse, reason = .Directory_Not_Writable}
}

// Refused ahead of every resume rule, because none of these is answered by an
// artifact that happens to be beside the Recording: a foreign `notes.md` beside
// `notes.mp4` would otherwise read as a Transcript already up to date
// (ADR-0008). Whether the directory can be WRITTEN to is not here and cannot be
// -- see `writable`.
@(private)
@(require_results)
refused :: proc(found: Found, current: artifact.Sidecar) -> (outcome: Outcome, yes: bool) {
	assert(len(found.source) > 0, "there is no Recording here to refuse")
	defer assert(yes == (outcome.decision == .Refuse), "a refusal that did not refuse anything")

	if len(artifact.stem_of(found.source)) == 0 {
		return Outcome{decision = .Refuse, reason = .Names_No_File}, true
	}
	if found.transcript == .Foreign {
		return Outcome{decision = .Refuse, reason = .Foreign_Transcript}, true
	}
	if !artifact.recordable(current) {
		return Outcome{decision = .Refuse, reason = .Dated_Before_1970}, true
	}
	return {}, false
}

// Artifacts with no Sidecar behind them are an interrupted run, and what they
// were made with is exactly what nothing on disk says.
@(private)
@(require_results)
unrecorded :: proc(found: Found) -> Outcome {
	assert(len(found.source) > 0, "there is no Recording here to decide anything about")
	assert(
		found.transcript != .Foreign,
		"a Markdown file transcibr did not write reached a resume rule",
	)

	if found.transcript == .Absent && !found.engine_output {
		return Outcome{decision = .Transcribe, reason = .Nothing_Recorded}
	}
	return Outcome{decision = .Transcribe, reason = .Provenance_Unknown}
}

// The container's own duration is carried over from the record rather than
// probed: a Recording whose size and modification time are unchanged is the same
// file, and probing every Recording to plan a Batch is the GPU-free half of the
// work this ticket exists to avoid (ADR-0026).
//
// This Sidecar is the right-hand side of a COMPARISON and is the right-hand side
// of nothing else. Two of its fields are copied out of the record rather than
// measured -- `container_ms` here, and `engine_version` wherever the Batch names
// no Engine (see `engine_of`) -- so it describes work that was DONE only by
// coincidence, and only where nothing has changed. Nothing persists it: `Plan`
// carries no Sidecar and `--plan` writes nothing at all.
//
// So it is not the Sidecar to WRITE after a transcribe, and the next ticket to
// run a Plan (#12's pipeline, driven by #16) is where that becomes reachable. A
// worker that recorded a fresh run with this would stamp the PREVIOUS Engine's
// version onto cues the currently installed one decoded -- the wrong provenance
// ADR-0003 forbids, and the exact danger ADR-0027 names for this field. What
// records a run is what that run actually used: `transcript.UNKNOWN` where the
// Batch named no Engine, and the duration the probe measured.
@(private)
@(require_results)
current_of :: proc(
	found: Found,
	settings: Settings,
	recorded: artifact.Sidecar,
	known: bool,
) -> artifact.Sidecar {
	assert(
		len(settings.merge_profile) > 0,
		"a Batch naming no Merge Profile compares against nothing",
	)
	if known {
		assert(
			recorded.container_ms >= 0,
			"a container cannot have lasted a negative length of time",
		)
	}

	return artifact.sidecar_of(
		engine_of(settings, recorded, known),
		settings.model,
		settings.beam,
		settings.merge_profile,
		settings.prompt,
		found.bytes,
		found.modified_ns,
		known ? recorded.container_ms : 0,
	)
}

// The Engine this Batch would record, and the Engine it MEASURES against. A
// Batch that names one is measured against it. A Batch that names NONE is
// measured against the record's own -- the same copy the container duration
// gets, and for a stricter reason: the Engine is the one setting taken on faith
// where the Model is hashed to identity, so an Engine nobody named is an
// unanswerable question rather than a change.
//
// The direction matters and is not symmetric. A RECORD that names no Engine is
// unknown provenance and ADR-0003 re-does it; a BATCH that names no Engine has
// said nothing about the Engine at all, and re-transcribing a finished corpus
// because somebody did not re-type a version string is hours of GPU time spent
// on an absence. Where there is no record either, what a run with no
// `--engine-version` writes is UNKNOWN, and that is what this would record.
@(private)
@(require_results)
engine_of :: proc(
	settings: Settings,
	recorded: artifact.Sidecar,
	known: bool,
) -> (
	engine: string,
) {
	defer assert(len(engine) > 0, "an Engine nobody named is UNKNOWN, never empty")

	if named, on_purpose := settings.engine_version.?; on_purpose {
		if len(named) > 0 {
			return named
		}
	}
	if known {
		return recorded.engine_version
	}
	return transcript.UNKNOWN
}

// `artifact.changed` answers with the FIRST recorded setting that differs, in an
// order where everything before the Merge Profile needs the GPU again (ADR-0003).
// There is no second comparison anywhere in this package.
@(private)
@(require_results)
resumed :: proc(found: Found, recorded, current: artifact.Sidecar, settings: Settings) -> Outcome {
	assert(
		len(current.merge_profile) > 0,
		"a Batch naming no Merge Profile compares against nothing",
	)

	change := artifact.changed(recorded, current)
	assert(
		change != .Container_Duration,
		"a duration this package copied out of the record differs from itself",
	)
	if _, named := settings.engine_version.?; !named {
		assert(
			change != .Engine_Version,
			"an Engine this package copied out of the record differs from itself",
		)
	}

	switch change {
	case .None:
		return settled(found)
	case .Merge_Profile:
		return rendered_again(found, Outcome{reason = .Settings_Changed, change = change})
	case .Source, .Engine_Version, .Model, .Beam, .Prompt, .Container_Duration:
		return Outcome{decision = .Transcribe, reason = .Settings_Changed, change = change}
	}
	unreachable()
}

@(private)
@(require_results)
settled :: proc(found: Found) -> Outcome {
	assert(len(found.source) > 0, "there is no Recording here to settle anything about")
	assert(
		found.transcript != .Foreign,
		"a Markdown file transcibr did not write was taken for done",
	)

	if found.transcript == .Transcibrs {
		return Outcome{decision = .Skip, reason = .Up_To_Date}
	}
	return rendered_again(found, Outcome{reason = .Transcript_Missing})
}

// Rendering again is only cheap while the Engine's own output is still there;
// without it the same reason costs the whole of the GPU time over again.
@(private)
@(require_results)
rendered_again :: proc(found: Found, wanted: Outcome) -> (outcome: Outcome) {
	assert(wanted.decision == .Transcribe, "a decision was made before it was decided")
	assert(wanted.reason != .Up_To_Date, "a Recording needing nothing was sent to be rendered")

	outcome = wanted
	outcome.decision = found.engine_output ? .Re_Render : .Transcribe
	return outcome
}
