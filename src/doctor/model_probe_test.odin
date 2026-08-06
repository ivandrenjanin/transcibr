#+vet explicit-allocators
package doctor

import "core:strings"
import "core:testing"

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
