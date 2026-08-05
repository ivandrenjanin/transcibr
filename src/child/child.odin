#+vet explicit-allocators
// Package child starts the child processes transcibr drives, reads what they say
// while they run, and stops them without leaving anything behind. One spawner,
// used by both binaries (ADR-0004).
//
// It also owns the one mechanism transcibr has for bounding any blocking wait
// on something outside its control, and for reclaiming what was waited on
// rather than abandoning it: `run_bounded` polls a process the way `stop`
// already does, and `read.odin`'s `Wait` / `await_or_abandon` is the same
// wait-then-cancel-then-join shape aimed at a thread instead -- an exact
// `win32.WaitForSingleObject` rather than a poll for the wait itself, and a
// bounded poll only once cancellation is in progress -- for a blocking read
// this package cannot otherwise interrupt (issue #27). A caller
// elsewhere in the tree with its own blocking call to bound -- `artifact`'s
// Model hash, `planning`'s directory and Sidecar reads -- calls
// `await_or_abandon` directly rather than re-deriving the Win32 cancellation
// it depends on; that is a widening of what this package is FOR, not an
// import of convenience (see ADR-0020's placement note).
package child

import "core:fmt"
import "core:mem"
import win32 "core:sys/windows"
import "transcibr:process"

Fault :: enum u8 {
	None = 0,
	Bad_Command_Line,
	No_Job_Object,
	No_Null_Device,
	No_Diagnostic_Pipe,
	Not_Started,
	Not_Assigned,
	No_Handle_List,
	Not_Resumed,
	Diagnostics_Unreadable,
}

Error :: struct {
	fault:      Fault,
	// Read at the point of failure, before any cleanup call could overwrite it.
	last_error: u32,
	build:      process.Build_Error,
}

// See CLAUDE.md, Odin notes: enumerated arrays and switches.
@(private, rodata)
FAULT := [Fault]string {
	.None                   = "",
	.Bad_Command_Line       = "",
	.No_Job_Object          = "the job object that stops a child outliving transcibr could not be created",
	.No_Null_Device         = "the null device the child writes its standard output to could not be opened",
	.No_Diagnostic_Pipe     = "the pipe carrying the child's diagnostic output could not be created",
	.No_Handle_List         = "the list of handles the child may inherit could not be built",
	.Not_Started            = "the executable could not be started",
	.Not_Assigned           = "the child could not be put in the job object that ends it with transcibr",
	.Not_Resumed            = "the child was created suspended and could not be resumed",
	.Diagnostics_Unreadable = "the child's diagnostic output could not be read",
}

@(private)
@(require_results)
fault_says :: proc(fault: Fault) -> string {
	assert(fault != .None, "the success value is not a fault and says nothing")
	assert(
		fault != .Bad_Command_Line,
		"a refused command line is reported by the package that refused it",
	)

	says := FAULT[fault]
	assert(len(says) > 0, "a fault was added to Fault without a row in FAULT")
	return says
}

// The line outlives this procedure and may be read by a worker other than the one
// that produced it (ADR-0010); free it with `delete` and the same allocator.
@(require_results)
error_message :: proc(err: Error, allocator: mem.Allocator) -> string {
	assert(err.fault != .None, "there is no message for a child that started")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs a chosen allocator",
	)

	message: string
	if err.fault == .Bad_Command_Line {
		message = process.error_message(err.build, allocator)
	} else {
		message = fmt.aprintf(
			"%s (Windows error %d)",
			fault_says(err.fault),
			err.last_error,
			allocator = allocator,
		)
	}
	assert(len(message) > 0, "a refusal rendered as nothing at all")
	return message
}

@(require_results)
disposition_of :: proc(err: Error) -> process.Disposition {
	assert(err.fault != .None, "a child that started has nothing to dispose of")

	if err.fault == .Bad_Command_Line {
		return process.disposition_of(err.build.fault)
	}
	return .Fail_The_Recording
}

Job_Object :: struct {
	handle: win32.HANDLE,
}

@(require_results)
job_object_open :: proc() -> (group: Job_Object, err: Error) {
	handle := CreateJobObjectW(nil, nil)
	if handle == nil {
		return {}, Error{fault = .No_Job_Object, last_error = u32(win32.GetLastError())}
	}

	limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	set := SetInformationJobObject(
		handle,
		JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
		rawptr(&limits),
		size_of(limits),
	)
	if !set {
		code := u32(win32.GetLastError())
		win32.CloseHandle(handle)
		return {}, Error{fault = .No_Job_Object, last_error = code}
	}
	return Job_Object{handle = handle}, Error{}
}

// Closing TERMINATES every child still in it; a caller that needs one stopped in
// an orderly way calls stop on it first.
job_object_close :: proc(group: ^Job_Object) {
	assert(group != nil, "there is no job object here to close")

	if group.handle == nil {
		return
	}
	closed := win32.CloseHandle(group.handle)
	assert(bool(closed), "a job object this package opened would not close")
	group.handle = nil
}

// The caller owns every handle in here and gives them all back with close.
Child :: struct {
	handle:      win32.HANDLE,
	thread:      win32.HANDLE,
	tree:        win32.HANDLE,
	diagnostics: win32.HANDLE,
	// End of stream is reported once by the pipe, so a caller that asks again after
	// draining would otherwise get a fresh failure instead of the answer it had.
	at_end:      bool,
}

// CREATE_SUSPENDED is not an optimisation: a child that runs before it is in the
// job object can fork in that window and leave a grandchild nothing will kill.
@(private)
CREATION_FLAGS ::
	win32.CREATE_NO_WINDOW | win32.CREATE_SUSPENDED | win32.EXTENDED_STARTUPINFO_PRESENT

// Why the compiler holds this flag: ADR-0020.
#assert(CREATION_FLAGS & win32.CREATE_NO_WINDOW != 0)

// The allocator is spent inside here. The returned Child points at nothing the
// caller passed in, so there is nothing to give back but its handles (close).
@(require_results)
start :: proc(
	group: ^Job_Object,
	executable: string,
	arguments: []string,
	allocator: mem.Allocator,
) -> (
	c: Child,
	err: Error,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(group.handle != nil, "a closed job object cannot hold a child")
	assert(allocator.procedure != nil, "the command line needs an allocator to be built in")

	command_line, refusal := process.build_command_line(executable, arguments, allocator)
	defer delete(command_line, allocator)
	if refusal.fault != .None {
		return {}, Error{fault = .Bad_Command_Line, build = refusal}
	}

	wide := win32.utf8_to_utf16(command_line, allocator)
	defer delete(wide, allocator)
	assert(wide != nil, "a command line the Process contract accepted would not convert to UTF-16")

	streams, opening := open_streams()
	if opening.fault != .None {
		return {}, opening
	}
	c, err = start_into(group, wide, &streams, allocator)

	close_child_side(&streams)
	if err.fault != .None {
		win32.CloseHandle(streams.read)
		return {}, err
	}
	c.diagnostics = streams.read
	return c, Error{}
}

@(private)
@(require_results)
start_into :: proc(
	group: ^Job_Object,
	command_line: []u16,
	s: ^Streams,
	allocator: mem.Allocator,
) -> (
	c: Child,
	err: Error,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(s != nil, "a child started with no streams would inherit this process's")

	pi, denial := create_hidden(command_line, s, allocator)
	if denial.fault != .None {
		return {}, denial
	}

	if !AssignProcessToJobObject(group.handle, pi.hProcess) {
		return {}, abandon(&pi, .Not_Assigned)
	}
	tree := CreateJobObjectW(nil, nil)
	if tree == nil {
		return {}, abandon(&pi, .No_Job_Object)
	}
	if !AssignProcessToJobObject(tree, pi.hProcess) {
		refused := abandon(&pi, .Not_Assigned)
		win32.CloseHandle(tree)
		return {}, refused
	}

	if win32.ResumeThread(pi.hThread) == ~win32.DWORD(0) {
		refused := abandon(&pi, .Not_Resumed)
		win32.CloseHandle(tree)
		return {}, refused
	}
	return Child{handle = pi.hProcess, thread = pi.hThread, tree = tree}, Error{}
}

// Why lpApplicationName is nil: ADR-0019.
@(private)
@(require_results)
create_hidden :: proc(
	command_line: []u16,
	s: ^Streams,
	allocator: mem.Allocator,
) -> (
	pi: win32.PROCESS_INFORMATION,
	err: Error,
) {
	assert(len(command_line) > 0, "there is no command line here to start")
	assert(s != nil, "a child started with no streams would inherit this process's")

	hl: Handle_List
	defer close_handle_list(&hl, allocator)
	refusal := open_handle_list(&hl, s, allocator)
	if refusal.fault != .None {
		return {}, refusal
	}

	si := STARTUPINFOEXW {
		StartupInfo = {
			cb = size_of(STARTUPINFOEXW),
			dwFlags = win32.STARTF_USESHOWWINDOW | win32.STARTF_USESTDHANDLES,
			wShowWindow = win32.WORD(win32.SW_HIDE),
			hStdInput = s.null_device,
			hStdOutput = s.null_device,
			hStdError = s.write,
		},
		lpAttributeList = hl.list,
	}
	started := win32.CreateProcessW(
		nil,
		win32.wstring(raw_data(command_line)),
		nil,
		nil,
		true,
		CREATION_FLAGS,
		nil,
		nil,
		&si.StartupInfo,
		&pi,
	)
	if !started {
		return {}, Error{fault = .Not_Started, last_error = u32(win32.GetLastError())}
	}
	assert(pi.hProcess != nil, "CreateProcessW reported success and handed back no process")
	assert(pi.hThread != nil, "CreateProcessW reported success and handed back no thread")
	return pi, Error{}
}

@(private)
@(require_results)
abandon :: proc(pi: ^win32.PROCESS_INFORMATION, fault: Fault) -> Error {
	assert(pi != nil, "there is nothing here to abandon")
	assert(pi.hProcess != nil, "a child abandoned before it was created")

	code := u32(win32.GetLastError())
	win32.TerminateProcess(pi.hProcess, TERMINATED_EXIT_CODE)
	_ = win32.WaitForSingleObject(pi.hProcess, win32.DWORD(ABANDON_BOUND_MS))
	win32.CloseHandle(pi.hThread)
	win32.CloseHandle(pi.hProcess)
	return Error{fault = fault, last_error = code}
}

// Bounded and not INFINITE: a Stop press that never comes back is a frozen window
// (issue #27). Thirty seconds is what scripts\common.ps1 gives a killed process
// tree, and the two agree on purpose.
STOP_BOUND_MS :: u32(30_000)

// Deliberately not STOP_BOUND_MS: an abandoned child was created suspended and
// has run nothing, so only its process object has to signal.
@(private)
ABANDON_BOUND_MS :: u32(2_000)

// The clock is handed in rather than read here, so a deadline already gone and
// one exactly reached are reachable in a test.
@(private)
@(require_results)
remaining_ms :: proc(deadline: win32.ULONGLONG, now: win32.ULONGLONG) -> u32 {
	if now >= deadline {
		return 0
	}
	left := deadline - now
	if left >= win32.ULONGLONG(win32.INFINITE) {
		return win32.INFINITE - 1
	}
	return u32(left)
}

// FALSE MEANS SOMETHING MAY STILL BE HOLDING FILES OPEN, and `milliseconds` is a
// budget for the whole of this rather than for each wait inside it.
// Why the tree and not the process alone: ADR-0004.
// Why never the cooperative request: see CLAUDE.md, Odin notes.
@(require_results)
stop :: proc(c: ^Child, milliseconds: u32 = STOP_BOUND_MS) -> (stopped: bool) {
	assert(c != nil, "there is no child here to stop")
	assert(c.handle != nil, "a child that was never started cannot be stopped")
	assert(c.tree != nil, "a started child always has a job object of its own")
	assert(milliseconds != win32.INFINITE, "a Stop press that never comes back is a frozen window")

	deadline := GetTickCount64() + win32.ULONGLONG(milliseconds)
	TerminateJobObject(c.tree, TERMINATED_EXIT_CODE)

	first := remaining_ms(deadline, GetTickCount64())
	if win32.WaitForSingleObject(c.handle, win32.DWORD(first)) != win32.WAIT_OBJECT_0 {
		return false
	}
	return job_emptied(c.tree, deadline)
}

// Polled because there is nothing to wait on: a job object signals when its
// end-of-job time limit is exceeded and never when its last process leaves.
@(private)
@(require_results)
job_emptied :: proc(job: win32.HANDLE, deadline: win32.ULONGLONG) -> bool {
	assert(job != nil, "there is no job object here to wait on")

	for {
		accounting: JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
		returned: win32.DWORD
		read := QueryInformationJobObject(
			job,
			JOB_OBJECT_BASIC_ACCOUNTING_INFORMATION,
			rawptr(&accounting),
			size_of(accounting),
			&returned,
		)
		if !read {
			return false
		}
		if accounting.ActiveProcesses == 0 {
			return true
		}
		if GetTickCount64() >= deadline {
			return false
		}
		win32.Sleep(1)
	}
}

// Distinct from anything ffmpeg or the Engine chooses for itself, so a caller
// reading an exit code can tell "we killed it" from "it failed".
TERMINATED_EXIT_CODE :: 0xC0000015

@(require_results)
wait :: proc(c: ^Child, milliseconds: u32) -> bool {
	assert(c != nil, "there is no child here to wait for")
	assert(c.handle != nil, "a child that was never started cannot be waited for")

	return win32.WaitForSingleObject(c.handle, win32.DWORD(milliseconds)) == win32.WAIT_OBJECT_0
}

// `exited` comes from the process object's signal state and never from the code:
// GetExitCodeProcess answers STILL_ACTIVE for a running one, which is 259 and a
// legal thing to exit with.
@(require_results)
exit_code :: proc(c: ^Child) -> (code: u32, exited: bool) {
	assert(c != nil, "there is no child here to ask")
	assert(c.handle != nil, "a child that was never started has no exit code")

	if win32.WaitForSingleObject(c.handle, 0) != win32.WAIT_OBJECT_0 {
		return 0, false
	}
	raw: win32.DWORD
	read := win32.GetExitCodeProcess(c.handle, &raw)
	assert(bool(read), "a child that has signalled would not report its exit code")
	return u32(raw), true
}

// Safe on a Child that never started, and it does NOT stop the child: a caller
// that wants that calls stop first.
close :: proc(c: ^Child) {
	assert(c != nil, "there is no child here to close")

	if c.handle != nil {
		win32.CloseHandle(c.handle)
		c.handle = nil
	}
	if c.thread != nil {
		win32.CloseHandle(c.thread)
		c.thread = nil
	}
	if c.diagnostics != nil {
		win32.CloseHandle(c.diagnostics)
		c.diagnostics = nil
	}
	if c.tree != nil {
		win32.CloseHandle(c.tree)
		c.tree = nil
	}
	c.at_end = false
}
