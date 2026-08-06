#+vet explicit-allocators
package audio

import "core:strings"
import "core:testing"
import "transcibr:child"
import "transcibr:process"

// See CLAUDE.md, Odin notes: enumerated arrays and switches. `.None` is skipped
// by name because it is the deliberately empty row.
@(test)
every_fault_renders_a_line_a_recordings_failure_row_can_carry :: proc(t: ^testing.T) {
	for fault in Fault {
		if fault == .None {
			continue
		}
		if !testing.expectf(t, len(FAULT[fault]) > 0, "%v has an empty row in FAULT", fault) {
			continue
		}

		err := Error {
			fault = fault,
			probe = .Duration_Unknown,
			child = child.Error{fault = .Not_Started},
			said = 48_000,
			got = 12_000,
		}
		message := error_message(err, "C:\\clips\\one talk.mp4", context.allocator)
		defer delete(message, context.allocator)

		testing.expectf(
			t,
			strings.contains(message, FAULT[fault]),
			"%v rendered <%s>, which does not carry its own sentence",
			fault,
			message,
		)
		testing.expectf(
			t,
			strings.contains(message, "one talk.mp4"),
			"%v rendered <%s>, which does not name the Recording",
			fault,
			message,
		)

		if fault == .Probe_Unreadable {
			testing.expectf(
				t,
				strings.contains(message, process.probe_fault_says(err.probe)),
				"%v rendered <%s>, which does not carry its borrowed Probe_Fault sentence",
				fault,
				message,
			)
		}
	}
}

@(test)
a_cache_refusal_names_the_cache_directory :: proc(t: ^testing.T) {
	message := cache_error_message(
		.Path_Not_Ascii,
		"D:\\scratch-42\\\u5f55\u97f3",
		context.allocator,
	)
	defer delete(message, context.allocator)

	testing.expectf(
		t,
		strings.contains(message, "scratch-42"),
		"a refused cache does not name the directory that was refused: <%s>",
		message,
	)
	testing.expectf(
		t,
		strings.contains(message, "\\u5f55"),
		"the bytes that got the cache refused were not escaped out of the line: <%s>",
		message,
	)
	testing.expectf(
		t,
		strings.contains(message, "Batch"),
		"a refusal that stops the whole Batch does not say so: <%s>",
		message,
	)
	testing.expectf(
		t,
		!strings.contains(message, "Recording"),
		"a Batch-level refusal was rendered against a Recording: <%s>",
		message,
	)
}

@(test)
every_cache_fault_renders_a_line_a_batch_can_refuse_to_start_with :: proc(t: ^testing.T) {
	for fault in Cache_Fault {
		if fault == .None {
			continue
		}
		says := cache_fault_says(fault)
		if !testing.expectf(t, len(says) > 0, "%v has no sentence at all", fault) {
			continue
		}

		message := cache_error_message(fault, "C:\\cache", context.allocator)
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
