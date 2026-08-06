#+vet explicit-allocators
package audio

// Whether the audio ffmpeg produced is the whole Recording, and the tolerance
// that decides it. Why the tolerance is what it is: ADR-0022.

Tolerance :: struct {
	floor_ms:  i64,
	per_mille: i64,
}

// Why one second and a thousandth: ADR-0022.
DEFAULT_TOLERANCE :: Tolerance {
	floor_ms  = 1000,
	per_mille = 1,
}

// A policy bound and not overflow protection: past it the check is off.
@(private)
MAX_PER_MILLE :: i64(1000)

// Issue #112: `container_ms > 0` below is internal, not a check on external
// input -- its callers are `durations_agree` in production and the literals
// `duration_test.odin` passes directly, and both only ever pass a value that
// traces back to `process.read_probe`'s success path, which that procedure's
// own doc comment establishes is always positive.
@(require_results)
allowed_difference_ms :: proc(container_ms: i64, tolerance: Tolerance) -> i64 {
	assert(container_ms > 0, "a container with no duration was never accepted by the probe")
	assert(tolerance.floor_ms >= 0, "a tolerance cannot allow a negative difference")
	assert(tolerance.per_mille >= 0, "a tolerance cannot allow a negative share of the duration")
	assert(tolerance.per_mille <= MAX_PER_MILLE, "a tolerance of more than the whole duration")

	return max(tolerance.floor_ms, container_ms * tolerance.per_mille / 1000)
}

// Two-sided deliberately: audio longer than the container means the probe and
// the extraction read different files.
//
// Issue #112: `container_ms > 0` below is internal for the same reason
// `allowed_difference_ms` above states it -- `check_audio` is the only
// production caller and passes through a value `process.read_probe` already
// proved positive.
@(require_results)
durations_agree :: proc(container_ms: i64, audio_ms: i64, tolerance: Tolerance) -> bool {
	assert(container_ms > 0, "a container with no duration was never accepted by the probe")
	assert(audio_ms >= 0, "audio cannot be a negative number of milliseconds long")

	return abs(container_ms - audio_ms) <= allowed_difference_ms(container_ms, tolerance)
}
