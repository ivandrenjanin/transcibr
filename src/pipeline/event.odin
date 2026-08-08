#+vet explicit-allocators
package pipeline

// ADR-0041's seam: every fault src/pipeline used to hand straight to
// fmt.eprintln/fmt.println now leaves the package as one of these instead.
// `at` is an INT index into the caller's own `plan.entries`, never a
// pointer -- a pointer to worker-owned memory escaping onto another thread is
// exactly the hazard ADR-0010 names, and an int cannot dangle. `-1` means
// "no one Recording, this is Batch-level" (a swept cache, an identified
// Engine, a refused plan entry has one; a Batch summary line does not).
//
// Every string field is BORROWED for the length of the `on_event` call that
// carries it -- built by the reporting call site, read by the Observer, and
// freed by the reporting call site the moment `on_event` returns (the same
// discipline ADR-0038 settled for `Refusal_Arg`'s own `string` arm: safe
// exactly when the backing bytes outlive the value carrying them, which here
// means "for the one call and no longer"). An Observer that needs a string
// past that call clones it under an allocator of its own.
import "transcibr:doctor"
import "transcibr:process"

Event_Kind :: enum u8 {
	Batch_Started = 0,
	Admitted,
	Extracting,
	Transcribing,
	Progress,
	Engine_Line,
	Language,
	Placed,
	Flagged,
	Failed,
	Skipped,
	Refused,
	Stopped,
	Health,
	Note,
	Batch_Finished,
}

Event :: struct {
	kind:     Event_Kind,
	at:       int,
	percent:  int,
	said:     int,
	factor:   f64,
	from:     process.Progress_Source,
	health:   doctor.Health_Fault,
	source:   string,
	message:  string,
	path:     string,
	language: string,
}

// `user` is exactly `core:sync`'s own `rawptr`-plus-cast pattern: a plain
// `proc` value here (no Odin closure) crosses into a wndproc or a worker
// thread with no captured state of its own, so an Observer that needs state
// carries it explicitly, cast back at the top of its own `on_event`. A zero
// `Observer{}` (nil `on_event`) is a real, safe value -- `fire` below treats
// it as "nobody is listening" rather than as a programmer error, because a
// Batch of one (`--transcribe`) and every existing pipeline test build a
// `Recording_Job`/`Batch_Options` with no Observer at all.
Observer :: struct {
	on_event: proc(event: Event, user: rawptr),
	user:     rawptr,
}

// The one place an Event actually reaches an Observer. Never asserts
// `observer.on_event != nil` -- a nil Observer is the documented "nobody is
// listening" value above, not a caller mistake (A8's boundary reasoning
// applied to an internal seam rather than external input: the untested
// `src/cli` callers this seam exists for could easily forget to wire one,
// and the correct response to that is silence, not a crash mid-Batch).
fire :: proc(observer: Observer, event: Event) {
	assert(event.at >= -1, "an Event's at index must be -1 (batch-level) or a valid plan index")

	if observer.on_event == nil {
		return
	}
	observer.on_event(event, observer.user)
}
