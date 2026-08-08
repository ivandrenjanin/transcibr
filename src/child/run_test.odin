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

@(private)
CHILD_RUN_BOUND_MS :: i64(60_000)

// Far shorter than the child that has to outlive it, so a case that wants a
// stopped child measures the bound rather than the child's patience.
@(private)
CHILD_SHORT_BOUND_MS :: i64(500)

// Issue #170: CHILD_SHORT_BOUND_MS is too tight for a case that also has to
// observe real bytes crossing the pipe, because that needs the freshly
// spawned cmd.exe to actually get a CPU slice before the bound expires, and
// nothing here controls when the OS schedules it. Instrumented under
// deliberate contention (14 CPU-bound threads oversubscribing a 12-logical-
// processor machine): a poll's own `WaitForSingleObject(..., POLL_MS)`
// (run.odin) routinely overran its 250 ms floor by 30-60 ms, and in 31 of 40
// runs cmd.exe had written nothing to the pipe by the time two such polls
// pushed elapsed past 500 ms -- `drain_bounded` correctly reported "nothing
// waiting" both times; the pipe genuinely held nothing yet. That is a
// scheduling race in this test's own assumption, not a missed-read window in
// the drain (drain_bounded's own ceiling is pinned separately, by
// a_single_drain_stops_at_its_ceiling_even_with_a_steady_flood, below).
// CHILD_FLOOD_BOUND_MS gives roughly 5x the worst delay measured that way --
// still two orders of magnitude under LONGER_SECONDS -- so the case keeps
// proving the poll loop regains control despite a flood, without the
// child's own dispatch latency deciding the outcome.
@(private)
CHILD_FLOOD_BOUND_MS :: i64(3_000)

@(test)
a_child_that_exits_inside_its_bound_ran_to_completion :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	ending, reason, err := run_bounded(
		&group,
		CMD,
		{"/c", "exit 3"},
		CHILD_RUN_BOUND_MS,
		context.allocator,
	)
	testing.expect_value(t, err.fault, Fault.None)
	testing.expect_value(t, ending, Run.Finished)
	testing.expect_value(t, reason, Stop_Reason.None)
}

@(test)
a_child_that_outlives_its_bound_is_stopped_rather_than_waited_for :: proc(t: ^testing.T) {
	signal := testkit.lonely_signal("Child", "boundedrun", context.allocator)
	defer delete(signal, context.allocator)
	command := fmt.aprintf(
		"waitfor /t %d %s",
		LONGER_SECONDS,
		signal,
		allocator = context.allocator,
	)
	defer delete(command, context.allocator)

	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	ending, reason, err := run_bounded(
		&group,
		CMD,
		{"/c", command},
		CHILD_SHORT_BOUND_MS,
		context.allocator,
	)
	testing.expect_value(t, err.fault, Fault.None)
	testing.expect_value(t, ending, Run.Stopped)
	testing.expect_value(t, reason, Stop_Reason.Bound_Expired)
}

// Issue #208: `run_bounded` has exactly one return site for `.Not_Started`
// (the `refusal.fault != .None` branch above), so this is also the
// guard-side half of the cross-package A4 pairing `src/doctor`'s
// `model_load_verdict` relies on: `child.error_message` asserts
// `err.fault != .None`, and every `.Not_Started` a doctor
// probe can observe traces back to this exact call. The general
// `err.fault != .None` check below states that guarantee as the implication
// it is, rather than only the one concrete fault the value-equality check
// beside it already pins.
@(test)
a_child_that_will_not_start_is_reported_rather_than_asserted :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	ending, reason, err := run_bounded(
		&group,
		"transcibr-no-such-executable.exe",
		{},
		CHILD_RUN_BOUND_MS,
		context.allocator,
	)
	testing.expect_value(t, ending, Run.Not_Started)
	testing.expect_value(t, reason, Stop_Reason.None)
	testing.expect_value(t, err.fault, Fault.Not_Started)
	if ending == .Not_Started {
		testing.expect(
			t,
			err.fault != .None,
			"a Not_Started run carried no fault, which child.error_message's callers rely on",
		)
	}
}

@(private)
Collected :: struct {
	chunks: [dynamic]string,
	ended:  bool,
	polls:  int,
}

@(private)
collect_chunk :: proc(chunk: string, elapsed_ns: i64, user: rawptr) {
	assert(user != nil, "there is nowhere to collect a chunk into")
	assert(elapsed_ns > 0, "a chunk arrived before the child's clock could have started")

	collected := (^Collected)(user)
	append(&collected.chunks, strings.clone(chunk, context.allocator))
}

@(private)
mark_end :: proc(elapsed_ns: i64, user: rawptr) {
	assert(user != nil, "there is nowhere to mark an end")
	assert(elapsed_ns > 0, "an end arrived before the child's clock could have started")

	collected := (^Collected)(user)
	collected.ended = true
}

@(private)
@(require_results)
count_poll :: proc(elapsed_ns: i64, user: rawptr) -> bool {
	assert(user != nil, "there is nowhere to count a poll")

	collected := (^Collected)(user)
	collected.polls += 1
	return false
}

@(private)
free_collected :: proc(collected: ^Collected, allocator: mem.Allocator) {
	assert(collected != nil, "there is no collected state here to free")

	for chunk in collected.chunks {
		delete(chunk, allocator)
	}
	delete(collected.chunks)
}

@(test)
a_run_hands_every_chunk_and_the_end_of_stream_to_its_callbacks :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	collected := Collected {
		chunks = make([dynamic]string, context.allocator),
	}
	defer free_collected(&collected, context.allocator)

	ending, reason, err := run_bounded(
		&group,
		CMD,
		{"/c", "echo said something 1>&2"},
		CHILD_RUN_BOUND_MS,
		context.allocator,
		Run_Callbacks {
			user = &collected,
			on_chunk = collect_chunk,
			on_end = mark_end,
			on_poll = count_poll,
		},
	)
	testing.expect_value(t, err.fault, Fault.None)
	testing.expect_value(t, ending, Run.Finished)
	testing.expect_value(t, reason, Stop_Reason.None)

	testing.expect(
		t,
		len(collected.chunks) > 0,
		"the run finished without handing over anything it said",
	)
	testing.expect(t, collected.ended, "the run finished without ever reaching end of stream")
	testing.expect(t, collected.polls > 0, "the run finished without ever being polled")

	said := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&said)
	for chunk in collected.chunks {
		strings.write_string(&said, chunk)
	}
	testing.expect(
		t,
		strings.contains(strings.to_string(said), "said something"),
		"the chunks handed to the callback do not add up to what the child said",
	)
}

@(private)
@(require_results)
always_stop :: proc(elapsed_ns: i64, user: rawptr) -> bool {
	assert(elapsed_ns > 0, "a poll arrived before the child's clock could have started")

	return true
}

@(test)
a_run_stops_early_when_its_own_callback_asks_it_to :: proc(t: ^testing.T) {
	signal := testkit.lonely_signal("Child", "earlystop", context.allocator)
	defer delete(signal, context.allocator)
	command := fmt.aprintf(
		"waitfor /t %d %s",
		LONGER_SECONDS,
		signal,
		allocator = context.allocator,
	)
	defer delete(command, context.allocator)

	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	started := time.tick_now()
	ending, reason, err := run_bounded(
		&group,
		CMD,
		{"/c", command},
		CHILD_RUN_BOUND_MS,
		context.allocator,
		Run_Callbacks{on_poll = always_stop},
	)
	elapsed := time.tick_since(started)

	testing.expect_value(t, err.fault, Fault.None)
	testing.expect_value(t, ending, Run.Stopped)
	testing.expect_value(t, reason, Stop_Reason.Poll_Asked)
	testing.expect(
		t,
		elapsed < time.Duration(CHILD_RUN_BOUND_MS) * time.Millisecond,
		"the callback's own answer was ignored and only the bound stopped the run",
	)
}

// Writes a file of at least `minimum_bytes` and a command that types it to
// standard error before waiting -- so the child outlives whatever the flood
// alone takes to drain. The caller frees both strings; an empty command means
// the file could not be written and the case should return early.
@(private)
@(require_results)
flood_command :: proc(
	t: ^testing.T,
	name: string,
	minimum_bytes: int,
	allocator: mem.Allocator,
) -> (
	path: string,
	command: string,
) {
	assert(minimum_bytes > 0, "a flood of nothing at all floods nothing")

	path = scratch_path(t, name, allocator)
	if !testkit.write_flood(
		t,
		path,
		minimum_bytes,
		"a line this test has no reading for\r\n",
		allocator,
	) {
		return path, ""
	}

	signal := testkit.lonely_signal("Child", name, allocator)
	defer delete(signal, allocator)
	command = testkit.flood_type_command(path, LONGER_SECONDS, signal, allocator)
	return path, command
}

// The poll loop regains control despite a flood, so the bound is reached
// within a few seconds of stop overhead rather than the 25-second waitfor this
// child would otherwise sit in -- both halves of that are the claim. It does
// NOT discriminate whether a single drain has a ceiling at all: mutating
// MAX_DRAIN_BYTES away leaves this green, because an unbounded drain still
// runs out of flood to read and hands control back the same way. Only
// a_single_drain_stops_at_its_ceiling_even_with_a_steady_flood, below, pins
// the ceiling itself.
@(test)
a_flood_on_the_diagnostic_stream_does_not_stop_the_bound_from_being_reached :: proc(
	t: ^testing.T,
) {
	path, command := flood_command(t, "flood", 1 << 20, context.allocator)
	defer delete(path, context.allocator)
	defer os.remove(path)
	defer delete(command, context.allocator)
	if len(command) == 0 {
		return
	}

	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	collected := Collected {
		chunks = make([dynamic]string, context.allocator),
	}
	defer free_collected(&collected, context.allocator)

	started := time.tick_now()
	ending, reason, err := run_bounded(
		&group,
		CMD,
		{"/c", command},
		CHILD_FLOOD_BOUND_MS,
		context.allocator,
		Run_Callbacks{user = &collected, on_chunk = collect_chunk},
	)
	elapsed := time.tick_since(started)

	testing.expect_value(t, err.fault, Fault.None)
	testing.expect_value(t, ending, Run.Stopped)
	testing.expect_value(t, reason, Stop_Reason.Bound_Expired)
	testing.expect(
		t,
		elapsed <
		time.Duration(CHILD_FLOOD_BOUND_MS) * time.Millisecond + testkit.FLOOD_STOP_SLACK,
		"the flood delayed the bound from being reached at all",
	)

	total := 0
	for chunk in collected.chunks {
		total += len(chunk)
	}
	testing.expect(t, total > 0, "the flood was never drained at all")
}

// Builds a buffer at least `minimum_bytes` long by repeating `filler_line`, so
// a pipe filled from it in one write is provably still holding data once a
// drain has taken its ceiling's worth. The caller frees the result.
@(private)
@(require_results)
build_flood_bytes :: proc(
	minimum_bytes: int,
	filler_line: string,
	allocator: mem.Allocator,
) -> []u8 {
	assert(minimum_bytes > 0, "a flood of nothing at all floods nothing")
	assert(len(filler_line) > 0, "a flood built from an empty line floods nothing per line")

	built := strings.builder_make(allocator)
	for strings.builder_len(built) < minimum_bytes {
		strings.write_string(&built, filler_line)
	}
	return built.buf[:]
}

// `capacity` sizes the pipe's own kernel buffer -- not a hint here, because the
// whole flood is written to it before anything ever reads it back (below), and
// a write past that capacity with no reader running would block forever. The
// pipe's read end is private; nothing spawned here ever needs to inherit it.
@(private)
@(require_results)
open_flood_pipe :: proc(
	capacity: win32.DWORD,
) -> (
	read: win32.HANDLE,
	write: win32.HANDLE,
	ok: bool,
) {
	assert(capacity > 0, "a pipe opened with no capacity at all cannot hold a flood")

	ok = bool(win32.CreatePipe(&read, &write, nil, capacity))
	return read, write, ok
}

// Whether `bytes` fits the plain DWORD `CreatePipe` takes as a capacity:
// pulled out on its own so the boundary can be proven false -- issue #98's
// 4*(1<<30) case -- without an `int` -> `win32.DWORD` narrowing wrapping
// silently past it (T1: the width is meaning at this Win32 boundary). A
// truncating `win32.DWORD(bytes)` here previously turned a too-large capacity
// into a too-small one instead of a refusal, which is what let
// `a_single_drain_stops_at_its_ceiling_even_with_a_steady_flood` go red on
// pipe setup rather than on the ceiling it exists to prove.
@(private)
@(require_results)
capacity_expressible :: proc(bytes: int) -> bool {
	assert(bytes > 0, "a pipe capacity of zero or fewer bytes was never a capacity")
	return bytes <= int(max(win32.DWORD))
}

// Mirrors `a_bound_of_infinite_itself_is_not_expressible_to_wait_for_single_object`
// in `src/child/read_test.odin`, the boundary test for `bound_expressible`
// that `capacity_expressible`'s own doc comment claims as its precedent.
// `capacity_expressible` admits `max(win32.DWORD)` itself -- unlike
// `bound_expressible`, nothing here is bit-identical to `win32.INFINITE` --
// so the true/false split sits one byte later than the read-bound version.
@(test)
a_capacity_one_past_the_dword_maximum_is_not_expressible_to_create_pipe :: proc(t: ^testing.T) {
	testing.expect(
		t,
		capacity_expressible(int(max(win32.DWORD)) - 1),
		"a capacity one below the DWORD maximum was refused as inexpressible",
	)
	testing.expect(
		t,
		capacity_expressible(int(max(win32.DWORD))),
		"a capacity bit-identical to the DWORD maximum was refused as inexpressible",
	)
	testing.expect(
		t,
		!capacity_expressible(int(max(win32.DWORD)) + 1),
		"a capacity past the DWORD maximum was accepted as an expressible pipe capacity",
	)
}

// Opens a pipe sized for the whole of `flood_bytes` and writes it all in one
// call before handing back the read end, so a caller's drain finds the pipe
// already holding the flood rather than racing anything to fill it. `ok` is
// false on either failure, and the read end is already closed by the time it
// is: there is nothing left for the caller to clean up.
@(private)
@(require_results)
fill_flood_pipe :: proc(t: ^testing.T, flood_bytes: []u8) -> (read: win32.HANDLE, ok: bool) {
	assert(t != nil, "there is no test here to report a refusal through")
	assert(len(flood_bytes) > 0, "a pipe filled with nothing at all floods nothing")

	write: win32.HANDLE
	opened: bool
	capacity_bytes := len(flood_bytes) + DRAIN_BYTES
	if !testing.expectf(
		t,
		capacity_expressible(capacity_bytes),
		"a flood pipe capacity of %d bytes does not fit in a DWORD (max %d)",
		capacity_bytes,
		max(win32.DWORD),
	) {
		return read, false
	}
	capacity := win32.DWORD(capacity_bytes)
	read, write, opened = open_flood_pipe(capacity)
	if !testing.expect(
		t,
		opened,
		"could not open a pipe large enough to hold the whole flood at once",
	) {
		return read, false
	}

	written: win32.DWORD
	filled := win32.WriteFile(
		write,
		raw_data(flood_bytes),
		win32.DWORD(len(flood_bytes)),
		&written,
		nil,
	)
	win32.CloseHandle(write)
	if !testing.expectf(
		t,
		bool(filled) && int(written) == len(flood_bytes),
		"could not fill the pipe with the whole flood before draining it (ok %v, wrote %d of %d bytes)",
		filled,
		written,
		len(flood_bytes),
	) {
		win32.CloseHandle(read)
		return read, false
	}
	return read, true
}

// The property under test -- one drain stops at its ceiling and leaves the
// rest waiting in the pipe -- only needs the pipe to be non-empty when the
// ceiling is reached; it does not need a live child racing this drain to keep
// it that way. Filling a pipe sized for the whole flood in a single write,
// before drain_bounded ever runs, makes the pipe non-empty at the ceiling by
// construction rather than by scheduling luck: several times MAX_DRAIN_BYTES,
// so the drain's only way out is the ceiling and not running out of flood to
// read.
//
// `expected_stop` mirrors drain_bounded's own loop exactly (src/child/run.odin
// -- `for taken < MAX_DRAIN_BYTES`, reading DRAIN_BYTES at a time) rather than
// naming MAX_DRAIN_BYTES a second time as a tolerance window: the loop can
// only ever stop on a DRAIN_BYTES boundary, so the one correct `total` is the
// smallest multiple of DRAIN_BYTES at or above MAX_DRAIN_BYTES, and nothing
// else. That is what pins the VALUE the ceiling holds, not merely that a
// ceiling exists -- issue #98. The canonical proof that this test still holds
// that relationship is mutating `drain_bounded`'s own loop bound in
// src/child/run.odin (an 8x mutation turns `total` far past `expected_stop`);
// a 1<<30 mutation of
// MAX_DRAIN_BYTES itself is no longer the recipe, since capacity_expressible
// above now refuses that capacity outright instead of an int -> DWORD wrap
// manufacturing a false red.
@(test)
a_single_drain_stops_at_its_ceiling_even_with_a_steady_flood :: proc(t: ^testing.T) {
	flood_bytes := build_flood_bytes(
		4 * MAX_DRAIN_BYTES,
		"a line this test has no reading for\r\n",
		context.allocator,
	)
	defer delete(flood_bytes, context.allocator)

	read, ok := fill_flood_pipe(t, flood_bytes)
	if !ok {
		return
	}

	c := Child {
		diagnostics = read,
	}
	defer close(&c)

	collected := Collected {
		chunks = make([dynamic]string, context.allocator),
	}
	defer free_collected(&collected, context.allocator)

	readable := drain_bounded(
		&c,
		time.tick_now(),
		Run_Callbacks{user = &collected, on_chunk = collect_chunk},
	)

	total := 0
	for chunk in collected.chunks {
		total += len(chunk)
	}

	expected_stop := ((MAX_DRAIN_BYTES + DRAIN_BYTES - 1) / DRAIN_BYTES) * DRAIN_BYTES

	testing.expect(t, readable, "a drain that hit its ceiling reported the pipe as unreadable")
	testing.expectf(
		t,
		total == expected_stop,
		"one drain took %d bytes; its %d-byte ceiling and %d-byte reads only ever stop it at %d",
		total,
		MAX_DRAIN_BYTES,
		DRAIN_BYTES,
		expected_stop,
	)
	testing.expectf(
		t,
		total < len(flood_bytes),
		"one drain took the whole flood (%d of %d bytes) instead of stopping at its ceiling with data still waiting in the pipe",
		total,
		len(flood_bytes),
	)
}

@(private)
Exit_Observation :: struct {
	code:   u32,
	called: int,
}

@(private)
observed_exit :: proc(code: u32, user: rawptr) {
	assert(user != nil, "there is no observation here to record an exit status into")

	observation := (^Exit_Observation)(user)
	observation.code = code
	observation.called += 1
}

// `Run.Finished` says only that the child stopped on its own; a child that
// aborted and one that succeeded reach it identically, which is exactly the
// distinction issue #13's Model load probe has to make. The status arrives
// through a callback rather than through run_bounded's own results so that
// every caller that never asked for it pays nothing.
@(test)
a_finished_run_reports_the_status_the_child_actually_exited_with :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	observation: Exit_Observation
	ending, reason, err := run_bounded(
		&group,
		CMD,
		{"/c", "exit 3"},
		CHILD_RUN_BOUND_MS,
		context.allocator,
		Run_Callbacks{user = &observation, on_exit = observed_exit},
	)
	testing.expect_value(t, err.fault, Fault.None)
	testing.expect_value(t, ending, Run.Finished)
	testing.expect_value(t, reason, Stop_Reason.None)
	testing.expect_value(t, observation.called, 1)
	testing.expect_value(t, observation.code, u32(3))
}

@(test)
a_child_that_exits_cleanly_reports_a_zero_status :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	observation: Exit_Observation
	ending, _, err := run_bounded(
		&group,
		CMD,
		{"/c", "exit 0"},
		CHILD_RUN_BOUND_MS,
		context.allocator,
		Run_Callbacks{user = &observation, on_exit = observed_exit},
	)
	testing.expect_value(t, err.fault, Fault.None)
	testing.expect_value(t, ending, Run.Finished)
	testing.expect_value(t, observation.called, 1)
	testing.expect_value(t, observation.code, u32(0))
}

// A halted child's status is this program's own kill and not the child's
// answer, so there is nothing here worth reporting and the caller is left
// able to tell "it never answered" from "it answered zero".
@(test)
a_run_stopped_at_its_bound_reports_no_exit_status_at_all :: proc(t: ^testing.T) {
	signal := testkit.lonely_signal("Child", "exitstatusbound", context.allocator)
	defer delete(signal, context.allocator)
	command := fmt.aprintf(
		"waitfor /t %d %s",
		LONGER_SECONDS,
		signal,
		allocator = context.allocator,
	)
	defer delete(command, context.allocator)

	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	observation: Exit_Observation
	ending, reason, _ := run_bounded(
		&group,
		CMD,
		{"/c", command},
		CHILD_SHORT_BOUND_MS,
		context.allocator,
		Run_Callbacks{user = &observation, on_exit = observed_exit},
	)
	testing.expect_value(t, ending, Run.Stopped)
	testing.expect_value(t, reason, Stop_Reason.Bound_Expired)
	testing.expect_value(t, observation.called, 0)
}
