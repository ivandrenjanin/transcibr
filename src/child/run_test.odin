#+vet explicit-allocators
package child

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(private)
CHILD_RUN_BOUND_MS :: i64(60_000)

// Far shorter than the child that has to outlive it, so a case that wants a
// stopped child measures the bound rather than the child's patience.
@(private)
CHILD_SHORT_BOUND_MS :: i64(500)

// Generous against the few seconds ADR-0020 measured for a real stop, so this
// only fires if the bound was never reached at all.
@(private)
FLOOD_STOP_SLACK :: 5 * time.Second

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
	signal := lonely_signal("boundedrun", context.allocator)
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
	return true
}

@(test)
a_run_stops_early_when_its_own_callback_asks_it_to :: proc(t: ^testing.T) {
	signal := lonely_signal("earlystop", context.allocator)
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

// Both halves are the claim (ADR-0020): the flood is drained, meaning the poll
// loop was handed back control rather than left spinning inside one drain, and
// the bound is still honoured within a few seconds of stop overhead rather
// than the 25-second waitfor this child would otherwise sit in.
@(test)
a_flooding_child_is_drained_and_still_stopped_at_its_bound :: proc(t: ^testing.T) {
	path := scratch_path(t, "flood", context.allocator)
	defer delete(path, context.allocator)
	defer os.remove(path)

	written := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&written)
	for strings.builder_len(written) < 1 << 20 {
		strings.write_string(&written, "a line this test has no reading for\r\n")
	}
	if !testing.expect(
		t,
		os.write_entire_file(path, written.buf[:]) == nil,
		"could not write the flood this case types",
	) {
		return
	}

	signal := lonely_signal("floodceiling", context.allocator)
	defer delete(signal, context.allocator)
	command := fmt.aprintf(
		"type %s 1>&2 & waitfor /t %d %s",
		path,
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
		elapsed < time.Duration(CHILD_SHORT_BOUND_MS) * time.Millisecond + FLOOD_STOP_SLACK,
		"the flood delayed the bound from being reached at all",
	)

	total := 0
	for chunk in collected.chunks {
		total += len(chunk)
	}
	testing.expect(t, total > 0, "the flood was never drained at all")
}
