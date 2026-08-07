#+vet explicit-allocators
package main

import "transcibr:artifact"
import "transcibr:pipeline"

// Fix round 1 (PR #245's review, finding 3): `plan.odin` and `transcribe.odin`
// each carried their own copy of this proc, differing only in which framing
// constant they closed over -- the third and fourth copies of the #237
// doctor shape, in the same package as the original two. One helper, its
// framing taken as a parameter, replaces both; `main.odin` and `doctor.odin`
// stay untouched (fenced under #75-s5b) so this lives beside its two callers
// instead of folding into either's own fenced sibling.
@(private)
@(require_results)
engine_identified_framed :: proc(
	path: string,
	framing: string,
) -> (
	identified: artifact.Digest,
	ok: bool,
) {
	assert(len(path) > 0, "there is no Engine here to identify")
	assert(len(framing) > 0, "an Engine refusal framing must name who is asking")

	unidentified: artifact.Engine_Fault
	identified, unidentified = artifact.identify_engine(path, context.allocator)
	if unidentified == .None {
		return identified, true
	}

	message := artifact.engine_error_message(unidentified, path, context.allocator, framing)
	assert(len(message) > 0, "an Engine was refused and nothing said why")
	pipeline.report_fault(message, context.allocator)
	return identified, false
}
