#+vet explicit-allocators
package doctor

import "core:strings"
import "core:testing"

@(private)
CUDA_SYSTEMINFO :: "n_threads = 4 / 12 | WHISPER : COREML = 0 | OPENVINO = 0 | CUDA : ARCHS = 500,610,700,750,800,860,890,900 | PEER_MAX_BATCH_SIZE = 128"

@(private)
NO_CUDA_SYSTEMINFO :: "n_threads = 4 / 12 | WHISPER : COREML = 0 | OPENVINO = 0 | METAL = 0 | PEER_MAX_BATCH_SIZE = 128"

// Well above MIN_HEALTH_CHECK_CONTAINER_MS, so these tests exercise the speed
// half of the check on its own terms rather than tripping the short-recording
// guard.
@(private)
LONG_CONTAINER_MS :: i64(10_000)

@(test)
the_baseline_and_threshold_are_pinned_to_the_measured_numbers :: proc(t: ^testing.T) {
	testing.expect_value(t, MEASURED_BASELINE_REALTIME_FACTOR, f64(17))
	testing.expect_value(t, BASELINE_ORDER_OF_MAGNITUDE, f64(10))
	testing.expect_value(t, health_threshold(), f64(1.7))
}

@(test)
a_recording_at_or_above_the_baseline_is_healthy :: proc(t: ^testing.T) {
	fault := first_recording_health(
		CUDA_SYSTEMINFO,
		MEASURED_BASELINE_REALTIME_FACTOR,
		LONG_CONTAINER_MS,
	)
	testing.expect_value(t, fault, Health_Fault.None)
}

@(test)
a_recording_right_at_the_threshold_is_still_healthy :: proc(t: ^testing.T) {
	fault := first_recording_health(CUDA_SYSTEMINFO, health_threshold(), LONG_CONTAINER_MS)
	testing.expect_value(t, fault, Health_Fault.None)
}

@(test)
a_recording_a_hair_below_the_threshold_fails_on_speed_alone :: proc(t: ^testing.T) {
	fault := first_recording_health(CUDA_SYSTEMINFO, health_threshold() - 0.01, LONG_CONTAINER_MS)
	testing.expect_value(t, fault, Health_Fault.Realtime_Factor_Too_Low)
}

@(test)
a_systeminfo_naming_no_cuda_fails_however_fast_it_ran :: proc(t: ^testing.T) {
	fault := first_recording_health(
		NO_CUDA_SYSTEMINFO,
		MEASURED_BASELINE_REALTIME_FACTOR * 2,
		LONG_CONTAINER_MS,
	)
	testing.expect_value(t, fault, Health_Fault.No_Cuda_Reported)
}

@(test)
no_cuda_is_reported_even_when_the_factor_would_also_fail :: proc(t: ^testing.T) {
	fault := first_recording_health(NO_CUDA_SYSTEMINFO, 0.01, LONG_CONTAINER_MS)
	testing.expect_value(t, fault, Health_Fault.No_Cuda_Reported)
}

@(test)
a_short_recording_is_not_failed_on_speed_alone :: proc(t: ^testing.T) {
	fault := first_recording_health(CUDA_SYSTEMINFO, 1.41, i64(2_000))
	testing.expect_value(t, fault, Health_Fault.None)
}

@(test)
a_short_recording_still_reports_no_cuda_when_it_is_named_absent :: proc(t: ^testing.T) {
	fault := first_recording_health(NO_CUDA_SYSTEMINFO, 1.41, i64(2_000))
	testing.expect_value(t, fault, Health_Fault.No_Cuda_Reported)
}

@(test)
unknown_systeminfo_lets_the_speed_half_carry_the_verdict :: proc(t: ^testing.T) {
	slow := first_recording_health("", health_threshold() - 0.01, LONG_CONTAINER_MS)
	testing.expect_value(t, slow, Health_Fault.Realtime_Factor_Too_Low)

	fast := first_recording_health("", MEASURED_BASELINE_REALTIME_FACTOR, LONG_CONTAINER_MS)
	testing.expect_value(t, fast, Health_Fault.None)
}

@(test)
health_error_message_names_both_the_reason_and_the_numbers :: proc(t: ^testing.T) {
	message := health_error_message(.Realtime_Factor_Too_Low, 0.9, context.allocator)
	defer delete(message, context.allocator)

	testing.expect(t, strings.contains(message, "0.9"), "the measured factor is missing")
	testing.expect(t, strings.contains(message, "17x"), "the baseline is missing")
	testing.expect(t, strings.contains(message, "GPU"), "the actionable reason is missing")
}
