#+vet explicit-allocators
package child

import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:thread"
import "core:time"

// Bounding a blocking read the same way run_bounded bounds a child. A path
// typed by hand or derived from a Recording can name a reserved Windows
// device -- CON, AUX, COM1 -- whose read never returns even with stdin from
// the null device, and a stalled network share or a named pipe with nobody
// writing to it block the identical way (issue #27). Nothing about a blocked
// ReadFile can be polled or cancelled from outside it, so the read runs on
// its own thread and this package polls THAT the way run_bounded polls a
// child: a ceiling, and abandon whatever has not finished inside it rather
// than wait on it forever.

// Order of magnitude alongside STOP_BOUND_MS, on purpose: both answer "how
// long transcibr waits for something outside it to answer". The largest
// thing this reads is a multi-megabyte Engine output, which comes back in
// well under a second even off a slow disk -- thirty seconds is margin
// against a stalled network share, not against a file this size taking that
// long to read.
READ_BOUND_MS :: i64(30_000)

#assert(READ_BOUND_MS > 0)

// Fine enough that a short bound in a test is not spent entirely on
// granularity, and far too coarse to matter against a read actually worth
// waiting on.
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

@(private)
Read_Job :: struct {
	path:     string,
	bytes:    []u8,
	os_error: os.Error,
}

// A thread this package cannot safely stop still needs somewhere to put what
// it reads, and the caller's own `allocator` is the wrong place for that: a
// worker in a future pipeline (issue #12) may hand this a per-Recording
// arena that gets destroyed once that Recording's stage finishes, and a read
// thread abandoned past its bound has no way to know that happened -- an
// arena-backed allocation reached after the arena is gone is a
// use-after-free, not a leak. Under `odin test` the same hazard shows up as
// a per-test tracking allocator torn down the moment the test that started
// this read returns, which is what caught it here. Every allocation a read
// thread might still touch after its caller has stopped waiting on it goes
// through this fixed, always-valid heap instead -- `finished` is where a
// completed read's answer crosses back onto the caller's own allocator, and
// `read_bounded` is why nothing here is freed when a read is abandoned
// instead.
@(private)
@(require_results)
job_allocator :: proc() -> mem.Allocator {
	return runtime.heap_allocator()
}

@(private)
read_worker :: proc(data: rawptr) {
	job := (^Read_Job)(data)
	assert(job != nil, "a read thread was started with no job to read")
	assert(len(job.path) > 0, "a read thread was started with no path to read")

	job.bytes, job.os_error = os.read_entire_file_from_path(job.path, job_allocator())
}

// Abandoned past its bound rather than joined: nothing may free `job`, or
// the path or bytes it owns, while the thread reading into it might still be
// running -- the same FALSE-MEANS-SOMETHING-MAY-STILL-BE-HOLDING-IT contract
// `stop` carries for a child (child.odin). A read abandoned this way leaks
// one Read_Job, its path, and whatever bytes the thread eventually reads,
// all on `job_allocator`'s heap and never on the caller's own: accepted for
// the reason `Unstoppable` is accepted elsewhere in this package -- there is
// no safe way to reclaim memory a thread may still be writing into, short of
// TerminateThread, which CLAUDE.md's own notes on this repository's test
// runner already found abandons locks mid-use.
@(require_results)
read_bounded :: proc(
	path: string,
	bound_ms: i64,
	allocator: mem.Allocator,
) -> (
	bytes: []u8,
	err: Read_Error,
) {
	assert(len(path) > 0, "there is no path here to read")
	assert(bound_ms > 0, "a read given no time at all cannot do anything")
	assert(allocator.procedure != nil, "a read outliving this procedure needs an allocator")

	job := new(Read_Job, job_allocator())
	job.path = strings.clone(path, job_allocator())

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

	started := time.tick_now()
	for {
		if thread.is_done(t) {
			return finished(t, job, allocator)
		}
		if i64(time.duration_milliseconds(time.tick_since(started))) > bound_ms {
			return nil, Read_Error{fault = .Did_Not_Finish}
		}
		time.sleep(READ_POLL)
	}
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
	delete(job.bytes, job_allocator())
	delete(job.path, job_allocator())
	free(job, job_allocator())
	thread.destroy(t)

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
		return "could not be read within its bound and was abandoned"
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
