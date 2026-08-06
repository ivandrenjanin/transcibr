#+vet explicit-allocators
package doctor

import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "transcibr:child"
import "transcibr:testkit"

@(private)
CMD :: "cmd.exe"

@(private)
@(require_results)
open_group :: proc(t: ^testing.T) -> (group: child.Job_Object, ok: bool) {
	opened, err := child.job_object_open()
	if !testing.expectf(t, err.fault == .None, "no job object: %v", err.fault) {
		return {}, false
	}
	return opened, true
}

@(test)
a_probe_captures_what_a_child_writes_to_its_diagnostic_stream :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	probe := probe_executable(
		&group,
		CMD,
		{"/c", "echo hello-from-the-probe 1>&2"},
		context.allocator,
	)
	defer delete(probe.captured, context.allocator)

	testing.expect_value(t, probe.run, child.Run.Finished)
	testing.expect(
		t,
		strings.contains(probe.captured, "hello-from-the-probe"),
		"the probe's own captured stream is missing what the child wrote",
	)
}

@(test)
a_probe_of_an_executable_that_will_not_start_is_reported_rather_than_asserted :: proc(
	t: ^testing.T,
) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	probe := probe_executable(&group, "there-is-no-such-executable.exe", {}, context.allocator)
	defer delete(probe.captured, context.allocator)

	testing.expect_value(t, probe.run, child.Run.Not_Started)
	testing.expect_value(t, len(probe.captured), 0)
	testing.expect(t, probe.child.fault != .None, "a child that never started named no reason")
}

// Proves the probe itself refuses a flood rather than growing its builder
// without bound: the flood file is sized past MAX_PROBE_CAPTURE_BYTES, typed
// to a signal nobody sends so the child would otherwise outlive the probe's
// own bound, exactly as testkit's own doc comment describes. Mutation check
// per the ticket's own acceptance criterion: removing the ceiling comparison
// in captured_chunk (src/doctor/tool.odin) leaves `probe.overflowed` always
// false and turns this red, because the flood would then finish draining
// inside the probe's bound with no refusal to report.
//
// The elapsed-time assertion at the end pins the VALUE `capture_overflow_poll`'s
// wiring buys, not merely that the probe was eventually stopped: removing
// `on_poll = capture_overflow_poll` from the `Run_Callbacks` literal in
// `probe_executable` (src/doctor/tool.odin) leaves the child running for the
// rest of `bound_ms` even though its verdict was already decided, and this
// assertion goes red on the extra wall time (issue #98's standard: pin the
// value a ceiling holds, not merely that a ceiling exists).
@(test)
a_probe_refuses_a_flood_past_its_capture_ceiling_rather_than_growing_without_bound :: proc(
	t: ^testing.T,
) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := testkit.made_scratch_cache(t, "doctor", "probeflood", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	flood := fmt.aprintf("%s\\flood.txt", cache, allocator = context.allocator)
	defer delete(flood, context.allocator)
	if !testkit.write_flood(
		t,
		flood,
		MAX_PROBE_CAPTURE_BYTES + child.MAX_DRAIN_BYTES,
		"a line this probe has no reading for\r\n",
		context.allocator,
	) {
		return
	}

	signal := testkit.lonely_signal("Doctor", "probeflood", context.allocator)
	defer delete(signal, context.allocator)
	command := testkit.flood_type_command(flood, 25, signal, context.allocator)
	defer delete(command, context.allocator)

	bound_ms := i64(30_000)
	started := time.tick_now()
	probe := probe_executable(&group, CMD, {"/c", command}, context.allocator, bound_ms)
	elapsed := time.tick_since(started)
	defer delete(probe.captured, context.allocator)

	testing.expect(
		t,
		probe.overflowed,
		"a flood well past the probe's capture ceiling was not reported as an overflow",
	)
	testing.expect(
		t,
		len(probe.captured) <= MAX_PROBE_CAPTURE_BYTES,
		"a probe's capture grew past its own ceiling",
	)
	testing.expect(
		t,
		probe.run == .Stopped || probe.run == .Unstoppable,
		"an overflowing probe was not stopped once its verdict could no longer change",
	)
	testing.expect(
		t,
		elapsed < time.Duration(bound_ms) * time.Millisecond - testkit.FLOOD_STOP_SLACK,
		"an overflowing probe was not stopped early -- it ran out its full bound",
	)
}

@(test)
a_probe_that_outlives_its_bound_is_stopped_rather_than_waited_for :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	signal := testkit.lonely_signal("Doctor", "boundedprobe", context.allocator)
	defer delete(signal, context.allocator)
	command := fmt.aprintf("waitfor /t 60 %s", signal, allocator = context.allocator)
	defer delete(command, context.allocator)

	probe := probe_executable(&group, CMD, {"/c", command}, context.allocator, 500)
	defer delete(probe.captured, context.allocator)

	testing.expect(
		t,
		probe.run == .Stopped || probe.run == .Unstoppable,
		"an executable well past its bound was neither stopped nor reported unstoppable",
	)
}
