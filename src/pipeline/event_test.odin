#+vet explicit-allocators
package pipeline

// ADR-0041's own three tests: the first in this repository that can assert a
// Batch prologue reported the right fault at all (a fake Observer over a
// deliberately broken path), the routing a fault Event takes to the trail
// sink (a pure mapping, no file touched), and the proof a zero `Observer{}`
// -- the value every existing `Recording_Job`/`Batch_Options` literal in this
// package already carries -- changes nothing about what `extract_recording`
// itself does.

import "core:strings"
import "core:testing"
import "transcibr:artifact"
import "transcibr:engine"
import "transcibr:testkit"
import "transcibr:transcript"

@(private)
Captured_Event :: struct {
	fired:   bool,
	kind:    Event_Kind,
	at:      int,
	message: string,
}

// Clones `event.message` immediately, under its own allocator -- the
// "an observer that keeps one clones it" half of event.odin's own doc
// comment. `event.message` is only valid for the length of this call: the
// reporting call site (`report_fault`) frees it, and the arena backing it is
// destroyed, the instant `fire` returns.
@(private)
capture_event :: proc(event: Event, user: rawptr) {
	captured := cast(^Captured_Event)user
	captured.fired = true
	captured.kind = event.kind
	captured.at = event.at
	captured.message = strings.clone(event.message, context.allocator)
}

@(test)
extract_recording_reports_a_missing_source_as_a_failed_event_not_only_stdio :: proc(
	t: ^testing.T,
) {
	cache := testkit.made_scratch_cache(
		t,
		"pipeline",
		"event-seam-missing-source",
		context.allocator,
	)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	captured: Captured_Event
	job := new_recording_job(
		"C:\\clips\\does-not-exist.mp4",
		"does-not-exist",
		nil,
		Tools{engine = engine.Tools{engine = "whisper-cli.exe"}},
		cache,
		artifact.Model{},
		"",
		"whisper.cpp 1.9.9",
		transcript.DEFAULT_PROFILE,
		engine.Report{},
		Health_Watch{},
		Observer{on_event = capture_event, user = &captured},
		7,
	)

	_, ok := extract_recording(job)
	defer delete(captured.message, context.allocator)

	testing.expect_value(t, ok, false)
	testing.expect_value(t, captured.fired, true)
	testing.expect_value(t, captured.kind, Event_Kind.Failed)
	testing.expect_value(t, captured.at, 7)
	testing.expect(t, len(captured.message) > 0, "a Failed event carried no message")
}

// A zero `Observer{}` (nil `on_event`) is the value every OTHER test in this
// package already builds a `Recording_Job` with -- this is what proves that
// choice is deliberate and safe rather than merely untested: the exact same
// missing-source path above, with no Observer wired at all, still refuses
// the same way and crashes nothing.
@(test)
a_nil_observer_changes_nothing_about_extract_recordings_own_outcome :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(
		t,
		"pipeline",
		"event-seam-nil-observer",
		context.allocator,
	)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	job := new_recording_job(
		"C:\\clips\\does-not-exist.mp4",
		"does-not-exist",
		nil,
		Tools{engine = engine.Tools{engine = "whisper-cli.exe"}},
		cache,
		artifact.Model{},
		"",
		"whisper.cpp 1.9.9",
		transcript.DEFAULT_PROFILE,
		engine.Report{},
		Health_Watch{},
	)

	_, ok := extract_recording(job)

	testing.expect_value(t, ok, false)
}

// The trail's own routing table (trail_observer.odin), pure and independent
// of `crashlog.note`'s own file I/O -- what actually decides whether a fault
// Event becomes a rolling-trail line, and under which subject.
@(test)
trail_routes_every_fault_kind_and_skips_every_kind_it_does_not_yet_own :: proc(t: ^testing.T) {
	_, failed_subject := trail_level_and_subject(.Failed)
	_, refused_subject := trail_level_and_subject(.Refused)
	_, health_subject := trail_level_and_subject(.Health)
	_, note_subject := trail_level_and_subject(.Note)
	_, progress_subject := trail_level_and_subject(.Progress)

	testing.expect_value(t, failed_subject, "fault")
	testing.expect_value(t, refused_subject, "refused")
	testing.expect_value(t, health_subject, "health")
	testing.expect_value(t, note_subject, "note")
	testing.expect_value(t, progress_subject, "")
}
