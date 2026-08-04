package child

import "core:mem"
import win32 "core:sys/windows"

// A child's three standard streams: standard output and standard input to the
// null device, standard error to a pipe. Piping standard output wedges the child
// -- the Engine floods it during inference (ADR-0004).

// Roughly four times what the Engine emits on this stream over a whole Recording,
// so a reader that falls a second behind never stops the child.
@(private)
DIAGNOSTIC_PIPE_BYTES :: 64 * 1024

// Three handles and two owners: `null_device` and `write` become the child's,
// `read` stays here.
@(private)
Streams :: struct {
	null_device: win32.HANDLE,
	write:       win32.HANDLE,
	read:        win32.HANDLE,
}

// Every handle here is created inheritable, including the read end the child must
// not get: `CreatePipe` takes one SECURITY_ATTRIBUTES for both ends, so making
// that one private is a second call rather than a creation flag.
@(private)
open_streams :: proc() -> (s: Streams, err: Error) {
	inheritable := win32.SECURITY_ATTRIBUTES {
		nLength        = size_of(win32.SECURITY_ATTRIBUTES),
		bInheritHandle = true,
	}
	s.null_device = win32.CreateFileW(
		win32.L("NUL"),
		win32.GENERIC_READ | win32.GENERIC_WRITE,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
		&inheritable,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if s.null_device == win32.INVALID_HANDLE_VALUE {
		return {}, Error{fault = .No_Null_Device, last_error = u32(win32.GetLastError())}
	}

	if !win32.CreatePipe(&s.read, &s.write, &inheritable, DIAGNOSTIC_PIPE_BYTES) {
		code := u32(win32.GetLastError())
		win32.CloseHandle(s.null_device)
		return {}, Error{fault = .No_Diagnostic_Pipe, last_error = code}
	}
	private := win32.SetHandleInformation(s.read, win32.HANDLE_FLAG_INHERIT, 0)
	assert(bool(private), "a pipe end this package created would not be made private")
	return s, Error{}
}

// The list holds the ADDRESS of `handles`, so this record must outlive
// `CreateProcessW`, must not be moved after the update call has seen it, and must
// never be returned by value. Why the shape: ADR-0020.
@(private)
Handle_List :: struct {
	handles: [2]win32.HANDLE,
	buffer:  []rawptr,
	list:    LPPROC_THREAD_ATTRIBUTE_LIST,
}

// Without a list, `bInheritHandles = TRUE` hands the child every inheritable
// handle this process holds at that instant, including the write end of another
// child's diagnostic pipe. Measured; see ADR-0020.
@(private)
open_handle_list :: proc(hl: ^Handle_List, s: ^Streams, allocator: mem.Allocator) -> Error {
	assert(hl != nil, "there is nowhere to build a handle list")
	assert(s != nil, "there are no streams here to name in a handle list")
	assert(s.null_device != s.write, "a handle named twice in the list is refused outright")

	hl.handles = {s.null_device, s.write}

	size: win32.SIZE_T
	InitializeProcThreadAttributeList(nil, 1, 0, &size)
	if size == 0 {
		return Error{fault = .No_Handle_List, last_error = u32(win32.GetLastError())}
	}

	hl.buffer = make([]rawptr, 1 + (int(size) - 1) / size_of(rawptr), allocator)
	hl.list = rawptr(raw_data(hl.buffer))
	if !InitializeProcThreadAttributeList(hl.list, 1, 0, &size) {
		code := u32(win32.GetLastError())
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

// Safe on a list that was never built, which is what the refusal paths above
// leave behind.
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

// Called on both spawn paths and exactly once. Keeping the write end costs a
// caller everything: the diagnostic pipe never reports end of stream, so a reader
// draining until end of stream waits forever on a child that finished an hour ago.
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

// Never blocks, which is what PeekNamedPipe is for: a bare ReadFile on an
// anonymous pipe waits, and the one worker that could afford to wait is also the
// one watching for a Stop press (ADR-0006). `at_end` is the ordinary end of a
// child's output and not a fault.
read_diagnostics :: proc(c: ^Child, into: []u8) -> (n: int, at_end: bool, err: Error) {
	assert(c != nil, "there is no child here to read from")
	assert(c.diagnostics != nil, "a child that was never started says nothing")
	assert(len(into) > 0, "there is nowhere to put what the child said")

	if c.at_end {
		return 0, true, Error{}
	}

	waiting: win32.DWORD
	if !win32.PeekNamedPipe(c.diagnostics, nil, 0, nil, &waiting, nil) {
		code := u32(win32.GetLastError())
		if code != u32(win32.ERROR_BROKEN_PIPE) {
			return 0, false, Error{fault = .Diagnostics_Unreadable, last_error = code}
		}
		waiting = win32.DWORD(len(into))
	} else if waiting == 0 {
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
	if taken == 0 {
		c.at_end = true
		return 0, true, Error{}
	}

	assert(int(taken) <= len(into), "the pipe wrote past the end of the buffer it was given")
	return int(taken), false, Error{}
}
