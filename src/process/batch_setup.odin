#+vet explicit-allocators
package process

import "core:fmt"
import "core:mem"

// The one sentence for a fault that stops the Batch from ever starting -- the
// scratch cache or the Model, both checked once before any Recording is
// touched. `audio` and `artifact` share no package of their own to hold it in;
// it lives here because it reuses `deliverable` (command_line.odin), the same
// NUL-free, valid-UTF-8, non-empty guard `error_message` already calls for
// `Build_Error` -- a call about proportion, not a structural necessity. See
// ADR-0030 for the argument in full, including the placements it turned down.
//
// Issue #216: the consequence clause used to be baked in, so every caller --
// `--doctor`, `--plan`, `--transcribe` included through `artifact.engine_error_message`
// -- inherited "the Batch cannot start" even when no Batch was ever asked
// for. `framing` is that clause, the `read_natural` `max_digits` precedent:
// the variable part a caller supplies, defaulted to `BATCH_CANNOT_START` so
// every call site that does not pass one (the Batch itself, and every
// un-migrated caller) keeps today's exact bytes.
//
// Free the answer with `delete` and this allocator. `says` and the allocator are
// asserted non-empty by every caller before this is reached (A4); only `subject`
// is not, so only it is asserted again here.
BATCH_CANNOT_START :: "the Batch cannot start"

@(require_results)
batch_setup_message :: proc(
	subject: string,
	says: string,
	allocator: mem.Allocator,
	framing: string = BATCH_CANNOT_START,
) -> string {
	assert(len(subject) > 0, "a batch setup refusal must name what it is reported against")
	assert(len(framing) > 0, "a batch setup refusal needs a consequence to end on")

	return deliverable(fmt.aprintf("%q: %s -- %s", subject, says, framing, allocator = allocator))
}
