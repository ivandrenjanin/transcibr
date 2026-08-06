#+vet explicit-allocators
// Package engine runs the Engine over one Recording's audio, reports how far it
// has got while it runs, and answers with what it left in the scratch cache.
package engine

import "core:fmt"
import "core:mem"
import "transcibr:child"
import "transcibr:process"

Tools :: struct {
	engine: string,
}

Job :: struct {
	// Mono 16 kHz, as `transcibr:audio` produces.
	audio:        string,
	// ASCII-only, and not this package's rule to check: `transcibr:audio`'s
	// `open_cache` answers it once for the whole cache.
	cache:        string,
	name:         string,
	model:        string,
	container_ms: i64,
	// Empty means no `--prompt` flag at all; see `process.Engine_Job.prompt`.
	prompt:       string,
}

Transcribed :: struct {
	// Owned by the caller and freed with `delete` and the allocator handed in.
	output:      string,
	duration_ms: i64,
	// Wall-clock time the Engine actually ran, measured by transcibr:child's
	// own clock (`child.Run_Callbacks.on_end`'s `elapsed_ns`) -- never the
	// Engine's own reported audio duration, which is what `duration_ms` above
	// holds. A realtime factor divides the Recording's audio length by THIS
	// field, not by `duration_ms`.
	elapsed_ms:  i64,
}

Limits :: struct {
	watch:    process.Watch,
	// Zero is the Recording's own bound, process.transcribe_bound_ms of its
	// length, which is what the shipped program runs.
	bound_ms: i64,
}

DEFAULT_LIMITS :: Limits {
	watch = process.DEFAULT_WATCH,
}

Report :: struct {
	on_progress: proc(shown: process.Progress, user: rawptr),
	user:        rawptr,
}

// Why a bare enumeration with one renderer and not a fault table: CLAUDE.md's
// Odin notes (issue #33).
Fault :: enum u8 {
	None = 0,
	// Why this is refused before the child starts, and per-Recording: ADR-0025.
	Path_Not_Ascii,
	Not_Started,
	Did_Not_Finish,
	Went_Silent,
	// The Engine may still be running and may still hold its output file open,
	// so nothing here touches that file.
	Not_Stopped,
	No_Output,
	Output_Empty,
}

Error :: struct {
	fault: Fault,
	// Only for `.Not_Started`.
	child: child.Error,
}

@(private)
@(require_results)
fault_says :: proc(fault: Fault) -> string {
	switch fault {
	case .Path_Not_Ascii:
		return(
			"one of the paths this Recording would have handed the Engine carries a byte outside ASCII, which the Engine cannot open" \
		)
	case .Not_Started:
		return "the Engine could not be started"
	case .Did_Not_Finish:
		return "the Engine was stopped before it finished"
	case .Went_Silent:
		return "the Engine stopped producing any output at all and was stopped"
	case .Not_Stopped:
		return "the Engine would not finish and would not stop"
	case .No_Output:
		return "the Engine left no output at all, whatever it exited with"
	case .Output_Empty:
		return "the Engine left an empty output file"
	case .None:
	}
	return ""
}

// The path is printed with %q and not %s: a refusal reaches a user through a
// UTF-16 Win32 call, and a byte that is not UTF-8 -- which NTFS permits in a
// filename -- makes the whole line convert to nil.
@(require_results)
error_message :: proc(err: Error, source: string, allocator: mem.Allocator) -> string {
	assert(err.fault != .None, "there is no message for a Recording that came through")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs a chosen allocator",
	)

	says := fault_says(err.fault)
	assert(len(says) > 0, "a fault was added to Fault without a sentence")
	if err.fault == .Not_Started {
		assert(err.child.fault != .None, "an Engine that would not start named no reason")
	}

	message: string
	if err.fault == .Not_Started {
		reason := child.error_message(err.child, allocator)
		defer delete(reason, allocator)
		message = fmt.aprintf("%q: %s (%s)", source, says, reason, allocator = allocator)
	} else {
		message = fmt.aprintf("%q: %s", source, says, allocator = allocator)
	}
	assert(len(message) > 0, "a refusal rendered as nothing at all")
	return message
}
