#+vet explicit-allocators
package child

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "transcibr:testkit"

@(private)
CHILD_RUN_BOUND_MS :: i64(60_000)

// Far shorter than the child that has to outlive it, so a case that wants a
// stopped child measures the bound rather than the child's patience.
@(private)
CHILD_SHORT_BOUND_MS :: i64(500)

// Not measuring anything a test asserts on, so ordinary Sleep quantization is
// fine here: this only has to be generous enough that `cmd.exe` has actually
// started running `type` before the first drain looks at the pipe.
@(private)
CHILD_STARTUP_HEAD_START :: 100 * time.Millisecond

// Gives the spawned `type` a head start on filling the pipe, so the first
// drain a caller runs afterward finds a steady trickle waiting rather than
// reading the pipe as momentarily empty and returning before a ceiling is
// ever reached.
@(private)
let_the_flood_start_filling_the_pipe :: proc() {
	time.sleep(CHILD_STARTUP_HEAD_START)
}

@(test)
a_child_that_exits_inside_its_bound_ran_to_completion :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	ending, err := run_bounded(
		&group,
		CMD,
		{"/c", "exit 3"},
		CHILD_RUN_BOUND_MS,
		context.allocator,
	)
	testing.expect_value(t, err.fault, Fault.None)
	testing.expect_value(t, ending, Run.Finished)
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

	ending, err := run_bounded(
		&group,
		CMD,
		{"/c", command},
		CHILD_SHORT_BOUND_MS,
		context.allocator,
	)
	testing.expect_value(t, err.fault, Fault.None)
	testing.expect_value(t, ending, Run.Stopped)
}

@(test)
a_child_that_will_not_start_is_reported_rather_than_asserted :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer job_object_close(&group)
	if !ok {
		return
	}

	ending, err := run_bounded(
		&group,
		"transcibr-no-such-executable.exe",
		{},
		CHILD_RUN_BOUND_MS,
		context.allocator,
	)
	testing.expect_value(t, ending, Run.Not_Started)
	testing.expect_value(t, err.fault, Fault.Not_Started)
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

	ending, err := run_bounded(
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
	ending, err := run_bounded(
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
	ending, err := run_bounded(
		&group,
		CMD,
		{"/c", command},
		CHILD_SHORT_BOUND_MS,
		context.allocator,
		Run_Callbacks{user = &collected, on_chunk = collect_chunk},
	)
	elapsed := time.tick_since(started)

	testing.expect_value(t, err.fault, Fault.None)
	testing.expect_value(t, ending, Run.Stopped)
	testing.expect(
		t,
		elapsed <
		time.Duration(CHILD_SHORT_BOUND_MS) * time.Millisecond + testkit.FLOOD_STOP_SLACK,
		"the flood delayed the bound from being reached at all",
	)

	total := 0
	for chunk in collected.chunks {
		total += len(chunk)
	}
	testing.expect(t, total > 0, "the flood was never drained at all")
}

// Sleep is quantized to Windows' default timer resolution -- measured in this
// suite at 3.70-3.79s for 256 chunks nominally costing 512ms at 2ms each,
// 7.4x, which is the 15.625ms granularity divided by 2ms -- unless something
// else on the machine has already lowered it with timeBeginPeriod, in which
// case the nominal 2ms holds instead and the margin this delay exists to give
// the flooding child shrinks by the same 7.4x with it. A busy wait reads the
// same monotonic clock this suite times its bounds with, rather than asking
// the scheduler for a wake-up, so the two-millisecond gap holds regardless of
// what else on the machine touches the system timer.
@(private)
spin_for :: proc(minimum: time.Duration) {
	assert(minimum > 0, "a spin with no minimum duration would spin forever or not at all")

	started := time.tick_now()
	for time.tick_since(started) < minimum {}
}

// A quarter of what MAX_DRAIN_BYTES/DRAIN_BYTES iterations would need to add
// up to the ceiling at all -- see slow_collect_chunk below for what it holds
// the pipe open for.
@(private)
SLOW_CHUNK_DELAY :: 2 * time.Millisecond

// A pipe holds at most DIAGNOSTIC_PIPE_BYTES (64 KiB), so nothing a real child
// writes can hand a single, unthrottled read loop much more than that at once
// -- measured, `type` on a multi-megabyte file into an unread pipe still
// leaves one drain reading only the pipe's own capacity, because the child
// cannot refill it faster than a tight loop empties it. The ceiling exists for
// the case a real Engine's diagnostic output resembles instead: many small
// writes arriving steadily, which is what a per-chunk delay on the CONSUMER
// side reproduces here -- it gives the child time to keep the pipe topped up
// between reads, so a single drain sees a steady trickle for as long as the
// flood file lasts. Deliberately several times MAX_DRAIN_BYTES, so the loop's
// only way out is the ceiling and not running out of flood to read.
@(private)
slow_collect_chunk :: proc(chunk: string, elapsed_ns: i64, user: rawptr) {
	collect_chunk(chunk, elapsed_ns, user)
	spin_for(SLOW_CHUNK_DELAY)
}

@(test)
a_single_drain_stops_at_its_ceiling_even_with_a_steady_flood :: proc(t: ^testing.T) {
	path, command := flood_command(t, "onedrain", 4 * MAX_DRAIN_BYTES, context.allocator)
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

	c, err := start(&group, CMD, {"/c", command}, context.allocator)
	defer close(&c)
	if !testing.expectf(t, err.fault == .None, "the child did not start: %v", err.fault) {
		return
	}

	let_the_flood_start_filling_the_pipe()

	collected := Collected {
		chunks = make([dynamic]string, context.allocator),
	}
	defer free_collected(&collected, context.allocator)

	readable := drain_bounded(
		&c,
		time.tick_now(),
		Run_Callbacks{user = &collected, on_chunk = slow_collect_chunk},
	)

	total := 0
	for chunk in collected.chunks {
		total += len(chunk)
	}

	testing.expect(t, readable, "a drain that hit its ceiling reported the pipe as unreadable")
	testing.expectf(
		t,
		total <= MAX_DRAIN_BYTES + DRAIN_BYTES,
		"one drain took %d bytes, more than its %d-byte ceiling permits even though more was waiting",
		total,
		MAX_DRAIN_BYTES,
	)
	testing.expectf(
		t,
		total >= MAX_DRAIN_BYTES,
		"one drain stopped at %d bytes, well short of its %d-byte ceiling, so the flood ran out rather than the ceiling being reached",
		total,
		MAX_DRAIN_BYTES,
	)
}
