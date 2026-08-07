#+vet explicit-allocators
package planning

import "transcibr:artifact"

// What one Recording's Transcript is, if it is there at all. The Sidecar answers
// staleness and never ownership: ADR-0026.
//
// `.Unreadable` and not `.Foreign`: a Transcript-head read that hit its
// bound (`planning.transcript_state_bounded`, issue #27) was never actually
// read, and `.Foreign` tells the operator transcibr did not write it -- a
// confident wrong diagnosis when the truth is that discovery does not know.
// `.Unreadable` and not `.Absent` either, for the reason `.Foreign` already
// argues at its own call site: `.Absent` plans the Recording fresh, and
// planning fresh over a Transcript this walk never got to read risks the
// data loss ADR-0009's boundary rule exists to prevent (PR #64's second
// review, findings 3 and 4).
Transcript_State :: enum u8 {
	Absent = 0,
	Transcibrs,
	Foreign,
	Unreadable,
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
	// The Engine's own SHA-256, identified from `--engine-exe` the same way
	// `model` is identified from `--model-file` -- ADR-0027's reopening
	// clause, closed by issue #50. Always present: a Batch that cannot
	// identify its Engine is refused before `decide` ever runs (A8), so
	// there is no absent case left for this field to carry.
	engine_version: artifact.Digest,
	// The Engine binary's own path -- the human half of its identity, recorded
	// into every Sidecar this Batch writes alongside `engine_version` (issue
	// #50's fix round). Compared like any other recorded field
	// (`artifact.changed`), never treated as identity on its own: a Batch is
	// never refused or resumed off this field alone.
	engine_path:    string,
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
	Transcript_Unreadable,
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
	return writable(found, resumed(found, recorded, current))
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
//
// `switch found.transcript` and not an `if` chain, deliberately: `transcript_-`
// `state_of` (walk.odin) is exhaustive over `child.Wait` so a member neither
// this repository nor `transcibr:child` has today fails the build rather than
// falling through silently, and this is the classifying site `Transcript_-`
// `State` itself deserves the same guard at (PR #64's third review, finding
// 9). A fifth member with no arm here would otherwise reach `unrecorded` and
// `settled`, whose asserts name only `.Foreign` and `.Unreadable` and would
// wave it through.
@(private)
@(require_results)
refused :: proc(found: Found, current: artifact.Sidecar) -> (outcome: Outcome, yes: bool) {
	assert(len(found.source) > 0, "there is no Recording here to refuse")
	defer assert(yes == (outcome.decision == .Refuse), "a refusal that did not refuse anything")

	if len(artifact.stem_of(found.source)) == 0 {
		return Outcome{decision = .Refuse, reason = .Names_No_File}, true
	}
	switch found.transcript {
	case .Foreign:
		return Outcome{decision = .Refuse, reason = .Foreign_Transcript}, true
	case .Unreadable:
		return Outcome{decision = .Refuse, reason = .Transcript_Unreadable}, true
	case .Absent, .Transcibrs:
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
	assert(
		found.transcript != .Unreadable,
		"a Transcript-head read that hit its bound reached a resume rule",
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
// of nothing else. `container_ms` is copied out of the record rather than
// measured, so it describes work that was DONE only by coincidence, and only
// where nothing has changed. `engine_version` carries no such copy any more --
// ADR-0027's reopening clause, closed by issue #50: the Engine is identified
// from `--engine-exe` exactly as the Model is, so this Batch's own digest is
// what it is measured against, never a value borrowed from the record. Nothing
// persists this Sidecar: `Plan` carries no Sidecar and `--plan` writes nothing
// at all.
//
// So it is not the Sidecar to WRITE after a transcribe, and the next ticket to
// run a Plan (#12's pipeline, driven by #16) is where that becomes reachable.
//
// `recorded.container_ms >= 0` below runs on a value read back from a
// Sidecar file (rule A8: external input), not a fresh probe -- see the
// `container_ms` field note at its definition in src/artifact/sidecar.odin.
// It holds today only because `read_sidecar` parses the field with
// `read_natural`, which accepts digits only and no sign, so a negative value
// cannot come out of a file; it does not hold because `recorded` has been
// re-probed or re-checked.
//
// `>= 0` and not every sibling `container_ms` assert's `> 0`: the assert
// above runs only when `known` is true, which in production means
// `recorded` came from a real Sidecar file on disk (walk.odin's
// `sidecar_at` -> `read_sidecar`) -- the test beside it constructs one
// directly, so this is today's sole production producer, not an invariant
// of the `artifact.Sidecar` type itself.
// `read_sidecar` accepts a zero `container_ms`, and `artifact.recordable`
// refuses only a negative one (see sidecar.odin's `container_ms` field
// note) -- so a Sidecar written with `container_ms: 0` is a value this
// assert must tolerate, not a defect it exists to catch.
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
	assert(
		len(settings.engine_version) == artifact.DIGEST_CHARS,
		"a Batch's own Engine was not identified by a full digest",
	)
	assert(len(settings.engine_path) > 0, "a Batch's own Engine was not identified by a path")
	if known {
		assert(
			recorded.container_ms >= 0,
			"a container cannot have lasted a negative length of time",
		)
	}

	return artifact.sidecar_of(
		settings.engine_path,
		string(settings.engine_version),
		settings.model,
		settings.beam,
		settings.merge_profile,
		settings.prompt,
		found.bytes,
		found.modified_ns,
		known ? recorded.container_ms : 0,
	)
}

// `artifact.changed` answers with the FIRST recorded setting that differs, in an
// order where everything before the Merge Profile needs the GPU again (ADR-0003).
// There is no second comparison anywhere in this package.
@(private)
@(require_results)
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
@(require_results)
settled :: proc(found: Found) -> Outcome {
	assert(len(found.source) > 0, "there is no Recording here to settle anything about")
	assert(
		found.transcript != .Foreign,
		"a Markdown file transcibr did not write was taken for done",
	)
	assert(
		found.transcript != .Unreadable,
		"a Transcript-head read that hit its bound was taken for done",
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
