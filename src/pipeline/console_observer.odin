#+vet explicit-allocators
package pipeline

// ADR-0041's console sink: the Observer `src/cli` wires everywhere it used to
// call `report_fault`/`fmt.eprintfln` directly, rendering the identical bytes
// those calls always wrote. `write_event_to_console` is the whole of what
// `report_fault`/`checked_first_recording_health`'s own health line used to
// do, moved here rather than deleted, so a `Batch prologue` fault still
// prints on stderr exactly where a user has always looked for it -- the
// byte-identity obligation this record's own PR body pins with a test.
import "core:fmt"

// Exhaustive over every `Event_Kind` (issue #33's enumerated-switch guard): a
// kind this PR does not yet produce -- `.Batch_Started` through
// `.Batch_Finished`, minus the four wired below -- renders nothing today,
// reserved for #16's GUI sink and, later, a console line of its own. Adding a
// member to `Event_Kind` with no arm here fails the build outright rather
// than silently printing nothing forever.
write_event_to_console :: proc(event: Event, user: rawptr) {
	switch event.kind {
	case .Failed, .Refused, .Note:
		assert(
			len(event.message) > 0,
			"a Failed/Refused/Note event reached the console with no message",
		)
		fmt.eprintln(event.message)
	case .Health:
		assert(len(event.source) > 0, "a Health event reached the console with no source")
		assert(len(event.message) > 0, "a Health event reached the console with no message")
		fmt.eprintfln("%s: %s", event.source, event.message)
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
	}
}

// The one Observer `src/pipeline` builds for itself: every production caller
// in `src/cli` passes this (directly, or folded into its own fan-out
// Observer alongside the trail sink) so a Recording's fault reaches stderr
// exactly as it always has, whether or not a Batch is running.
CONSOLE_OBSERVER := Observer {
	on_event = write_event_to_console,
}
