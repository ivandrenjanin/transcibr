#+vet explicit-allocators
package child

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"
import "core:thread"
import "core:time"
import "transcibr:crashlog"

// Bounding a blocking read the same way run_bounded bounds a child. A path
// typed by hand or derived from a Recording can name a reserved Windows
// device -- CON, AUX, COM1 -- whose read never returns even with stdin from
// the null device, and a stalled network share or a named pipe with nobody
// writing to it block the identical way (issue #27). Nothing about a blocked
// ReadFile can be polled from outside it, so the read runs on its own thread
// and this package polls THAT the way run_bounded polls a child: a ceiling,
// and past it, `win32.CancelSynchronousIo` asks the thread's own blocked call
// to return before anything is ever left to leak -- see `Wait` below for what
// happens when that does not work.

// Order of magnitude alongside STOP_BOUND_MS, on purpose: both answer "how
// long transcibr waits for something outside it to answer". Grounded rather
// than assumed: the committed fixture (`transcibr:transcript`'s
// `engine-output.json`) is 2,335 bytes for 30,356 ms of audio -- about 77
// bytes of Engine JSON per second transcribed. Scaled to the corpus's longest
// Recording, 168 minutes (docs/spec/0001-transcibr-v1.md), at the SAME
// segment density that gives about 760 KiB; a Recording segmented several
// times denser than the fixture -- short, choppy phrases throughout -- still
// lands in the low megabytes. Even a pessimistic 8 MiB has only to average
// 267 KiB/s over thirty seconds to land inside the bound, which is well
// below what "slow but still answering" means for a share -- a share slower
// than that is the wedge this bound exists to abandon, not a Recording it
// should have finished with.
// `a_worst_case_sized_engine_output_reads_well_within_its_bound` in
// read_test.odin is what pins this against real disk I/O, using
// READ_BOUND_MS itself rather than a shortened stand-in.
READ_BOUND_MS :: i64(30_000)

#assert(READ_BOUND_MS > 0)

// Deliberately smaller than READ_BOUND_MS: once cancellation is requested,
// the thread only has to let its already-blocked call return with an error,
// not finish the read it was abandoned for not finishing. Measured against
// eight reads blocked on a named pipe nobody was writing to, cancelled and
// joined together: 6.5 ms total, thread count back at its exact baseline.
// Five seconds is margin against a slower machine, not the expected cost.
@(private)
CANCEL_BOUND_MS :: i64(5_000)

#assert(CANCEL_BOUND_MS > 0)
#assert(CANCEL_BOUND_MS < READ_BOUND_MS)

// The cancellation phase's own poll, and nothing else's: `await_or_abandon`
// waits for `bound_ms` with one exact `win32.WaitForSingleObject` rather
// than a loop, so this interval is only ever spent asking
// `win32.CancelSynchronousIo` again after a bound has already been missed.
// Fine enough that a short CANCEL_BOUND_MS in a test is not spent entirely
// on granularity, and far too coarse to matter against a cancellation that
// is itself measured in single-digit milliseconds.
@(private)
READ_POLL :: 10 * time.Millisecond

// A second, smaller vocabulary alongside `Fault`: `Fault` names a child that
// did not start or run to completion, `Read_Fault` names a read that could
// not be brought back an answer at all.
Read_Fault :: enum u8 {
	None = 0,
	Not_Started,
	Unreadable,
	Did_Not_Finish,
}

Read_Error :: struct {
	fault:    Read_Fault,
	// Only meaningful when fault == .Unreadable.
	os_error: os.Error,
}

// What waiting on a thread this package cannot otherwise poll came to. The
// vocabulary matches `Run` in run.odin on purpose, one layer down: `Finished`
// is a natural end, `Stopped` is one this package asked for and got, and
// `Unstoppable` is the one case nothing here could end -- the same three
// shapes `stop` in child.odin already reports for a whole process.
Wait :: enum u8 {
	Finished,
	Stopped,
	Unstoppable,
}

// Whether `bound_ms` can be handed to `WaitForSingleObject` without meaning
// something this package never intends: `core:sys/windows` defines
// `INFINITE :: ~DWORD(0)`, which is bit-identical to `max(win32.DWORD)`, so
// a guard that ADMITS `bound_ms == max(win32.DWORD)` admits an unbounded
// wait -- the exact defect issue #27 exists to abolish, previously let
// through by `bound_ms <= i64(max(win32.DWORD))` (PR #64's third review,
// finding 5). No caller passes that value today, but `await_or_abandon` is
// public API and a future caller that computes a bound (issue #12's
// pipeline) is not a caller this package controls. Pulled out of the assert
// it guards so the boundary can be proven without tripping it -- CLAUDE.md
// forbids a test that deliberately trips an assertion (issue #22).
@(private)
@(require_results)
bound_expressible :: proc(bound_ms: i64) -> bool {
	return bound_ms < i64(max(win32.DWORD))
}

// The generic engine behind every bounded blocking call in this tree, not
// only a read: wait up to `bound_ms` for `t` to finish, and if it has not,
// ask `win32.CancelSynchronousIo` to unblock whatever synchronous Win32 call
// it is inside and give it `CANCEL_BOUND_MS` more to actually stop before
// giving up on it for good.
//
// `.Finished` and `.Stopped` both mean `t` is done and safe to
// `thread.destroy`, and whatever its worker was writing into is safe to
// read. `.Unstoppable` means the opposite: neither `t` nor what its worker
// was writing into may be touched again -- FALSE MEANS SOMETHING MAY STILL
// BE HOLDING IT, the same contract `stop` documents for a child, one layer
// down. A caller whose worker writes into memory that might outlive it this
// way needs that memory on a heap nothing but process exit ever reclaims,
// the way `job_allocator` is for a Read_Job.
//
// Waiting for `t` reaches `t.win32_thread`, a `#+private` field of
// `core:thread`'s `Thread_Os_Specific` that `Thread`'s own `using specific:`
// promotes onto `Thread` -- `#+private` restricts the identifier
// `Thread_Os_Specific`, not the field name the promotion reaches through,
// which is why this compiles without `core:thread` exporting it on
// purpose. An upstream rename is a loud build break here and never a
// silent wrong, and this program is Windows-only, so the exposure is
// bounded; see ADR-0020 for what breaks if it moves.
//
// `bound_ms` is spent in one `win32.WaitForSingleObject` call and not a poll
// loop: `WaitForSingleObject` returns the instant `t`'s handle signals,
// where a poll loop can only notice as often as it sleeps, and Windows
// quantizes `time.sleep` to its own roughly 15.6 ms timer period. Multiplied
// by every bounded read and directory listing a walk of hundreds of
// Recordings makes, that quantization is what took a 150-Recording `--plan`
// from tens of milliseconds to 7.5 seconds before this fix (PR #64's second
// review, finding 2) -- `core:thread`'s own `Thread.flags` is set `.Done`
// before the thread's win32 handle can ever signal (see
// `__windows_thread_entry_proc`), so a `.Finished` this way is exactly as
// safe to trust as the polled `thread.is_done` it replaces. Only past the
// bound does this package poll at all: cancellation has no handle to wait
// on, only `thread.is_done` to ask again after each
// `win32.CancelSynchronousIo`.
//
// `WAIT_FAILED` answers `.Unstoppable` directly rather than falling into the
// cancel loop below: the wait itself errored rather than timing out, so
// `t.win32_thread` is not known blocked at all, and unlike a real timeout,
// this was never actually waited for `bound_ms` in the first place -- there
// is nothing measured here that makes `CancelSynchronousIo` or a poll of it
// any more trustworthy against a handle whose own wait already failed (PR
// #64's third review, finding 8).
@(require_results)
await_or_abandon :: proc(t: ^thread.Thread, bound_ms: i64) -> Wait {
	assert(t != nil, "there is no thread here to wait for")
	assert(bound_ms > 0, "a wait for no time at all cannot tell a wedge from a fast answer")
	assert(
		bound_expressible(bound_ms),
		"a bound this large cannot be expressed to WaitForSingleObject without meaning INFINITE",
	)

	switch win32.WaitForSingleObject(t.win32_thread, win32.DWORD(bound_ms)) {
	case win32.WAIT_OBJECT_0:
		return .Finished
	case win32.WAIT_TIMEOUT:
	case win32.WAIT_FAILED:
		return .Unstoppable
	case:
		unreachable()
	}

	cancelling := time.tick_now()
	for !thread.is_done(t) {
		if i64(time.duration_milliseconds(time.tick_since(cancelling))) > CANCEL_BOUND_MS {
			return .Unstoppable
		}
		_ = CancelSynchronousIo(t.win32_thread)
		time.sleep(READ_POLL)
	}
	return .Stopped
}

@(private)
Read_Job :: struct {
	path:         string,
	bytes:        []u8,
	os_error:     os.Error,
	drill_assert: bool,
}

// `core:thread` builds this thread a context from scratch, so
// `context.assertion_failure_proc` arrives back at Odin's own default however
// `main` wired the process (issue #76 review round 6: an assert here left the
// log holding a bare `CRASH` line and nothing else). The hook is per-context
// and cannot be reinstalled by a helper -- Odin's implicit context does not
// propagate back out of a call that returned -- so every worker entry point
// writes the line itself, per `transcibr:crashlog`'s own doc comment.
@(private)
read_worker :: proc(data: rawptr) {
	context.assertion_failure_proc = crashlog.assertion_hook
	job := (^Read_Job)(data)
	assert(job != nil, "a read thread was started with no job to read")
	assert(len(job.path) > 0, "a read thread was started with no path to read")
	assert(!job.drill_assert, "a read thread was asked to fail on purpose, and did")

	job.bytes, job.os_error = os.read_entire_file_from_path(job.path, job_allocator())
}

// Read past its bound and then stopped rather than simply waited on: this
// package cannot poll a blocked `ReadFile` any other way, so the read runs
// on its own thread and `await_or_abandon` is what brings that thread back
// under control. `.Unstoppable` -- measured to not happen against a reserved
// device name, a stalled share or a named pipe with no writer, all of which
// answer `win32.CancelSynchronousIo` inside single-digit milliseconds -- is
// the one path that still leaks: one `Read_Job`, its cloned path, and
// whatever bytes its thread eventually reads, all on `job_allocator`'s heap
// and never on the caller's own, for the reason `Unstoppable` is accepted
// elsewhere in this package -- there is no safe way to reclaim memory a
// thread may still be writing into, short of `TerminateThread`, which
// CLAUDE.md's own notes on this repository's test runner already found
// abandons locks mid-use.
//
// `drill_assert` is a worker-side deliberate assertion no production caller
// ever passes -- `read_bounded(path, bound_ms, allocator)` behaves identically
// to a call that spells the default out. It is the same shape
// `transcibr:engine`'s `landed_bounded` and `transcibr:audio`'s
// `read_head_bounded` already carry for `stall_ms`: a defaulted parameter that
// exists to reach a worker-thread state no ordinary input can produce. Issue
// #76 review round 6 is what it is for -- `transcibr-cli --crash-drill
// worker-assert` passes it so a committed test can measure that THIS worker's
// own `context.assertion_failure_proc` install is what puts the message,
// location and symbolized stack in the crash log, on a real production worker
// rather than on a synthetic thread the drill itself created.
@(require_results)
read_bounded :: proc(
	path: string,
	bound_ms: i64,
	allocator: mem.Allocator,
	drill_assert := false,
) -> (
	bytes: []u8,
	err: Read_Error,
) {
	assert(len(path) > 0, "there is no path here to read")
	assert(bound_ms > 0, "a read given no time at all cannot do anything")
	assert(allocator.procedure != nil, "a read outliving this procedure needs an allocator")

	job := new(Read_Job, job_allocator())
	job.path = strings.clone(path, job_allocator())
	job.drill_assert = drill_assert

	context.allocator = job_allocator()
	t := thread.create_and_start_with_data(job, read_worker)
	if t == nil {
		delete(job.path, job_allocator())
		free(job, job_allocator())
		return nil, Read_Error{fault = .Not_Started}
	}

	return await_bounded(t, job, bound_ms, allocator)
}

@(private)
@(require_results)
await_bounded :: proc(
	t: ^thread.Thread,
	job: ^Read_Job,
	bound_ms: i64,
	allocator: mem.Allocator,
) -> (
	bytes: []u8,
	err: Read_Error,
) {
	assert(t != nil, "there is no thread here to wait for")
	assert(job != nil, "there is no job here to wait for an answer from")

	finished_ok, reclaim := await_and_reclaim(t, bound_ms)
	if finished_ok {
		return finished(t, job, allocator)
	}
	if reclaim {
		release_job(t, job)
	}
	return nil, Read_Error{fault = .Did_Not_Finish}
}

// Frees everything a Read_Job and its thread hold, on the allocator they were
// given out on -- shared by a read that finished on its own and one this
// package had to cancel, since both are equally safe to reclaim once
// `thread.is_done` is true.
@(private)
release_job :: proc(t: ^thread.Thread, job: ^Read_Job) {
	assert(t != nil, "there is no thread here to release")
	assert(job != nil, "there is no job here to release")
	assert(thread.is_done(t), "release_job called on a thread that never finished")

	delete(job.bytes, job_allocator())
	delete(job.path, job_allocator())
	free(job, job_allocator())
	thread.destroy(t)
}

// Where a completed read's answer crosses from `job_allocator`'s heap onto
// the allocator the caller actually asked for -- copied rather than handed
// over, so a caller freeing `bytes` with its own allocator is freeing memory
// that allocator actually owns.
@(private)
@(require_results)
finished :: proc(
	t: ^thread.Thread,
	job: ^Read_Job,
	allocator: mem.Allocator,
) -> (
	bytes: []u8,
	err: Read_Error,
) {
	assert(t != nil, "there is no thread here to close out")
	assert(job != nil, "a finished read has no job to read its answer from")

	os_error := job.os_error
	if os_error == nil {
		bytes = make([]u8, len(job.bytes), allocator)
		copy(bytes, job.bytes)
	}
	release_job(t, job)

	if os_error != nil {
		return nil, Read_Error{fault = .Unreadable, os_error = os_error}
	}
	return bytes, Read_Error{}
}

@(private)
@(require_results)
read_fault_says :: proc(fault: Read_Fault) -> string {
	switch fault {
	case .Not_Started:
		return "a thread to read it on could not be started"
	case .Did_Not_Finish:
		return DID_NOT_FINISH_SAYS
	case .Unreadable, .None:
	}
	return ""
}

// %q and not %s: the line may reach a user through a UTF-16 Win32 call, where
// a raw NUL cuts it off and a byte that is not UTF-8 converts the whole of it
// to nil. Free the answer with `delete` and this allocator.
@(require_results)
read_error_message :: proc(err: Read_Error, path: string, allocator: mem.Allocator) -> string {
	assert(err.fault != .None, "there is no message for a read that came through")
	assert(len(path) > 0, "a refusal must name the path it is reported against")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs an allocator",
	)

	message: string
	if err.fault == .Unreadable {
		message = fmt.aprintf("%q: %v", path, err.os_error, allocator = allocator)
	} else {
		says := read_fault_says(err.fault)
		assert(len(says) > 0, "a fault was added to Read_Fault without a sentence")
		message = fmt.aprintf("%q: %s", path, says, allocator = allocator)
	}
	assert(len(message) > 0, "a refusal rendered as nothing at all")
	return message
}
