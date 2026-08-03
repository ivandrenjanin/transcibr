package transcript

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"

// What was wrong with a piece of Engine output.
//
// Every one of these is an OPERATING error (CLAUDE.md A8): the Engine is
// outside this program, and nothing outside may crash it. ADR-0002 settles what
// happens next -- output that will not parse is treated as *absent*, quarantined
// and re-run, never reported as a permanent failure.
Parse_Fault :: enum u8 {
	None = 0,
	Empty_Input,
	Malformed_Json,
	Not_An_Object,
	No_Transcription,
	No_Cues,
	Cue_Not_An_Object,
	No_Offsets,
	Offset_Missing,
	Offset_Not_A_Number,
	Offset_Not_Whole,
	Offset_Out_Of_Range,
	No_Text,
	Negative_Offset,
	Cue_Ends_Before_It_Starts,
	Cues_Out_Of_Order,
}

// One rejected piece of Engine output, named against the input that carried it.
//
// The name is borrowed, never owned: it is the caller's spelling of the file,
// and it lives at least as long as the report.
Parse_Error :: struct {
	fault:     Parse_Fault,
	json_name: string,
	// The 1-based position of the offending Cue, or 0 when the fault is about
	// the input as a whole.
	cue:       int,
}

// Parses the Engine's JSON into Cues.
//
// `json_name` is what to report an operating error against -- the path the
// Engine wrote, as the caller spells it. `recording_duration` is what the shell
// probed off the container (ADR-0009).
//
// The allocator is explicit and never defaulted: the Cue set outlives this
// procedure and crosses a worker boundary (ADR-0010). Free it with
// destroy_cues, passing the same allocator.
parse_cues :: proc(
	json_name: string,
	json_text: string,
	recording_duration: Millis,
	allocator: mem.Allocator,
) -> (
	cues: []Cue,
	err: Parse_Error,
) {
	assert(len(json_name) > 0, "the input must be named; a report nobody can locate is not a report")
	assert(recording_duration >= 0, "a negative recording duration is a probe defect, not engine output")
	assert(allocator.procedure != nil, "the cue set outlives this procedure and needs a chosen allocator")

	// A zero-byte file and a file the Engine opened and never wrote to are one
	// operating error, and neither is malformed json worth a word about syntax.
	if len(strings.trim_space(json_text)) == 0 {
		return nil, fault_at(.Empty_Input, json_name, 0)
	}

	// The decoded tree is scratch: it dies in this procedure and the Cue text
	// below is cloned out of it. It gets an arena of its own because
	// core:encoding/json LEAKS on several of its error paths -- an object key
	// parsed just before the value after it fails is never inserted into the
	// object, so the parser's own cleanup, which walks that object, never sees
	// it. Truncated Engine output takes exactly that path, and truncated output
	// is the case ADR-0002 exists for, not a rarity. An arena settles it: no
	// individual free happens here and everything goes back at once.
	//
	// Blocks come from the caller's allocator and never from
	// `context.temp_allocator`, which is thread-local and belongs to whichever
	// worker happens to be running this (ADR-0010).
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, block_allocator = allocator, array_allocator = allocator)
	defer mem.dynamic_arena_destroy(&scratch)

	// `.JSON` rather than the package default of JSON5, and `parse_integers`
	// stated rather than left at its default of false -- see read_millis for
	// what that default costs. The Engine writes strict JSON, so a trailing
	// comma or a comment means this is not what the Engine wrote, and ADR-0002
	// wants that quarantined rather than guessed at.
	root, decode_err := json.parse(json_text, .JSON, true, mem.dynamic_arena_allocator(&scratch))
	if decode_err != nil {
		return nil, fault_at(.Malformed_Json, json_name, 0)
	}

	entries, locate_fault := read_transcription(root)
	if locate_fault != .None {
		return nil, fault_at(locate_fault, json_name, 0)
	}

	built, read_fault, at := read_cues(entries, allocator)
	if read_fault != .None {
		assert(built == nil, "read_cues kept a cue set it also reported a fault for")
		return nil, fault_at(read_fault, json_name, at)
	}

	// The parser's own promise, asserted where it is made; every consumer
	// asserts the same on the way in (CLAUDE.md A4). Nothing external reaches
	// these -- read_cues has already rejected, as an operating error, everything
	// the Engine could have written that breaks them.
	assert(len(built) > 0, "returned an empty cue set without reporting No_Cues")
	assert(cues_are_ordered(built), "returned a cue set that is not ordered")
	return built, Parse_Error{}
}

// Locates the array of Cues inside the Engine's top-level object.
//
// Every other key the Engine writes -- `systeminfo`, `model`, `params`,
// `result` -- is ignored here, and so is any key a later Engine release adds.
// Rejecting an unrecognised field would make an Engine upgrade look like a
// corrupt Transcript.
//
// Leaf lookups over external data; parse_cues carries the assertions (A1, A8).
@(private)
read_transcription :: proc(root: json.Value) -> (json.Array, Parse_Fault) {
	body, is_object := root.(json.Object)
	if !is_object {
		return nil, .Not_An_Object
	}
	listed, present := body["transcription"]
	if !present {
		return nil, .No_Transcription
	}
	entries, is_array := listed.(json.Array)
	if !is_array {
		return nil, .No_Transcription
	}
	if len(entries) == 0 {
		return nil, .No_Cues
	}
	return entries, .None
}

// Reads every entry into a Cue, checking the ordering as it goes so that a
// caller holding a successful return holds an ordered set.
//
// Returns the 1-based position of the offending Cue alongside the fault, and
// nothing else: a partially built set is freed here rather than handed out, so
// there is never a half-owned Cue set for a caller to leak.
@(private)
read_cues :: proc(
	entries: json.Array,
	allocator: mem.Allocator,
) -> (
	cues: []Cue,
	fault: Parse_Fault,
	at: int,
) {
	assert(len(entries) > 0, "an empty transcription array is No_Cues, settled before this point")
	assert(allocator.procedure != nil, "a cue's text outlives this procedure")

	built := make([]Cue, len(entries), allocator)
	filled := 0
	handed_over := false
	defer if !handed_over {
		for i in 0 ..< filled {
			delete(built[i].text, allocator)
		}
		delete(built, allocator)
	}

	for entry, i in entries {
		cue, cue_fault := read_cue(entry, allocator)
		if cue_fault != .None {
			return nil, cue_fault, i + 1
		}
		built[i] = cue
		filled = i + 1

		order_fault := cue_follows(cue, built[:i])
		if order_fault != .None {
			return nil, order_fault, i + 1
		}
	}

	handed_over = true
	assert(filled == len(built), "left a cue unread without reporting a fault")
	assert(cues_are_ordered(built), "built a cue set the per-cue checks should have rejected")
	return built, .None, 0
}

// Whether a Cue may follow the ones already built, and why not if it may not.
//
// The write side of the ordering cues_are_ordered checks on the read side
// (CLAUDE.md A4), stated per Cue so the report can name which one. Leaf
// comparison over external data; read_cues carries the assertions (A8).
@(private)
cue_follows :: proc(cue: Cue, built: []Cue) -> Parse_Fault {
	if cue.start < 0 {
		return .Negative_Offset
	}
	if cue.end < cue.start {
		return .Cue_Ends_Before_It_Starts
	}
	if len(built) > 0 && cue.start < built[len(built) - 1].start {
		return .Cues_Out_Of_Order
	}
	return .None
}

// Reads one entry of the `transcription` array into a Cue.
@(private)
read_cue :: proc(entry: json.Value, allocator: mem.Allocator) -> (cue: Cue, fault: Parse_Fault) {
	assert(allocator.procedure != nil, "a cue's text outlives this procedure")

	fields, is_object := entry.(json.Object)
	if !is_object {
		return Cue{}, .Cue_Not_An_Object
	}

	offsets_value, has_offsets := fields["offsets"]
	if !has_offsets {
		return Cue{}, .No_Offsets
	}
	offsets, offsets_is_object := offsets_value.(json.Object)
	if !offsets_is_object {
		return Cue{}, .No_Offsets
	}

	start, start_fault := read_millis(offsets, "from")
	if start_fault != .None {
		return Cue{}, start_fault
	}
	end, end_fault := read_millis(offsets, "to")
	if end_fault != .None {
		return Cue{}, end_fault
	}

	text_value, has_text := fields["text"]
	if !has_text {
		return Cue{}, .No_Text
	}
	text, text_is_string := text_value.(json.String)
	if !text_is_string {
		return Cue{}, .No_Text
	}

	// The Engine's escaping is already undone by the decode; this is the copy
	// that outlives the json tree parse_cues destroys on the way out.
	cue = Cue{start = start, end = end, text = strings.clone(text, allocator)}
	assert(len(cue.text) == len(text), "the clone lost bytes the engine wrote")
	return cue, .None
}

// The widest offset this parser will read, either sign: 2^53 milliseconds, the
// largest integer an f64 still represents exactly. Past it a JSON float has
// already lost the value it was written with, so converting is guessing.
@(private)
READABLE_MS_LIMIT :: f64(1 << 53)

// Reads one whole-millisecond offset out of a Cue's `offsets` object.
//
// THE TRAP THIS PROCEDURE EXISTS FOR. `core:encoding/json` decodes every number
// as a `json.Float` unless `parse_integers` is passed true, and it defaults to
// FALSE. So the obvious `value.(json.Integer)` matches nothing at all on real
// Engine output; every offset falls back to zero; and the ordering check still
// passes on the way out, because a set of zeroes is perfectly monotonic. What
// ships is a Transcript with every Cue at 00:00 and not one diagnostic
// anywhere -- which is why parse_cues also refuses a Cue set whose final offset
// is zero over a Recording that is not.
//
// Both number forms are accepted here AND parse_cues passes `parse_integers`:
// the flag on its own is one brace, not a belt. The tokenizer classifies on the
// decimal point, so `4380.0` stays a Float under that flag and would start
// reading as zero the day an Engine release writes it that way.
@(private)
read_millis :: proc(offsets: json.Object, key: string) -> (Millis, Parse_Fault) {
	assert(len(key) > 0, "an offset is read by name; the empty key is a caller defect")

	value, present := offsets[key]
	if !present {
		return 0, .Offset_Missing
	}

	#partial switch number in value {
	case json.Integer:
		return Millis(number), .None
	case json.Float:
		if number != math.trunc(number) {
			return 0, .Offset_Not_Whole
		}
		if number < -READABLE_MS_LIMIT || number > READABLE_MS_LIMIT {
			return 0, .Offset_Out_Of_Range
		}
		converted := Millis(number)
		assert(f64(converted) == number, "a whole in-range offset did not survive the conversion")
		return converted, .None
	}
	return 0, .Offset_Not_A_Number
}

// What each fault reads as, without the input's name or the Cue's position --
// error_message supplies those, so no entry here can forget to.
//
// An enumerated array rather than a switch: adding a Parse_Fault without a
// sentence for it leaves an empty string here, which the assertion in
// error_message catches on the first report rather than shipping a diagnostic
// that says nothing.
@(private, rodata)
FAULT_TEXT := [Parse_Fault]string {
	.None                      = "",
	.Empty_Input               = "the engine wrote nothing",
	.Malformed_Json            = "not valid json; the file is truncated or was not written by the engine",
	.Not_An_Object             = "valid json, but not the object the engine writes",
	.No_Transcription          = "no `transcription` array",
	.No_Cues                   = "the `transcription` array is empty; the engine transcribed nothing",
	.Cue_Not_An_Object         = "is not an object",
	.No_Offsets                = "has no `offsets` object",
	.Offset_Missing            = "is missing one of its `from`/`to` offsets",
	.Offset_Not_A_Number       = "has an offset that is not a number",
	.Offset_Not_Whole          = "has an offset that is not a whole number of milliseconds",
	.Offset_Out_Of_Range       = "has an offset too large to read as milliseconds",
	.No_Text                   = "has no `text` string",
	.Negative_Offset           = "starts before the recording does",
	.Cue_Ends_Before_It_Starts = "ends before it starts",
	.Cues_Out_Of_Order         = "starts before the cue in front of it",
}

// Renders one operating error as a line naming the input it came from.
//
// The allocator is explicit and never defaulted: the line outlives this
// procedure and is written by a worker other than the one that reads it
// (ADR-0010).
error_message :: proc(err: Parse_Error, allocator: mem.Allocator) -> string {
	assert(err.fault != .None, "there is no message for a parse that did not fail")
	assert(len(err.json_name) > 0, "an operating error must name the input it is reported against")
	assert(err.cue >= 0, "a cue ordinal is a position, or zero for the input as a whole")
	assert(allocator.procedure != nil, "the message outlives this procedure and needs a chosen allocator")

	text := FAULT_TEXT[err.fault]
	assert(len(text) > 0, "a fault was added to Parse_Fault without a sentence in FAULT_TEXT")

	out: string
	if err.cue == 0 {
		out = fmt.aprintf("%s: %s", err.json_name, text, allocator = allocator)
	} else {
		out = fmt.aprintf("%s: cue %d: %s", err.json_name, err.cue, text, allocator = allocator)
	}

	// The one property every caller depends on and no format string guarantees:
	// the report says which file to go and look at (ADR-0002 -- the answer is
	// always to quarantine that file and re-run it).
	assert(strings.contains(out, err.json_name), "an operating error that does not name its input")
	return out
}

// Builds a report, checking at the one place they are made that every report
// can actually be delivered.
@(private)
fault_at :: proc(fault: Parse_Fault, json_name: string, cue: int) -> Parse_Error {
	assert(fault != .None, "a fault of .None is the success value and reports nothing")
	assert(len(json_name) > 0, "an operating error must name the input it is reported against")
	// The ordinal convention checked where a Parse_Error is WRITTEN;
	// cues_are_ordered checks the same range where one is read (CLAUDE.md A4).
	assert(cue >= 0, "a cue ordinal is a position, or zero for the input as a whole")
	return Parse_Error{fault = fault, json_name = json_name, cue = cue}
}
