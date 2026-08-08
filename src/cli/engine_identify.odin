#+vet explicit-allocators
package main

import "transcibr:artifact"
import "transcibr:pipeline"

// Fix round 1 (PR #245's review, finding 3): `plan.odin` and `transcribe.odin`
// each carried their own copy of this proc, differing only in which framing
// constant they closed over -- the third and fourth copies of the #237
// doctor shape, in the same package as the original two. One helper, its
// framing taken as a parameter, replaces both. Issue #249 item 4 later moved
// `doctor.odin` and `batch.odin` onto this same helper once the #75-s5b
// fence lifted, so it is now the one place in the package that identifies an
// Engine at all.
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
	pipeline.report_fault(pipeline.FAULT_OBSERVER, .Failed, -1, message, context.allocator)
	return identified, false
}

// Fix round 2 (PR #245's review): `plan.odin` and `transcribe.odin` still
// called `main.odin`'s shared, unparametrized `model_identified` for their
// Model refusal, which -- like the Engine refusal above before round 1 --
// always reported `artifact.model_error_message`'s own default framing,
// `process.BATCH_CANNOT_START`. Issue #216's headline defect, live on both
// commands the ticket titles. Same shape as `engine_identified_framed`
// above, and the same later convergence: issue #249 item 4 moved
// `doctor.odin` and `batch.odin` onto this one procedure too, so
// `main.odin` carries no Model wrapper of its own any more either.
@(private)
@(require_results)
model_identified_framed :: proc(
	path: string,
	framing: string,
) -> (
	identified: artifact.Model,
	ok: bool,
) {
	assert(len(path) > 0, "there is no Model here to identify")
	assert(len(framing) > 0, "a Model refusal framing must name who is asking")

	unidentified: artifact.Model_Fault
	identified, unidentified = artifact.identify_model(path, context.allocator)
	if unidentified == .None {
		return identified, true
	}

	message := artifact.model_error_message(unidentified, path, context.allocator, framing)
	assert(len(message) > 0, "a Model was refused and nothing said why")
	pipeline.report_fault(pipeline.FAULT_OBSERVER, .Failed, -1, message, context.allocator)
	return identified, false
}
