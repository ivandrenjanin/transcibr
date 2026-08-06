#+vet explicit-allocators
package doctor

import "core:testing"

@(test)
report_ok_ignores_an_advisory_failed_check :: proc(t: ^testing.T) {
	checks := []Check {
		passed("engine"),
		failed("gpu (diagnostic)", "no GPU enumerated", advisory = true),
	}

	testing.expect(
		t,
		report_ok(checks),
		"an advisory-only failure turned the whole report's verdict false",
	)
}

@(test)
report_ok_still_fails_on_a_non_advisory_failed_check :: proc(t: ^testing.T) {
	checks := []Check{passed("engine"), failed("model", "unreadable")}

	testing.expect(
		t,
		!report_ok(checks),
		"a real, non-advisory failure was not reported as a failed report",
	)
}
