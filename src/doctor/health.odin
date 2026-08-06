#+vet explicit-allocators
// Package doctor answers whether the Engine, the Model and the GPU are
// actually usable, before a Batch spends any of them, and keeps answering the
// GPU half of that question once a Batch is running (ADR-0011). Nothing here
// trusts that a GPU exists because Windows says one is attached: the verdict
// on GPU usability comes from spawning the Engine and reading what it says,
// never from enumeration alone.
package doctor

import "core:fmt"
import "core:mem"
import "core:strings"

// The reference measurement docs/spec/0001-transcibr-v1.md records: "roughly
// 17x realtime at beam size 5 on the reference corpus of 56 Recordings
// totalling 75 hours." Not a promise about any one machine's own GPU, only
// the one number this repository has actually measured against a working
// CUDA path.
MEASURED_BASELINE_REALTIME_FACTOR :: f64(17)

// ADR-0011: "a first-recording realtime factor an order of magnitude below
// the measured baseline aborts the batch." A factor under a tenth of the
// baseline is the CPU-fallback signature this check exists to catch -- an
// Engine transcribing at all, only far too slowly to be running on the GPU
// it was told to use -- not ordinary machine-to-machine variance, which does
// not cross a whole order of magnitude.
BASELINE_ORDER_OF_MAGNITUDE :: f64(10)

#assert(MEASURED_BASELINE_REALTIME_FACTOR > 0)
#assert(BASELINE_ORDER_OF_MAGNITUDE > 1)

@(require_results)
health_threshold :: proc() -> f64 {
	return MEASURED_BASELINE_REALTIME_FACTOR / BASELINE_ORDER_OF_MAGNITUDE
}

// Measured against the reference GPU install, ggml-large-v3-turbo, beam 5: a
// 2s clip's factor (1.41x) sits below health_threshold() purely from the
// Engine's fixed per-run overhead (model load, CUDA init), while a 4s clip
// (2.78x) and an 8s clip (5.60x) both clear it. Below this many container
// milliseconds, that fixed overhead dominates the measurement and the speed
// half of the check is not trusted to carry a verdict either way.
MIN_HEALTH_CHECK_CONTAINER_MS :: i64(5_000)

#assert(MIN_HEALTH_CHECK_CONTAINER_MS > 0)

Health_Fault :: enum u8 {
	None = 0,
	// The Engine's own `systeminfo` line names no CUDA support at all -- the
	// build itself has nothing to fall back FROM.
	No_Cuda_Reported,
	// CUDA is named, but this Recording ran an order of magnitude slower
	// than the measured baseline -- the CPU-fallback signature ADR-0011
	// describes: a candidate GPU backend library that failed to load and was
	// skipped without being reported.
	Realtime_Factor_Too_Low,
}

// Why `systeminfo` alone is not proof of anything: it names what the Engine
// was BUILT with, not what it is actually driving this Recording on -- see
// CONTEXT.md's Engine entry and ADR-0011. `realtime_factor` is the load-
// bearing half of this check for exactly that reason: the caller is expected
// to compute it as the Recording's own container duration divided by how
// long the Engine actually took, both already measured before this is
// called, which is why an invalid factor is asserted rather than refused --
// this procedure's own precondition, not anything read from outside the
// program. An empty `systeminfo` means no evidence either way -- the caller
// passes it that way when the Engine's own output named no systeminfo field
// or could not be parsed at all -- and this never turns absence of evidence
// into `.No_Cuda_Reported`; the speed half of the check still applies.
//
// `conclusive` is `false` only when the container is too short for the speed
// half to carry a verdict and the name half found nothing to say either --
// a round-4 adversarial review measured this exact `.None` standing in for
// "healthy" when it actually meant "this Recording could not be judged",
// which spent a Batch's one health check on a Recording it never actually
// judged and left every Recording behind it unchecked. A caller that only
// spends its one check on a `conclusive` answer keeps asking until it gets
// one.
//
// Issue #132: `container_ms > 0` below is internal, not a check on external
// input, for the same reason #129 recorded at `read_probe`'s guard in
// src/process/ffmpeg.odin. `first_recording_health`'s only caller,
// `pipeline.checked_first_recording_health`, forwards the same value its
// own identical assert already checked, itself traced to
// `audio.Extracted.container_ms`.
@(require_results)
first_recording_health :: proc(
	systeminfo: string,
	realtime_factor: f64,
	container_ms: i64,
) -> (
	fault: Health_Fault,
	conclusive: bool,
) {
	assert(
		realtime_factor > 0,
		"a Recording that took no measurable time reached the health check",
	)
	assert(container_ms > 0, "a Recording nobody could time reached the health check")

	if len(systeminfo) > 0 && !strings.contains(systeminfo, "CUDA") {
		return .No_Cuda_Reported, true
	}
	if container_ms < MIN_HEALTH_CHECK_CONTAINER_MS {
		return .None, false
	}
	if realtime_factor < health_threshold() {
		return .Realtime_Factor_Too_Low, true
	}
	return .None, true
}

@(private)
@(require_results)
health_fault_says :: proc(fault: Health_Fault) -> string {
	switch fault {
	case .No_Cuda_Reported:
		return(
			"the engine's own system report names no CUDA support at all; it was not built against the GPU backend" \
		)
	case .Realtime_Factor_Too_Low:
		return(
			"the first recording transcribed an order of magnitude slower than this program's measured GPU baseline, which is the signature of a GPU backend library that failed to load and was silently skipped" \
		)
	case .None:
	}
	return ""
}

// The realtime factor is reported to one decimal place because a user acting
// on this message is comparing it against the baseline printed beside it,
// not reading it back into anything this program parses.
@(require_results)
health_error_message :: proc(
	fault: Health_Fault,
	realtime_factor: f64,
	allocator: mem.Allocator,
) -> string {
	assert(
		fault != .None,
		"there is no message for a first recording that passed its health check",
	)
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs an allocator",
	)

	says := health_fault_says(fault)
	assert(len(says) > 0, "a fault was added to Health_Fault without a sentence")

	message := fmt.aprintf(
		"%s (measured %.1fx realtime; the baseline is %.0fx)",
		says,
		realtime_factor,
		MEASURED_BASELINE_REALTIME_FACTOR,
		allocator = allocator,
	)
	assert(len(message) > 0, "a refusal rendered as nothing at all")
	return message
}
