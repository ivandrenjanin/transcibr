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
import "transcibr:crashlog"

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
// itself, and it asserts nothing: a kind this PR does not route to the trail
// is not a programmer error at this call site, it is simply a kind #16 has
// not wired a GUI-only story for yet.
write_event_to_trail :: proc(event: Event, user: rawptr) {
	level, subject := trail_level_and_subject(event.kind)
	if len(subject) == 0 {
		return
	}
	crashlog.note(level, subject, event.message)
}

// The Observer `src/cli` actually wires everywhere it used to call
// `report_fault` alone (D5's "the trail is a second observer, wired in the
// same PR"): every fault reaches both sinks -- console first, because a
// console user is watching right now, the trail second, because it is the
// one nobody is watching until something has already gone wrong.
write_event_to_console_and_trail :: proc(event: Event, user: rawptr) {
	write_event_to_console(event, user)
	write_event_to_trail(event, user)
}

FAULT_OBSERVER := Observer {
	on_event = write_event_to_console_and_trail,
}
