#+vet explicit-allocators
package artifact

import "core:fmt"
import "core:mem"
import "core:os"
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
	fault: Fault,
	which: Artifact,
	// The name inside it is borrowed from the caller's own spelling of the Engine's
	// output, so the message is rendered while that string is still alive.
	parse: transcript.Parse_Error,
}

// The Names come back whichever way this ends, except where the Recording's own
// path names no file; free them with destroy_names and the same allocator.
//
// Why the whole record is validated before the first artifact lands: ADR-0024.
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

	names, namable := names_of(source, allocator)
	if !namable {
		return {}, Error{fault = .Named_No_File}
	}

	if !recordable(made) {
		return names, Error{fault = .Not_Recordable}
	}

	json_bytes, unreadable := os.read_entire_file_from_path(output, allocator)
	if unreadable != nil {
		return names, Error{fault = .Output_Unreadable}
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
	case .None, .Named_No_File, .Not_Recordable, .Output_Unreadable:
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
