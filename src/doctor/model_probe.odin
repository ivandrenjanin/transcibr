#+vet explicit-allocators
package doctor

// A round-5 adversarial review measured a 200 MiB head-truncation of a real
// 1.6 GB Model clearing `model_check`'s size floor and magic-bytes screen,
// while the real Engine refused the same file in well under a second
// ("not all tensors loaded from model file"). Re-deriving the Model's true
// byte count from ggml/gguf's own tensor list would re-implement the
// Engine's own loading logic; spawning the Engine against the Model and a
// tiny probe clip is the same spawn-and-verify shape `verify_engine`
// already uses against `--help`, and the review measured it cheaper than
// the SHA-256 pass `model_check` already pays.

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"
import "transcibr:child"

// A committed fixture already exercised elsewhere (`transcibr:audio`'s own
// extraction tests); short and silent is all a load probe needs, since the
// only thing under test is whether the Engine can build a context from the
// Model, never what it transcribes.
@(private)
MODEL_PROBE_WAV := #load("../audio/fixtures/ffmpeg-mono-16k.wav")

// A real 1.6 GB Model loads (warm cache) in under 1.5 s on the reference
// machine; fifteen seconds leaves an order of magnitude for a cold page
// cache without coming close to what a real transcription would cost.
MODEL_LOAD_PROBE_BOUND_MS :: i64(15_000)

#assert(MODEL_LOAD_PROBE_BOUND_MS > 0)

// Wording only, and never the verdict: whisper.cpp's own line for a failure
// to build a context from a Model file, measured against the real reference
// Engine and three distinct broken Models (200 MiB and 800 MiB head-
// truncations of a real 1.6 GB Model, and a small stub). What decides the
// verdict is the exit status, because a Model that aborts the Engine outright
// never reaches the code that prints this.
MODEL_LOAD_FAILURE_MARKER :: "error: failed to initialize whisper context"

// The current OS thread id is folded into the file name, between the
// package-wide prefix and `os.create_temp_file`'s own random `*` component:
// `odin test` runs a package's tests across 12 threads, one test to
// completion per thread, and `src\doctor\checks_test.odin` drives this same
// procedure from eight tests of its own -- so a scan of `%TEMP%` for the
// bare prefix during one test's own call cannot tell its own wav from a
// sibling's, and a 430 ms scheduling shift is enough to prove it in
// practice. Two calls on the same thread never overlap, so the thread id
// alone is already a scan identity nothing outside this thread can produce
// (issue #125's round-4 review, finding 1).
@(private)
@(require_results)
write_probe_wav :: proc(allocator: mem.Allocator) -> (path: string, ok: bool) {
	assert(allocator.procedure != nil, "a probe wav outlives this call and needs an allocator")

	pattern := fmt.tprintf("transcibr-doctor-probe-%d-*.wav", win32.GetCurrentThreadId())
	f, unopenable := os.create_temp_file("", pattern)
	if unopenable != nil {
		return "", false
	}
	name := strings.clone(os.name(f), allocator)
	_, unwritable := os.write(f, MODEL_PROBE_WAV)
	unclosed := os.close(f)
	if unwritable != nil || unclosed != nil {
		os.remove(name)
		delete(name, allocator)
		return "", false
	}
	return name, true
}

// Whether the scratch wav `model_load_check` below wrote is safe to remove:
// `.Unstoppable` is the one `child.Run` member whose child may still be
// running and may still hold the wav open, exactly as `Run`'s own doc
// comment (`src\child\run.odin`) states -- so removal is refused on it, and
// the wav is leaked deliberately, the same way `child.Read_Job`'s own doc
// comment states its worker leaks for the identical reason (issue #125,
// filed from the #66 review's comment on this ticket, adjacent to #66's own
// reclaim vocabulary in `src\child\reclaim.odin`, ADR-0034).
//
// An exhaustive switch, not `!= .Unstoppable`: issue #33's compile guard
// applies to a switch that names every member itself exactly as it does to
// an enumerated array, and it is what makes a member added to `Run` without
// a case here a build failure rather than a silent settled-for-removal
// default (issue #125's round-1 review, finding 2 -- the `!=` form fails
// OPEN, toward removing a file a child may still hold).
@(private)
@(require_results)
model_probe_wav_settled :: proc(run: child.Run) -> bool {
	switch run {
	case .Not_Started, .Finished, .Stopped:
		return true
	case .Unstoppable:
		return false
	}
	unreachable()
}

// `model_load_check`'s removal of `wav` is threaded through this type
// rather than calling `os.remove` inline, so a test can prove the ordering
// by passing a counting stand-in through `model_load_check_using` below. A
// package variable would race every other test in this package calling
// `model_load_check` concurrently (`odin test` runs 12 threads by default),
// so this is a parameter, not shared state (issue #125's round-1 review,
// finding 1).
@(private)
Wav_Remove :: #type proc(path: string)

@(private)
os_remove_wav :: proc(path: string) {
	os.remove(path)
}

// Pulled out of `model_load_check_using` so its removal effect is provable
// directly, by handing it a `settled` value straight from a test, rather
// than only ever proving `model_probe_wav_settled` classifies a `child.Run`
// correctly in isolation from anything that touches disk (issue #125's
// round-1 review, finding 1).
@(private)
remove_probe_wav_if_settled :: proc(wav: string, settled: bool, remove: Wav_Remove) {
	assert(len(wav) > 0, "there is no scratch wav here to conditionally remove")
	if settled {
		remove(wav)
	}
}

// `model_load_check_using`'s spawn of the probe itself is threaded through
// this type rather than calling `probe_executable` inline, so a test can
// supply the probe's INPUT (a `Probe{run = .Unstoppable}`, with no real
// unstoppable child needed) while the code under test still supplies the
// DECISION -- `model_probe_wav_settled` plus `remove_probe_wav_if_settled`
// -- distinguishing a guarded call site from an unconditional `remove(wav)`
// the way the equivalent `Answer_Remove` spy already distinguishes it for
// `probe_using` in `src\audio\run.odin` (issue #125's round-2 review,
// finding 1).
@(private)
Probe_Maker :: #type proc(
	group: ^child.Job_Object,
	executable: string,
	arguments: []string,
	allocator: mem.Allocator,
	bound_ms: i64,
) -> Probe

// The authoritative half of the Model check: `model_check`'s size floor and
// magic bytes are a cheap pre-filter for obviously broken files, but only
// actually spawning the Engine against the Model proves it loads.
@(require_results)
model_load_check :: proc(
	group: ^child.Job_Object,
	engine_executable: string,
	model_path: string,
	allocator: mem.Allocator,
) -> Check {
	return model_load_check_using(
		group,
		engine_executable,
		model_path,
		allocator,
		os_remove_wav,
		probe_executable,
	)
}

// The real body of `model_load_check`, taking its remover and its probe
// maker as parameters rather than package variables so a test can swap
// either without racing every other test in this package that calls
// `model_load_check` concurrently (issue #125's round-1 review, finding 1;
// the probe maker parameter is round-2's finding 1).
@(private)
@(require_results)
model_load_check_using :: proc(
	group: ^child.Job_Object,
	engine_executable: string,
	model_path: string,
	allocator: mem.Allocator,
	remove: Wav_Remove,
	make_probe: Probe_Maker,
) -> Check {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(engine_executable) > 0, "there is no engine here to load the model with")
	assert(len(model_path) > 0, "there is no model here to load")

	wav, wrote := write_probe_wav(allocator)
	if !wrote {
		message := combined_message(
			model_path,
			"could not be verified: no scratch audio file could be written for the load probe",
			"",
			allocator,
		)
		return failed("model", message)
	}
	defer delete(wav, allocator)

	arguments := []string{"-m", model_path, "-f", wav, "--no-prints"}
	probe := make_probe(group, engine_executable, arguments, allocator, MODEL_LOAD_PROBE_BOUND_MS)
	defer delete(probe.captured, allocator)

	remove_probe_wav_if_settled(wav, model_probe_wav_settled(probe.run), remove)

	return model_load_verdict(probe, model_path, allocator)
}

@(private)
@(require_results)
model_load_verdict :: proc(probe: Probe, model_path: string, allocator: mem.Allocator) -> Check {
	assert(len(model_path) > 0, "there is no model here to report a verdict against")

	if probe.overflowed {
		return failed("model", probe_overflow_message(model_path, allocator))
	}
	switch probe.run {
	case .Not_Started:
		reason := child.error_message(probe.child, allocator)
		defer delete(reason, allocator)
		message := combined_message(
			model_path,
			"could not be loaded by the engine",
			reason,
			allocator,
		)
		return failed("model", message)
	case .Stopped, .Unstoppable:
		message := combined_message(
			model_path,
			"could not be loaded by the engine within the probe's time bound",
			"",
			allocator,
		)
		return failed("model", message)
	case .Finished:
	}
	if !probe.exited {
		message := combined_message(
			model_path,
			"could not be verified: the engine's own exit status could not be read",
			"",
			allocator,
		)
		return failed("model", message)
	}
	if probe.exit_code != 0 {
		return model_refused(probe, model_path, allocator)
	}
	if len(probe.captured) == 0 {
		message := combined_message(
			model_path,
			"could not be verified: the engine ran but reported nothing at all",
			"",
			allocator,
		)
		return failed("model", message)
	}
	return passed("model")
}

// The status is the verdict and the marker is only wording. An adversarial
// review measured a 104,857,604-byte file of genuine ggml magic and random
// bytes hard-aborting the real Engine in 0.92 s -- GGML_ASSERT, exit
// 0xC0000409, and the marker line never printed at all, because the process
// died before whisper.cpp could report anything about it. A probe that reads
// the marker alone calls that a PASS.
@(private)
@(require_results)
model_refused :: proc(probe: Probe, model_path: string, allocator: mem.Allocator) -> Check {
	assert(len(model_path) > 0, "there is no model here to report a refusal against")
	assert(probe.exit_code != 0, "a clean exit was reported as the engine refusing the model")

	says := "was refused by the engine; the download is truncated or corrupt"
	if strings.contains(probe.captured, MODEL_LOAD_FAILURE_MARKER) {
		says = "failed to load in the engine; the download is truncated or corrupt"
	}
	status := fmt.aprintf("engine exit status 0x%X", probe.exit_code, allocator = allocator)
	defer delete(status, allocator)

	message := combined_message(model_path, says, status, allocator)
	return failed("model", message)
}
