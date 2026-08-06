#+vet explicit-allocators
package doctor

import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "transcibr:child"

// Proves the caller-side refusal without spawning a flooding child:
// `model_load_verdict` already takes a caller-constructed `Probe`, so an
// overflowed one is a zero-child, zero-second case. Mutation check per the
// ticket's own acceptance criterion: deleting the `if probe.overflowed`
// guard in `model_load_verdict` (src/doctor/model_probe.odin) leaves this
// red, because the overflowed Probe would then fall through to
// `switch probe.run`, which this Probe leaves at its zero value
// `.Not_Started` and reports a different, wrong message.
@(test)
an_overflowed_probe_is_refused_by_the_model_verdict_rather_than_judged_on_its_capture :: proc(
	t: ^testing.T,
) {
	probe := Probe {
		overflowed = true,
	}
	check := model_load_verdict(probe, "model.bin", context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, false)
	testing.expect(
		t,
		strings.contains(check.reason, "MAX_PROBE_CAPTURE_BYTES"),
		"an overflow refusal did not name its own ceiling",
	)
}

// Named per member rather than recomputed from the same formula
// `model_probe_wav_settled` itself uses -- the shape `child\read_test.odin`'s
// own fault tests use, so this cannot agree with a wrong implementation of
// that formula's shape just by sharing it (issue #125's round-1 review,
// finding 2). The build-time guard against a member silently defaulting to
// settled-for-removal lives in `model_probe_wav_settled`'s own exhaustive
// switch, not here -- issue #33's compile guard applies to a switch that
// names every member itself exactly as it does to an enumerated array.
@(test)
a_child_confirmed_not_running_leaves_its_wav_settled_for_removal :: proc(t: ^testing.T) {
	testing.expect(
		t,
		model_probe_wav_settled(child.Run.Not_Started),
		"a child that never started was not settled for removal",
	)
	testing.expect(
		t,
		model_probe_wav_settled(child.Run.Finished),
		"a child that finished was not settled for removal",
	)
	testing.expect(
		t,
		model_probe_wav_settled(child.Run.Stopped),
		"a child confirmed stopped was not settled for removal",
	)
}

@(test)
an_unstoppable_child_never_leaves_its_wav_settled_for_removal :: proc(t: ^testing.T) {
	testing.expect(
		t,
		!model_probe_wav_settled(child.Run.Unstoppable),
		"an unstoppable child's wav was settled for removal, which would race a child that might still hold it open",
	)
}

// `model_probe_wav_settled` on its own only ever proves the BOOLEAN is
// right -- nothing above reaches the file-system effect that boolean is
// supposed to gate. `remove_probe_wav_if_settled` is the exact code
// `model_load_check` calls with that boolean, so handing it a real,
// disk-backed wav and a genuine `settled` value proves the removal itself,
// not only the predicate that decides it (issue #125's round-1 review,
// finding 1).
@(test)
a_settled_probe_wav_is_actually_removed_from_disk :: proc(t: ^testing.T) {
	f, unopenable := os.create_temp_file("", "transcibr-doctor-probe-settled-*.wav")
	testing.expect(t, unopenable == nil, "could not open a scratch wav to remove")
	if unopenable != nil {
		return
	}
	wav := strings.clone(os.name(f), context.allocator)
	defer delete(wav, context.allocator)
	testing.expect(t, os.close(f) == nil, "could not close the scratch wav fixture")

	remove_probe_wav_if_settled(wav, true, os_remove_wav)
	testing.expect(t, !os.exists(wav), "a settled probe wav was left on disk")
}

@(test)
an_unsettled_probe_wav_is_left_on_disk :: proc(t: ^testing.T) {
	f, unopenable := os.create_temp_file("", "transcibr-doctor-probe-unsettled-*.wav")
	testing.expect(t, unopenable == nil, "could not open a scratch wav to leave alone")
	if unopenable != nil {
		return
	}
	wav := strings.clone(os.name(f), context.allocator)
	defer delete(wav, context.allocator)
	defer os.remove(wav)
	testing.expect(t, os.close(f) == nil, "could not close the scratch wav fixture")

	remove_probe_wav_if_settled(wav, false, os_remove_wav)
	testing.expect(
		t,
		os.exists(wav),
		"an unsettled probe wav was removed, which would race a child that might still hold it open",
	)
}

// `remove_probe_wav_if_settled` on its own only proves the wiring between a
// `settled` value and a removal call -- nothing above proves
// `model_load_check` itself passes that call through rather than removing
// `wav` some other way. `model_load_check_using`'s `remove` parameter is
// `model_load_check`'s only route to removing its scratch wav; passing a
// counting spy through it, around a real, fast-exiting engine stand-in,
// reads the ordering off the call site directly. The count lives behind
// `context.user_ptr` rather than a package variable, which would race every
// other test in this package calling `model_load_check` concurrently
// (`test.ps1` runs 12 threads by default) (issue #125's round-1 review,
// finding 1).
@(private)
spy_wav_remove :: proc(path: string) {
	calls := (^int)(context.user_ptr)
	calls^ += 1
}

@(test)
a_finished_engine_probe_calls_the_wav_remover_exactly_once :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	calls := 0
	context.user_ptr = &calls
	check := model_load_check_using(
		&group,
		"where.exe",
		"model.bin",
		context.allocator,
		spy_wav_remove,
		probe_executable,
	)
	defer destroy_check(check, context.allocator)

	testing.expectf(
		t,
		calls == 1,
		"model_load_check called its remover %d time(s) for a finished engine probe, wanted 1",
		calls,
	)
}

// `a_finished_engine_probe_calls_the_wav_remover_exactly_once` above and the
// mutated `remove(wav)` an unconditional removal would compile to both call
// the remover exactly once for a `.Finished` probe -- so on its own it
// cannot tell a guarded call site from an unconditional one. This stub
// supplies the probe's INPUT directly (`Probe{run = .Unstoppable}`, with no
// real unstoppable child constructible on Windows per this ticket's own
// round-1 report) while `model_load_check_using` still supplies the
// DECISION, so a call site reverted to a bare `remove(wav)` turns this test
// red (issue #125's round-2 review, finding 1).
@(private)
@(require_results)
stub_unstoppable_probe :: proc(
	group: ^child.Job_Object,
	executable: string,
	arguments: []string,
	allocator: mem.Allocator,
	bound_ms: i64,
) -> Probe {
	return Probe{run = .Unstoppable}
}

@(test)
an_unstoppable_engine_probe_never_calls_the_wav_remover :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	calls := 0
	context.user_ptr = &calls
	check := model_load_check_using(
		&group,
		"where.exe",
		"model.bin",
		context.allocator,
		spy_wav_remove,
		stub_unstoppable_probe,
	)
	defer destroy_check(check, context.allocator)

	testing.expectf(
		t,
		calls == 0,
		"model_load_check called its remover %d time(s) for an unstoppable engine probe, wanted 0",
		calls,
	)
}
