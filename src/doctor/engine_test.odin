#+vet explicit-allocators
package doctor

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "transcibr:child"
import "transcibr:testkit"

@(private)
REAL_CMD :: `C:\Windows\System32\cmd.exe`

@(private)
@(require_results)
written :: proc(path: string, bytes: []u8) -> bool {
	assert(len(path) > 0, "there is nowhere here to write a fixture file")

	handle, unopenable := os.open(path, {.Write, .Create, .Trunc})
	if unopenable != nil {
		return false
	}
	defer os.close(handle)

	n, unwritable := os.write(handle, bytes)
	return unwritable == nil && n == len(bytes)
}

@(test)
the_backend_library_is_reported_present_only_when_it_sits_beside_the_executable :: proc(
	t: ^testing.T,
) {
	dir := testkit.made_scratch_cache(t, "Doctor", "backendlib", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	executable := fmt.aprintf("%s\\whisper-cli.exe", dir, allocator = context.allocator)
	defer delete(executable, context.allocator)
	testing.expect(t, written(executable, {1, 2, 3}), "the case could not write its own fixture")
	testing.expect(
		t,
		!backend_library_present(executable),
		"an install with no backend dll passed",
	)

	beside := fmt.aprintf("%s\\%s", dir, GPU_BACKEND_LIBRARY, allocator = context.allocator)
	defer delete(beside, context.allocator)
	testing.expect(t, written(beside, {1, 2, 3}), "the case could not write its own fixture")
	testing.expect(
		t,
		backend_library_present(executable),
		"an install with the backend dll failed",
	)
}

// The round-4 finding: a wrong or nonexistent `--engine-exe` used to report
// the backend-library sentence, sending a user to redownload an Engine that
// was never the problem. `os.is_file` ahead of `backend_library_present`
// names the real one.
@(test)
review_a_nonexistent_engine_exe_is_reported_before_the_backend_library_check :: proc(
	t: ^testing.T,
) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	check := verify_engine(&group, `C:\nope\whisper-cli.exe`, context.allocator)

	testing.expect_value(t, check.fault, Engine_Fault.Executable_Not_Found)
}

// The other round-4 fixture: a directory passed as `--engine-exe` (a
// plausible reading of ADR-0011's "resolved as a directory"). `filepath.dir`
// of a directory is its own parent, so `backend_library_present` used to
// check the WRONG directory and report the same misleading sentence as a
// nonexistent path. `os.is_file` refuses a directory outright, the same way
// `model_check` already refuses one for `--model-file`.
@(test)
review_a_directory_passed_as_the_engine_exe_is_reported_as_missing_not_as_a_backend_fault :: proc(
	t: ^testing.T,
) {
	dir := testkit.made_scratch_cache(t, "Doctor", "engineisdir", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	check := verify_engine(&group, dir, context.allocator)

	testing.expect_value(t, check.fault, Engine_Fault.Executable_Not_Found)
}

@(test)
an_install_with_no_backend_library_fails_before_anything_is_spawned :: proc(t: ^testing.T) {
	dir := testkit.made_scratch_cache(t, "Doctor", "nobackend", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	executable := fmt.aprintf("%s\\whisper-cli.exe", dir, allocator = context.allocator)
	defer delete(executable, context.allocator)
	testing.expect(t, written(executable, {1, 2, 3}), "the case could not write its own fixture")

	check := verify_engine(&group, executable, context.allocator)

	testing.expect_value(t, check.fault, Engine_Fault.Backend_Library_Missing)
}

@(test)
an_engine_that_starts_but_never_names_cuda_loaded_is_reported_rather_than_trusted :: proc(
	t: ^testing.T,
) {
	dir := testkit.made_scratch_cache(t, "Doctor", "silentcpu", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	beside := fmt.aprintf("%s\\%s", dir, GPU_BACKEND_LIBRARY, allocator = context.allocator)
	defer delete(beside, context.allocator)
	testing.expect(t, written(beside, {1, 2, 3}), "the case could not write its own fixture")

	real_cmd, unreadable := os.read_entire_file(REAL_CMD, context.allocator)
	testing.expect(t, unreadable == nil, "the case could not read a real cmd.exe to copy")
	defer delete(real_cmd, context.allocator)

	executable := fmt.aprintf("%s\\whisper-cli.exe", dir, allocator = context.allocator)
	defer delete(executable, context.allocator)
	testing.expect(t, written(executable, real_cmd), "the case could not write its own fixture")

	check := verify_engine(&group, executable, context.allocator)

	testing.expect_value(t, check.fault, Engine_Fault.Backend_Not_Loaded)
}

@(test)
an_engine_that_will_not_start_is_reported_rather_than_asserted :: proc(t: ^testing.T) {
	dir := testkit.made_scratch_cache(t, "Doctor", "willnotstart", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	beside := fmt.aprintf("%s\\%s", dir, GPU_BACKEND_LIBRARY, allocator = context.allocator)
	defer delete(beside, context.allocator)
	testing.expect(t, written(beside, {1, 2, 3}), "the case could not write its own fixture")

	executable := fmt.aprintf("%s\\whisper-cli.exe", dir, allocator = context.allocator)
	defer delete(executable, context.allocator)
	testing.expect(
		t,
		written(executable, {'n', 'o', 't', ' ', 'a', ' ', 'p', 'e'}),
		"the case could not write its own fixture",
	)

	check := verify_engine(&group, executable, context.allocator)

	testing.expect_value(t, check.fault, Engine_Fault.Not_Started)
	testing.expect(t, check.child.fault != .None, "an engine that would not start named no reason")
}

// The real reference install this dev machine carries, exercised end to end
// exactly once so the whole wire-up -- backend detection, spawning, and
// reading `--help`'s own stderr for the line the Engine actually writes --
// is proved against a genuine release rather than only against fixtures.
// Skipped, not failed, wherever that install is absent: this is GPU behaviour
// (docs/spec/0001-transcibr-v1.md's Testing Decisions names it out of every
// automated seam) and CI carries no such directory. Issue #230: the skip is
// named in the test itself and logged, so a green run still says what it
// did not measure.
@(private)
REFERENCE_ENGINE :: `C:\tools\whisper\Release\whisper-cli.exe`

@(test)
the_reference_engine_install_reports_cuda_loaded_when_reference_assets_exist :: proc(
	t: ^testing.T,
) {
	if reference_asset_missing(t, "reference engine", REFERENCE_ENGINE) {
		return
	}

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	check := verify_engine(&group, REFERENCE_ENGINE, context.allocator)

	if check.fault != .None {
		message := engine_error_message(check, REFERENCE_ENGINE, context.allocator)
		defer delete(message, context.allocator)
		testing.expectf(t, false, "%s", message)
		return
	}
	testing.expect_value(t, check.fault, Engine_Fault.None)
}

// Proves the caller-side refusal without spawning a flooding child: an
// overflowed Probe is a caller-constructed value, and `engine_probe_verdict`
// is the pure procedure `verify_engine` hands it to before anything else.
// Mutation check per the ticket's own acceptance criterion: deleting the
// `if probe.overflowed` guard in `engine_probe_verdict` (src/doctor/engine.odin)
// leaves this red, because the overflowed Probe would then fall through to
// `switch probe.run`, which this Probe leaves at its zero value
// `.Not_Started` and reports a different fault entirely.
@(test)
an_overflowed_probe_is_refused_by_the_engine_verdict_rather_than_judged_on_its_capture :: proc(
	t: ^testing.T,
) {
	probe := Probe {
		overflowed = true,
	}
	check := engine_probe_verdict(probe)

	testing.expect_value(t, check.fault, Engine_Fault.Capture_Overflowed)
}

// Issue #208 round 1: `engine_error_message`'s `.Not_Started` branch called
// `child.error_message(check.child, allocator)` unconditionally, reaching
// that procedure's own `assert(err.fault != .None, ...)` (child.odin:86)
// for any fault-free `.Not_Started` check -- the same reachable-assert
// defect `model_load_verdict` had, and this one is reached through a public
// procedure. Drives a fault-free `.Not_Started` Engine_Check (the shape
// `engine_probe_verdict` returns for a caller-constructed Probe whose child
// field is left at its zero value) directly through `engine_error_message`,
// and proves it renders a fallback message rather than reaching that
// assert at all.
@(test)
a_fault_free_not_started_probe_is_refused_by_the_engine_verdict_without_asserting :: proc(
	t: ^testing.T,
) {
	probe := Probe {
		run = .Not_Started,
	}
	check := engine_probe_verdict(probe)
	testing.expect_value(t, check.fault, Engine_Fault.Not_Started)

	message := engine_error_message(check, `C:\engines\whisper-cli.exe`, context.allocator)
	defer delete(message, context.allocator)

	testing.expect(
		t,
		strings.contains(message, "could not be started"),
		"a fault-free Not_Started check's message did not name the start failure",
	)
}

@(test)
an_engine_fault_message_names_the_capture_ceiling_when_overflowed :: proc(t: ^testing.T) {
	check := Engine_Check {
		fault = .Capture_Overflowed,
	}
	message := engine_error_message(check, `C:\engines\whisper-cli.exe`, context.allocator)
	defer delete(message, context.allocator)

	testing.expect(
		t,
		strings.contains(message, "MAX_PROBE_CAPTURE_BYTES"),
		"an overflow fault message did not name its own ceiling",
	)
}

@(test)
an_engine_fault_message_names_the_executable_and_an_actionable_reason :: proc(t: ^testing.T) {
	check := Engine_Check {
		fault = .Backend_Library_Missing,
	}
	message := engine_error_message(check, `C:\engines\whisper-cli.exe`, context.allocator)
	defer delete(message, context.allocator)

	testing.expect(t, strings.contains(message, "whisper-cli.exe"), "the executable is missing")
	testing.expect(
		t,
		strings.contains(message, "ggml-cuda.dll"),
		"the actionable reason is missing",
	)
}

@(test)
an_executable_not_found_message_never_blames_the_backend_library :: proc(t: ^testing.T) {
	check := Engine_Check {
		fault = .Executable_Not_Found,
	}
	message := engine_error_message(check, `C:\nope\whisper-cli.exe`, context.allocator)
	defer delete(message, context.allocator)

	testing.expect(t, strings.contains(message, "whisper-cli.exe"), "the executable is missing")
	testing.expect(
		t,
		!strings.contains(message, "ggml-cuda.dll"),
		"a missing executable was blamed on the backend library",
	)
}
