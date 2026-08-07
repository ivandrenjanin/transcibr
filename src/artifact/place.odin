#+vet explicit-allocators
package artifact

import "core:fmt"
import "core:mem"
import "core:os"
import "transcibr:child"
import "transcibr:transcript"

Artifact :: enum u8 {
	Transcript = 0,
	Engine_Output,
	Sidecar,
}

Fault :: enum u8 {
	None = 0,
	Named_No_File,
	Not_Recordable,
	Output_Unreadable,
	Output_Quarantined,
	Output_Not_Quarantined,
	Nothing_Transcribed,
	Not_Written,
	Not_Placed,
}

Error :: struct {
	fault:  Fault,
	which:  Artifact,
	// The name inside it is borrowed from the caller's own spelling of the Engine's
	// output, so the message is rendered while that string is still alive.
	parse:  transcript.Parse_Error,
	// Only meaningful when fault == .Output_Unreadable. A share wedged for
	// child.READ_BOUND_MS and a file Windows can no longer find both collapsed
	// into this one Fault until issue #27's PR review found it: an operator
	// deciding between retrying and re-running a Recording needs to know
	// which one happened, and this is where that distinction is carried.
	read:   child.Read_Error,
	// Only meaningful when fault == .Output_Unreadable, and borrowed the same
	// way `parse` is: `complete`'s own `output` argument, alive while the
	// message is rendered. `error_message` used to render this fault against
	// `source` instead -- the Recording, which `complete` never opens or
	// reads at all -- naming a file that was never the one that failed
	// rather than the Engine's own output, the path this fault is actually
	// about (PR #64's second review, finding 5).
	output: string,
}

// The Names come back whichever way this ends, except where the Recording's own
// path names no file; free them with destroy_names and the same allocator.
//
// Why the whole record is validated before the first artifact lands: ADR-0024.
//
// Reading `output` is bounded even though it is a path this program built
// from the Recording's own stem and never one it discovered: a Recording
// named exactly a reserved Windows device cannot exist, since Win32 refuses
// to create one, but the read still has to survive a stalled network share
// or scratch cache the same way a hand-typed `--from-json` path does. Issue
// #27; the ceiling itself is `child.READ_BOUND_MS`.
@(require_results)
complete :: proc(
	source: string,
	output: string,
	duration: Maybe(transcript.Millis),
	rc: transcript.Render_Context,
	made: Sidecar,
	allocator: mem.Allocator,
) -> (
	placed: Names,
	err: Error,
) {
	assert(len(source) > 0, "there is no Recording here to place artifacts beside")
	assert(len(output) > 0, "there is no Engine output here to make a Transcript from")
	assert(
		allocator.procedure != nil,
		"the artifacts outlive this procedure and need an allocator",
	)
	assert(
		len(rc.language) == 0,
		"the language is read out of the Engine's own output here and is not the caller's to supply",
	)
	assert_filled_in(made)
	assert_agree(duration, rc, made)

	names, namable := names_of(source, allocator)
	if !namable {
		return {}, Error{fault = .Named_No_File}
	}

	if !recordable(made) {
		return names, Error{fault = .Not_Recordable}
	}

	json_bytes, unreadable := child.read_bounded(output, child.READ_BOUND_MS, allocator)
	if unreadable.fault != .None {
		return names, Error{fault = .Output_Unreadable, read = unreadable, output = output}
	}
	defer delete(json_bytes, allocator)

	return names, rendered_and_placed(
		names,
		output,
		string(json_bytes),
		duration,
		rc,
		made,
		allocator,
	)
}

// The front matter (`rc`) and the Sidecar (`made`) are assembled at two
// separate call sites and read by two different consumers -- a person
// reading the Transcript's header, and `artifact.changed` deciding whether
// to resume. Nothing else in this program checks that the two agree; this
// is the one place both records are in hand together. Every comparison here
// is over values this program itself assembled, never anything read
// straight from a file, a child process, or the command line (A8).
@(private)
assert_agree :: proc(
	duration: Maybe(transcript.Millis),
	rc: transcript.Render_Context,
	made: Sidecar,
) {
	assert(
		rc.engine_version == engine_display_name(made.engine),
		"the Transcript's header and its Sidecar name two different Engines",
	)
	assert(
		transcript.profile_name(rc.profile) == made.merge_profile,
		"the Transcript's header and its Sidecar name two different Merge Profiles",
	)
	assert(
		rc.model == model_display_name(made.model),
		"the Transcript's header and its Sidecar name two different Models",
	)
	if ms, given := duration.?; given {
		assert(
			i64(ms) == made.container_ms,
			"the duration passed to place this Transcript disagrees with its own Sidecar",
		)
	}
}

@(private)
@(require_results)
rendered_and_placed :: proc(
	names: Names,
	output: string,
	json_text: string,
	duration: Maybe(transcript.Millis),
	rc: transcript.Render_Context,
	made: Sidecar,
	allocator: mem.Allocator,
) -> Error {
	rendered := rc
	rendered.language = transcript.parse_language(json_text, allocator)
	defer delete(rendered.language, allocator)

	markdown, parse_err := transcript.render_transcript(
		output,
		json_text,
		duration,
		rendered,
		allocator,
	)
	defer delete(markdown, allocator)
	if parse_err.fault != .None {
		return disposed_of(output, parse_err, allocator)
	}

	return placed_in_order(names, transmute([]u8)json_text, markdown, made, allocator)
}

// Why output that will not parse is quarantined and re-run, while output that
// parsed and said nothing fails the Recording: ADR-0002. Why a quarantine that
// Windows refuses is reported under a fault of its own rather than as the move
// that did not happen: ADR-0024. `Shorten_And_Replan` and `Unset` never reach
// here -- a Parse_Fault's row in transcript's own FAULT table never names either
// one -- and both stay in this switch only because process.Disposition is shared
// with a package (`process` itself) that does produce `Shorten_And_Replan`; each
// is named explicitly below rather than left for the trailing unreachable(), so
// the impossibility is stated where it holds (ADR-0030).
@(private)
@(require_results)
disposed_of :: proc(
	output: string,
	parse_err: transcript.Parse_Error,
	allocator: mem.Allocator,
) -> Error {
	assert(parse_err.fault != .None, "a parse that came through was disposed of as a failure")

	switch transcript.disposition_of(parse_err.fault) {
	case .Quarantine_And_Rerun:
		if !quarantine(output, allocator) {
			return Error{fault = .Output_Not_Quarantined, parse = parse_err}
		}
		return Error{fault = .Output_Quarantined, parse = parse_err}
	case .Fail_The_Recording:
		return Error{fault = .Nothing_Transcribed, parse = parse_err}
	case .Shorten_And_Replan, .Unset:
		unreachable()
	}
	unreachable()
}

@(private)
@(require_results)
placed_in_order :: proc(
	names: Names,
	json_bytes: []u8,
	markdown: string,
	made: Sidecar,
	allocator: mem.Allocator,
) -> Error {
	assert(len(markdown) > 0, "a Transcript of nothing at all reached the placement")

	if err := publish(names, .Engine_Output, json_bytes, allocator); err.fault != .None {
		return err
	}
	if err := publish(names, .Transcript, transmute([]u8)markdown, allocator); err.fault != .None {
		return err
	}

	text := sidecar_text(made, allocator)
	defer delete(text, allocator)
	return publish(names, .Sidecar, transmute([]u8)text, allocator)
}

// Why the temporary name sits beside the destination, and which MoveFileExW
// flags `core:os` passes to make the rename atomic and replacing: ADR-0024.
@(require_results)
publish :: proc(
	names: Names,
	which: Artifact,
	bytes: []u8,
	allocator: mem.Allocator,
) -> (
	err: Error,
) {
	destination := names[which]
	assert(len(destination) > 0, "there is nowhere here to publish an artifact to")
	assert(allocator.procedure != nil, "a temporary name needs an allocator to be built in")

	part := part_of(destination, os.get_pid(), allocator)
	defer delete(part, allocator)
	defer if err.fault != .None {
		os.remove(part)
	}

	if !wrote(part, bytes) {
		return Error{fault = .Not_Written, which = which}
	}
	if os.rename(part, destination) != nil {
		return Error{fault = .Not_Placed, which = which}
	}
	return Error{}
}

// Why the bytes are flushed before publish renames onto the final name: ADR-0024.
@(private)
@(require_results)
wrote :: proc(path: string, bytes: []u8) -> bool {
	assert(len(path) > 0, "there is nowhere here to write an artifact")

	handle, unopenable := os.open(path, {.Write, .Create, .Trunc})
	if unopenable != nil {
		return false
	}
	if written, unwritable := os.write(handle, bytes); unwritable != nil || written != len(bytes) {
		os.close(handle)
		return false
	}
	if os.sync(handle) != nil {
		os.close(handle)
		return false
	}
	return os.close(handle) == nil
}

@(require_results)
quarantine :: proc(path: string, allocator: mem.Allocator) -> bool {
	assert(len(path) > 0, "there is nothing here to move aside")
	assert(allocator.procedure != nil, "a quarantine name needs an allocator to be built in")

	aside := quarantined(path, allocator)
	defer delete(aside, allocator)
	return os.rename(path, aside) == nil
}

@(private)
@(require_results)
fault_says :: proc(fault: Fault) -> string {
	switch fault {
	case .Named_No_File:
		return "it names no file to make artifacts from"
	case .Not_Recordable:
		return "the filesystem dates it before 1970, and no Sidecar can record a moment below zero"
	case .Output_Unreadable:
		return "what the Engine left could not be read back"
	case .Output_Quarantined:
		return(
			"what the Engine left is not what the Engine writes; it has been moved aside and this Recording will be done again from the start" \
		)
	case .Output_Not_Quarantined:
		return(
			"what the Engine left is not what the Engine writes; it could not be moved aside, and this Recording will be done again from the start over the top of it" \
		)
	case .Nothing_Transcribed:
		return "the Engine transcribed nothing that could be made into a Transcript"
	case .Not_Written:
		return "could not be written"
	case .Not_Placed:
		return "was written and could not be moved into place"
	case .None:
	}
	return ""
}

@(private)
@(require_results)
artifact_says :: proc(which: Artifact) -> string {
	switch which {
	case .Transcript:
		return "its Transcript"
	case .Engine_Output:
		return "its retained Engine output"
	case .Sidecar:
		return "its Sidecar"
	}
	return ""
}

// %q on the path: a refusal reaches a user through a UTF-16 Win32 call, where a
// raw NUL cuts the line off and a byte that is not UTF-8 converts it all to nil.
//
// The line outlives this procedure; free it with delete and the same allocator.
@(require_results)
error_message :: proc(err: Error, source: string, allocator: mem.Allocator) -> string {
	assert(err.fault != .None, "there is no message for a Recording that came through")
	assert(len(source) > 0, "a refusal must name the Recording it is reported against")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs an allocator",
	)

	says := fault_says(err.fault)
	assert(len(says) > 0, "a fault was added to Fault without a sentence")

	message: string
	switch err.fault {
	case .Not_Written, .Not_Placed:
		which := artifact_says(err.which)
		assert(len(which) > 0, "an artifact was added to Artifact without a name")
		message = fmt.aprintf("%q: %s %s", source, which, says, allocator = allocator)
	case .Output_Quarantined, .Output_Not_Quarantined, .Nothing_Transcribed:
		message = borrowed_message(err, source, says, allocator)
	case .Output_Unreadable:
		assert(
			err.read.fault != .None,
			"an unreadable Engine output carries no read fault to explain it",
		)
		assert(
			len(err.output) > 0,
			"an unreadable Engine output carries no path to the output that failed",
		)
		message = child.read_error_message(err.read, err.output, allocator)
	case .None, .Named_No_File, .Not_Recordable:
		message = fmt.aprintf("%q: %s", source, says, allocator = allocator)
	}
	assert(len(message) > 0, "a refusal rendered as nothing at all")
	return message
}

@(private)
@(require_results)
borrowed_message :: proc(
	err: Error,
	source: string,
	says: string,
	allocator: mem.Allocator,
) -> string {
	assert(err.parse.fault != .None, "a Recording refused for its output named no reason")

	reason := transcript.error_message(err.parse, allocator)
	defer delete(reason, allocator)
	return fmt.aprintf("%q: %s (%s)", source, says, reason, allocator = allocator)
}
