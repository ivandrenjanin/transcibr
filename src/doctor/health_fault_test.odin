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
