#+vet explicit-allocators
package doctor

import "core:strings"
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

// Fix round 1 made an advisory failure exit 0, but `render_check` still
// printed it as an ordinary "FAIL" line -- indistinguishable from a failure
// that DID decide the exit code, and false about a machine whose `engine`
// check (two lines above it in a real report) already proved a working GPU.
@(test)
review_an_advisory_failure_does_not_render_as_a_plain_failure :: proc(t: ^testing.T) {
	check := failed("gpu (diagnostic)", "no GPU could be enumerated at all", advisory = true)

	rendered := render_check(check, context.allocator)
	defer delete(rendered, context.allocator)

	testing.expect(
		t,
		!strings.contains(rendered, "FAIL"),
		"an advisory failure rendered with the same word a real failure uses",
	)
}
