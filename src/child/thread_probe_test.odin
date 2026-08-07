#+vet explicit-allocators
package child

import "core:log"
import "core:strings"
import "core:testing"

// #264: on this dev-machine class, CreateToolhelp32Snapshot/Thread32First is
// a LOCAL Win32 call against this process's own snapshot -- not #230's
// multi-GB reference asset, which is routinely and legitimately absent on a
// CI box or a fresh dev machine. A snapshot of a process's own threads has
// no such routine-absence case: the calling process always has at least one
// thread to enumerate, so a failure here is not a condition to skip past --
// it is news about a broken machine or a broken assumption. Door (a) is
// taken: report_thread_count_probe turns `counted == false` into a reported
// test failure (testing.expectf, which lands on `t.error_count` the same as
// any other unmet expectation) naming the probe call and the moment it was
// taken, rather than #263's honest-skip shape of a printed line and a quiet
// return. Because the failure mode this gate exists to catch is different
// from #230's, the helper does not move to testkit alongside #263's
// reference_asset_missing -- there is no second consumer for an
// infallible-on-a-healthy-machine gate to share.
@(private)
@(require_results)
report_thread_count_probe :: proc(
	t: ^testing.T,
	n: int,
	counted: bool,
	moment: string,
) -> (
	int,
	bool,
) {
	assert(len(moment) > 0, "a probe report with no moment names nothing")
	if !testing.expectf(
		t,
		counted,
		"the Win32 thread probe (CreateToolhelp32Snapshot/Thread32First) could not count this process's own threads %s -- on a healthy machine this is a bug, not a condition to skip past",
		moment,
	) {
		return 0, false
	}
	return n, true
}

@(private)
Captured_Probe_Log :: struct {
	lines: [dynamic]string,
}

@(private)
capturing_probe_logger_proc :: proc(
	logger_data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	captured := cast(^Captured_Probe_Log)logger_data
	append(&captured.lines, strings.clone(text, context.allocator))
}

@(test)
report_thread_count_probe_reports_the_fault_when_the_probe_did_not_count :: proc(t: ^testing.T) {
	captured := Captured_Probe_Log {
		lines = make([dynamic]string, context.allocator),
	}
	defer {
		for line in captured.lines {
			delete(line, context.allocator)
		}
		delete(captured.lines)
	}

	previous_logger := context.logger
	context.logger = log.Logger {
		procedure    = capturing_probe_logger_proc,
		data         = &captured,
		lowest_level = .Debug,
		options      = {},
	}

	n, ok := report_thread_count_probe(t, 0, false, "at baseline")

	context.logger = previous_logger

	testing.expect_value(t, ok, false)
	testing.expect_value(t, n, 0)
	testing.expect(t, len(captured.lines) == 1, "a failed probe must report exactly one line")
	if len(captured.lines) == 1 {
		testing.expect(
			t,
			strings.contains(captured.lines[0], "CreateToolhelp32Snapshot"),
			"the report does not name the probe that failed",
		)
		testing.expect(
			t,
			strings.contains(captured.lines[0], "at baseline"),
			"the report does not name the moment the probe was taken",
		)
	}
}

@(test)
report_thread_count_probe_stays_silent_when_the_probe_counted :: proc(t: ^testing.T) {
	captured := Captured_Probe_Log {
		lines = make([dynamic]string, context.allocator),
	}
	defer delete(captured.lines)

	previous_logger := context.logger
	context.logger = log.Logger {
		procedure    = capturing_probe_logger_proc,
		data         = &captured,
		lowest_level = .Debug,
		options      = {},
	}

	n, ok := report_thread_count_probe(t, 7, true, "at baseline")

	context.logger = previous_logger

	testing.expect_value(t, ok, true)
	testing.expect_value(t, n, 7)
	testing.expect(t, len(captured.lines) == 0, "a successful probe was reported anyway")
}
