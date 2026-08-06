#+vet explicit-allocators
package doctor

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

// `model_probe_wav_settled` walks every `child.Run` member rather than
// trusting a hand-picked few: a member added to `Run` without a case here
// fails the build first (issue #33's enumerated-array/exhaustive-switch
// guarantee applies equally to a switch that names every member itself).
// `.Unstoppable` is the one case whose engine child may still be running and
// may still hold the probe's scratch wav open -- `child.Run`'s own doc
// comment states exactly that -- so it is the one member this must refuse to
// settle (issue #125, filed from the #66 review's comment on this ticket).
@(test)
a_model_probe_wav_is_settled_for_removal_only_when_the_engine_is_known_done :: proc(
	t: ^testing.T,
) {
	for run in child.Run {
		want := run != .Unstoppable
		testing.expectf(
			t,
			model_probe_wav_settled(run) == want,
			"child.Run.%v was settled for removal as %v, wanted %v",
			run,
			model_probe_wav_settled(run),
			want,
		)
	}
}
