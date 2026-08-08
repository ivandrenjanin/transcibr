#+vet explicit-allocators
package pipeline

// ADR-0041's own three tests: the first in this repository that can assert a
// Batch prologue reported the right fault at all (a fake Observer over a
// deliberately broken path), the routing a fault Event takes to the trail
// sink (a pure mapping, no file touched), and the proof a zero `Observer{}`
// -- the value every existing `Recording_Job`/`Batch_Options` literal in this
// package already carries -- changes nothing about what `extract_recording`
// itself does.

import "core:fmt"
import "core:os"
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
	source:  string,
	message: string,
}

// Clones `event.message`/`event.source` immediately, under its own allocator
// -- the "an observer that keeps one clones it" half of event.odin's own doc
// comment. Both are only valid for the length of this call: the reporting
// call site frees `message` (`report_fault`) or holds `source` on its own
// stack (`checked_first_recording_health`), and either can vanish the
// instant `fire` returns.
@(private)
capture_event :: proc(event: Event, user: rawptr) {
	captured := cast(^Captured_Event)user
	captured.fired = true
	captured.kind = event.kind
	captured.at = event.at
	captured.source = strings.clone(event.source, context.allocator)
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
	defer delete(captured.source, context.allocator)
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

// Fix round 2 (PR #285's review, finding 1, Important): event.odin's own doc
// comment on `Observer` says a partly-built value -- `user` set, `on_event`
// still nil -- is exactly as safe as a zero `Observer{}`, because no sink can
// read `user` without `on_event`. This is the shape #16's GUI sink will build
// mid-construction. `fire` must treat it the same as "nobody is listening":
// return without touching `user`, never assert it.
@(test)
fire_treats_a_partly_built_observer_the_same_as_a_zero_observer :: proc(t: ^testing.T) {
	state: int
	fire(Observer{user = &state}, Event{kind = .Failed, at = -1, message = "m"})

	testing.expect_value(t, state, 0)
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

// Fix round 1 (PR #285's review, finding 3, Important): before this test,
// every existing health test built its `Recording_Job` through
// `health_checked_job` (recording_test.odin), which passes no Observer --
// the zero `Observer{}` short-circuits `fire`, so the `.Health` fire block
// inside `checked_first_recording_health` was reached by zero tests. The
// reviewer deleted that whole `fire(...)` block and measured src/pipeline's
// suite green 2/2 runs. This test builds its own Job with a real Observer
// wired, drives an "no gpu backend at all" fixture through
// `checked_first_recording_health` the same way `health_checked_job` does,
// and asserts the captured Event actually carries the `.Health` shape the
// reviewer's own probe measured (kind `.Health`, `source == job.source`,
// non-empty message, `health != .None`).
@(test)
checked_first_recording_health_fires_a_health_event_reaching_the_observer :: proc(t: ^testing.T) {
	dir := testkit.made_scratch_cache(t, "pipeline", "event-seam-health", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	output := fmt.aprintf("%s\\engine-output.json", dir, allocator = context.allocator)
	defer delete(output, context.allocator)
	handle, unopenable := os.open(output, {.Write, .Create, .Trunc})
	testing.expect(t, unopenable == nil, "the case could not write its own fixture")
	json_text := `{"systeminfo": "WHISPER : no gpu backend at all"}`
	_, unwritable := os.write(handle, transmute([]u8)json_text)
	testing.expect(t, unwritable == nil, "the case could not write its own fixture")
	os.close(handle)

	captured: Captured_Event
	checked, abort, unhealthy: bool
	job := new_recording_job(
		"C:\\clips\\talk.mp4",
		"talk",
		nil,
		Tools{engine = engine.Tools{engine = "whisper-cli.exe"}},
		dir,
		artifact.Model{},
		"",
		"whisper.cpp 1.9.9",
		transcript.DEFAULT_PROFILE,
		engine.Report{},
		Health_Watch{checked = &checked, abort = &abort, unhealthy = &unhealthy},
		Observer{on_event = capture_event, user = &captured},
		3,
	)
	defer abandon_recording_job(job)

	checked_first_recording_health(
		job,
		60_000,
		engine.Transcribed{output = output, duration_ms = 3_000, elapsed_ms = 3_000},
	)
	defer delete(captured.source, context.allocator)
	defer delete(captured.message, context.allocator)

	testing.expect_value(t, captured.fired, true)
	testing.expect_value(t, captured.kind, Event_Kind.Health)
	testing.expect_value(t, captured.at, 3)
	testing.expect_value(t, captured.source, job.source)
	testing.expect(t, len(captured.message) > 0, "a Health event carried no message")
}
