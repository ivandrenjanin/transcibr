#+vet explicit-allocators
package pipeline

// Fix round 1 (PR #285's review, finding 1, Critical): proves `trail_mutex`
// actually serializes `write_event_to_trail` rather than merely existing.
// This does not open a real crashlog file -- `crashlog.note` is a silent
// no-op with no log installed (its own doc comment), and installing one
// in-process means calling `crashlog.register`, which points
// `SetUnhandledExceptionFilter` at process-wide state the implementer's own
// report (decision 3) already ruled out running from inside this package's
// tests, for the same reason `crashlog_crash_test.odin` spawns a separate
// binary instead. What is provable from here, without that risk, is that a
// second caller of `write_event_to_trail` blocks for as long as the first
// holds `trail_mutex` -- the exact race the reviewer's isolation probe
// measured (581/640 torn lines at 8 threads, 0/80 at 1) -- and unblocks the
// instant the first releases it. The bound-then-give-up shape below is
// `topology_test.odin`'s own `nothing_entered`/`await_entry` pattern: poll,
// never hang the runner.

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

@(private)
TRAIL_MUTEX_TEST_BOUND_MS :: i64(2_000)

@(private)
trail_probe :: proc(started, finished: ^bool) {
	sync.atomic_store(started, true)
	write_event_to_trail(Event{kind = .Failed, message = "probe fault"}, nil)
	sync.atomic_store(finished, true)
}

@(test)
write_event_to_trail_serializes_concurrent_calls_through_trail_mutex :: proc(t: ^testing.T) {
	sync.mutex_lock(&trail_mutex)

	started, finished: bool
	worker := thread.create_and_start_with_poly_data2(&started, &finished, trail_probe)
	defer thread.destroy(worker)

	start_deadline := time.tick_now()
	for !sync.atomic_load(&started) {
		if i64(time.duration_milliseconds(time.tick_since(start_deadline))) >
		   TRAIL_MUTEX_TEST_BOUND_MS {
			testing.expect(t, false, "the probe thread never reached write_event_to_trail")
			sync.mutex_unlock(&trail_mutex)
			return
		}
		time.sleep(time.Millisecond)
	}

	held_deadline := time.tick_now()
	for i64(time.duration_milliseconds(time.tick_since(held_deadline))) < 100 {
		if sync.atomic_load(&finished) {
			testing.expect(
				t,
				false,
				"write_event_to_trail finished while trail_mutex was still held elsewhere",
			)
			sync.mutex_unlock(&trail_mutex)
			return
		}
		time.sleep(time.Millisecond)
	}

	sync.mutex_unlock(&trail_mutex)

	finish_deadline := time.tick_now()
	for !sync.atomic_load(&finished) {
		if i64(time.duration_milliseconds(time.tick_since(finish_deadline))) >
		   TRAIL_MUTEX_TEST_BOUND_MS {
			testing.expect(
				t,
				false,
				"write_event_to_trail never returned once trail_mutex was released",
			)
			return
		}
		time.sleep(time.Millisecond)
	}

	thread.join(worker)
}
