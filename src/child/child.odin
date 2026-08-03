// Package child starts the child processes transcibr drives, reads what they say
// while they run, and stops them without leaving anything behind. One spawner,
// used by both binaries, because a console binary that took a different path
// would leave every integration test certifying code the shipped window never
// executes (ADR-0004).
//
// The IMPURE half of driving a child, and the shell module the spec names
// "process spawning and termination". `transcibr:process` is the pure half and
// stays that way: this package calls into it for the one command line Windows
// hands a child, and owns everything the pure core is forbidden -- Win32, the
// filesystem, handles, and the child itself.
//
// Nothing outside this program may crash it (A8). An exit code, a byte on a
// child's diagnostic output, a missing executable and a full handle table are all
// from outside, so every one of them is an operating error reported through
// `Error` and reported against the Recording that caused it. The assertions here
// are about this package's own state: a handle it opened, a child it started, an
// invariant it is holding.
package child

import "core:fmt"
import "core:mem"
import win32 "core:sys/windows"
import "transcibr:process"

// This file holds the spawner itself: the job object children are started into,
// starting one, asking whether it has finished, and giving its handles back.

// How starting or stopping a child refused. `.None` is the only value that comes
// with a child.
Fault :: enum u8 {
	None = 0,
	// The Process contract would not spell this command line at all. The reason
	// travels in `Error.build`, which names the argument it was about -- see
	// error_message.
	Bad_Command_Line,
	// No job object, which is refused rather than worked around: a child started
	// outside one survives transcibr's death holding video memory, and that is
	// the failure ADR-0004 introduced the job object to prevent.
	No_Job_Object,
	// `CreateProcessW` refused. Overwhelmingly an executable that is not there or
	// not runnable, which is external input and a per-Recording failure.
	Not_Started,
	// The child exists but could not be put in the job object. Fatal to the child
	// rather than merely noted: it is started suspended, so a child that cannot be
	// made to die with transcibr never runs at all.
	Not_Assigned,
	// The child was created suspended and the resume failed, which leaves a
	// process that will never do anything.
	Not_Resumed,
}

// One refusal, with whatever the failing layer knew about it.
Error :: struct {
	fault:      Fault,
	// `GetLastError()` read at the point of failure and before any cleanup call
	// could overwrite it, or 0 where the fault carries no Windows code.
	last_error: u32,
	// Only for `.Bad_Command_Line`, and it is the whole report: the Process
	// contract names the argument and says what cannot be spelled about it.
	build:      process.Build_Error,
}

// What each fault reads as, without the Windows error code -- error_message
// supplies that, so no entry here can forget to.
//
// An enumerated array rather than a switch, for the reason the FAULT table in
// `transcibr:process` gives: add a Fault and leave this alone and the COMPILER
// refuses the build with `Unhandled enumerated array case`, so a row cannot go
// missing in anything that ships. Write the row and leave it empty and the
// assertion in fault_says catches it on the first report.
@(private, rodata)
FAULT := [Fault]string {
	// Two rows are deliberately empty, and fault_says refuses both by name rather
	// than letting the emptiness check find them: `.None` is the success value,
	// and `.Bad_Command_Line`'s sentence belongs to the package that refused.
	.None             = "",
	.Bad_Command_Line = "",
	.No_Job_Object    = "the job object that stops a child outliving transcibr could not be created",
	.Not_Started      = "the executable could not be started",
	.Not_Assigned     = "the child could not be put in the job object that ends it with transcibr",
	.Not_Resumed      = "the child was created suspended and could not be resumed",
}

// One fault's sentence, checked. The one place the table is read.
@(private)
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

// Renders one refusal as a line a Recording's failure row can carry.
//
// The allocator is explicit and never defaulted: the line outlives this procedure
// and may be read by a worker other than the one that produced it (ADR-0010).
// Free it with `delete` and the same allocator.
error_message :: proc(err: Error, allocator: mem.Allocator) -> string {
	assert(err.fault != .None, "there is no message for a child that started")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs a chosen allocator",
	)

	// Passed through rather than wrapped. That report already names the argument
	// and says what about it cannot be spelled; a prefix from here would add a
	// layer's name to a sentence that is about the caller's own settings.
	if err.fault == .Bad_Command_Line {
		return deliverable(process.error_message(err.build, allocator))
	}
	// The numeric code is printed and never translated. `FormatMessageW` renders
	// it in the machine's UI language, which is a second thing to be wrong about,
	// while the number is what a search engine and a header file both answer to.
	return deliverable(
		fmt.aprintf(
			"%s (Windows error %d)",
			fault_says(err.fault),
			err.last_error,
			allocator = allocator,
		),
	)
}

// One rendered refusal, checked at the one place both branches leave through.
@(private)
deliverable :: proc(message: string) -> string {
	assert(len(message) > 0, "a refusal rendered as nothing at all")
	return message
}

// Whether a different plan would make this same job run, answered in the
// vocabulary the Process contract already established so a caller has one
// disposition to switch on rather than two.
disposition_of :: proc(err: Error) -> process.Disposition {
	assert(err.fault != .None, "a child that started has nothing to dispose of")

	if err.fault == .Bad_Command_Line {
		return process.disposition_of(err.build.fault)
	}
	// Nothing here is re-plannable. A missing executable, a job object that could
	// not be created and a resume that failed are all the same answer: this
	// Recording fails, and the Batch carries on (ADR-0002).
	return .Fail_The_Job
}

// The kill switch every child is started into.
//
// Held by the caller and not by this package, because a global is a decision
// nobody can override in a test and this one has to be exercised: the case that
// proves a child dies with its group closes a job object on purpose. The shipped
// program opens exactly one, at start-up, and closes it last.
Job_Object :: struct {
	handle: win32.HANDLE,
}

// Opens a job object that terminates everything still in it when its last handle
// closes.
//
// The caller owns the handle and gives it back with job_object_close. Process
// exit closes it too, which is the whole point: a parent that is killed outright
// runs no cleanup, and the kernel closing its handles is what stops an Engine
// surviving with the model resident in video memory.
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
		// Read BEFORE the close, which is a call that sets its own last error.
		code := u32(win32.GetLastError())
		win32.CloseHandle(handle)
		// A job object without the limit is worse than none: it looks like
		// containment and contains nothing, and every child started into it
		// survives transcibr.
		return {}, Error{fault = .No_Job_Object, last_error = code}
	}
	return Job_Object{handle = handle}, Error{}
}

// Closes the job object, which TERMINATES every child still in it.
//
// Not a tidy-up that can be skipped, and not one to run while a child holds a
// file that matters: the children die here, and a caller that needs one stopped
// in an orderly way calls stop on it first.
job_object_close :: proc(group: ^Job_Object) {
	assert(group != nil, "there is no job object here to close")

	// A job object that was never opened, which is what a caller's `defer` runs
	// against when job_object_open refused. Both halves stated (A3): nothing to
	// close is a no-op, and something to close is closed exactly once.
	if group.handle == nil {
		return
	}
	closed := win32.CloseHandle(group.handle)
	assert(bool(closed), "a job object this package opened would not close")
	group.handle = nil
}

// A process identifier, which is NOT an integer and must not pass for one (T2).
//
// Worth the distinct type for a reason beyond tidiness: a pid is stale the moment
// the process exits and Windows recycles it, so it is safe to print and never
// safe to act on. Everything this package does to a child goes through the
// handle, which names that one process for as long as it is held.
Child_ID :: distinct u32

// One started child. The caller owns every handle in it and gives them all back
// with close.
Child :: struct {
	handle: win32.HANDLE,
	thread: win32.HANDLE,
	id:     Child_ID,
}

// What every child is created with.
//
// CREATE_NO_WINDOW is the flag `core:os` cannot pass -- `Process_Desc` has no
// creation-flags field and the spawn path hard-codes the word -- and it is the
// reason this package exists at all (ADR-0004). Without it a GUI-subsystem parent
// pops a console window per child, once per ffmpeg and once per Engine, for every
// Recording in the Batch.
//
// CREATE_SUSPENDED is not an optimisation. The child must be in the job object
// before it can run, or a child that starts and forks in the window between
// creation and assignment leaves a grandchild nothing will ever kill.
@(private)
CREATION_FLAGS :: win32.CREATE_NO_WINDOW | win32.CREATE_SUSPENDED

// Starts one child, hidden, inside the caller's job object.
//
// The executable and the arguments are UTF-8 and are the caller's; nothing in the
// returned Child points at them. The allocator is used for the command line and
// its UTF-16 form, both of which die here -- the Child carries handles and an
// identifier and no memory at all, so there is nothing to free but the handles.
//
// A8: the executable path and every argument come from outside -- a settings
// field, a discovered Recording, a bundled tool's location -- so each is refused
// through `err` and none of them reaches an assertion.
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
	// Not an operating error, and this is the one place that is worth stating.
	// build_command_line refuses every byte Windows cannot encode -- a NUL, a
	// stray surrogate off NTFS -- and it does so precisely because a failed
	// conversion answers nil and nil names no argument. So a nil here is this
	// package losing the string, never a caller handing one in.
	assert(wide != nil, "a command line the Process contract accepted would not convert to UTF-16")

	pi, denial := create_hidden(wide)
	if denial.fault != .None {
		return {}, denial
	}

	if !AssignProcessToJobObject(group.handle, pi.hProcess) {
		return {}, abandon(&pi, .Not_Assigned)
	}
	// (DWORD)-1, which is what ResumeThread answers with rather than zero: zero is
	// the legitimate previous suspend count of a thread that was already running.
	if win32.ResumeThread(pi.hThread) == ~win32.DWORD(0) {
		return {}, abandon(&pi, .Not_Resumed)
	}
	return Child{handle = pi.hProcess, thread = pi.hThread, id = Child_ID(pi.dwProcessId)}, Error{}
}

// The `CreateProcessW` call itself, suspended and with no window of any kind.
//
// lpApplicationName is deliberately nil, so Windows reads the executable back out
// of the command line. That is safe HERE and nowhere else: argv[0] is always
// quoted by build_command_line, so `C:\Program Files\ffmpeg\ffmpeg.exe` cannot be
// re-read as `C:\Program.exe` with arguments -- the hijack an unquoted path
// invites. What it buys is that a caller may name a bare `ffmpeg.exe` and have it
// found the way every other program on the machine finds it.
@(private)
create_hidden :: proc(command_line: []u16) -> (pi: win32.PROCESS_INFORMATION, err: Error) {
	assert(len(command_line) > 0, "there is no command line here to start")

	// SW_HIDE for a child that turns out to have a window of its own, which
	// CREATE_NO_WINDOW says nothing about: that flag withholds a CONSOLE, and a
	// GUI child would still show itself. Both, because the children are ffmpeg
	// and the Engine today and neither is a promise about tomorrow.
	si := win32.STARTUPINFOW {
		cb          = size_of(win32.STARTUPINFOW),
		dwFlags     = win32.STARTF_USESHOWWINDOW,
		wShowWindow = win32.WORD(win32.SW_HIDE),
	}
	started := win32.CreateProcessW(
		nil,
		win32.wstring(raw_data(command_line)),
		nil,
		nil,
		false,
		CREATION_FLAGS,
		nil,
		nil,
		&si,
		&pi,
	)
	if !started {
		return {}, Error{fault = .Not_Started, last_error = u32(win32.GetLastError())}
	}
	assert(pi.hProcess != nil, "CreateProcessW reported success and handed back no process")
	assert(pi.hThread != nil, "CreateProcessW reported success and handed back no thread")
	return pi, Error{}
}

// Undoes a `CreateProcessW` that cannot be completed: stop the child, wait for it
// to actually be gone, and give both handles back.
//
// The last error is read FIRST, before any of that. TerminateProcess and
// CloseHandle each set their own, so a code read after the cleanup is the
// cleanup's answer and not the failure's -- and the failure is the only one worth
// reporting.
@(private)
abandon :: proc(pi: ^win32.PROCESS_INFORMATION, fault: Fault) -> Error {
	assert(pi != nil, "there is nothing here to abandon")
	assert(pi.hProcess != nil, "a child abandoned before it was created")

	code := u32(win32.GetLastError())
	stop_and_wait(pi.hProcess)
	win32.CloseHandle(pi.hThread)
	win32.CloseHandle(pi.hProcess)
	return Error{fault = fault, last_error = code}
}

// Stop is TERMINATE, then WAIT -- never `process_terminate`, which is a
// cooperative request the child may ignore and which reports success without
// stopping anything in a console binary (CLAUDE.md's Odin notes, ADR-0004).
//
// The wait is what the caller is really buying: until the process object
// signals, the child may still hold a file open, and touching that file before
// then is a sharing violation or, worse, a read of a half-written artifact.
@(private)
stop_and_wait :: proc(handle: win32.HANDLE) {
	assert(handle != nil, "there is no child here to stop")

	// A child that has already exited is not an error to report: TerminateProcess
	// fails on it, the wait below returns immediately, and the outcome asked for
	// is the outcome. So the answer is not read -- the WAIT is the check.
	win32.TerminateProcess(handle, TERMINATED_EXIT_CODE)
	signalled := win32.WaitForSingleObject(handle, win32.INFINITE)
	assert(
		signalled == win32.WAIT_OBJECT_0,
		"a terminated child never signalled, so nothing it held is safe to touch",
	)
}

// What a child transcibr stopped exits with. Distinct from anything ffmpeg or the
// Engine chooses for itself, so a caller reading an exit code can tell "we killed
// it" from "it failed": 1 and 2 and 255 are all somebody else's.
TERMINATED_EXIT_CODE :: 0xC0000015

// Waits for a child to exit, for at most this many milliseconds. False means it
// is still running, and the caller decides what that is worth.
wait :: proc(c: ^Child, milliseconds: u32) -> bool {
	assert(c != nil, "there is no child here to wait for")
	assert(c.handle != nil, "a child that was never started cannot be waited for")

	return win32.WaitForSingleObject(c.handle, win32.DWORD(milliseconds)) == win32.WAIT_OBJECT_0
}

// The code a child exited with, and whether it has exited at all.
//
// `exited` comes from the process object's signal state and NEVER from the code.
// GetExitCodeProcess answers STILL_ACTIVE for a running process, STILL_ACTIVE is
// 259, and 259 is a perfectly legal thing to exit with -- so a reading that
// treats the code as the liveness answer calls one real exit a running process,
// forever.
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

// Gives back every handle this package opened for one child.
//
// Safe on a Child that never started, which is not a convenience: every caller
// defers this immediately after start, so the refusal paths run it on a zeroed
// Child. It does NOT stop the child -- a caller that wants that calls stop first,
// and a caller that does neither still has the job object behind it.
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
	c.id = 0
}
