package child

import "core:testing"

// Every child this suite starts is BOUNDED, and that is a rule rather than a
// habit: `odin test` runs what it builds, and a test that starts a child which
// never exits wedges the sweep behind scripts\common.ps1's ten-minute ceiling
// with nothing naming the case that did it (issue #27). Two bounds, and both
// are load-bearing.
//
// LIVE_SECONDS is how long a child that must still be running when it is looked
// at stays alive on its own -- `waitfor /t` returns when nobody signals it, so
// the child ends by itself even if this suite never gets to it. Long enough that
// a loaded machine has not raced past it, short enough that a leaked one is gone
// before the sweep is.
@(private)
LIVE_SECONDS :: "4"

// The ceiling on waiting for any child to exit. Generous against a cold or
// loaded machine and still far under the sweep's own budget: what it bounds is a
// HANG, not slowness.
@(private)
BOUND_MS :: u32(60_000)

// Found on PATH rather than spelled absolutely, which is what a bare name asks
// CreateProcessW to do -- and safely, because argv[0] is always quoted (see
// start). %SystemRoot%\System32 is on the PATH of every Windows session.
@(private)
CMD :: "cmd.exe"

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
