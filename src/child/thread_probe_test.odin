#+vet explicit-allocators
package child

import "core:log"
import "core:strings"
import "core:testing"

// #264: CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0) takes a SYSTEM-WIDE
// thread snapshot, not one scoped to this process -- the pid filter that
// narrows it down to "this process's own threads" is applied afterward, by
// the caller's own Thread32First/Next walk (see read_test.odin). Door (a)
// does not rest on "a live process always has a thread to enumerate";
// that argument does not bound a system-wide capture. It rests on direct
// measurement instead: 40,000 real snapshot+walk rounds, 20,000 of them
// taken under six concurrent process-churn loops, produced zero
// CreateToolhelp32Snapshot failures and zero Thread32First failures.
// report_thread_count_probe turns `counted == false` into a reported test
// failure (testing.expectf) naming the probe call and the moment it was
// taken, rather than #263's honest-skip shape of a printed line and a
// quiet return.
//
// testing.expectf never touches the `t` it is passed -- at the pinned
// core:testing sources it is accepted and unused. What actually turns a
// failed expectf into a counted failure is context.logger: the test
// runner installs, once per running test, a logger whose `data` points at
// that SAME test's own `T` (runner.odin), and test_logger_proc increments
// `t.error_count` there whenever a message at or above .Error arrives
// (logging.odin). expectf's failure path is log.errorf, an Error-level
// message, so it reaches that logger and lands in error_count -- through
// log ROUTING, never through the `t` parameter. The two self-tests below
// swap context.logger to a capturing logger, which is why they observe a
// logged line rather than an error_count increment; they cannot observe
// the real increment without corrupting the outer `odin test` run's own
// result, since the ambient logger's `data` is the currently-running
// test's `t`, not any `t` an inner call happens to pass to expectf.
// report_thread_count_probe_fault_reaches_the_ambient_logger_not_the_t_parameter
// closes that gap without touching the ambient logger: it installs its own
// logger over a throwaway sink and shows the increment follows whatever
// context.logger points at, independent of the `t` argument. Because the
// failure mode this gate exists to catch is different from #230's, the
// helper does not move to testkit alongside #263's reference_asset_missing
// -- there is no second consumer for an infallible-on-a-healthy-machine
// gate to share.
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

@(private)
Fault_Sink :: struct {
	errors: int,
}

@(private)
fault_sink_logger_proc :: proc(
	logger_data: rawptr,
	level: log.Level,
	text: string,
	options: log.Options,
	location := #caller_location,
) {
	sink := cast(^Fault_Sink)logger_data
	if level >= .Error {
		sink.errors += 1
	}
}

@(test)
report_thread_count_probe_fault_reaches_the_ambient_logger_not_the_t_parameter :: proc(
	t: ^testing.T,
) {
	sink := Fault_Sink{}

	previous_logger := context.logger
	context.logger = log.Logger {
		procedure    = fault_sink_logger_proc,
		data         = &sink,
		lowest_level = .Debug,
		options      = {},
	}

	_, ok := report_thread_count_probe(t, 0, false, "at baseline")

	context.logger = previous_logger

	testing.expect_value(t, ok, false)
	testing.expect_value(t, sink.errors, 1)
}
