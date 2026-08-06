#+vet explicit-allocators
package doctor

import "core:fmt"
import "core:strings"
import "core:testing"

// See CLAUDE.md, Odin notes: enumerated arrays and switches, and
// engine_fault_test.odin's identical shape for Engine_Fault (#130/#137).
// `.None` is skipped by name because it is the deliberately empty case -- a
// Recording that passed its health check has no message to render at all.
@(test)
every_health_fault_renders_a_sentence_a_reader_can_act_on :: proc(t: ^testing.T) {
	for fault in Health_Fault {
		if fault == .None {
			continue
		}

		says := health_fault_says(fault)
		if !testing.expectf(t, len(says) > 0, "%v has an empty sentence", fault) {
			continue
		}
		raw := fmt.tprintf("%v", fault)
		testing.expectf(
			t,
			!strings.contains(says, raw),
			"%v's sentence <%s> renders its own identifier verbatim",
			fault,
			says,
		)

		message := health_error_message(fault, 0.9, context.allocator)
		defer delete(message, context.allocator)

		testing.expectf(
			t,
			strings.contains(message, says),
			"%v rendered <%s>, which does not carry its own sentence",
			fault,
			message,
		)
	}
}

// #139 fix round 1: health_error_message's own fallback branch had no
// covering test -- deleting it left the full suite green. `.None` is the one
// Health_Fault member health_fault_says genuinely renders empty, so it
// exercises the real fallback branch in render_health_fault_message without
// a test-only fault; health_error_message's own precondition assert refuses
// `.None`, which is why this goes through render_health_fault_message
// directly.
@(test)
render_health_fault_message_falls_back_to_the_pinned_text_for_none :: proc(t: ^testing.T) {
	message := render_health_fault_message(.None, 0.9, context.allocator)
	defer delete(message, context.allocator)

	testing.expect(
		t,
		strings.contains(message, NO_SENTENCE_FALLBACK),
		"a health fault with no sentence did not fall back to the pinned text",
	)
}
