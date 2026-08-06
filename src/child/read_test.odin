#+vet explicit-allocators
package child

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"
import "core:testing"
import "core:thread"
import "core:time"
import "transcibr:testkit"

// Far shorter than READ_BOUND_MS, so a case that wants the ceiling reached
// measures the bound rather than a real caller's patience.
@(private)
READ_SHORT_BOUND_MS :: i64(300)

// Windows' default timer resolution quantizes both `time.sleep` calls this
// case makes: the poll loop's own sleeps and the granularity `tick_since`
// is read against -- measured elsewhere in this suite at 3.70-3.79s for what
// a 2ms-per-chunk nominal cost predicts as 512ms, a 7.4x inflation from the
// 15.625ms timer period. The margin here is generous rather than tight
// because nothing in this case pins READ_POLL itself.
@(private)
READ_BOUND_SLACK :: 2 * time.Second

// A read that is expected to finish still needs a bound to hand `read_bounded`
// (it has no INFINITE of its own), and this file has no child running to
// borrow one from: `run_test.odin`'s `CHILD_RUN_BOUND_MS` is `@(private)` to
// the package and reachable from here, but it is named and commented for a
// CHILD's run, and retuning it would silently retune two read cases in a
// file nobody reading run_test.odin would think to open. Two files, two
// constants, even where the number is the same.
@(private)
READ_TEST_RUN_BOUND_MS :: i64(60_000)

// A named pipe with a server end and nobody ever writing to it or closing
// it: the general case issue #27 names alongside a reserved device name, and
// the one this suite can reach without depending on a Windows device name at
// all. The caller closes `server` and frees `path`.
@(private)
@(require_results)
pipe_with_no_writer :: proc(
	t: ^testing.T,
	tag: string,
	allocator: mem.Allocator,
) -> (
	path: string,
	server: win32.HANDLE,
	ok: bool,
) {
	assert(t != nil, "there is no test here to report a refusal through")
	assert(len(tag) > 0, "a pipe name shared by two cases is a pipe one of them cannot claim")

	path = fmt.aprintf(
		`\\.\pipe\transcibr-read-bound-%d-%s`,
		win32.GetCurrentProcessId(),
		tag,
		allocator = allocator,
	)

	wide := win32.utf8_to_utf16(path, allocator)
	defer delete(wide, allocator)

	server = win32.CreateNamedPipeW(
		win32.wstring(raw_data(wide)),
		win32.PIPE_ACCESS_OUTBOUND,
		win32.PIPE_TYPE_BYTE | win32.PIPE_WAIT,
		1,
		4096,
		4096,
		0,
		nil,
	)
	if server == win32.INVALID_HANDLE_VALUE {
		delete(path, allocator)
		testing.expect(t, false, "could not create a named pipe with nobody writing to it")
		return "", nil, false
	}
	return path, server, true
}

// Finding 5 of PR #64's third review: `await_or_abandon`'s own guard used to
// read `bound_ms <= i64(max(win32.DWORD))`, which ADMITS `max(win32.DWORD)`
// -- and `core:sys/windows` defines `INFINITE :: ~DWORD(0)`, bit-identical
// to `max(win32.DWORD)`, so that admitted value means an unbounded
// `WaitForSingleObject`, the exact defect issue #27 exists to abolish.
// Checked here rather than by calling `await_or_abandon` with the forbidden
// value: that would trip the assert the fix installs, and CLAUDE.md forbids
// a test that deliberately trips one (issue #22 -- the runner hangs rather
// than reporting a clean failure).
@(test)
infinite_itself_is_bit_identical_to_the_dword_maximum :: proc(t: ^testing.T) {
	testing.expect_value(t, u32(win32.INFINITE), max(win32.DWORD))
}

@(test)
a_bound_of_infinite_itself_is_not_expressible_to_wait_for_single_object :: proc(t: ^testing.T) {
	testing.expect(
		t,
		bound_expressible(i64(max(win32.DWORD)) - 1),
		"a bound one below the DWORD maximum was refused as inexpressible",
	)
	testing.expect(
		t,
		!bound_expressible(i64(max(win32.DWORD))),
		"a bound bit-identical to INFINITE was accepted as an expressible wait",
	)
	testing.expect(
		t,
		!bound_expressible(i64(max(win32.DWORD)) + 1),
		"a bound past the DWORD maximum was accepted as an expressible wait",
	)
}

@(test)
a_read_that_cannot_finish_is_abandoned_at_its_bound :: proc(t: ^testing.T) {
	path, server, ok := pipe_with_no_writer(t, "abandoned", context.allocator)
	if !ok {
		return
	}
	defer delete(path, context.allocator)
	defer win32.CloseHandle(server)

	started := time.tick_now()
	bytes, err := read_bounded(path, READ_SHORT_BOUND_MS, context.allocator)
	elapsed := time.tick_since(started)

	testing.expect_value(t, err.fault, Read_Fault.Did_Not_Finish)
	testing.expect(t, len(bytes) == 0, "an abandoned read handed back bytes it never finished")
	testing.expectf(
		t,
		elapsed < time.Duration(READ_SHORT_BOUND_MS) * time.Millisecond + READ_BOUND_SLACK,
		"the read ran %v past its %d ms bound instead of being abandoned at it",
		elapsed,
		READ_SHORT_BOUND_MS,
	)
}

@(private)
Instant_Job :: struct {
	done: bool,
}

@(private)
instant_worker :: proc(data: rawptr) {
	job := (^Instant_Job)(data)
	assert(job != nil, "an instant-finishing thread was started with no job to mark")
	job.done = true
}

// Finding 2 of the PR #64 review: `await_or_abandon`'s wait phase used to be
// a poll loop that checked `thread.is_done` once before its first sleep and
// slept READ_POLL -- quantized by Windows to roughly 15.6 ms -- on every
// iteration after. A thread finishing in microseconds still cost at least
// one of those sleeps in practice, because `CreateThread`'s own scheduling
// latency almost always beats this loop to that first check. Measured
// against 150 Recordings through the public `--plan` seam: about 85 ms
// before this wait phase existed at all, 7,573 ms with the poll loop in
// place, back under 200 ms with `win32.WaitForSingleObject` in its place.
// This case pins the mechanism directly rather than the CLI's timing: a
// thread that finishes on its own, waited on immediately after it starts,
// must not cost this a whole poll interval to notice.
//
// Finding 4 of PR #64's third review: `elapsed < READ_POLL` (10 ms) gave
// only about 2x margin against real scheduling noise. Instrumented under
// this package's full concurrent sweep -- the load `windows-latest`'s four
// vCPUs actually run this case under, twelve `odin test` threads alongside
// the 8 MiB flood write and the 25 abandoned reads elsewhere in this file --
// `elapsed` measured 502 us, 3.37 ms and 5.12 ms, the last of those already
// half the old budget. What this case exists to catch is a regression back
// to the ORIGINAL poll loop, whose floor was Windows' own timer
// quantization -- about 15.6 ms for even a single sleep -- and not READ_-
// POLL's literal value, so a wider margin loses no discrimination against
// the regression this case is for.
@(private)
INSTANT_WAIT_BOUND :: 25 * time.Millisecond

@(test)
await_or_abandon_notices_a_finished_thread_without_waiting_for_a_poll :: proc(t: ^testing.T) {
	job: Instant_Job
	th := thread.create_and_start_with_data(&job, instant_worker)
	if !testing.expect(t, th != nil, "a thread this case needed to start would not start") {
		return
	}

	started := time.tick_now()
	wait := await_or_abandon(th, READ_TEST_RUN_BOUND_MS)
	elapsed := time.tick_since(started)
	thread.destroy(th)

	testing.expect_value(t, wait, Wait.Finished)
	testing.expect(t, job.done, "a thread reported finished had not actually run its worker")
	testing.expectf(
		t,
		elapsed < INSTANT_WAIT_BOUND,
		"waiting for an already-finishing thread took %v, at least one poll's worth of sleep rather than an exact wait",
		elapsed,
	)
}

// Counts only this process's own threads, so a busy CI box running other work
// alongside the suite cannot move the number this test reads.  `-1, false` on
// a snapshot Windows refuses to hand back, which the caller treats as nothing
// proven rather than as zero.
@(private)
@(require_results)
transcibr_thread_count :: proc() -> (n: int, counted: bool) {
	snapshot := win32.CreateToolhelp32Snapshot(win32.TH32CS_SNAPTHREAD, 0)
	if snapshot == win32.INVALID_HANDLE_VALUE {
		return 0, false
	}
	defer win32.CloseHandle(snapshot)

	pid := win32.GetCurrentProcessId()
	entry: win32.THREADENTRY32
	entry.dwSize = size_of(win32.THREADENTRY32)
	if !win32.Thread32First(snapshot, &entry) {
		return 0, false
	}
	for {
		if entry.th32OwnerProcessID == pid {
			n += 1
		}
		entry.dwSize = size_of(win32.THREADENTRY32)
		if !win32.Thread32Next(snapshot, &entry) {
			break
		}
	}
	return n, true
}

// Finding 7 of the PR #64 review's second pass: five rounds made this case's
// only guard on the headline finding below a single stray thread away from
// either failure direction, since the sweep runs every package's tests
// across twelve concurrent threads and a sibling case (the single-read case
// above, the 8 MiB worst-case read) holds a read thread of its own live in
// that same window. A sibling that exits between `baseline` and `after`
// fails this spuriously; one that starts in that window masks a real leak by
// the identical amount. Scaling the round count up and the pass condition to
// a tolerance rather than an exact match is what tells the two apart: the
// unfixed code's own signature is +1 thread EVERY round, never reclaimed, so
// at `ROUNDS` large enough that signal dwarfs whatever a handful of sibling
// threads starting or stopping during this case's wall-clock window could
// produce, only a real leak can clear `TOLERANCE`.
//
// Finding 2 of PR #64's third review: `ROUNDS :: 25` made that "large enough"
// claim true only against a leak on EVERY round. Mutating `await_or_abandon`
// to skip `CancelSynchronousIo` on one call in four -- a partial regression,
// not the totally-unfixed original -- leaked 6 threads at 25 rounds, which
// `TOLERANCE :: 8` absorbed as noise: the case reported PASS over a real
// leak. The signal a partial leak produces scales with `ROUNDS`, the same
// way the fully-broken signal already did; `TOLERANCE` does not, because it
// bounds a handful of SIBLING threads whose count has nothing to do with how
// many rounds this case itself runs. `ROUNDS :: 100` is the fix: a 1-in-4
// leak now leaks roughly 25 threads, more than three times `TOLERANCE`,
// while a clean run's own delta does not move at all (the reviewer measured
// `TOLERANCE = 0` passing clean at both 25 and 200 rounds, so this is
// margin against sibling noise and not against the read path's own cost).
// Proven by mutation directly: with the skip-one-in-four change above and
// `ROUNDS :: 25`, this case passed; with the identical mutation and
// `ROUNDS :: 100`, it failed with "abandoning 100 reads left ~25 thread(s)
// behind" -- the report this case exists to make impossible to miss.
@(private)
ROUNDS :: 100

// However many of its own threads a sibling case in this package's suite
// might transiently hold across this case's window -- comfortably above
// that, and comfortably below what even a PARTIAL per-round leak reaches at
// `ROUNDS :: 100`.
@(private)
TOLERANCE :: 8

#assert(TOLERANCE < ROUNDS)

// Finding 1 of the PR #64 review: every abandoned read used to leak a live OS
// thread, its stack, its thread handle and the file handle `ReadFile` was
// blocked inside -- permanently, because nothing ever joined it. Measured
// with this exact technique (CreateToolhelp32Snapshot) against the unfixed
// code: eight abandoned reads took the thread count from 5 to 13, +1 per
// read, never reclaimed. `await_or_abandon` now asks
// `win32.CancelSynchronousIo` to unblock the thread's `ReadFile` before this
// case's bound is even reached again, and joins it -- so `ROUNDS` abandonments
// in a row, run one after another through the public `read_bounded` seam,
// must not leave the thread count more than `TOLERANCE` above where it
// started.
//
// Every server end stays open until after `after` is read: closing one early
// breaks its pipe and unblocks that round's ReadFile on its own, which would
// let the thread exit WITHOUT the fix this case exists to pin -- the leak
// only shows up while every pipe is still genuinely unanswered, the same way
// the single-read case above keeps its one server open for its whole body.
//
// N2 of PR #64's fourth review: at `ROUNDS`, a cancellation broken on EVERY
// round pays the full `CANCEL_BOUND_MS` penalty each time -- about 530
// seconds of the 600-second ceiling `scripts\common.ps1` gives the whole
// `child` package, an 11% margin that reports as "the child package did not
// finish within 600 seconds and was killed" rather than this case's own
// message, the identical defect Finding 1 of the same review closes for the
// worker. `LEAK_SWEEP_BUDGET` bails the round loop and not the detection: a
// healthy run pays `READ_SHORT_BOUND_MS` on every round regardless -- there
// is never a writer to race, so the bound is always what ends the read, not
// a fast cancellation -- measured at 31.8 s for the full `ROUNDS` sweep, and
// `LEAK_SWEEP_BUDGET` leaves it almost four times that before bailing. A
// regression bad enough to reach it anyway has already leaked several times
// `TOLERANCE` worth of threads by the time it does, so `after - baseline <=`
// `TOLERANCE` below still catches it -- this budget only stops the case from
// spending the package's own ceiling to say so.
@(private)
LEAK_SWEEP_BUDGET :: 120 * time.Second

@(test)
abandoning_a_read_repeatedly_does_not_accumulate_threads :: proc(t: ^testing.T) {
	baseline, counted := transcibr_thread_count()
	if !counted {
		return
	}

	servers: [ROUNDS]win32.HANDLE
	paths: [ROUNDS]string
	rounds_ok := 0
	started := time.tick_now()
	for round in 0 ..< ROUNDS {
		if !testing.expectf(
			t,
			time.tick_since(started) < LEAK_SWEEP_BUDGET,
			"abandoning reads is taking far longer than a healthy run ever should (stopped after %d of %d rounds) -- bailing out rather than risking the package's own ceiling",
			round,
			ROUNDS,
		) {
			break
		}

		tag := fmt.aprintf("leakcheck%d", round, allocator = context.allocator)
		path, server, ok := pipe_with_no_writer(t, tag, context.allocator)
		delete(tag, context.allocator)
		if !ok {
			break
		}
		servers[round] = server
		paths[round] = path
		rounds_ok += 1

		bytes, err := read_bounded(path, READ_SHORT_BOUND_MS, context.allocator)
		delete(bytes, context.allocator)
		testing.expect_value(t, err.fault, Read_Fault.Did_Not_Finish)
	}

	after, counted_after := transcibr_thread_count()

	for i in 0 ..< rounds_ok {
		win32.CloseHandle(servers[i])
		delete(paths[i], context.allocator)
	}

	if !counted_after {
		return
	}
	testing.expectf(
		t,
		after - baseline <= TOLERANCE,
		"abandoning %d reads left %d thread(s) behind that were never reclaimed (baseline %d, after %d, tolerance %d)",
		rounds_ok,
		after - baseline,
		baseline,
		after,
		TOLERANCE,
	)
}

@(test)
a_read_that_finishes_within_its_bound_returns_what_was_written :: proc(t: ^testing.T) {
	path := scratch_path(t, "readbound-ok", context.allocator)
	defer delete(path, context.allocator)
	defer os.remove(path)

	testing.expect(
		t,
		os.write_entire_file(path, transmute([]u8)string("said something")) == nil,
		"could not write the file this case reads back",
	)

	bytes, err := read_bounded(path, READ_TEST_RUN_BOUND_MS, context.allocator)
	defer delete(bytes, context.allocator)

	testing.expect_value(t, err.fault, Read_Fault.None)
	testing.expect_value(t, string(bytes), "said something")
}

@(test)
a_read_of_a_path_that_names_no_file_is_reported_rather_than_abandoned :: proc(t: ^testing.T) {
	path := scratch_path(t, "readbound-missing", context.allocator)
	defer delete(path, context.allocator)

	bytes, err := read_bounded(path, READ_TEST_RUN_BOUND_MS, context.allocator)
	defer delete(bytes, context.allocator)

	testing.expect_value(t, err.fault, Read_Fault.Unreadable)
	testing.expect(t, len(bytes) == 0, "a read of nothing at all handed back bytes")
}

@(test)
a_read_error_message_names_the_path_it_is_reported_against :: proc(t: ^testing.T) {
	err := Read_Error {
		fault = .Did_Not_Finish,
	}

	message := read_error_message(err, "C:/example/output.json", context.allocator)
	defer delete(message, context.allocator)

	testing.expect(
		t,
		strings.contains(message, "C:/example/output.json"),
		"a refusal did not name the path it was reported against",
	)
	testing.expect(
		t,
		strings.contains(message, "bound"),
		"a refusal for a read that timed out did not say so",
	)
}

// Finding 5 of the PR #64 review: every existing bound test overrides
// READ_BOUND_MS with a short stand-in, so the production constant's own
// value was never exercised by anything. This case reads with READ_BOUND_MS
// itself, against a file the size of the pessimistic worst case
// READ_BOUND_MS's own comment derives -- 8 MiB, several times denser than
// the committed fixture scaled to the corpus's longest Recording (168
// minutes) would actually produce. What is pinned is headroom: a real disk
// read of that much data finishes in a small fraction of the bound, so the
// thirty-second ceiling is margin against a stalled share and not against
// the read itself ever taking that long.
@(private)
WORST_CASE_ENGINE_JSON_BYTES :: 8 * 1024 * 1024

@(test)
a_worst_case_sized_engine_output_reads_well_within_its_bound :: proc(t: ^testing.T) {
	path := scratch_path(t, "readbound-worstcase", context.allocator)
	defer delete(path, context.allocator)
	defer os.remove(path)

	if !testkit.write_flood(
		t,
		path,
		WORST_CASE_ENGINE_JSON_BYTES,
		`{"text":" a worst-case-sized Engine segment, repeated"}` + "\n",
		context.allocator,
	) {
		return
	}

	started := time.tick_now()
	bytes, err := read_bounded(path, READ_BOUND_MS, context.allocator)
	elapsed := time.tick_since(started)
	defer delete(bytes, context.allocator)

	testing.expect_value(t, err.fault, Read_Fault.None)
	testing.expect(
		t,
		len(bytes) >= WORST_CASE_ENGINE_JSON_BYTES,
		"the flood was not read back whole",
	)
	testing.expectf(
		t,
		elapsed < time.Duration(READ_BOUND_MS) * time.Millisecond / 3,
		"reading %d bytes took %v, leaving less margin against READ_BOUND_MS than a real disk should",
		WORST_CASE_ENGINE_JSON_BYTES,
		elapsed,
	)
}

// Finding 2 of the PR #64 review: `read_fault_says`'s switch can gain a
// member grouped into its trailing empty arm -- `case .Unreadable, .None,
// .Mutant_Probe:` -- and still compile, still pass every existing case, and
// only fail at the assert inside `read_error_message`, in front of a Batch
// operator whose Recording is already failing. Every sibling vocabulary in
// this tree (`child.Fault`, `artifact.Fault`, `audio.Fault`,
// `transcript.Parse_Fault`) is walked by a test rather than trusted to that
// assert; this is Read_Fault's. `.Unreadable` is skipped by name because it
// is the other deliberately empty row -- its message comes from `os_error`
// and never from this table, the same way `.None` never has a sentence
// because it is not a failure.
@(test)
every_read_fault_renders_a_sentence_a_refusal_can_carry :: proc(t: ^testing.T) {
	for fault in Read_Fault {
		if fault == .None {
			continue
		}
		if fault == .Unreadable {
			continue
		}
		testing.expectf(
			t,
			len(read_fault_says(fault)) > 0,
			"%v has no sentence in read_fault_says",
			fault,
		)
	}
}
