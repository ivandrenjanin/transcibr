#+vet explicit-allocators
package doctor

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"
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

// Issue #208: `model_load_verdict`'s `.Not_Started` branch used to call
// `child.error_message` unconditionally, reaching its own
// `assert(err.fault != .None, ...)` (child.odin:79) whenever a `.Not_Started`
// probe's child carried no fault -- reachable only because nothing in this
// package checked the fault first before calling it. `run_bounded` never
// actually returns `.Not_Started` with `err.fault == .None`
// (`child/run_test.odin` pins that guarantee), but the doctor branch relied
// on it without checking -- an unrecorded cross-package pairing. This drives
// a fault-free `.Not_Started` Probe directly through `model_load_verdict`,
// the shape a caller-constructed stub Probe reaches without a real child,
// and proves the branch renders a fallback message rather than reaching
// that assert at all.
@(test)
a_fault_free_not_started_probe_is_refused_by_the_model_verdict_without_asserting :: proc(
	t: ^testing.T,
) {
	probe := Probe {
		run = .Not_Started,
	}
	check := model_load_verdict(probe, "model.bin", context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, false)
	testing.expect(
		t,
		strings.contains(check.reason, "could not be loaded by the engine"),
		"a fault-free Not_Started probe's message did not name the load failure",
	)
}

// Issue #145: `model_load_verdict`'s `probe.exit_code != 0` branch was the
// only route to `model_refused`, which re-asserted the identical condition
// on a value that originates in a child process -- a legitimate A4 pair, but
// nothing exercised it, and it was the one assert in the package standing
// between external data and a fault report. Drives the child-originated
// exit code through `model_load_verdict` directly, the seam a real doctor
// run reaches this through, and pins the branch-distinguishing prefix
// ("was refused by the engine") rather than only the substring the two
// `says` branches share ("truncated or corrupt"), so a mutation that
// renders the marker branch's sentence ("failed to load in the engine...")
// for a refused-without-marker engine still turns this red.
@(test)
a_refused_engine_probe_names_its_exit_status_without_asserting :: proc(t: ^testing.T) {
	probe := Probe {
		run       = .Finished,
		exited    = true,
		exit_code = 1,
		captured  = "",
	}
	check := model_load_verdict(probe, "model.bin", context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, false)
	testing.expect(
		t,
		strings.contains(check.reason, "engine exit status 0x1"),
		"a refused probe's message did not name the engine's own exit status",
	)
	testing.expect(
		t,
		strings.contains(check.reason, "was refused by the engine"),
		"a refused-without-marker probe's message did not carry the branch-distinguishing wording",
	)
	testing.expect(
		t,
		strings.contains(check.reason, "truncated or corrupt"),
		"a refused probe's message did not carry the download-corruption wording",
	)
}

// Issue #209: `model_refused`'s marker-branch selection
// (`strings.contains(probe.captured, MODEL_LOAD_FAILURE_MARKER)`) had no
// SYNTHETIC unit coverage of its marker-CARRYING branch specifically.
// `a_refused_engine_probe_names_its_exit_status_without_asserting` above
// already pins the marker-FREE branch (`captured = ""`) onto "was refused by
// the engine", and the real-engine review test
// (`review_a_200_mib_head_truncation_above_the_floor_must_not_pass_the_model_check`,
// which the ordinary suite does run -- it self-skips only when the reference
// engine/model are absent) already reds on the marker-carrying branch too.
// This test drives a synthetic marker-carrying `captured` string through
// `model_load_verdict` directly, so the marker-carrying branch has a unit pin
// that runs unconditionally rather than only when the reference assets are
// present. Together with the marker-free test above, the two turn red on
// either direction of an inverted `contains()`.
@(test)
a_marker_carrying_probe_is_refused_by_the_model_verdict_with_the_load_failure_wording :: proc(
	t: ^testing.T,
) {
	probe := Probe {
		run       = .Finished,
		exited    = true,
		exit_code = 1,
		captured  = MODEL_LOAD_FAILURE_MARKER,
	}
	check := model_load_verdict(probe, "model.bin", context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, false)
	testing.expect(
		t,
		strings.contains(check.reason, "failed to load in the engine"),
		"a marker-carrying probe's message did not carry the load-failure wording",
	)
	testing.expect(
		t,
		!strings.contains(check.reason, "was refused by the engine"),
		"a marker-carrying probe's message carried the marker-free branch's wording",
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
// (`odin test` runs 12 threads by default) (issue #125's round-1 review,
// finding 1).
@(private)
spy_wav_remove :: proc(path: string) {
	calls := (^int)(context.user_ptr)
	calls^ += 1
}

// `a_finished_engine_probe_calls_the_wav_remover_exactly_once` (round-1/round-2)
// drove `model_load_check_using` directly, which can never see whether the
// public `model_load_check` wrapper below it actually passes `os_remove_wav`
// through -- no test called that wrapper at all, so a mutation swapping its
// hard-coded `os_remove_wav` argument for a no-op left the full suite green
// (issue #125's round-3 review, finding 1). This drives `model_load_check`
// itself, the same way `src\audio\run_test.odin`'s
// `a_probe_whose_answer_read_finishes_removes_the_answer_file_at_the_call_site`
// drives the public `probe` wrapper, and reads the removal off disk rather
// than off a spy, because the public wrapper has no seam left to inject one
// through.
//
// `probe_wav_scan_guard` -- round-3 review, finding 2 -- keeps this scan and
// `an_unstoppable_engine_probe_never_calls_the_wav_remover`'s scan below from
// reading each other's scratch wav mid-flight: `odin test` runs a package's
// tests across 12 threads by default, and both tests watch the same `TEMP`
// directory for the same file-name shape.
@(private)
probe_wav_scan_guard: sync.Mutex

// `os.temp_directory` is on this ticket's own refuted list (round-1's
// report). `os.get_env("TEMP", ...)` is the same call `testkit.scratch_cache`
// already makes for the identical reason.
//
// `write_probe_wav` folds the calling OS thread's id into its file name
// (`src\doctor\model_probe.odin`); this scans for that same thread's own
// prefix rather than the bare `transcibr-doctor-probe-` one, which is what
// makes this scan a scan of THIS call's own wav and nothing else's --
// neither this file's own settled/unsettled fixtures below, nor a wav
// `src\doctor\checks_test.odin`'s eight `model_check` tests write from a
// different thread while this test's own call is in flight. Before this,
// diffing the bare prefix across the whole of `%TEMP%` counted any
// concurrently-created sibling wav as this call's own leak -- proven by a
// single 430 ms sleep added to one of those eight tests, with this file
// untouched, turning the call-site test red (issue #125's round-4 review,
// finding 1).
@(private)
@(require_results)
own_probe_wav_prefix :: proc(allocator: mem.Allocator) -> string {
	assert(allocator.procedure != nil, "a scan prefix outlives this call and needs an allocator")
	return fmt.aprintf(
		"transcibr-doctor-probe-%d-",
		win32.GetCurrentThreadId(),
		allocator = allocator,
	)
}

@(private)
@(require_results)
probe_wav_paths :: proc(allocator: mem.Allocator) -> []string {
	assert(allocator.procedure != nil, "a path listing outlives this call and needs an allocator")

	directory := os.get_env("TEMP", allocator)
	defer delete(directory, allocator)
	assert(len(directory) > 0, "TEMP names nowhere to find the doctor's scratch wav")

	prefix := own_probe_wav_prefix(allocator)
	defer delete(prefix, allocator)

	paths := make([dynamic]string, allocator)
	listing, unreadable := os.read_all_directory_by_path(directory, allocator)
	if unreadable != nil {
		return paths[:]
	}
	defer os.file_info_slice_delete(listing, allocator)
	for info in listing {
		if strings.has_prefix(info.name, prefix) {
			append(&paths, strings.clone(info.fullpath, allocator))
		}
	}
	return paths[:]
}

@(private)
destroy_probe_wav_paths :: proc(paths: []string, allocator: mem.Allocator) {
	for path in paths {
		delete(path, allocator)
	}
	delete(paths, allocator)
}

@(private)
@(require_results)
contains_path :: proc(paths: []string, path: string) -> bool {
	for candidate in paths {
		if candidate == path {
			return true
		}
	}
	return false
}

@(test)
a_finished_engine_probe_removes_its_scratch_wav_at_the_call_site :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	sync.mutex_lock(&probe_wav_scan_guard)
	defer sync.mutex_unlock(&probe_wav_scan_guard)

	before := probe_wav_paths(context.allocator)
	defer destroy_probe_wav_paths(before, context.allocator)

	check := model_load_check(&group, "where.exe", "model.bin", context.allocator)
	defer destroy_check(check, context.allocator)

	after := probe_wav_paths(context.allocator)
	defer destroy_probe_wav_paths(after, context.allocator)

	leaked := 0
	for path in after {
		if !contains_path(before, path) {
			leaked += 1
		}
	}
	testing.expectf(
		t,
		leaked == 0,
		"model_load_check's own call site left %d scratch wav(s) on disk",
		leaked,
	)
}

// `a_finished_engine_probe_removes_its_scratch_wav_at_the_call_site` above
// drives the public wrapper, which would also leave no file behind under the
// mutated `remove(wav)` an unconditional removal would compile to -- so on
// its own it cannot tell a guarded call site from an unconditional one. This
// stub supplies the probe's INPUT directly (`Probe{run = .Unstoppable}`, with no
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

// `stub_unstoppable_probe` skips the real Engine spawn, but
// `model_load_check_using` still calls the real `write_probe_wav` before it
// ever reaches the stub -- so this test's own scratch wav is real, and
// because the guard under test deliberately never removes it (the point of
// the assertion below), nothing else ever will. Left alone, that is a real
// ~5.7 KB file per run leaking into `%TEMP%` unbounded (issue #125's round-3
// review, finding 2); the scan below finds exactly the file this run created
// and removes it directly, after the assertion it exists to protect has
// already run.
@(test)
an_unstoppable_engine_probe_never_calls_the_wav_remover :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	sync.mutex_lock(&probe_wav_scan_guard)
	defer sync.mutex_unlock(&probe_wav_scan_guard)

	before := probe_wav_paths(context.allocator)
	defer destroy_probe_wav_paths(before, context.allocator)

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

	after := probe_wav_paths(context.allocator)
	defer destroy_probe_wav_paths(after, context.allocator)
	for path in after {
		if !contains_path(before, path) {
			os.remove(path)
		}
	}
}
