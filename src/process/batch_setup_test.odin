#+vet explicit-allocators
package process

import "core:strings"
import "core:testing"

// `says` is a synthetic sentence, not copied from any real Fault table --
// `batch_setup_message` treats it as an opaque string, and `process` cannot
// import `audio` or `artifact` to read their real ones without a cycle, so a
// copy here would drift silently against whichever one it was borrowed from.
@(test)
a_batch_setup_refusal_names_its_subject_and_says_the_batch_cannot_start :: proc(t: ^testing.T) {
	says := "a made-up reason, unconnected to any real Fault sentence"
	message := batch_setup_message("D:\\scratch-42\\cache", says, context.allocator)
	defer delete(message, context.allocator)

	testing.expectf(
		t,
		strings.contains(message, "scratch-42"),
		"a batch setup refusal does not name what it is about: <%s>",
		message,
	)
	testing.expectf(
		t,
		strings.contains(message, says),
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
