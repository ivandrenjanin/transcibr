#+vet explicit-allocators
package doctor

import "core:strings"
import "core:testing"

// Issue #130 fix round 1: an Engine_Fault with an emptied sentence used to
// crash here (report.odin:19, `assert(len(says) > 0, ...)`) rather than
// render -- exactly the failure the walking test in engine_fault_test.odin
// exists to prevent from ever reaching a Recording that is already failing.
@(test)
combined_message_with_no_sentence_still_renders_something_a_reader_can_act_on :: proc(
	t: ^testing.T,
) {
	rendered := combined_message("engine", "", "", context.allocator)
	defer delete(rendered, context.allocator)

	testing.expect(
		t,
		strings.contains(rendered, "engine"),
		"a missing sentence dropped the subject a reader needs to find the failure",
	)
	testing.expect(
		t,
		len(rendered) > 0,
		"a missing sentence rendered as nothing a reader can act on",
	)
}

// #139's own extra AC: emptying NO_SENTENCE_FALLBACK left every existing
// test here green, because the other assertions only check that something
// non-empty renders. Pin the text itself.
@(test)
the_no_sentence_fallback_text_is_pinned :: proc(t: ^testing.T) {
	testing.expect_value(t, NO_SENTENCE_FALLBACK, "failed, but this build has no sentence for why")
}

@(test)
combined_message_with_no_sentence_falls_back_to_the_pinned_text :: proc(t: ^testing.T) {
	rendered := combined_message("engine", "", "", context.allocator)
	defer delete(rendered, context.allocator)

	testing.expect(
		t,
		strings.contains(rendered, NO_SENTENCE_FALLBACK),
		"a missing sentence did not fall back to the pinned text",
	)
}

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

// CONTEXT.md's Advisory entry once claimed an advisory Check "renders as INFO
// like any other line" -- but `render_check` tests `check.ok` first, so a
// passing advisory renders PASS same as any other passing Check; only a
// failing advisory renders INFO.
@(test)
a_passing_advisory_renders_as_pass_not_info :: proc(t: ^testing.T) {
	check := passed("gpu (diagnostic)", advisory = true)

	rendered := render_check(check, context.allocator)
	defer delete(rendered, context.allocator)

	testing.expect(t, strings.contains(rendered, "PASS"), "a passing advisory did not render PASS")
	testing.expect(
		t,
		!strings.contains(rendered, "INFO"),
		"a passing advisory rendered INFO instead of PASS",
	)
}

// A check that never ran is neither a pass nor a failure. Whatever stopped it
// from running is a FAIL of its own further up the report and already carries
// the nonzero exit, so counting the skip a second time would only tell a user
// to fix something that is not broken.
@(test)
report_ok_ignores_a_skipped_check :: proc(t: ^testing.T) {
	checks := []Check {
		failed("engine", "no cuda backend"),
		skipped("model", "the engine is broken"),
	}

	testing.expect(
		t,
		!report_ok(checks),
		"a failed engine check stopped deciding the report once a skip stood beside it",
	)

	healthy := []Check{passed("engine"), skipped("model", "the engine is broken")}

	testing.expect(
		t,
		report_ok(healthy),
		"a skipped check turned the whole report's verdict false on its own",
	)
}

@(test)
a_skipped_check_does_not_render_as_a_failure :: proc(t: ^testing.T) {
	check := skipped("model", "a model cannot be loaded through an engine that does not work")

	rendered := render_check(check, context.allocator)
	defer delete(rendered, context.allocator)

	testing.expect(
		t,
		!strings.contains(rendered, "FAIL"),
		"a skipped check rendered with the same word a real failure uses",
	)
	testing.expect(
		t,
		strings.contains(rendered, "SKIP"),
		"a skipped check did not say it was skipped",
	)
}
