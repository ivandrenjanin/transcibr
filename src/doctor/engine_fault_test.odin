#+vet explicit-allocators
package doctor

import "core:fmt"
import "core:strings"
import "core:testing"
import "transcibr:child"

// See CLAUDE.md, Odin notes: enumerated arrays and switches. `.None` is
// skipped by name because it is the deliberately empty case -- a Check that
// passed has no message to render at all.
@(test)
every_engine_fault_renders_a_sentence_a_reader_can_act_on :: proc(t: ^testing.T) {
	for fault in Engine_Fault {
		if fault == .None {
			continue
		}

		says := engine_fault_says(fault)
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

		check := Engine_Check {
			fault = fault,
		}
		if fault == .Not_Started {
			check.child = child.Error {
				fault = .Not_Started,
			}
		}
		message := engine_error_message(check, `C:\engines\whisper-cli.exe`, context.allocator)
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
