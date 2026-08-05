#+vet explicit-allocators
package child

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"
import "core:testing"
import "core:time"
import "transcibr:testkit"

// Far shorter than READ_BOUND_MS, so a case that wants the ceiling reached
// measures the bound rather than a real caller's patience.
@(private)
READ_SHORT_BOUND_MS :: i64(300)

// Windows' default timer resolution quantizes both `time.sleep` calls this
// case makes: the poll loop's own sleeps and the granularity `tick_since`
// is read against. See child/run_test.odin's `spin_for` comment for the
// figures this was measured against; the margin here is generous rather than
// tight because nothing in this case pins READ_POLL itself.
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

// Finding 1 of the PR #64 review: every abandoned read used to leak a live OS
// thread, its stack, its thread handle and the file handle `ReadFile` was
// blocked inside -- permanently, because nothing ever joined it. Measured
// with this exact technique (CreateToolhelp32Snapshot) against the unfixed
// code: eight abandoned reads took the thread count from 5 to 13, +1 per
// read, never reclaimed. `await_or_abandon` now asks
// `win32.CancelSynchronousIo` to unblock the thread's `ReadFile` before this
// case's bound is even reached again, and joins it -- so five abandonments in
// a row, run one after another through the public `read_bounded` seam, must
// not leave the thread count any higher than where it started.
//
// Every server end stays open until after `after` is read: closing one early
// breaks its pipe and unblocks that round's ReadFile on its own, which would
// let the thread exit WITHOUT the fix this case exists to pin -- the leak
// only shows up while every pipe is still genuinely unanswered, the same way
// the single-read case above keeps its one server open for its whole body.
@(test)
abandoning_a_read_repeatedly_does_not_accumulate_threads :: proc(t: ^testing.T) {
	baseline, counted := transcibr_thread_count()
	if !counted {
		return
	}

	ROUNDS :: 5
	servers: [ROUNDS]win32.HANDLE
	paths: [ROUNDS]string
	rounds_ok := 0
	for round in 0 ..< ROUNDS {
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
		after <= baseline,
		"abandoning %d reads left %d thread(s) behind that were never reclaimed (baseline %d, after %d)",
		rounds_ok,
		after - baseline,
		baseline,
		after,
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
