#+vet explicit-allocators
package doctor

import "core:strings"
import "core:testing"

@(private)
CUDA_SYSTEMINFO :: "n_threads = 4 / 12 | WHISPER : COREML = 0 | OPENVINO = 0 | CUDA : ARCHS = 500,610,700,750,800,860,890,900 | PEER_MAX_BATCH_SIZE = 128"

@(private)
NO_CUDA_SYSTEMINFO :: "n_threads = 4 / 12 | WHISPER : COREML = 0 | OPENVINO = 0 | METAL = 0 | PEER_MAX_BATCH_SIZE = 128"

@(test)
a_recording_at_or_above_the_baseline_is_healthy :: proc(t: ^testing.T) {
	fault := first_recording_health(CUDA_SYSTEMINFO, MEASURED_BASELINE_REALTIME_FACTOR)
	testing.expect_value(t, fault, Health_Fault.None)
}

@(test)
a_recording_right_at_the_threshold_is_still_healthy :: proc(t: ^testing.T) {
	fault := first_recording_health(CUDA_SYSTEMINFO, health_threshold())
	testing.expect_value(t, fault, Health_Fault.None)
}

@(test)
a_recording_a_hair_below_the_threshold_fails_on_speed_alone :: proc(t: ^testing.T) {
	fault := first_recording_health(CUDA_SYSTEMINFO, health_threshold() - 0.01)
	testing.expect_value(t, fault, Health_Fault.Realtime_Factor_Too_Low)
}

@(test)
a_systeminfo_naming_no_cuda_fails_however_fast_it_ran :: proc(t: ^testing.T) {
	fault := first_recording_health(NO_CUDA_SYSTEMINFO, MEASURED_BASELINE_REALTIME_FACTOR * 2)
	testing.expect_value(t, fault, Health_Fault.No_Cuda_Reported)
}

@(test)
no_cuda_is_reported_even_when_the_factor_would_also_fail :: proc(t: ^testing.T) {
	fault := first_recording_health(NO_CUDA_SYSTEMINFO, 0.01)
	testing.expect_value(t, fault, Health_Fault.No_Cuda_Reported)
}

@(test)
health_error_message_names_both_the_reason_and_the_numbers :: proc(t: ^testing.T) {
	message := health_error_message(.Realtime_Factor_Too_Low, 0.9, context.allocator)
	defer delete(message, context.allocator)

	testing.expect(t, strings.contains(message, "0.9"), "the measured factor is missing")
	testing.expect(t, strings.contains(message, "17"), "the baseline is missing")
	testing.expect(t, strings.contains(message, "GPU"), "the actionable reason is missing")
}
