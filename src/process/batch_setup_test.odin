#+vet explicit-allocators
package process

import "core:strings"
import "core:testing"

@(test)
a_batch_setup_refusal_names_its_subject_and_says_the_batch_cannot_start :: proc(t: ^testing.T) {
	message := batch_setup_message(
		"D:\\scratch-42\\cache",
		"the scratch cache could not be created or listed",
		context.allocator,
	)
	defer delete(message, context.allocator)

	testing.expectf(
		t,
		strings.contains(message, "scratch-42"),
		"a batch setup refusal does not name what it is about: <%s>",
		message,
	)
	testing.expectf(
		t,
		strings.contains(message, "the scratch cache could not be created or listed"),
		"a batch setup refusal drops its own reason: <%s>",
		message,
	)
	testing.expectf(
		t,
		strings.contains(message, " -- the Batch cannot start"),
		"a batch setup refusal does not say the Batch cannot start: <%s>",
		message,
	)
}
