#+vet explicit-allocators
package process

import "core:fmt"
import "core:mem"

// The one sentence for a fault that stops the Batch from ever starting -- the
// scratch cache or the Model, both checked once before any Recording is
// touched. `audio` and `artifact` share no package of their own, and both
// already import `process` in the file this lives beside -- `audio/fault.odin`
// for Probe_Fault, `artifact/model.odin` for ascii_only -- which is why the one
// spelling lives here; see ADR-0030 for the placement argument in full.
//
// Free the answer with `delete` and this allocator. `says` and the allocator are
// asserted non-empty by every caller before this is reached (A4); only `subject`
// is not, so only it is asserted again here.
@(require_results)
batch_setup_message :: proc(subject: string, says: string, allocator: mem.Allocator) -> string {
	assert(len(subject) > 0, "a batch setup refusal must name what it is reported against")

	return deliverable(
		fmt.aprintf("%q: %s -- the Batch cannot start", subject, says, allocator = allocator),
	)
}
