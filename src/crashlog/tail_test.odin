#+vet explicit-allocators
package crashlog

import "core:testing"

// A8: `last_run_ended_in_a_crash` reads a `transcibr.log` tail, and that
// file is external input by the time anything opens it again -- a second
// process could have written it last, or it could have been truncated by a
// crash mid-`WriteFile`. Every case here is a file a user could actually
// hand this, and none of them may assert.

@(test)
last_run_ended_in_a_crash_is_true_for_a_crash_terminated_tail :: proc(t: ^testing.T) {
	tail :=
		"2026-08-07T12:00:00Z INFO process start: transcibr-cli 1.0.0\n" +
		"crash_drill.odin(42) runtime assertion: deliberate failure\n" +
		"stack frame: main::run_crash_drill crash_drill.odin(42)\n"
	testing.expect(
		t,
		last_run_ended_in_a_crash(tail),
		"a stack-frame-terminated tail should read as a crash",
	)
}

@(test)
last_run_ended_in_a_crash_is_true_for_a_bare_exception_line :: proc(t: ^testing.T) {
	tail :=
		"2026-08-07T12:00:00Z INFO process start: transcibr-cli 1.0.0\n" +
		"CRASH exception=0xc000008c address=0x1234\n"
	testing.expect(
		t,
		last_run_ended_in_a_crash(tail),
		"an exception-terminated tail should read as a crash",
	)
}

@(test)
last_run_ended_in_a_crash_is_false_for_an_ordinary_tail :: proc(t: ^testing.T) {
	tail :=
		"2026-08-07T12:00:00Z INFO process start: transcibr-cli 1.0.0\n" +
		"2026-08-07T12:00:01Z INFO batch start: root=C:\\rec\n" +
		"2026-08-07T12:05:00Z INFO batch summary: 3 ok, 0 failed\n"
	testing.expect(
		t,
		!last_run_ended_in_a_crash(tail),
		"a tail ending in a routine note line should not read as a crash",
	)
}

@(test)
last_run_ended_in_a_crash_is_false_for_an_empty_tail :: proc(t: ^testing.T) {
	testing.expect(t, !last_run_ended_in_a_crash(""), "an empty tail should never read as a crash")
}

@(test)
last_run_ended_in_a_crash_is_false_for_a_tail_truncated_mid_line :: proc(t: ^testing.T) {
	tail :=
		"2026-08-07T12:00:00Z INFO process start: transcibr-cli 1.0.0\n" +
		"2026-08-07T12:00:01Z INFO batch start: root=C:\\r"
	testing.expect(
		t,
		!last_run_ended_in_a_crash(tail),
		"a mid-line truncation should fall back to its last COMPLETE line, which is a routine note",
	)
}

@(test)
last_run_ended_in_a_crash_is_false_for_a_tail_with_no_complete_line_at_all :: proc(t: ^testing.T) {
	tail := "2026-08-07T12:00:0"
	testing.expect(
		t,
		!last_run_ended_in_a_crash(tail),
		"a tail with no complete line at all cannot be judged, so it must not read as a crash",
	)
}
