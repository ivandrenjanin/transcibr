#+vet explicit-allocators
package process

import "core:fmt"
import "core:mem"

// The one sentence for a fault that stops the Batch from ever starting -- the
// scratch cache or the Model, both checked once before any Recording is
// touched. `audio` and `artifact` share no package of their own, and both
// already import `process` for Build_Fault or ascii_only, which is why the one
// spelling lives here (ADR-0030).
//
// Free the answer with `delete` and this allocator.
@(require_results)
batch_setup_message :: proc(subject: string, says: string, allocator: mem.Allocator) -> string {
	assert(len(subject) > 0, "a batch setup refusal must name what it is reported against")
	assert(len(says) > 0, "there is no message for a batch setup refusal that names nothing")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs a chosen allocator",
	)

	message := fmt.aprintf(
		"%q: %s -- the Batch cannot start",
		subject,
		says,
		allocator = allocator,
	)
	assert(len(message) > 0, "a refusal rendered as nothing at all")
	return message
}
