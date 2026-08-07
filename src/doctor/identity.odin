#+vet explicit-allocators
package doctor

// Reporting the Engine's identity beside the doctor's existing verdicts
// (issue #189, ADR-0037): identifying the binary -- reading it, hashing it,
// refusing an unreadable one -- is CLI-layer I/O, exactly the shape
// `engine_identified` already gives --batch, --plan and --transcribe
// (ADR-0038). This package only renders the digest once the caller already
// has it, so a doctor pass and a Batch pass name the identical identity for
// the identical binary rather than this package hashing a second time.

import "core:fmt"
import "core:mem"
import "transcibr:artifact"

@(require_results)
render_engine_identity :: proc(digest: artifact.Digest, allocator: mem.Allocator) -> string {
	assert(
		len(digest) == artifact.DIGEST_CHARS,
		"rendered an engine identity from a partial digest",
	)
	assert(allocator.procedure != nil, "the line outlives this procedure and needs an allocator")

	line := fmt.aprintf("engine identity: %s", digest, allocator = allocator)
	assert(len(line) > 0, "an engine identity rendered as nothing at all")
	return line
}
