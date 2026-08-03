package child

import "core:fmt"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"
import "core:testing"
import "core:time"

// The one Win32 entry point this suite asks its questions through, declared
// HERE and not beside the ones the package itself calls.
//
// The argument is command_line_test.odin's, measured on that side and carried
// over: a `_test.odin` file is type-checked in an ordinary build but nothing in
// it is linked into one, so a probe declared here costs the shipped image
// nothing. Declared beside the spawner's own bindings they would read as
// something the spawner uses, and nothing anywhere would say otherwise.
//
// A second `foreign import` of the same library under a second name, because one
// name cannot be bound twice in one package. It is the same Kernel32.
foreign import kernel32_probe "system:Kernel32.lib"

@(default_calling_convention = "system")
foreign kernel32_probe {
	IsProcessInJob :: proc(ProcessHandle: win32.HANDLE, JobHandle: win32.HANDLE, Result: ^win32.BOOL) -> win32.BOOL ---
}

// NO CASE HERE COVERS THE CONSOLE-WINDOW CRITERION, and that is a finding rather
// than an omission -- the pull request records the hand verification instead.
//
// The criterion is "no console window appears, from a windowed binary", and a
// windowed binary is what does not exist yet (issue #15). The proxy that looks
// obvious is `GetConsoleProcessList`: start a child, ask whether it joined this
// process's console, and require that it did not. MEASURED against a spike
// spawning the same child five ways, that proxy answers a different question.
//
//   no flags, no std handles     on this console: TRUE
//   STARTF_USESTDHANDLES alone   on this console: false
//   handle list                  on this console: false
//   CREATE_NO_WINDOW alone       on this console: false
//   CREATE_NO_WINDOW + list      on this console: false
//
// Redirecting the standard handles is what takes a child off that list, so the
// proxy stays green with CREATE_NO_WINDOW deleted -- measured that way too, on
// this suite, before the case was withdrawn. A case that cannot fail on the edit
// it exists to catch is a comment with a runtime cost, and this repository has
// already learned that once, in utf16_units next door.
//
// Every child this suite starts is BOUNDED, and that is a rule rather than a
// habit: `odin test` runs what it builds, and a test that starts a child which
// never exits wedges the sweep behind scripts\common.ps1's ten-minute ceiling
// with nothing naming the case that did it (issue #27). Every bound below is
// load-bearing.
//
// A long-lived child is one told to wait for a signal nobody sends, so it ends by
// itself after its own timeout even if this suite never gets to it -- see
// stays_alive for why every one of them waits on a DIFFERENT signal.
@(private)
ALIVE_SECONDS :: 5

// The one case that has to still be running long after a bound has run out; see
// KILL_BOUND_MS.
@(private)
LONGER_SECONDS :: 25

// The ceiling on waiting for any child to exit. Generous against a cold or
// loaded machine and still far under the sweep's own budget: what it bounds is a
// HANG, not slowness. A child that has to be killed to meet it FAILS a case
// rather than wedging one, which is the whole point of asking for a bound
// instead of INFINITE.
@(private)
BOUND_MS :: u32(60_000)

// The bound on waiting for a child that a closed job object should have ended.
//
// MEASURED, and the reason it is not BOUND_MS: the job-object case below first
// waited sixty seconds for the child to end, and with the kill-on-close limit
// mutated away it STILL passed -- because the child ends by itself well inside
// sixty seconds, and the case could not tell "the job object ended it" from "it
// finished". A wait bound has to be far shorter than the child's own life or it
// measures the child's patience instead of the mechanism. Closing a job object
// ends its members in microseconds, so five seconds is generous by four orders of
// magnitude and still twenty short of the child.
@(private)
KILL_BOUND_MS :: u32(5_000)

// The ceiling on waiting for a child to SAY something, which is a shorter wait
// than waiting for one to finish and is bounded separately for that reason.
@(private)
SAY_BOUND :: 20 * time.Second

// Found on PATH rather than spelled absolutely, which is what a bare name asks
// CreateProcessW to do -- and safely, because argv[0] is always quoted (see
// start). %SystemRoot%\System32 is on the PATH of every Windows session.
@(private)
CMD :: "cmd.exe"

// Everything the child has said that has arrived so far, appended, and whether
// the pipe has reached end of stream.
//
// Never blocks and never spins on a child that is quiet: `read_diagnostics`
// answers what is there NOW, which is the property the case about reading a
// running child is measuring.
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

// Reads until the child has said something in particular, or until the bound
// runs out. False means it never did.
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

// A path under the user's temp directory, named for this run so two sweeps in
// one checkout cannot write each other's file. The caller owns it and removes
// the file.
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

// The name of a signal nobody ever sends, unique to this run AND to the case that
// asks for it.
//
// UNIQUE IS NOT TIDINESS. `waitfor` registers its signal name machine-wide, and a
// second instance asking for a name already registered fails at once with
// "ERROR: Cannot wait for the specified signal" -- measured directly, and
// measured the hard way first. Five cases here shared one name, and under the
// sweep's own concurrency the children that were supposed to outlive a check
// exited immediately instead, turning a different case red on each run. The
// process identifier keeps two sweeps in one checkout apart as well, which is a
// thing scripts\selftest.ps1 does on purpose.
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

// A command that keeps a child running and then ends it, whatever this suite does
// or fails to do: `waitfor /t` returns on its own when nobody signals it, and
// nothing here ever signals anything.
@(private)
stays_alive :: proc(seconds: int, tag: string, allocator := context.allocator) -> string {
	name := lonely_signal(tag, allocator)
	defer delete(name, allocator)

	return fmt.aprintf("waitfor /t %d %s", seconds, name, allocator = allocator)
}

@(test)
a_child_runs_and_reports_the_code_it_exited_with :: proc(t: ^testing.T) {
	group, group_err := job_object_open()
	defer job_object_close(&group)
	if !testing.expectf(t, group_err.fault == .None, "no job object: %v", group_err.fault) {
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

// A8: an executable path arrives from outside -- a settings field, a discovered
// tool -- so one that names nothing is an operating error reported through the
// return, never an assertion. The message names the fault so a Recording's
// failure line can carry it.
@(test)
an_executable_that_is_not_there_is_refused_rather_than_asserted :: proc(t: ^testing.T) {
	group, group_err := job_object_open()
	defer job_object_close(&group)
	if !testing.expectf(t, group_err.fault == .None, "no job object: %v", group_err.fault) {
		return
	}

	c, err := start(&group, "transcibr-no-such-executable.exe", {}, context.allocator)
	defer close(&c)
	testing.expect_value(t, err.fault, Fault.Not_Started)

	message := error_message(err, context.allocator)
	defer delete(message, context.allocator)
	testing.expect(t, len(message) > 0, "a refusal rendered as nothing at all")
}

// The Process contract's own refusals reach the caller intact rather than being
// flattened into "could not start": a NUL in an argument names the argument it
// was in, and that is the only handle anybody has on which setting to go and fix.
@(test)
a_command_line_that_cannot_be_spelled_is_refused_before_anything_starts :: proc(t: ^testing.T) {
	group, group_err := job_object_open()
	defer job_object_close(&group)
	if !testing.expectf(t, group_err.fault == .None, "no job object: %v", group_err.fault) {
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

// The Engine writes progress to its diagnostic output for hours before it is
// finished, and a progress bar that only moved when the run ended would be a
// progress bar nobody could use (issue #9). So this is the case that says the
// output arrives WHILE the child runs: the child speaks, waits, and speaks
// again, and the first line is read back with the child demonstrably still
// alive.
@(test)
diagnostic_output_is_readable_while_the_child_is_still_running :: proc(t: ^testing.T) {
	group, group_err := job_object_open()
	defer job_object_close(&group)
	if !testing.expectf(t, group_err.fault == .None, "no job object: %v", group_err.fault) {
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

	// The whole claim, in one line: the bytes above were read out of a process
	// that has not finished. Its negative space is checked too (A3) -- the second
	// line cannot have arrived yet, so a reading that only worked because the
	// child had already run to completion fails here.
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

// End of stream is what tells a reader the child has said everything it is going
// to. It arrives because the PARENT closes its own copy of the write end after
// the child is created: keep that copy and the pipe stays open forever, however
// long the child has been gone.
@(test)
the_diagnostic_pipe_reaches_end_of_stream_once_the_child_is_gone :: proc(t: ^testing.T) {
	group, group_err := job_object_open()
	defer job_object_close(&group)
	if !testing.expectf(t, group_err.fault == .None, "no job object: %v", group_err.fault) {
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

// ADR-0004's measured case: the Engine writes every Cue to standard output during
// inference -- 14,468 bytes for twenty minutes of audio, against a default pipe
// buffer of a few kilobytes -- so an undrained stdout pipe wedges the child early
// in the first Recording, with nothing to show for it.
//
// The child here writes a quarter of a megabyte to standard output and then says
// one word on its diagnostic output. Both halves are the test: reaching the word
// is what proves the child was never blocked, and it cannot be reached by a child
// stopped part-way through the first half.
//
// MEASURED against the mutant it exists to catch. Point hStdOutput at the
// diagnostic pipe instead of the null device and this case fails in exactly the
// way ADR-0004 describes -- the child wedges at the pipe buffer and never
// finishes, and the case reports "the child never finished writing to standard
// output" after its full sixty-second bound.
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

	group, group_err := job_object_open()
	defer job_object_close(&group)
	if !testing.expectf(t, group_err.fault == .None, "no job object: %v", group_err.fault) {
		return
	}

	// `&&` and not `&`, and the path as its OWN argument. Both are what make this
	// case say anything at all.
	//
	// `&&` runs the echo only if `type` SUCCEEDED, so the word arriving is proof
	// the whole file went to standard output rather than proof the child reached
	// the end of its command line. With a plain `&` the case passed whether the
	// file was read or not -- which it was not, because the path was inside a
	// single command string: build_command_line escapes a quote as `\"`, which is
	// the rule CommandLineToArgvW reads and NOT the rule cmd.exe reads, so cmd was
	// handed a path with backslashes still on it and `type` failed every time.
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

// THE CASE THAT CARRIES THE HANDLE-INHERITANCE CRITERION, and it is written this
// way because the obvious spelling of it cannot fail.
//
// `bInheritHandles = TRUE` hands a child EVERY inheritable handle this process
// holds at that instant, not merely the ones it was given -- so two spawns
// overlapping by microseconds leave the second child holding the first's pipe,
// and the first's pipe then never reports end of stream however long ago that
// child exited. A reader draining until end of stream waits forever, and nothing
// anywhere says why.
//
// Spawning two children and watching is not a test of that: this package closes
// its copy of a write end the moment the child has one, so a second spawn STARTED
// AFTERWARDS has nothing left to inherit and passes whatever the flags say. What
// makes the failure real is the window between CreatePipe and that close, and a
// case that has to hit a window is a case that passes by luck.
//
// So the window is stood still instead. An inheritable pipe is opened HERE and
// held open across a spawn -- which is exactly the state another spawn is in
// mid-flight -- and the child must not come away with it.
@(test)
a_child_inherits_nothing_but_the_streams_it_was_given :: proc(t: ^testing.T) {
	group, group_err := job_object_open()
	defer job_object_close(&group)
	if !testing.expectf(t, group_err.fault == .None, "no job object: %v", group_err.fault) {
		return
	}

	// Another spawn's handles, caught mid-flight: inheritable, and in this
	// process's table at the moment the child below is created.
	other, other_err := open_streams()
	if !testing.expectf(t, other_err.fault == .None, "no stand-in pipe: %v", other_err.fault) {
		return
	}
	// A Child that was never started, carrying nothing but the read end -- so
	// close gives back exactly the one handle this case still owns, and the pipe
	// is read back through the package's own definition of end of stream.
	listener := Child {
		diagnostics = other.read,
	}
	defer close(&listener)

	alive := stays_alive(ALIVE_SECONDS, "inheritance")
	defer delete(alive, context.allocator)
	c, err := start(&group, CMD, {"/c", alive}, context.allocator)
	defer close(&c)
	if !testing.expectf(t, err.fault == .None, "the child did not start: %v", err.fault) {
		return
	}

	// This process gives up its own copy of the stand-in write end. Nothing else
	// should hold one, so the read end is at end of stream immediately.
	close_child_side(&other)

	said := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&said)
	testing.expect(
		t,
		drain(t, &listener, &said),
		"a running child is holding a pipe it was never given open",
	)
	// The negative space (A3): end of stream arrived while the child was still
	// running, so it is the handle table being right and not the child being gone.
	_, exited := exit_code(&c)
	testing.expect(
		t,
		!exited,
		"the child had already exited, so nothing was proved about inheritance",
	)
}

// The criterion as a reader states it: two children at once, and the one that
// finishes reports end of stream on its own pipe while the other is still going.
//
// Weaker than the case above and kept for what it does cover -- the parent
// closing its own copy of each write end, and two children not being confused for
// one another -- rather than for the inheritance rule itself.
@(test)
one_childs_pipe_ends_while_another_child_is_still_running :: proc(t: ^testing.T) {
	group, group_err := job_object_open()
	defer job_object_close(&group)
	if !testing.expectf(t, group_err.fault == .None, "no job object: %v", group_err.fault) {
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

// Half of the criterion about killing the parent, and the half that can be
// automated: the job object really carries the limit that ends its members when
// its last handle closes, and the child really is in it.
//
// The other half -- that a parent killed outright leaves no child behind -- is
// the same mechanism seen from outside, because process exit is nothing more
// than the kernel closing the handles a process held. It is verified by hand and
// recorded in the pull request; no test can meaningfully kill the process it is
// running in.
@(test)
a_child_is_put_in_a_job_object_that_ends_its_members_when_it_closes :: proc(t: ^testing.T) {
	group, group_err := job_object_open()
	defer job_object_close(&group)
	if !testing.expectf(t, group_err.fault == .None, "no job object: %v", group_err.fault) {
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

// The mechanism itself, exercised: a running child ends when the job object
// holding it is closed, and it ends because of that and not because it had
// already finished.
@(test)
closing_the_job_object_ends_a_child_that_is_still_running :: proc(t: ^testing.T) {
	group, group_err := job_object_open()
	// Closed part-way through on purpose. The defer is still here and is still
	// worth having: it is a no-op on a job object already given back, and it is
	// what covers every early return above that point.
	defer job_object_close(&group)
	if !testing.expectf(t, group_err.fault == .None, "no job object: %v", group_err.fault) {
		return
	}

	alive := stays_alive(LONGER_SECONDS, "jobclose")
	defer delete(alive, context.allocator)
	c, err := start(&group, CMD, {"/c", alive}, context.allocator)
	defer close(&c)
	if !testing.expectf(t, err.fault == .None, "the child did not start: %v", err.fault) {
		return
	}

	// The instrument, before anything is proved by it: a child that had already
	// exited would make the next three lines pass for the wrong reason.
	_, early := exit_code(&c)
	if !testing.expect(t, !early, "the child was already gone before the job object closed") {
		return
	}

	job_object_close(&group)

	testing.expect(t, wait(&c, KILL_BOUND_MS), "the child outlived the job object that held it")
	_, gone := exit_code(&c)
	testing.expect(t, gone, "the child never exited after its job object closed")
}

// Whether this process can take the file for itself, which is how "the child has
// let go of it" is asked without guessing at what the child opened it with.
//
// A share mode of zero conflicts with EVERY other open handle whatever sharing
// that handle allowed, so this answers false while anyone at all holds the file
// and true the moment nobody does. False also means the file is not there, which
// is why the case below waits for it to appear first.
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

// The bound this case gives stop, and it is the case's whole discrimination.
//
// MEASURED. With stop's own thirty-second default, a stop that terminated only
// the child and not the tree still PASSED -- it waited twenty-five seconds for
// the process the child had started to finish on its own, and then everything was
// true. Correct on that child and useless on a real one: the Engine holds its
// output for hours, so "eventually it finished by itself" is not stopping.
// Terminating a job object ends its members in microseconds, so three seconds
// passes the mechanism and fails the impostor.
@(private)
STOP_BOUND :: u32(3_000)

// The bound on waiting for a file to come free after its holder is gone.
//
// Not slack in the claim being made, and it has to be read against the
// twenty-five seconds the child would still be holding the file if stop had come
// back early: three seconds is an eighth of that, so a stop that left the child
// running still fails. What it absorbs is somebody ELSE opening the file in the
// instant after the child let go -- real-time virus scanning opens a file when
// its last handle closes, which is exactly this moment, and that is a race no
// case here can win by asserting harder. Without it this case failed about one
// sweep in three.
@(private)
FREED_BOUND :: 3 * time.Second

// Whether the file comes free, under that bound.
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

// Waits until the child has the file open, under a bound. A child that never got
// that far would make the case below pass on a file nobody was holding.
@(private)
held_by_the_child :: proc(path: string) -> bool {
	started := time.tick_now()
	for time.tick_since(started) < SAY_BOUND {
		if os.exists(path) && !taken_exclusively(path) {
			return true
		}
		time.sleep(5 * time.Millisecond)
	}
	return false
}

// Stopping a child is TERMINATE then WAIT, and the wait is the whole value: until
// the process object signals, the child may still hold a file open, and the next
// thing transcibr does to a stopped child is move, delete or re-run against the
// artifacts it was writing (ADR-0002).
//
// So the file is the measurement. The child holds one open for as long as it
// runs, and an exclusive open conflicts with any handle at all, so the file comes
// free only when nothing is holding it.
//
// MEASURED against both ways of getting stop wrong:
//
//   terminate the child and not the tree   -> "the child did not stop within the
//                                             bound", after three seconds
//   terminate and come straight back       -> "stop came back with the child
//                                             still running", at once
//
// The first is the mistake that was actually made here, and it is caught by the
// bound rather than by the file: see STOP_BOUND.
@(test)
a_stopped_child_has_let_go_of_the_file_it_held :: proc(t: ^testing.T) {
	path := scratch_path(t, "held-open")
	defer delete(path, context.allocator)
	defer os.remove(path)

	group, group_err := job_object_open()
	defer job_object_close(&group)
	if !testing.expectf(t, group_err.fault == .None, "no job object: %v", group_err.fault) {
		return
	}

	// The path goes in as its OWN argument rather than inside a command string,
	// and that is not a style choice. build_command_line quotes an argument that
	// holds a space and escapes a quote inside one as `\"` -- which is the rule
	// CommandLineToArgvW reads and NOT the rule cmd.exe reads, so a quoted path
	// buried in a single command string reaches cmd with the backslashes still on
	// it. As its own argument it is quoted once, by us, and cmd sees a path.
	// Spelled as SEPARATE, space-free arguments so that only the path is quoted.
	// cmd.exe strips the outer quotes of a `/c` string when its first character is
	// one, and the quote it removes is the LAST on the line -- which would be the
	// path's own closing quote on a machine whose temp directory holds a space.
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
		held_by_the_child(path),
		"the child never opened the file it was told to",
	) {
		return
	}

	testing.expect(t, stop(&c, STOP_BOUND), "the child did not stop within the bound")

	// Asked FIRST and with no waiting of any kind: this is what catches a stop
	// that terminated and came straight back. The file below is the other half --
	// what the child, or anything the child started, was still holding.
	_, gone := exit_code(&c)
	testing.expect(t, gone, "stop came back with the child still running")
	testing.expect(
		t,
		freed_within_bound(path),
		"the file the child held was still open when stop came back",
	)
}
