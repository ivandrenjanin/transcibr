package planning

import "transcibr:artifact"

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
	engine_version: string,
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

decide :: proc(found: Found, settings: Settings) -> (outcome: Outcome) {
	assert(len(found.source) > 0, "there is no Recording here to decide anything about")
	assert(len(settings.merge_profile) > 0, "a Batch naming no Merge Profile decides nothing")
	defer assert(
		(outcome.change != .None) == (outcome.reason == .Settings_Changed),
		"a decision names a changed setting it was not made for, or hides the one it was",
	)
	defer assert(
		outcome.decision != .Skip || outcome.reason == .Up_To_Date,
		"a Recording was skipped for a reason that is not that it is done",
	)

	recorded, known := found.recorded.?
	current := current_of(found, settings, known ? recorded.container_ms : 0)
	if refusal, refused := refused(found, current); refused {
		return refusal
	}
	if !known {
		return unrecorded(found)
	}
	return resumed(found, recorded, current)
}

// Refused ahead of every resume rule, because a Recording nothing may be written
// for is not made runnable by an artifact that happens to be beside it -- and a
// foreign `notes.md` beside `notes.mp4` would otherwise read as a Transcript
// already up to date (ADR-0008).
@(private)
refused :: proc(found: Found, current: artifact.Sidecar) -> (outcome: Outcome, yes: bool) {
	assert(len(found.source) > 0, "there is no Recording here to refuse")
	defer assert(yes == (outcome.decision == .Refuse), "a refusal that did not refuse anything")

	if len(artifact.stem_of(found.source)) == 0 {
		return Outcome{decision = .Refuse, reason = .Names_No_File}, true
	}
	if !found.directory_writable {
		return Outcome{decision = .Refuse, reason = .Directory_Not_Writable}, true
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
@(private)
current_of :: proc(found: Found, settings: Settings, container_ms: i64) -> artifact.Sidecar {
	assert(container_ms >= 0, "a container cannot have lasted a negative length of time")
	assert(len(settings.engine_version) > 0, "an Engine nobody named is UNKNOWN, never empty")

	return artifact.sidecar_of(
		settings.engine_version,
		settings.model,
		settings.beam,
		settings.merge_profile,
		settings.prompt,
		found.bytes,
		found.modified_ns,
		container_ms,
	)
}

// `artifact.changed` answers with the FIRST recorded setting that differs, in an
// order where everything before the Merge Profile needs the GPU again (ADR-0003).
// There is no second comparison anywhere in this package.
@(private)
resumed :: proc(found: Found, recorded, current: artifact.Sidecar) -> Outcome {
	assert(
		len(current.merge_profile) > 0,
		"a Batch naming no Merge Profile compares against nothing",
	)

	change := artifact.changed(recorded, current)
	assert(
		change != .Container_Duration,
		"a duration this package copied out of the record differs from itself",
	)

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
rendered_again :: proc(found: Found, wanted: Outcome) -> (outcome: Outcome) {
	assert(wanted.decision == .Transcribe, "a decision was made before it was decided")
	assert(wanted.reason != .Up_To_Date, "a Recording needing nothing was sent to be rendered")

	outcome = wanted
	outcome.decision = found.engine_output ? .Re_Render : .Transcribe
	return outcome
}
