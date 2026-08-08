#+vet explicit-allocators
// Package audio turns one Recording into the mono 16 kHz audio the Engine
// reads, and settles -- before any of that -- how long the Recording actually is
// and whether anything is still writing it.
package audio

import "core:fmt"
import "core:mem"
import "transcibr:child"
import "transcibr:process"

// Two vocabularies: `Error` names a Recording and the Batch carries on,
// `Cache_Fault` names the scratch cache and the Batch does not start.

Cache_Fault :: enum u8 {
	None = 0,
	Path_Not_Ascii,
	Unusable,
	Not_A_Directory,
	Parent_Missing,
	// A non-empty directory transcibr did not create and cannot prove it
	// already owns: ADR-0023's #256 addendum.
	Foreign_Directory,
}

@(private)
@(require_results)
cache_fault_says :: proc(fault: Cache_Fault) -> string {
	switch fault {
	case .Path_Not_Ascii:
		return(
			"the scratch cache is under a path the Engine cannot open, because it carries a byte outside ASCII" \
		)
	case .Unusable:
		return "the scratch cache could not be created or listed"
	case .Not_A_Directory:
		return "the scratch cache path names an existing file, not a directory"
	case .Parent_Missing:
		return "the scratch cache's parent directory does not exist"
	case .Foreign_Directory:
		return(
			"the scratch cache directory is not empty and holds files transcibr did not write -- point --cache at an empty directory, or one transcibr already owns, before a sweep or an extraction can reach it" \
		)
	case .None:
	}
	return ""
}

// Free the answer with `delete` and this allocator.
//
// Issue #216, item 2: `framing` used to be absent entirely, so this always
// reported `process.batch_setup_message`'s own "the Batch cannot start" --
// the identical defect `engine_error_message` carried until #237. Defaulted
// to `process.BATCH_CANNOT_START` so every call site that does not pass one
// keeps today's exact bytes.
@(require_results)
cache_error_message :: proc(
	fault: Cache_Fault,
	cache: string,
	allocator: mem.Allocator,
	framing: string = process.BATCH_CANNOT_START,
) -> string {
	assert(fault != .None, "there is no message for a scratch cache that opened")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs an allocator",
	)

	says := cache_fault_says(fault)
	assert(len(says) > 0, "a fault was added to Cache_Fault without a sentence")

	return process.batch_setup_message(cache, says, allocator, framing)
}

Fault :: enum u8 {
	None = 0,
	Source_Unreadable,
	Planned_Reading_Unusable,
	Still_Being_Written,
	Still_Unsettled,
	Probe_Not_Started,
	Probe_Did_Not_Finish,
	// Nothing deletes the probe's answer file: ffprobe may still hold it open.
	Probe_Not_Stopped,
	// ffprobe finished and exited nonzero, before its answer was ever read.
	Probe_Refused,
	Probe_Answer_Unreadable,
	Probe_Unreadable,
	No_Audio_Stream,
	Extraction_Not_Started,
	Extraction_Did_Not_Finish,
	// The `.part` is left where it is: ffmpeg may still hold it open.
	Extraction_Not_Stopped,
	// ffmpeg finished and exited nonzero, before `check_audio` ever ran.
	Extraction_Refused,
	Audio_Unreadable,
	Audio_Malformed,
	Audio_Not_As_Asked_For,
	Durations_Disagree,
	Audio_Not_Published,
}

Error :: struct {
	fault:     Fault,
	// Only for `.Probe_Unreadable` and `.Audio_Malformed`.
	probe:     process.Probe_Fault,
	riff:      Riff_Fault,
	// Only for the two `_Not_Started` faults.
	child:     child.Error,
	// Only for `.Durations_Disagree`.
	said:      i64,
	got:       i64,
	// Only for `.Probe_Refused` and `.Extraction_Refused`: the code the child
	// itself chose to exit with.
	exit_code: u32,
}

// See CLAUDE.md, Odin notes: enumerated arrays and switches.
@(private, rodata)
FAULT := [Fault]string {
	// `.None` is the success value and the one deliberately empty row, which
	// fault_says refuses by name.
	.None                      = "",
	.Probe_Unreadable          = "its container could not be timed",
	.Audio_Malformed           = "the audio produced from it would not read",
	.Source_Unreadable         = "the Recording could not be read",
	.Planned_Reading_Unusable  = "the reading taken when the Batch planned this Recording carries no timestamp",
	.Still_Being_Written       = "the Recording is still being written to",
	.Still_Unsettled           = "the Recording could not be shown to have stopped changing",
	.Probe_Not_Started         = "ffprobe could not be started",
	.Probe_Did_Not_Finish      = "ffprobe was stopped before it finished",
	.Probe_Not_Stopped         = "ffprobe would not finish and would not stop",
	.Probe_Refused             = "ffprobe refused the Recording",
	.Probe_Answer_Unreadable   = "ffprobe left nothing readable behind",
	.No_Audio_Stream           = "the Recording carries no audio stream at all",
	.Extraction_Not_Started    = "ffmpeg could not be started",
	.Extraction_Did_Not_Finish = "ffmpeg was stopped before it finished",
	.Extraction_Not_Stopped    = "ffmpeg would not finish and would not stop",
	.Extraction_Refused        = "ffmpeg refused the Recording",
	.Audio_Unreadable          = "the audio ffmpeg was asked for is not there to read",
	.Audio_Not_As_Asked_For    = "the audio ffmpeg produced is not the mono 16 kHz it was asked for",
	.Durations_Disagree        = "the audio is not the length the Recording's container says it is",
	.Audio_Not_Published       = "the audio was produced and could not be moved into place",
}

@(private)
@(require_results)
fault_says :: proc(fault: Fault) -> string {
	assert(fault != .None, "the success value is not a fault and says nothing")

	says := FAULT[fault]
	assert(len(says) > 0, "a fault was added to Fault without a row in FAULT")
	return says
}

@(private)
@(require_results)
borrowed_message :: proc(err: Error, source: string, allocator: mem.Allocator) -> string {
	assert(
		err.fault == .Probe_Unreadable || err.fault == .Audio_Malformed,
		"a fault that borrows nobody's reason was rendered as one that does",
	)

	message: string
	if err.fault == .Probe_Unreadable {
		message = fmt.aprintf(
			"%q: %s (%s)",
			source,
			fault_says(err.fault),
			process.probe_fault_says(err.probe),
			allocator = allocator,
		)
	} else {
		message = fmt.aprintf(
			"%q: %s (%s)",
			source,
			fault_says(err.fault),
			riff_fault_says(err.riff),
			allocator = allocator,
		)
	}
	return message
}

// %q and not %s: the line reaches a user through a UTF-16 Win32 call, where a
// raw NUL cuts it off and a byte that is not UTF-8 converts the whole of it to
// nil -- and NTFS permits an unpaired surrogate in a filename. Free the answer
// with `delete` and this allocator.
//
// The `.Probe_Not_Started, .Extraction_Not_Started` arm below calls
// `child.error_message(err.child, allocator)` unconditionally, relying on
// `err.child.fault != .None` for both -- but the two arms reach that
// guarantee through different paths. `produce`'s extraction call goes
// straight through `child.run_bounded` (src/audio/run.odin's `produce`),
// which has exactly one return site for `.Not_Started` (src/child/run.odin),
// pinned guard-side by src/child/run_test.odin's
// a_child_that_will_not_start_is_reported_rather_than_asserted (issue #208).
// `probe_using`'s call goes through its injectable `run: Probe_Run`
// parameter (src/audio/run.odin's `probe_using`, issue #125's round-4 seam)
// instead -- `child.run_bounded`'s own guard test cannot see that arm,
// because it never calls through `probe_using` at all. `probe`'s only
// production wiring (src/audio/run.odin's `probe`) always passes
// `run_probe_child`, itself a plain
// forward into `child.run_bounded`, so production inherits the same
// guarantee; that specific path is what
// src/audio/run_test.odin's a_probe_that_will_not_start_carries_a_child_fault_through_its_real_wiring
// pins guard-side (issue #223's fix round 2). A test that swaps in a
// different `Probe_Run` stub is not covered by either guard test and must
// supply a real `child.Error` itself, the same way
// stub_unstoppable_probe_run supplies a real `child.Run` ending.
@(require_results)
error_message :: proc(err: Error, source: string, allocator: mem.Allocator) -> string {
	assert(err.fault != .None, "there is no message for a Recording that came through")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs an allocator",
	)

	message: string
	switch err.fault {
	case .Probe_Unreadable, .Audio_Malformed:
		message = borrowed_message(err, source, allocator)
	case .Durations_Disagree:
		message = fmt.aprintf(
			"%q: %s -- %d ms against %d ms",
			source,
			fault_says(err.fault),
			err.said,
			err.got,
			allocator = allocator,
		)
	case .Probe_Not_Started, .Extraction_Not_Started:
		reason := child.error_message(err.child, allocator)
		defer delete(reason, allocator)
		message = fmt.aprintf(
			"%q: %s (%s)",
			source,
			fault_says(err.fault),
			reason,
			allocator = allocator,
		)
	case .Probe_Refused, .Extraction_Refused:
		message = fmt.aprintf(
			"%q: %s (exit code %d)",
			source,
			fault_says(err.fault),
			err.exit_code,
			allocator = allocator,
		)
	case .None,
	     .Source_Unreadable,
	     .Planned_Reading_Unusable,
	     .Still_Being_Written,
	     .Still_Unsettled,
	     .Probe_Did_Not_Finish,
	     .Probe_Not_Stopped,
	     .Probe_Answer_Unreadable,
	     .No_Audio_Stream,
	     .Extraction_Did_Not_Finish,
	     .Extraction_Not_Stopped,
	     .Audio_Unreadable,
	     .Audio_Not_As_Asked_For,
	     .Audio_Not_Published:
		message = fmt.aprintf("%q: %s", source, fault_says(err.fault), allocator = allocator)
	}
	return process.refusal_line(message)
}
