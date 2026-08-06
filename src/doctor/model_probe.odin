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

@(private)
@(require_results)
write_probe_wav :: proc(allocator: mem.Allocator) -> (path: string, ok: bool) {
	assert(allocator.procedure != nil, "a probe wav outlives this call and needs an allocator")

	f, unopenable := os.create_temp_file("", "transcibr-doctor-probe-*.wav")
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
@(private)
@(require_results)
model_probe_wav_settled :: proc(run: child.Run) -> bool {
	return run != .Unstoppable
}

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
	probe := probe_executable(
		group,
		engine_executable,
		arguments,
		allocator,
		MODEL_LOAD_PROBE_BOUND_MS,
	)
	defer delete(probe.captured, allocator)

	if model_probe_wav_settled(probe.run) {
		os.remove(wav)
	}

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
