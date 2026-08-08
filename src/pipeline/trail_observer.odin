#+vet explicit-allocators
package pipeline

// ADR-0041's trail sink -- residual 3 of the #176 tracker comment (2026-08-08):
// an operating-error run used to note that it started and never why it
// failed. `write_event_to_trail` is that fix: every fault Event this package
// now fires reaches `crashlog.note` the same way `src/cli`'s own CLI
// refusals already do (`refuse`, main.odin), so the rolling trail carries the
// reason a mid-run fault happened, not only that the process ran at all.
// `crashlog` carries no `transcibr:` imports of its own (checked at the pin:
// every import in `src/crashlog/*.odin` is `core:`/`base:`/`win32`), so
// `pipeline` importing it here closes no cycle.
//
// Fix round 1 (PR #285's review, finding 1, Critical): `crashlog.note`
// (src/crashlog/record.odin's `record_note_line`) writes a line as six to
// nine separate unlocked `WriteFile` calls with no composed buffer -- safe
// only because, before this PR, every caller ran on `src/cli`'s one main
// thread. `write_event_to_trail` is now reached from `report_fault`/`fire`
// inside `extract_recording`, `transcribe_and_place` and
// `checked_first_recording_health`, all of which `run_batch` runs on spawned
// extract/transcribe worker threads (`spawn_extract_workers`, run.odin) --
// so two Recordings faulting at the same moment can interleave their
// `WriteFile` fragments into one torn trail line. The real fix (composing
// the line into one caller-owned buffer and issuing one `WriteFile`) belongs
// to `crashlog`, which this PR's fence excludes; `trail_mutex` closes the
// race from this side instead, serializing every call this package makes
// into `crashlog.note` -- the only path a worker thread can reach it through
// today, since every other `note` call site (`refuse`, `main`'s own process
// start) still runs on the CLI's single main thread.
import "core:sync"
import "transcibr:crashlog"

@(private)
trail_mutex: sync.Mutex

// Pure and independently testable: what level and subject a fault Event
// becomes as a trail line, with no file, handle or global state touched.
// `subject == ""` is the "this kind does not reach the trail" answer -- every
// kind `write_event_to_trail` does not yet wire (`.Batch_Started` through
// `.Batch_Finished`, minus the four below) reserved for a later stage, the
// same set `write_event_to_console`'s own switch leaves silent. Exhaustive
// over `Event_Kind` (issue #33): a member added with no arm here fails the
// build rather than silently never reaching the trail.
@(require_results)
trail_level_and_subject :: proc(kind: Event_Kind) -> (level: crashlog.Level, subject: string) {
	defer assert(
		len(subject) > 0 || level == .Info,
		"a kind that skips the trail must map to crashlog.Level.Info, not a level nobody reads",
	)
	defer assert(subject != "fault" || level == .Error, "the trail's only fault subject is Error")
	defer assert(level != .Error || subject == "fault", "the trail's only Error subject is fault")

	switch kind {
	case .Failed:
		return .Error, "fault"
	case .Refused:
		return .Warn, "refused"
	case .Health:
		return .Warn, "health"
	case .Note:
		return .Info, "note"
	case .Batch_Started,
	     .Admitted,
	     .Extracting,
	     .Transcribing,
	     .Progress,
	     .Engine_Line,
	     .Language,
	     .Placed,
	     .Flagged,
	     .Skipped,
	     .Stopped,
	     .Batch_Finished:
		return .Info, ""
	}
	return .Info, ""
}

// `crashlog.note` is `"contextless"` and a silent no-op with no log open
// (its own doc comment) -- this never has to check whether a log is open
// itself. A kind this PR does not route to the trail returns early with no
// assertion at all: that is simply a kind #16 has not wired a GUI-only story
// for yet, not a programmer error at this call site. `trail_mutex` (fix
// round 1) is what makes the actual `crashlog.note` call below safe from two
// worker threads at once.
write_event_to_trail :: proc(event: Event, user: rawptr) {
	level, subject := trail_level_and_subject(event.kind)
	if len(subject) == 0 {
		return
	}
	assert(
		len(subject) > 0,
		"write_event_to_trail must not reach crashlog.note with an empty subject",
	)
	assert(len(event.message) > 0, "a fault Event reaching the trail carried no message")

	sync.guard(&trail_mutex)
	crashlog.note(level, subject, event.message)
}

// The Observer `src/cli` actually wires everywhere it used to call
// `report_fault` alone (D5's "the trail is a second observer, wired in the
// same PR"): every fault reaches both sinks -- console first, because a
// console user is watching right now, the trail second, because it is the
// one nobody is watching until something has already gone wrong.
write_event_to_console_and_trail :: proc(event: Event, user: rawptr) {
	assert(
		user == nil,
		"write_event_to_console_and_trail's fan-out carries no observer state of its own",
	)

	write_event_to_console(event, user)
	write_event_to_trail(event, user)
}

FAULT_OBSERVER := Observer {
	on_event = write_event_to_console_and_trail,
}
