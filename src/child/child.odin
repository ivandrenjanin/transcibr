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

// WHAT FOLLOWS IS A NEAR-CLONE OF `transcibr:process`, AND THE SECOND COPY IS
// THE LAST ONE. A fault enumeration, an error record, a FAULT table, one checked
// reader of it, a renderer and a disposition: the Process contract has the same
// six, and the shape is repeated here rather than shared because the two fault
// sets are disjoint and neither package should own the other's vocabulary. That
// argument holds for two packages and stops holding at three -- a third copy is
// the point at which the shape moves into a package of its own and both of these
// import it, rather than the point at which somebody copies this file again.
//
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
	// The null device would not open. Refused rather than fallen back on: the
	// fallback is a pipe nobody drains, and ADR-0004 measured what that costs --
	// the Engine wedges part-way through the first Recording with nothing to show.
	No_Null_Device,
	// No pipe for the child's diagnostic output, so nothing could read its
	// progress. A handle table this program has exhausted, in practice.
	No_Diagnostic_Pipe,
	// `CreateProcessW` refused. Overwhelmingly an executable that is not there or
	// not runnable, which is external input and a per-Recording failure.
	Not_Started,
	// The child exists but could not be put in the job object. Fatal to the child
	// rather than merely noted: it is started suspended, so a child that cannot be
	// made to die with transcibr never runs at all.
	Not_Assigned,
	// The list of handles the child may inherit could not be built, so the only
	// alternative would be to let it inherit every handle this process holds --
	// see open_handle_list for what that costs.
	No_Handle_List,
	// The child was created suspended and the resume failed, which leaves a
	// process that will never do anything.
	Not_Resumed,
	// The pipe carrying the child's diagnostic output failed in a way that is not
	// the end of it. Distinct from end of stream, which is the ordinary outcome
	// and no fault at all.
	Diagnostics_Unreadable,
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
// missing in anything that ships. Write the row and leave it EMPTY and
// every_fault_renders_a_line_a_failure_row_can_carry catches it before the sweep
// is green; fault_says asserts the same thing, but only on the first report of
// that fault, which is a Recording already failing in front of somebody.
@(private, rodata)
FAULT := [Fault]string {
	// Two rows are deliberately empty, and fault_says refuses both by name rather
	// than letting the emptiness check find them: `.None` is the success value,
	// and `.Bad_Command_Line`'s sentence belongs to the package that refused.
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

	message: string
	if err.fault == .Bad_Command_Line {
		// Passed through rather than wrapped. That report already names the argument
		// and says what about it cannot be spelled; a prefix from here would add a
		// layer's name to a sentence that is about the caller's own settings.
		message = process.error_message(err.build, allocator)
	} else {
		// The numeric code is printed and never translated. `FormatMessageW` renders
		// it in the machine's UI language, which is a second thing to be wrong
		// about, while the number is what a search engine and a header file both
		// answer to.
		message = fmt.aprintf(
			"%s (Windows error %d)",
			fault_says(err.fault),
			err.last_error,
			allocator = allocator,
		)
	}
	// The one place both branches leave through, which is why it is a postcondition
	// here rather than a check on each of them.
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

// One started child. The caller owns every handle in it and gives them all back
// with close.
//
// THERE IS NO PROCESS IDENTIFIER HERE, and the omission is the decision rather
// than an oversight. A pid is stale the moment the process exits and Windows
// recycles it, so a stored one is a number that silently starts naming somebody
// else's application -- and a late terminate against it is CLAUDE.md's own
// warning, arriving as a killed browser. Everything this package does to a child
// goes through a HANDLE, which names that one process for exactly as long as it
// is held and refuses to name anything after. One was carried here for a while,
// written and zeroed and never read; a reader who wants one back should add a
// caller that needs it in the same change, and should read this first.
Child :: struct {
	handle:      win32.HANDLE,
	thread:      win32.HANDLE,
	// A job object holding this child alone, nested inside the caller's. WIN32
	// HAS NO PROCESS TREE, which is ADR-0004's own sentence about the group -- and
	// it is just as true of one child: a child that starts something of its own
	// leaves a process TerminateProcess cannot reach and a handle table nothing
	// can enumerate. This is what gives stop a tree to stop.
	//
	// Deliberately WITHOUT the kill-on-close limit the group carries, so that
	// close stays what it says it is: giving handles back, not ending anything.
	// The group behind it is where that guarantee lives.
	tree:        win32.HANDLE,
	// The READ end of the child's diagnostic pipe, and the only end this process
	// keeps: the write end is the child's and is closed here the moment the child
	// has its copy, which is what lets this one report end of stream.
	diagnostics: win32.HANDLE,
	// Remembered rather than re-derived, because end of stream is reported ONCE by
	// the pipe and a caller that asks again after draining would otherwise get a
	// fresh failure instead of the answer it already had.
	at_end:      bool,
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
CREATION_FLAGS ::
	win32.CREATE_NO_WINDOW | win32.CREATE_SUSPENDED | win32.EXTENDED_STARTUPINFO_PRESENT

// The flag this package exists for, held by the COMPILER.
//
// It restates the line above and that is the entire point of it. Every automated
// proxy for "no console window appears" was measured against the mutation that
// deletes CREATE_NO_WINDOW and stayed green -- see the head of child_test.odin,
// which withdrew a case for exactly that -- so with this gone the one criterion
// this package was written to meet has nothing but a hand-run harness behind it.
// This does fail on that edit, and it fails before a test runs -- MEASURED: with
// CREATE_NO_WINDOW deleted, `scripts\test.ps1` reports `Compile time assertion`
// against this line and collects zero tests. It fires wherever this package is
// COMPILED, which today is the sweep and not scripts\build.ps1, because the only
// target built so far does not import it yet (issue #15).
//
// What it does NOT claim: that no window appears. That is a property of a
// windowed binary and is checked by hand. This claims only that the flag is
// still in the word, which is the part a refactor can quietly drop.
#assert(CREATION_FLAGS & win32.CREATE_NO_WINDOW != 0)

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

	streams, opening := open_streams()
	if opening.fault != .None {
		return {}, opening
	}
	c, err = start_into(group, wide, &streams, allocator)

	// Whatever happened above, the two handles the CHILD holds are no longer this
	// process's to keep -- and the pipe's write end especially. A parent that keeps
	// its copy holds the pipe open, and the read end then never reports end of
	// stream however long ago the child exited.
	close_child_side(&streams)
	if err.fault != .None {
		// There is no child left to say anything, so the read end goes too rather
		// than sitting in a zeroed Child that close cannot see.
		win32.CloseHandle(streams.read)
		return {}, err
	}
	c.diagnostics = streams.read
	return c, Error{}
}

// The three Win32 calls that actually make a child, in the one order that is
// safe: create it suspended, put it in the job object, and only then let it run.
@(private)
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

	// The group FIRST and the child's own job second, which is the order nested
	// jobs require: a process may only join a job that is a child of the ones it
	// is already in, so the outer one has to be the outer one.
	if !AssignProcessToJobObject(group.handle, pi.hProcess) {
		return {}, abandon(&pi, .Not_Assigned)
	}
	tree := CreateJobObjectW(nil, nil)
	if tree == nil {
		return {}, abandon(&pi, .No_Job_Object)
	}
	if !AssignProcessToJobObject(tree, pi.hProcess) {
		// abandon reads the last error first, so the close below cannot overwrite
		// the code being reported.
		refused := abandon(&pi, .Not_Assigned)
		win32.CloseHandle(tree)
		return {}, refused
	}

	// (DWORD)-1, which is what ResumeThread answers with rather than zero: zero is
	// the legitimate previous suspend count of a thread that was already running.
	if win32.ResumeThread(pi.hThread) == ~win32.DWORD(0) {
		refused := abandon(&pi, .Not_Resumed)
		win32.CloseHandle(tree)
		return {}, refused
	}
	return Child{handle = pi.hProcess, thread = pi.hThread, tree = tree}, Error{}
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

	// Declared HERE and passed by pointer, because the attribute list holds the
	// address of the array inside it: a Handle_List returned by value would leave
	// Windows reading a dead frame. See Handle_List.
	hl: Handle_List
	defer close_handle_list(&hl, allocator)
	refusal := open_handle_list(&hl, s, allocator)
	if refusal.fault != .None {
		return {}, refusal
	}

	// SW_HIDE for a child that turns out to have a window of its own, which
	// CREATE_NO_WINDOW says nothing about: that flag withholds a CONSOLE, and a
	// GUI child would still show itself. Both, because the children are ffmpeg
	// and the Engine today and neither is a promise about tomorrow.
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
		// Handles cannot reach a child at all without this. WHICH ones it lets
		// through is not this flag's answer but the handle list's: on its own it
		// means every inheritable handle this process holds right now, including
		// another spawn's caught mid-flight.
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
	// The answer is not read, and that is the honest reading rather than a
	// shrug: the fault being reported is the one the caller needs, and a
	// suspended child that would not die does not change what went wrong. It
	// held no file -- it never ran -- so the reason a caller waits does not
	// apply here.
	win32.TerminateProcess(pi.hProcess, TERMINATED_EXIT_CODE)
	_ = win32.WaitForSingleObject(pi.hProcess, win32.DWORD(ABANDON_BOUND_MS))
	win32.CloseHandle(pi.hThread)
	win32.CloseHandle(pi.hProcess)
	return Error{fault = fault, last_error = code}
}

// How long a stopped child is given to actually be gone, in milliseconds.
//
// BOUNDED and not INFINITE, which is issue #27's rule and is not pedantry here:
// TerminateProcess is a request the kernel grants, but a process wedged in a
// driver call can outlive it, and a Stop press that never comes back is the
// window frozen with no way out. Thirty seconds is what scripts\common.ps1 gives
// a killed process tree for the same reason, and the two agree on purpose.
//
// A BUDGET FOR THE WHOLE OF STOP and not for each wait inside it -- see stop.
STOP_BOUND_MS :: u32(30_000)

// How long a child that never ran is given, in milliseconds.
//
// Deliberately not STOP_BOUND_MS, and the difference is the whole reason it has
// a name: an abandoned child was created SUSPENDED and has not executed one
// instruction. It opened no file, started nothing and holds nothing, so there is
// nothing here to wait for but the process object signalling, which is what
// makes the two handle closes below safe. Thirty seconds of that is thirty
// seconds before a refused start reaches a Recording's failure line, with the
// rest of the Batch waiting behind it (ADR-0002).
@(private)
ABANDON_BOUND_MS :: u32(2_000)

// What is left of a budget, in milliseconds.
//
// The two numbers are handed in rather than a clock read inside, which is what
// makes the answer checkable: a deadline already gone and one exactly reached
// are the values that matter and the ones a clock will not produce on request.
//
// Never INFINITE, whatever arithmetic led here. That is an unbounded wait, which
// is the Stop press that never comes back (issue #27) -- and the property is
// held in two places rather than one (A4): stop refuses that bound on the way in
// and this refuses to produce it.
@(private)
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

// Stops a child and does not come back until it is gone, or until the bound runs
// out.
//
// FALSE MEANS SOMETHING MAY STILL BE HOLDING FILES OPEN, and a caller that treats
// it as success is the defect this return value exists to prevent: the next thing
// transcibr does to a stopped Recording is move, delete or re-run against the
// artifacts it was writing (ADR-0002). The group is still behind it either way --
// whatever survives this dies when transcibr does.
//
// The JOB OBJECT is terminated and not merely the process, and that was measured
// rather than reasoned about. `TerminateProcess` on the child alone left the file
// the child had opened still held: the thing holding it was a process the child
// had started, which TerminateProcess cannot reach and no handle enumerates.
// Microsoft describes TerminateJobObject as TerminateProcess applied to every
// member, so ADR-0004's rule is not weakened here -- it is extended to the
// descendants Win32 otherwise gives no handle on. What is never used is the
// cooperative request, which reports success without stopping anything.
//
// Then the wait, which is the whole value: until everything has actually gone,
// a file may still be open, and touching it is a sharing violation or a read of
// something half written.
//
// `milliseconds` is a budget for THE WHOLE OF THIS and not for each of the two
// waits below. Given to both it would be a bound that means half what it says:
// at the thirty-second default a Stop press could take a minute to come back,
// and for the second half of that the window has nothing to show and no way out
// (issue #16).
stop :: proc(c: ^Child, milliseconds: u32 = STOP_BOUND_MS) -> (stopped: bool) {
	assert(c != nil, "there is no child here to stop")
	assert(c.handle != nil, "a child that was never started cannot be stopped")
	assert(c.tree != nil, "a started child always has a job object of its own")
	assert(milliseconds != win32.INFINITE, "a Stop press that never comes back is a frozen window")

	deadline := GetTickCount64() + win32.ULONGLONG(milliseconds)
	// The answer is not read: a job object whose members have all already exited
	// is the outcome being asked for, not an error. The WAIT below is the check.
	TerminateJobObject(c.tree, TERMINATED_EXIT_CODE)

	// NOT an assertion, though a child that ignores termination feels like an
	// impossibility worth asserting. It is not this program's own state: a process
	// wedged in a driver call is outside transcibr, and nothing outside it may
	// crash it (A8). The caller is told instead, and told plainly what it means.
	//
	// Both halves are waited for (A3): the child itself, whose process object is
	// the one definite signal there is, and then everything it started, which only
	// the job object can account for.
	first := remaining_ms(deadline, GetTickCount64())
	if win32.WaitForSingleObject(c.handle, win32.DWORD(first)) != win32.WAIT_OBJECT_0 {
		return false
	}
	return job_emptied(c.tree, deadline)
}

// Whether a job object has emptied, before a deadline.
//
// Polled, because there is nothing to wait on: a job object signals when its
// end-of-job TIME LIMIT is exceeded and never when its last process leaves, so
// `ActiveProcesses` read in a loop is the only answer Windows offers. A
// millisecond between reads, on a path taken once per stopped Recording.
//
// A DEADLINE and not a bound of its own, because the bound was already half
// spent by the time this is reached -- see stop. The counter is read once before
// the deadline is consulted, so a deadline already gone still gets the one
// question that is usually enough: everything the job held is normally gone by
// the time the child's own process object has signalled.
@(private)
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
	if c.diagnostics != nil {
		win32.CloseHandle(c.diagnostics)
		c.diagnostics = nil
	}
	// Harmless on a child still running, and deliberately so: this job object
	// carries no kill-on-close limit, so giving it back ends nothing. What ends a
	// child nobody stopped is the GROUP, which outlives every Child in it.
	if c.tree != nil {
		win32.CloseHandle(c.tree)
		c.tree = nil
	}
	c.at_end = false
}
