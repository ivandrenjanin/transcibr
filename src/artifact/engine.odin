#+vet explicit-allocators
package artifact

import "core:mem"
import "core:os"
import "transcibr:child"
import "transcibr:process"

// Identifying the Engine the way the Model already is: ADR-0027's reopening
// clause, closed by issue #50. `digest_of_bounded` (model.odin) is the one
// hasher this package owns, and this calls it rather than growing a second
// one -- nothing here re-reads a file or re-drives a thread.
//
// No ASCII check here, unlike `identify_model`: that check exists because a
// MODEL path is later handed to the Engine's own ANSI-mangled argv
// (ADR-0025), and the Engine binary's own path is never handed to itself
// that way -- it is what `CreateProcessW` spawns, which takes it as UTF-16.

Engine_Fault :: enum u8 {
	None = 0,
	Unreadable,
	Did_Not_Finish,
	Not_Started,
}

@(require_results)
identify_engine :: proc(
	engine_exe: string,
	allocator: mem.Allocator,
) -> (
	digest: Digest,
	fault: Engine_Fault,
) {
	assert(len(engine_exe) > 0, "there is no Engine binary here to identify")
	assert(
		allocator.procedure != nil,
		"the identity outlives this procedure and needs an allocator",
	)
	defer if fault != .None {
		assert(len(digest) == 0, "refused an Engine binary and identified it anyway")
	} else {
		assert(len(digest) == DIGEST_CHARS, "identified an Engine binary by a partial digest")
	}

	resolved, unresolvable := os.get_absolute_path(engine_exe, allocator)
	if unresolvable != nil {
		return "", .Unreadable
	}
	defer delete(resolved, allocator)

	hashed, _, model_fault := digest_of_bounded(resolved, MODEL_READ_BOUND_MS, allocator)
	fault = engine_fault_of(model_fault)
	if fault != .None {
		return "", fault
	}
	return hashed, .None
}

// `digest_of_bounded` never refuses a path for its own script -- that check
// runs ahead of it in `identify_model`, never inside it -- so its own fault
// vocabulary never actually reports `.Path_Not_Ascii`; this switch stays
// exhaustive over `Model_Fault` anyway so a member added there fails the
// build here rather than growing a silent fifth case (issue #33).
@(private)
@(require_results)
engine_fault_of :: proc(fault: Model_Fault) -> Engine_Fault {
	switch fault {
	case .None:
		return .None
	case .Unreadable:
		return .Unreadable
	case .Did_Not_Finish:
		return .Did_Not_Finish
	case .Not_Started:
		return .Not_Started
	case .Path_Not_Ascii:
		unreachable()
	}
	unreachable()
}

@(private)
@(require_results)
engine_fault_says :: proc(fault: Engine_Fault) -> string {
	switch fault {
	case .Unreadable:
		return "the Engine binary could not be read"
	case .Did_Not_Finish:
		return child.DID_NOT_FINISH_SAYS
	case .Not_Started:
		return "a thread to hash it on could not be started"
	case .None:
	}
	return ""
}

// %q because a refusal reaches a user through a UTF-16 Win32 call, the same
// reason `model_error_message` carries it: CLAUDE.md, Odin notes.
//
// Issue #216: `framing` used to be absent entirely, so this always reported
// `process.batch_setup_message`'s own "the Batch cannot start" -- a lie for
// every non-Batch caller (`--doctor`, and until their fenced files migrate,
// `--plan` and `--transcribe`). Defaulted to `process.BATCH_CANNOT_START` so
// every call site that does not pass one keeps today's exact bytes.
@(require_results)
engine_error_message :: proc(
	fault: Engine_Fault,
	engine_exe: string,
	allocator: mem.Allocator,
	framing: string = process.BATCH_CANNOT_START,
) -> string {
	assert(fault != .None, "there is no message for an Engine that was identified")
	assert(len(engine_exe) > 0, "a refusal must name the Engine binary it is reported against")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs an allocator",
	)

	says := engine_fault_says(fault)
	assert(len(says) > 0, "a fault was added to Engine_Fault without a sentence")

	return process.batch_setup_message(engine_exe, says, allocator, framing)
}
