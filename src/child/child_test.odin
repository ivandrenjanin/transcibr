package child

import "core:fmt"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"
import "core:testing"
import "core:time"
import "transcibr:process"

// A second `foreign import` of Kernel32 under a second name, because one name
// cannot be bound twice in one package.
foreign import kernel32_probe "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32_probe {
	IsProcessInJob :: proc(ProcessHandle: win32.HANDLE, JobHandle: win32.HANDLE, Result: ^win32.BOOL) -> win32.BOOL ---
}

// A long-lived child waits for a signal nobody sends, so it ends by itself even
// if the suite never gets to it. Why every child here is bounded: ADR-0020.
@(private)
ALIVE_SECONDS :: 5

@(private)
LONGER_SECONDS :: 25

// Generous against a cold or loaded machine: what it bounds is a hang, not
// slowness.
@(private)
BOUND_MS :: u32(60_000)

// MEASURED: at BOUND_MS the job-object case still passed with the kill-on-close
// limit mutated away, because the child ends by itself inside sixty seconds. A
// wait bound has to be far shorter than the child's own life.
@(private)
KILL_BOUND_MS :: u32(5_000)

@(private)
SAY_BOUND :: 20 * time.Second

// Why a bare name is safe here: ADR-0019.
@(private)
CMD :: "cmd.exe"

@(private)
drain :: proc(t: ^testing.T, c: ^Child, into: ^strings.Builder) -> (at_end: bool) {
	buffer: [4096]u8
	for {
		n, done, err := read_diagnostics(c, buffer[:])
		if !testing.expectf(t, err.fault == .None, "reading diagnostics: %v", err.fault) {
			return true
		}
		strings.write_bytes(into, buffer[:n])
		if done {
			return true
		}
		if n == 0 {
			return false
		}
	}
}

@(private)
read_until :: proc(t: ^testing.T, c: ^Child, marker: string, into: ^strings.Builder) -> bool {
	started := time.tick_now()
	for time.tick_since(started) < SAY_BOUND {
		at_end := drain(t, c, into)
		if strings.contains(strings.to_string(into^), marker) {
			return true
		}
		if at_end {
			return false
		}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

@(private)
scratch_path :: proc(t: ^testing.T, name: string, allocator := context.allocator) -> string {
	directory := os.get_env("TEMP", allocator)
	defer delete(directory, allocator)
	testing.expect(t, len(directory) > 0, "TEMP names nowhere to put a scratch file")

	return fmt.aprintf(
		"%s\\transcibr-child-%d-%s.txt",
		directory,
		win32.GetCurrentProcessId(),
		name,
		allocator = allocator,
	)
}

// The caller still writes its own `defer job_object_close(&group)`: the object
// has to outlive this procedure.
@(private)
open_group :: proc(t: ^testing.T) -> (group: Job_Object, ok: bool) {
	err: Error
	group, err = job_object_open()
	if !testing.expectf(t, err.fault == .None, "no job object: %v", err.fault) {
		return group, false
	}
	return group, true
}

// MEASURED: `waitfor` registers its signal name machine-wide, and a second
// instance asking for a name already registered fails at once. Five cases
// sharing one name turned a different case red on each concurrent run.
@(private)
lonely_signal :: proc(tag: string, allocator := context.allocator) -> string {
	assert(len(tag) > 0, "a signal name shared by two cases is a signal one of them cannot have")

	return fmt.aprintf(
		"transcibrNoSignal%d%s",
		win32.GetCurrentProcessId(),
		tag,
		allocator = allocator,
	)
}

// `waitfor /t` returns on its own when nobody signals it, and nothing here ever
// signals anything.
@(private)
stays_alive :: proc(seconds: int, tag: string, allocator := context.allocator) -> string {
	name := lonely_signal(tag, allocator)
	defer delete(name, allocator)

	return fmt.aprintf("waitfor /t %d %s", seconds, name, allocator = allocator)
}

@(test)
a_child_runs_and_reports_the_code_it_exited_with :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	c, err := start(&group, CMD, {"/c", "exit 7"}, context.allocator)
	defer close(&c)
	if !testing.expectf(t, err.fault == .None, "the child did not start: %v", err.fault) {
		return
	}

	testing.expect(t, wait(&c, BOUND_MS), "the child did not exit within the bound")
	code, exited := exit_code(&c)
	testing.expect(t, exited, "a child that was waited for reports that it is still running")
	testing.expect_value(t, code, u32(7))
}

@(test)
an_executable_that_is_not_there_is_refused_rather_than_asserted :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	c, err := start(&group, "transcibr-no-such-executable.exe", {}, context.allocator)
	defer close(&c)
	testing.expect_value(t, err.fault, Fault.Not_Started)

	message := error_message(err, context.allocator)
	defer delete(message, context.allocator)
	testing.expect(t, len(message) > 0, "a refusal rendered as nothing at all")
}

@(test)
a_command_line_that_cannot_be_spelled_is_refused_before_anything_starts :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	c, err := start(&group, CMD, {"/c", "exit\x000"}, context.allocator)
	defer close(&c)
	testing.expect_value(t, err.fault, Fault.Bad_Command_Line)
	testing.expect_value(t, err.build.argument, 2)

	message := error_message(err, context.allocator)
	defer delete(message, context.allocator)
	testing.expect(t, len(message) > 0, "a refusal rendered as nothing at all")
}

// The emptiness is read off the table rather than left to fault_says's own
// assertion: a test that asserts takes the runner down (CLAUDE.md, Odin notes).
@(test)
every_fault_renders_a_line_a_failure_row_can_carry :: proc(t: ^testing.T) {
	for fault in Fault {
		if fault == .None {
			continue
		}
		if fault == .Bad_Command_Line {
			continue
		}
		if !testing.expectf(t, len(FAULT[fault]) > 0, "%v has an empty row in FAULT", fault) {
			continue
		}

		message := error_message(Error{fault = fault, last_error = 5}, context.allocator)
		defer delete(message, context.allocator)
		want := fmt.tprintf("%s (Windows error 5)", FAULT[fault])
		testing.expectf(t, message == want, "%v rendered <%s>, wanted <%s>", fault, message, want)
	}
}

@(test)
every_fault_says_whether_a_different_plan_would_help :: proc(t: ^testing.T) {
	for fault in Fault {
		if fault == .None {
			continue
		}
		err := Error {
			fault = fault,
		}
		if fault == .Bad_Command_Line {
			err.build = process.Build_Error {
				fault = .Too_Long,
			}
			testing.expect_value(t, disposition_of(err), process.Disposition.Shorten_And_Replan)
			err.build = process.Build_Error {
				fault = .Nul_In_Argument,
			}
		}
		got := disposition_of(err)
		testing.expectf(t, got == .Fail_The_Job, "%v is %v, want Fail_The_Job", fault, got)
	}
}

@(test)
what_is_left_of_a_budget_is_never_all_of_it_again :: proc(t: ^testing.T) {
	testing.expect_value(t, remaining_ms(1_000, 0), u32(1_000))
	testing.expect_value(t, remaining_ms(1_000, 400), u32(600))
	testing.expect_value(t, remaining_ms(1_000, 999), u32(1))
	testing.expect_value(t, remaining_ms(1_000, 1_000), u32(0))
	testing.expect_value(t, remaining_ms(1_000, 5_000), u32(0))
	far := win32.ULONGLONG(win32.INFINITE) + 10
	testing.expect(t, remaining_ms(far, 0) != win32.INFINITE, "a budget rendered as INFINITE")
}

@(test)
diagnostic_output_is_readable_while_the_child_is_still_running :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	alive := stays_alive(ALIVE_SECONDS, "readwhilerunning")
	defer delete(alive, context.allocator)
	command := fmt.aprintf(
		"echo first 1>&2 & %s & echo second 1>&2",
		alive,
		allocator = context.allocator,
	)
	defer delete(command, context.allocator)
	c, err := start(&group, CMD, {"/c", command}, context.allocator)
	defer close(&c)
	if !testing.expectf(t, err.fault == .None, "the child did not start: %v", err.fault) {
		return
	}

	said := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&said)
	testing.expect(t, read_until(t, &c, "first", &said), "the child's first line never arrived")

	_, exited := exit_code(&c)
	testing.expect(
		t,
		!exited,
		"the child had already exited, so nothing was read from a running one",
	)
	testing.expect(
		t,
		!strings.contains(strings.to_string(said), "second"),
		"the child said everything at once",
	)

	testing.expect(t, wait(&c, BOUND_MS), "the child did not exit within the bound")
	testing.expect(t, drain(t, &c, &said), "the pipe never reached end of stream")
	testing.expect(
		t,
		strings.contains(strings.to_string(said), "second"),
		"the child's last line was lost",
	)
}

@(test)
the_diagnostic_pipe_reaches_end_of_stream_once_the_child_is_gone :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	c, err := start(&group, CMD, {"/c", "echo the whole story 1>&2"}, context.allocator)
	defer close(&c)
	if !testing.expectf(t, err.fault == .None, "the child did not start: %v", err.fault) {
		return
	}

	testing.expect(t, wait(&c, BOUND_MS), "the child did not exit within the bound")

	said := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&said)
	testing.expect(
		t,
		read_until(t, &c, "the whole story", &said),
		"the child's line never arrived",
	)
	testing.expect(t, drain(t, &c, &said), "the pipe never reached end of stream")
}

// Why standard output goes to the null device: ADR-0004.
@(test)
standard_output_goes_to_the_null_device :: proc(t: ^testing.T) {
	path := scratch_path(t, "stdout-volume")
	defer delete(path, context.allocator)
	bulk := strings.repeat(
		"transcibr writes a great deal to standard output.\r\n",
		5000,
		context.allocator,
	)
	defer delete(bulk, context.allocator)
	if !testing.expect_value(t, os.write_entire_file(path, transmute([]u8)bulk), nil) {
		return
	}
	defer os.remove(path)

	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	c, err := start(
		&group,
		CMD,
		{"/c", "type", path, "&&", "echo", "drained", "1>&2"},
		context.allocator,
	)
	defer close(&c)
	if !testing.expectf(t, err.fault == .None, "the child did not start: %v", err.fault) {
		return
	}

	testing.expect(t, wait(&c, BOUND_MS), "the child never finished writing to standard output")

	said := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&said)
	testing.expect(
		t,
		read_until(t, &c, "drained", &said),
		"the child never got past its standard output",
	)
}

// Why the case stands the spawn window still instead of racing it: ADR-0020.
@(test)
a_child_inherits_nothing_but_the_streams_it_was_given :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	other, other_err := open_streams()
	if !testing.expectf(t, other_err.fault == .None, "no stand-in pipe: %v", other_err.fault) {
		return
	}
	listener := Child {
		diagnostics = other.read,
	}
	defer close(&listener)

	alive := stays_alive(ALIVE_SECONDS, "inheritance")
	defer delete(alive, context.allocator)
	c, err := start(&group, CMD, {"/c", alive}, context.allocator)
	defer close(&c)

	close_child_side(&other)
	if !testing.expectf(t, err.fault == .None, "the child did not start: %v", err.fault) {
		return
	}

	said := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&said)
	testing.expect(
		t,
		drain(t, &listener, &said),
		"a running child is holding a pipe it was never given open",
	)
	_, exited := exit_code(&c)
	testing.expect(
		t,
		!exited,
		"the child had already exited, so nothing was proved about inheritance",
	)
}

@(test)
one_childs_pipe_ends_while_another_child_is_still_running :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	brief, brief_err := start(&group, CMD, {"/c", "echo brief 1>&2"}, context.allocator)
	defer close(&brief)
	alive := stays_alive(ALIVE_SECONDS, "twoatonce")
	defer delete(alive, context.allocator)
	lasting, lasting_err := start(&group, CMD, {"/c", alive}, context.allocator)
	defer close(&lasting)
	if !testing.expectf(t, brief_err.fault == .None, "the brief child: %v", brief_err.fault) {
		return
	}
	if !testing.expectf(
		t,
		lasting_err.fault == .None,
		"the lasting child: %v",
		lasting_err.fault,
	) {
		return
	}

	testing.expect(t, wait(&brief, BOUND_MS), "the brief child did not exit within the bound")

	said := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&said)
	testing.expect(
		t,
		read_until(t, &brief, "brief", &said),
		"the brief child's line never arrived",
	)
	testing.expect(
		t,
		drain(t, &brief, &said),
		"the brief child's pipe never reached end of stream",
	)

	_, exited := exit_code(&lasting)
	testing.expect(t, !exited, "the lasting child was gone, so nothing ran alongside anything")
}

// No test can kill the process it is running in, so the other half -- a parent
// killed outright leaving no child behind -- is verified by hand.
@(test)
a_child_is_put_in_a_job_object_that_ends_its_members_when_it_closes :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION
	returned: win32.DWORD
	read := QueryInformationJobObject(
		group.handle,
		JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
		rawptr(&limits),
		size_of(limits),
		&returned,
	)
	if !testing.expect(t, bool(read), "the job object would not say what limits it carries") {
		return
	}
	testing.expect(
		t,
		limits.BasicLimitInformation.LimitFlags & JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE != 0,
		"the job object does not end its members when it closes, so it contains nothing",
	)

	alive := stays_alive(ALIVE_SECONDS, "jobmembership")
	defer delete(alive, context.allocator)
	c, err := start(&group, CMD, {"/c", alive}, context.allocator)
	defer close(&c)
	if !testing.expectf(t, err.fault == .None, "the child did not start: %v", err.fault) {
		return
	}

	inside: win32.BOOL
	asked := IsProcessInJob(c.handle, group.handle, &inside)
	testing.expect(t, bool(asked), "Windows would not say whether the child is in the job object")
	testing.expect(t, bool(inside), "the child was started outside the job object it was given")
}

@(test)
closing_the_job_object_ends_a_child_that_is_still_running :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	alive := stays_alive(LONGER_SECONDS, "jobclose")
	defer delete(alive, context.allocator)
	c, err := start(&group, CMD, {"/c", alive}, context.allocator)
	defer close(&c)
	if !testing.expectf(t, err.fault == .None, "the child did not start: %v", err.fault) {
		return
	}

	_, early := exit_code(&c)
	if !testing.expect(t, !early, "the child was already gone before the job object closed") {
		return
	}

	job_object_close(&group)

	testing.expect(t, wait(&c, KILL_BOUND_MS), "the child outlived the job object that held it")
	_, gone := exit_code(&c)
	testing.expect(t, gone, "the child never exited after its job object closed")
}

// A share mode of zero conflicts with every other open handle whatever sharing
// that handle allowed. False also means the file is not there.
@(private)
taken_exclusively :: proc(path: string) -> bool {
	wide := win32.utf8_to_utf16(path, context.allocator)
	defer delete(wide, context.allocator)

	handle := win32.CreateFileW(
		win32.wstring(raw_data(wide)),
		win32.GENERIC_WRITE,
		0,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if handle == win32.INVALID_HANDLE_VALUE {
		return false
	}
	win32.CloseHandle(handle)
	return true
}

// Measured; see ADR-0020.
@(private)
STOP_BOUND :: u32(3_000)

// Measured; see ADR-0020.
@(private)
FREED_BOUND :: 3 * time.Second

@(private)
freed_within_bound :: proc(path: string) -> bool {
	started := time.tick_now()
	for {
		if taken_exclusively(path) {
			return true
		}
		if time.tick_since(started) >= FREED_BOUND {
			return false
		}
		time.sleep(5 * time.Millisecond)
	}
}

// Why three: ADR-0020.
@(private)
HOLDERS_OF_THE_FILE :: u32(3)

@(private)
job_holds :: proc(job: win32.HANDLE) -> u32 {
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
		return 0
	}
	return u32(accounting.ActiveProcesses)
}

@(private)
held_by_the_child :: proc(c: ^Child, path: string) -> bool {
	assert(c != nil, "there is no child here to wait on")
	assert(c.tree != nil, "a started child always has a job object of its own")

	started := time.tick_now()
	for time.tick_since(started) < SAY_BOUND {
		if job_holds(c.tree) >= HOLDERS_OF_THE_FILE {
			if os.exists(path) && !taken_exclusively(path) {
				return true
			}
		}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

// Measured; see ADR-0020.
// Why the path goes in as its own argument: ADR-0019.
@(test)
a_stopped_child_has_let_go_of_the_file_it_held :: proc(t: ^testing.T) {
	path := scratch_path(t, "held-open")
	defer delete(path, context.allocator)
	defer os.remove(path)

	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	name := lonely_signal("heldopen", context.allocator)
	defer delete(name, context.allocator)
	block := fmt.aprintf("%s)", name, allocator = context.allocator)
	defer delete(block, context.allocator)
	seconds := fmt.aprintf("%d", LONGER_SECONDS, allocator = context.allocator)
	defer delete(seconds, context.allocator)

	arguments := [?]string{"/c", "(waitfor", "/t", seconds, block, ">", path}
	c, err := start(&group, CMD, arguments[:], context.allocator)
	defer close(&c)
	if !testing.expectf(t, err.fault == .None, "the child did not start: %v", err.fault) {
		return
	}

	if !testing.expect(
		t,
		held_by_the_child(&c, path),
		"the child never got as far as holding the file through a process of its own",
	) {
		return
	}

	testing.expect(t, stop(&c, STOP_BOUND), "the child did not stop within the bound")

	_, gone := exit_code(&c)
	testing.expect(t, gone, "stop came back with the child still running")
	testing.expectf(
		t,
		job_holds(c.tree) == 0,
		"stop came back with %d process(es) the child started still running",
		job_holds(c.tree),
	)
	testing.expect(
		t,
		freed_within_bound(path),
		"the file the child held was still open when stop came back",
	)
}

// Query and not JOB_OBJECT_TERMINATE (0x0008), which is the gap the case below is
// built on.
@(private)
JOB_OBJECT_QUERY :: win32.DWORD(0x0004)

@(private)
query_only_view :: proc(job: win32.HANDLE) -> win32.HANDLE {
	assert(job != nil, "there is no job object here to duplicate")

	view: win32.HANDLE
	me := win32.GetCurrentProcess()
	if !win32.DuplicateHandle(me, job, me, &view, JOB_OBJECT_QUERY, false, 0) {
		return nil
	}
	assert(view != nil, "DuplicateHandle reported success and handed back nothing")
	return view
}

// Only how long the case is willing to watch stop fail to see a job object empty:
// the member it is asked about has twenty-five seconds left.
@(private)
LINGER_BOUND_MS :: u32(500)

// Why the terminate is withheld, and what this does not measure: ADR-0020.
@(test)
stop_is_false_while_something_the_child_started_is_still_running :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	name := lonely_signal("outlived", context.allocator)
	defer delete(name, context.allocator)
	seconds := fmt.aprintf("%d", LONGER_SECONDS, allocator = context.allocator)
	defer delete(seconds, context.allocator)

	arguments := [?]string{"/c", "start", "/b", "waitfor", "/t", seconds, name}
	c, err := start(&group, CMD, arguments[:], context.allocator)
	defer close(&c)
	if !testing.expectf(t, err.fault == .None, "the child did not start: %v", err.fault) {
		return
	}

	if !testing.expect(t, wait(&c, BOUND_MS), "the child did not exit within the bound") {
		return
	}
	if !testing.expect(t, job_holds(c.tree) > 0, "the child left nothing running behind it") {
		return
	}

	view := query_only_view(c.tree)
	if !testing.expect(t, view != nil, "Windows would not duplicate the job object handle") {
		return
	}
	defer win32.CloseHandle(view)

	probe := Child {
		handle = c.handle,
		tree   = view,
	}
	testing.expect(
		t,
		!stop(&probe, LINGER_BOUND_MS),
		"stop said it had stopped a child with something it started still running",
	)
	testing.expect(
		t,
		job_holds(c.tree) > 0,
		"the job object emptied anyway, so nothing here was standing still",
	)

	testing.expect(t, stop(&c, STOP_BOUND), "the child's tree did not stop within the bound")
}
