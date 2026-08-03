package child

import "core:mem"
import win32 "core:sys/windows"

// This file is what a child's three standard streams are wired to, and reading
// back the one of them that comes home.
//
// The wiring is asymmetric on purpose, and the asymmetry is ADR-0004's central
// measurement rather than a preference:
//
//   standard output -> the null device, NEVER a pipe. The Engine prints every Cue
//   to standard output during inference -- 14,468 bytes for twenty minutes of
//   audio, against a default pipe buffer of a few kilobytes -- so an undrained
//   stdout pipe wedges the child early in the first Recording, with the window
//   frozen and no error anywhere.
//
//   standard error  -> a pipe, which is where progress comes from (ADR-0012).
//
//   standard input  -> the null device, so a child that reads standard input gets
//   end of file at once instead of blocking on a stream nobody will ever write
//   to (issue #27).

// How much of a child's diagnostic output the kernel will hold before the child
// blocks writing it.
//
// Not tuning: it is the margin between a reader that is a little late and a child
// that stops running. Sixty-four kilobytes is roughly four times what ADR-0012's
// Engine emits on this stream over a whole Recording, so a caller that falls
// behind for a second costs nothing at all.
@(private)
DIAGNOSTIC_PIPE_BYTES :: 64 * 1024

// The handles one child is started with, before either side has given any of them
// up. Three handles and two owners: `null_device` and `write` become the child's,
// `read` stays here.
@(private)
Streams :: struct {
	null_device: win32.HANDLE,
	write:       win32.HANDLE,
	read:        win32.HANDLE,
}

// Opens everything one child's streams need.
//
// EVERY handle here is created inheritable, including the one the child must not
// get, and that is deliberate: `SetHandleInformation` then takes the read end
// back out again. Making it non-inheritable at creation is not an option --
// `CreatePipe` takes one SECURITY_ATTRIBUTES for both ends -- and the two-step is
// the documented shape.
@(private)
open_streams :: proc() -> (s: Streams, err: Error) {
	inheritable := win32.SECURITY_ATTRIBUTES {
		nLength        = size_of(win32.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}
	// Shared for reading AND writing because one handle serves as both the child's
	// standard input and its standard output, and a handle opened write-only would
	// make the first read from standard input fail rather than end.
	s.null_device = win32.CreateFileW(
		win32.L("NUL"),
		win32.GENERIC_READ | win32.GENERIC_WRITE,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
		&inheritable,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	// INVALID_HANDLE_VALUE and not nil, which is what CreateFileW answers with and
	// is a different value: a nil check here passes on every failure there is.
	if s.null_device == win32.INVALID_HANDLE_VALUE {
		return {}, Error{fault = .No_Null_Device, last_error = u32(win32.GetLastError())}
	}

	if !win32.CreatePipe(&s.read, &s.write, &inheritable, DIAGNOSTIC_PIPE_BYTES) {
		code := u32(win32.GetLastError())
		win32.CloseHandle(s.null_device)
		return {}, Error{fault = .No_Diagnostic_Pipe, last_error = code}
	}
	// The reader's end is this process's alone. A child holding a copy of it is a
	// second thing keeping the pipe alive, and a caller waiting for end of stream
	// would wait on a pipe the child itself is propping open.
	//
	// ASSERTED and not reported, which is the boundary rule read the right way
	// round (A8). Nothing outside this program is involved: the handle is one
	// CreatePipe produced two lines above and reported success for, and the only
	// way this call refuses it is that it is not a handle. A handle table this
	// package cannot reason about is corrupt internal state, and every guarantee
	// here rests on handle identity -- so the crash belongs at the point of
	// corruption rather than in whatever later reads the wrong pipe.
	private := win32.SetHandleInformation(s.read, win32.HANDLE_FLAG_INHERIT, 0)
	assert(bool(private), "a pipe end this package created would not be made private")
	return s, Error{}
}

// The list naming exactly which handles a child may inherit, and the storage
// Windows keeps it in.
//
// THE ADDRESS OF `handles` IS WHAT GOES INTO THE LIST, not a copy of it, so this
// record must outlive `CreateProcessW` and must not be moved after
// UpdateProcThreadAttribute has seen it. That is why it is filled through a
// pointer the caller owns rather than returned by value: returning it would copy
// the array into the caller's frame and leave the list pointing at a dead one --
// a defect with no diagnostic, since the stale bytes are usually still the right
// handles.
@(private)
Handle_List :: struct {
	// The two handles the child gets and the ONLY two: its null device and the
	// write end of its own diagnostic pipe.
	handles: [2]win32.HANDLE,
	// Pointer-element rather than byte-element storage, so the buffer is aligned
	// the way a structure full of pointers needs. Windows gives a size in bytes
	// and says nothing about alignment, and a byte slice is aligned to one.
	buffer:  []rawptr,
	list:    LPPROC_THREAD_ATTRIBUTE_LIST,
}

// Builds the handle list for one child.
//
// THIS IS THE ANSWER TO THE CONCURRENT-SPAWN TRAP. `bInheritHandles = TRUE` is
// all-or-nothing: without a list it hands the child every inheritable handle this
// process holds at that instant, which for two spawns overlapping by microseconds
// includes the write end of the OTHER child's diagnostic pipe. That pipe then
// never reports end of stream -- a live process is still holding it open -- and a
// caller draining until end of stream waits on a child that exited an hour ago.
// Measured before this existed: the suite's own six concurrent cases turned the
// end-of-stream case red, and only under concurrency.
//
// With a list, inheritance is exactly these two handles whatever else is open,
// and no lock, no ordering rule and no window is involved.
@(private)
open_handle_list :: proc(hl: ^Handle_List, s: ^Streams, allocator: mem.Allocator) -> Error {
	assert(hl != nil, "there is nowhere to build a handle list")
	assert(s != nil, "there are no streams here to name in a handle list")
	assert(s.null_device != s.write, "a handle named twice in the list is refused outright")

	hl.handles = {s.null_device, s.write}

	// The first call is EXPECTED to fail: asking for a list that fits nowhere is
	// the documented way to be told how large one would have to be, so the answer
	// read is `size` and never the return value.
	size: win32.SIZE_T
	InitializeProcThreadAttributeList(nil, 1, 0, &size)
	if size == 0 {
		return Error{fault = .No_Handle_List, last_error = u32(win32.GetLastError())}
	}

	hl.buffer = make([]rawptr, 1 + (int(size) - 1) / size_of(rawptr), allocator)
	hl.list = rawptr(raw_data(hl.buffer))
	if !InitializeProcThreadAttributeList(hl.list, 1, 0, &size) {
		code := u32(win32.GetLastError())
		// Nothing to delete: an initialise that failed left no list behind, and
		// DeleteProcThreadAttributeList on one is not a call this package makes.
		hl.list = nil
		return Error{fault = .No_Handle_List, last_error = code}
	}
	if !UpdateProcThreadAttribute(
		hl.list,
		0,
		PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
		rawptr(&hl.handles[0]),
		size_of(hl.handles),
		nil,
		nil,
	) {
		return Error{fault = .No_Handle_List, last_error = u32(win32.GetLastError())}
	}
	return Error{}
}

// Gives back the attribute list and the memory under it. Safe on one that was
// never built, which is what the refusal paths above leave behind.
@(private)
close_handle_list :: proc(hl: ^Handle_List, allocator: mem.Allocator) {
	assert(hl != nil, "there is no handle list here to close")

	if hl.list != nil {
		DeleteProcThreadAttributeList(hl.list)
		hl.list = nil
	}
	delete(hl.buffer, allocator)
	hl.buffer = nil
}

// Gives back the two handles that are the child's once it has been created --
// or, where no child was created, the two nobody will ever use.
//
// Called on BOTH paths and exactly once, which is why it is a procedure rather
// than two lines at the end of start. The write end in particular is the one
// mistake that costs a caller everything: keep it and the diagnostic pipe never
// reports end of stream, so a reader that drains until end of stream waits
// forever on a child that finished an hour ago.
@(private)
close_child_side :: proc(s: ^Streams) {
	assert(s != nil, "there are no streams here to hand over")
	assert(s.null_device != nil, "streams with no null device were never opened")
	assert(s.write != nil, "streams with no write end were never opened")

	win32.CloseHandle(s.write)
	win32.CloseHandle(s.null_device)
	s.write = nil
	s.null_device = nil
}

// Reads whatever the child has said that has arrived, without ever blocking.
//
// `at_end` is the ordinary end of a child's output and is NOT a fault: it means
// the child is gone and every copy of the write end with it. A caller reads until
// it, and only then knows it has the whole story.
//
// Never blocking is the property that matters, and it is what PeekNamedPipe is
// for. A bare ReadFile on an anonymous pipe waits until something arrives, so a
// caller that also has a window to keep painting cannot use it -- and the one
// worker that could afford to block is the one that must not, because it is also
// watching for a Stop press (ADR-0006).
//
// A8: everything here is the child's, which is outside this program. A pipe that
// fails for any reason other than ending is reported through `err`.
read_diagnostics :: proc(c: ^Child, into: []u8) -> (n: int, at_end: bool, err: Error) {
	assert(c != nil, "there is no child here to read from")
	assert(c.diagnostics != nil, "a child that was never started says nothing")
	assert(len(into) > 0, "there is nowhere to put what the child said")

	if c.at_end {
		return 0, true, Error{}
	}

	// How much can be taken without waiting, or -- where the pipe has already
	// broken -- permission to ask for everything, since a read that cannot block
	// is exactly what a broken pipe guarantees.
	waiting: win32.DWORD
	if !win32.PeekNamedPipe(c.diagnostics, nil, 0, nil, &waiting, nil) {
		code := u32(win32.GetLastError())
		if code != u32(win32.ERROR_BROKEN_PIPE) {
			return 0, false, Error{fault = .Diagnostics_Unreadable, last_error = code}
		}
		waiting = win32.DWORD(len(into))
	} else if waiting == 0 {
		// Quiet, not finished. The child is thinking, or loading a model, and
		// ADR-0012 is explicit that silence must not be read as a stall.
		return 0, false, Error{}
	}

	taken: win32.DWORD
	wanted := win32.DWORD(min(int(waiting), len(into)))
	if !win32.ReadFile(c.diagnostics, raw_data(into), wanted, &taken, nil) {
		code := u32(win32.GetLastError())
		if code != u32(win32.ERROR_BROKEN_PIPE) {
			return 0, false, Error{fault = .Diagnostics_Unreadable, last_error = code}
		}
		c.at_end = true
		return 0, true, Error{}
	}
	// A pipe whose writers are all gone answers a read with zero bytes rather than
	// an error, and a caller told "nothing right now" would spin on that forever.
	if taken == 0 {
		c.at_end = true
		return 0, true, Error{}
	}

	assert(int(taken) <= len(into), "the pipe wrote past the end of the buffer it was given")
	return int(taken), false, Error{}
}
