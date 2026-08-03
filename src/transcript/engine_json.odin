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
	Final_Offset_Is_Zero,
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

	// Blocks come from the caller's allocator and never from
	// `context.temp_allocator`, which is thread-local and belongs to whichever
	// worker happens to be running this (ADR-0010).
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, block_allocator = allocator, array_allocator = allocator)
	defer mem.dynamic_arena_destroy(&scratch)

	root, decode_fault := decode_engine_json(json_text, &scratch)
	if decode_fault != .None {
		return nil, fault_at(decode_fault, json_name, 0)
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

	set_fault, set_at := check_cue_set(built, recording_duration)
	if set_fault != .None {
		destroy_cues(built, allocator)
		return nil, fault_at(set_fault, json_name, set_at)
	}

	// The parser's own promise, asserted where it is made; every consumer
	// asserts the same on the way in (CLAUDE.md A4). Nothing external reaches
	// these -- read_cues has already rejected, as an operating error, everything
	// the Engine could have written that breaks them.
	assert(len(built) > 0, "returned an empty cue set without reporting No_Cues")
	assert(cues_are_ordered(built), "returned a cue set that is not ordered")
	return built, Parse_Error{}
}

// Decodes the Engine's JSON into a tree that lives on `scratch` and dies with
// it, which is what makes an arena the right home for it in the first place.
//
// core:encoding/json LEAKS on several of its error paths -- an object key parsed
// just before the value after it fails is never inserted into the object, so the
// parser's own cleanup, which walks that object, never sees it. Truncated Engine
// output takes exactly that path, and truncated output is the case ADR-0002
// exists for, not a rarity. An arena settles the question: nothing here is freed
// individually and everything goes back at once.
//
// `.JSON` rather than the package default of JSON5, and `parse_integers` stated
// rather than left at its default of false -- see read_millis for what that
// default costs. The Engine writes strict JSON, so a trailing comma or a comment
// means this is not what the Engine wrote, and ADR-0002 wants that quarantined
// rather than guessed at.
@(private)
decode_engine_json :: proc(
	json_text: string,
	scratch: ^mem.Dynamic_Arena,
) -> (
	json.Value,
	Parse_Fault,
) {
	assert(len(json_text) > 0, "an empty input is Empty_Input, settled before this point")
	assert(scratch.block_allocator.procedure != nil, "the scratch arena was never initialised")

	root, decode_err := json.parse(json_text, .JSON, true, mem.dynamic_arena_allocator(scratch))
	if decode_err != nil {
		return nil, .Malformed_Json
	}
	return root, .None
}

// The one check that is about the Cue set rather than any Cue in it, and the
// only guard against a silent success.
//
// A Cue set whose LAST offset is zero over a Recording that is not empty is the
// exact signature of an offset reader that matched nothing -- see read_millis.
// Every Cue is well-formed, the set is perfectly monotonic, and the Transcript
// that comes out has every Cue at 00:00. Nothing else in this parser can tell.
//
// Reported and never asserted: a genuine Engine failure produces the same shape,
// and nothing outside this program may crash it (CLAUDE.md A8).
@(private)
check_cue_set :: proc(cues: []Cue, recording_duration: Millis) -> (Parse_Fault, int) {
	assert(len(cues) > 0, "an empty cue set is No_Cues, settled before this point")
	// The read side of the ordering read_cues enforced per Cue as it built
	// (CLAUDE.md A4). The implication below is sound only on an ordered set.
	assert(cues_are_ordered(cues), "a disordered cue set reached the set-wide checks")
	assert(recording_duration >= 0, "a negative recording duration is a probe defect")

	// A Recording the shell could not measure arrives as zero, and a comparison
	// against an unknown has nothing to say. Inventing a failure out of missing
	// information is how a working Recording gets quarantined forever.
	if recording_duration == 0 {
		return .None, 0
	}
	if cues[len(cues) - 1].end != 0 {
		return .None, 0
	}

	// Ordered means starts never go backwards and no Cue ends before it starts,
	// so a final end of zero forces every START to zero as well. Asserted rather
	// than left to a comment, because it is the step that makes one comparison
	// stand for the whole set (CLAUDE.md A6).
	for cue in cues {
		assert(cue.start == 0, "an ordered set ending at zero has a cue starting after it")
	}
	return .Final_Offset_Is_Zero, len(cues)
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
//
// Untyped, so the one number serves both branches of read_millis: naming it
// twice, once per width, is how the two branches came to disagree about where
// the limit was.
@(private)
READABLE_MS :: 1 << 53

// The range check in read_millis is the only thing keeping the conversion to
// Millis from overflowing, and it does that job only while the limit it checks
// against fits in one. A constant relationship the code relies on, stated in
// checked code rather than in prose (CLAUDE.md A5).
#assert(READABLE_MS <= max(i64))

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
//
// THE RANGE CHECK IS ON BOTH BRANCHES, and it has to be. `core:encoding/json`
// reads an integer token with `strconv.parse_i64` and discards the error -- but
// the error is not even set: parse_i64 WRAPS on overflow and reports success, so
// `99999999999999999999999` arrives as 200376420520689663, about six million
// years, and `170141183460469231731687303715884105728` arrives as 0. There is
// nothing to read the failure off. The magnitude is the only signal left, which
// is why the same limit is applied to a number that arrived already parsed.
//
// It is not a complete guard and cannot be from here: a literal big enough to
// wrap back INSIDE the limit -- 18446744073709556616 wraps to 5000 -- is
// indistinguishable from a Recording that really has a Cue at 5 seconds, and
// the token text it was written as is gone by the time this sees it. What that
// case cannot do is escape the parser's other promises: it is still one whole,
// in-range, ordered offset, and the wrap-to-zero end of it is exactly what
// check_cue_set refuses.
@(private)
read_millis :: proc(offsets: json.Object, key: string) -> (Millis, Parse_Fault) {
	assert(len(key) > 0, "an offset is read by name; the empty key is a caller defect")

	value, present := offsets[key]
	if !present {
		return 0, .Offset_Missing
	}

	#partial switch number in value {
	case json.Integer:
		if number < -READABLE_MS || number > READABLE_MS {
			return 0, .Offset_Out_Of_Range
		}
		return Millis(number), .None
	case json.Float:
		if number != math.trunc(number) {
			return 0, .Offset_Not_Whole
		}
		if number < -READABLE_MS || number > READABLE_MS {
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
	.Final_Offset_Is_Zero      = "ends at offset zero and is the last cue, over a recording that is not empty; the engine's offsets did not survive being read",
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
