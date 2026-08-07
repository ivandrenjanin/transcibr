#+vet explicit-allocators
package child

import "base:runtime"
import win32 "core:sys/windows"
import "core:thread"
import "core:time"
import "transcibr:crashlog"

// A persistent OS thread reused across many bounded jobs, instead of one
// created and joined per job. A walk over N Recordings across D directories
// used to pay for a fresh thread per Transcript-head read, per Sidecar read
// and per directory listing -- 2N+D create/join pairs, almost all of them
// for the dominant case where neither file exists and the whole answer is
// ERROR_FILE_NOT_FOUND (issue #65's follow-up review, PR #64's third
// review, finding 3).
//
// `wake` and `done` stand in for a one-shot thread's own win32 handle,
// which `await_or_abandon` waits on because a one-shot thread's handle
// signals the instant it exits. A persistent thread never exits between
// jobs, so it needs its own signal for "a job is waiting" and its own
// signal for "that job is done" -- both auto-reset, so one `SetEvent`
// wakes exactly one wait and re-arms for the next.
// `wedged` is what turns `release_worker`'s "never after `.Unstoppable`"
// precondition from prose into something a caller cannot get past silently:
// PR #64's fourth review found the one test pinning this contract itself
// violating it, unconditionally releasing a worker `run_on_worker` had just
// reported `.Unstoppable`, past a soft `testing.expect_value` that recorded
// the mismatch and let the case carry on into the join that never returns.
Worker :: struct {
	thread: ^thread.Thread,
	wake:   win32.HANDLE,
	done:   win32.HANDLE,
	job:    proc(data: rawptr),
	data:   rawptr,
	wedged: bool,
}

// The crash hook is installed here rather than around each `w.job` call: this
// loop IS the persistent thread's entry point, so one assignment on the way in
// covers every job that thread will ever run. Why it cannot be folded into a
// helper: `read_worker`'s own doc comment, and `transcibr:crashlog`'s.
@(private)
worker_loop :: proc(w: ^Worker) {
	context.assertion_failure_proc = crashlog.assertion_hook
	assert(w != nil, "a worker thread was started with no worker to run")

	for {
		win32.WaitForSingleObject(w.wake, win32.INFINITE)
		if w.job == nil {
			return
		}
		w.job(w.data)
		win32.SetEvent(w.done)
	}
}

@(private)
close_worker_events :: proc(w: ^Worker) {
	assert(w != nil, "there is no worker here to close the events of")

	if w.wake != nil {
		win32.CloseHandle(w.wake)
	}
	if w.done != nil {
		win32.CloseHandle(w.done)
	}
}

// `nil` on any failure to set the worker up at all -- the same resource-
// exhaustion sentinel `thread.create_and_start_with_data` already hands
// every one-shot caller in this tree, so a caller checks it the same way.
@(require_results)
spawn_worker :: proc() -> ^Worker {
	w := new(Worker, runtime.heap_allocator())
	w.wake = win32.CreateEventW(nil, false, false, nil)
	w.done = win32.CreateEventW(nil, false, false, nil)
	if w.wake == nil || w.done == nil {
		close_worker_events(w)
		free(w, runtime.heap_allocator())
		return nil
	}

	context.allocator = runtime.heap_allocator()
	t := thread.create_and_start_with_poly_data(w, worker_loop)
	if t == nil {
		close_worker_events(w)
		free(w, runtime.heap_allocator())
		return nil
	}
	w.thread = t
	return w
}

// The reusable-worker counterpart to `await_or_abandon`: the same bound,
// the same `win32.CancelSynchronousIo` escalation past it, and the same
// three outcomes -- polling `w.done` rather than `thread.is_done`, since
// `w`'s own thread never finishes between jobs. `.Unstoppable` means `w`
// itself is no longer safe to hand a job: `spawn_worker` a fresh one and
// let this one leak exactly as an abandoned one-shot thread already does --
// neither `w` nor whatever `data` points at may be touched again once this
// returns `.Unstoppable`, the identical contract `await_or_abandon`
// documents for a one-shot thread.
//
// `WAIT_FAILED` answers `.Unstoppable` directly, the same reasoning
// `await_or_abandon` carries for a one-shot thread (finding 8): nothing here
// was actually waited on for `bound_ms`, so there is nothing that makes a
// cancel-and-poll loop against it any more trustworthy.
@(require_results)
run_on_worker :: proc(w: ^Worker, job: proc(data: rawptr), data: rawptr, bound_ms: i64) -> Wait {
	assert(w != nil, "there is no worker here to run a job on")
	assert(w.thread != nil, "a worker with no thread was handed a job")
	assert(job != nil, "a worker was asked to run no job at all")
	assert(bound_ms > 0, "a wait for no time at all cannot tell a wedge from a fast answer")
	assert(
		bound_expressible(bound_ms),
		"a bound this large cannot be expressed to WaitForSingleObject without meaning INFINITE",
	)
	assert(!w.wedged, "a worker already reported unstoppable was handed another job")

	w.job = job
	w.data = data
	win32.SetEvent(w.wake)

	switch win32.WaitForSingleObject(w.done, win32.DWORD(bound_ms)) {
	case win32.WAIT_OBJECT_0:
		return .Finished
	case win32.WAIT_TIMEOUT:
	case win32.WAIT_FAILED:
		w.wedged = true
		return .Unstoppable
	case:
		unreachable()
	}

	cancelling := time.tick_now()
	for win32.WaitForSingleObject(w.done, 0) != win32.WAIT_OBJECT_0 {
		if i64(time.duration_milliseconds(time.tick_since(cancelling))) > CANCEL_BOUND_MS {
			w.wedged = true
			return .Unstoppable
		}
		_ = CancelSynchronousIo(w.thread.win32_thread)
		time.sleep(READ_POLL)
	}
	return .Stopped
}

// Only safe once `w` is known idle -- after `run_on_worker` answered
// `.Finished` or `.Stopped`, never after `.Unstoppable`: the thread may
// still be inside the job it was abandoned for, and joining it would be the
// same indefinite wait issue #27 exists to abolish. `w.wedged` is the check
// below and not only this paragraph.
release_worker :: proc(w: ^Worker) {
	assert(w != nil, "there is no worker here to release")
	assert(w.thread != nil, "a worker with no thread was released")
	assert(!w.wedged, "release_worker called on a worker still wedged in an unstoppable job")

	w.job = nil
	win32.SetEvent(w.wake)
	thread.destroy(w.thread)
	close_worker_events(w)
	free(w, runtime.heap_allocator())
}
