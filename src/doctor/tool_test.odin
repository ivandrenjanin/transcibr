#+vet explicit-allocators
package doctor

import "core:fmt"
import "core:strings"
import "core:testing"
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
