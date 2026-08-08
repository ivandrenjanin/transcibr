#+vet explicit-allocators
package transcript

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "transcibr:process"

Parse_Fault :: enum u8 {
	None = 0,
	Empty_Input,
	Malformed_Json,
	Not_An_Object,
	No_Transcription,
	Too_Deeply_Nested,
	No_Cues,
	Nothing_Said,
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

// The name is borrowed, never owned: it is the caller's spelling of the file,
// and it lives at least as long as the report.
Parse_Error :: struct {
	fault:     Parse_Fault,
	json_name: string,
	// The 1-based position of the offending Cue, or 0 when the fault is about
	// the input as a whole.
	cue:       int,
}

@(private)
Fault_Scope :: enum u8 {
	Unset = 0,
	Input,
	Cue,
}

@(private)
Fault_Facts :: struct {
	says:        string,
	scope:       Fault_Scope,
	// Why this is not readable off the fault's own name: ADR-0002.
	disposition: process.Disposition,
}

@(private, rodata)
FAULT := [Parse_Fault]Fault_Facts {
	.None = {},
	.Empty_Input = {
		says = "the engine wrote nothing",
		scope = .Input,
		disposition = .Fail_The_Recording,
	},
	.Malformed_Json = {
		says = "not valid json; the file is truncated or was not written by the engine",
		scope = .Input,
		disposition = .Quarantine_And_Rerun,
	},
	.Not_An_Object = {
		says = "valid json, but not the object the engine writes",
		scope = .Input,
		disposition = .Quarantine_And_Rerun,
	},
	.No_Transcription = {
		says = "no `transcription` array",
		scope = .Input,
		disposition = .Quarantine_And_Rerun,
	},
	.Too_Deeply_Nested = {
		says = "json nested far deeper than the engine writes; the file was not written by the engine",
		scope = .Input,
		disposition = .Quarantine_And_Rerun,
	},
	.No_Cues = {
		says = "the `transcription` array is empty; the engine transcribed nothing",
		scope = .Input,
		disposition = .Fail_The_Recording,
	},
	.Nothing_Said = {
		says = "no paragraph could be made from it; nothing in it is speech",
		scope = .Input,
		disposition = .Fail_The_Recording,
	},
	.Cue_Not_An_Object = {
		says = "is not an object",
		scope = .Cue,
		disposition = .Quarantine_And_Rerun,
	},
	.No_Offsets = {
		says = "has no `offsets` object",
		scope = .Cue,
		disposition = .Quarantine_And_Rerun,
	},
	.Offset_Missing = {
		says = "is missing one of its `from`/`to` offsets",
		scope = .Cue,
		disposition = .Quarantine_And_Rerun,
	},
	.Offset_Not_A_Number = {
		says = "has an offset that is not a number",
		scope = .Cue,
		disposition = .Quarantine_And_Rerun,
	},
	.Offset_Not_Whole = {
		says = "has an offset that is not a whole number of milliseconds",
		scope = .Cue,
		disposition = .Quarantine_And_Rerun,
	},
	.Offset_Out_Of_Range = {
		says = "has an offset too large to read as milliseconds",
		scope = .Cue,
		disposition = .Quarantine_And_Rerun,
	},
	.No_Text = {says = "has no `text` string", scope = .Cue, disposition = .Quarantine_And_Rerun},
	.Negative_Offset = {
		says = "starts before the recording does",
		scope = .Cue,
		disposition = .Quarantine_And_Rerun,
	},
	.Cue_Ends_Before_It_Starts = {
		says = "ends before it starts",
		scope = .Cue,
		disposition = .Quarantine_And_Rerun,
	},
	.Cues_Out_Of_Order = {
		says = "starts before the cue in front of it",
		scope = .Cue,
		disposition = .Quarantine_And_Rerun,
	},
	.Final_Offset_Is_Zero = {
		says = "ends at offset zero and is the last cue, over a recording that is not empty; the engine's offsets did not survive being read",
		scope = .Cue,
		disposition = .Quarantine_And_Rerun,
	},
}

// The asserts below are the A4 pair to engine_json_test.odin's
// every_fault_says_what_adr_0002_does_with_it and
// every_parse_fault_names_a_disposition, which walk Parse_Fault. See
// CLAUDE.md, Odin notes: enumerated arrays and switches.
@(private)
@(require_results)
fault_facts :: proc(fault: Parse_Fault) -> (facts: Fault_Facts) {
	assert(fault != .None, "the success value is not a fault and carries no facts")

	facts = FAULT[fault]
	assert(len(facts.says) > 0, "a fault was added to Parse_Fault without a row in FAULT")
	assert(facts.scope != .Unset, "a fault's row in FAULT names no scope")
	assert(facts.disposition != .Unset, "a fault's row in FAULT names no disposition")
	return
}

@(require_results)
disposition_of :: proc(fault: Parse_Fault) -> process.Disposition {
	assert(fault != .None, "a parse that did not fail has nothing to dispose of")
	return fault_facts(fault).disposition
}

// The cue set outlives this procedure and crosses a worker boundary (ADR-0010):
// free it with destroy_cues and the same allocator.
@(require_results)
parse_cues :: proc(
	json_name: string,
	json_text: string,
	recording_duration: Maybe(Millis),
	allocator: mem.Allocator,
) -> (
	cues: []Cue,
	err: Parse_Error,
) {
	assert(
		len(json_name) > 0,
		"the input must be named; a report nobody can locate is not a report",
	)
	assert(
		allocator.procedure != nil,
		"the cue set outlives this procedure and needs a chosen allocator",
	)
	if duration, measured := recording_duration.?; measured {
		assert(duration >= 0, "a negative recording duration is a probe defect, not engine output")
	}

	if len(strings.trim_space(json_text)) == 0 {
		return nil, fault_at(.Empty_Input, json_name, 0)
	}

	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, block_allocator = allocator, array_allocator = allocator)
	defer mem.dynamic_arena_destroy(&scratch)

	root, decode_fault := decode_engine_json(json_text, mem.dynamic_arena_allocator(&scratch))
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

	assert(len(built) > 0, "returned an empty cue set without reporting No_Cues")
	return built, Parse_Error{}
}

// `result.language` is what the Engine DETECTED; `params.language` is what it was
// asked for and reads `auto` unless somebody chose. The answer always comes back
// cloned, UNKNOWN included, and is always freed with `delete` (ADR-0010).
@(require_results)
parse_language :: proc(json_text: string, allocator: mem.Allocator) -> (language: string) {
	assert(
		allocator.procedure != nil,
		"the language outlives this procedure and needs a chosen allocator",
	)
	defer assert(len(language) > 0, "handed back a front matter field with nothing in it")

	if len(strings.trim_space(json_text)) == 0 {
		return strings.clone(UNKNOWN, allocator)
	}

	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, block_allocator = allocator, array_allocator = allocator)
	defer mem.dynamic_arena_destroy(&scratch)

	root, fault := decode_engine_json(json_text, mem.dynamic_arena_allocator(&scratch))
	if fault != .None {
		return strings.clone(UNKNOWN, allocator)
	}
	body, is_object := root.(json.Object)
	if !is_object {
		return strings.clone(UNKNOWN, allocator)
	}
	result, has_result := field(json.Object, body, "result")
	if !has_result {
		return strings.clone(UNKNOWN, allocator)
	}
	detected, is_text := field(json.String, result, "language")
	if !is_text || len(detected) == 0 {
		return strings.clone(UNKNOWN, allocator)
	}
	return strings.clone(detected, allocator)
}

// `systeminfo` is the Engine's own report of what it was BUILT with -- CPU
// features, and which optional backends the binary carries -- read the
// identical way `parse_language` reads `result.language`: best-effort, and
// UNKNOWN rather than a fault when the field is missing or malformed, because
// neither procedure is on the path that decides whether a Recording
// succeeded. `transcibr:doctor` is the one caller that reads this for a
// decision, and only ever alongside a measured realtime factor -- see
// ADR-0011 and CONTEXT.md's Engine entry for why the string alone proves
// nothing.
@(require_results)
parse_systeminfo :: proc(json_text: string, allocator: mem.Allocator) -> (systeminfo: string) {
	assert(
		allocator.procedure != nil,
		"the systeminfo outlives this procedure and needs a chosen allocator",
	)
	defer assert(len(systeminfo) > 0, "handed back a front matter field with nothing in it")

	if len(strings.trim_space(json_text)) == 0 {
		return strings.clone(UNKNOWN, allocator)
	}

	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(&scratch, block_allocator = allocator, array_allocator = allocator)
	defer mem.dynamic_arena_destroy(&scratch)

	root, fault := decode_engine_json(json_text, mem.dynamic_arena_allocator(&scratch))
	if fault != .None {
		return strings.clone(UNKNOWN, allocator)
	}
	body, is_object := root.(json.Object)
	if !is_object {
		return strings.clone(UNKNOWN, allocator)
	}
	reported, is_text := field(json.String, body, "systeminfo")
	if !is_text || len(reported) == 0 {
		return strings.clone(UNKNOWN, allocator)
	}
	return strings.clone(reported, allocator)
}

// The tree lives on `scratch` and dies with it, because the decoder leaks on the
// error paths a truncated file takes. See CLAUDE.md, Odin notes:
// core:encoding/json.
@(private)
@(require_results)
decode_engine_json :: proc(
	json_text: string,
	scratch: mem.Allocator,
) -> (
	json.Value,
	Parse_Fault,
) {
	assert(len(json_text) > 0, "an empty input is Empty_Input, settled before this point")
	assert(scratch.procedure != nil, "the decoded tree has to live somewhere")

	if !json_nesting_is_bounded(json_text) {
		return nil, .Too_Deeply_Nested
	}

	root, decode_err := json.parse(json_text, .JSON, false, scratch)
	if decode_err != nil {
		return nil, .Malformed_Json
	}
	return root, .None
}

// The Engine writes five levels at the deepest, and the stack gives out around
// 800 -- a limit here has to sit an order of magnitude clear of both, because the
// depth the stack survives moves with the build and with the calling thread. See
// CLAUDE.md, Odin notes: core:encoding/json.
@(private)
MAX_JSON_DEPTH :: 64

// Counted off the decoder's own tokenizer, which is iterative and allocates
// nothing. A hand-rolled byte scan would be a second answer to "where does this
// string end", and would refuse a Recording for containing "[[[".
@(private)
@(require_results)
json_nesting_is_bounded :: proc(json_text: string) -> bool {
	assert(len(json_text) > 0, "an empty input is Empty_Input, settled before this point")

	tokenizer := json.make_tokenizer(json_text, .JSON, false)
	depth := 0
	for {
		token, _ := json.get_token(&tokenizer)
		if token.kind == .EOF {
			break
		}
		#partial switch token.kind {
		case .Open_Brace, .Open_Bracket:
			depth += 1
			if depth > MAX_JSON_DEPTH {
				return false
			}
		case .Close_Brace, .Close_Bracket:
			if depth > 0 {
				depth -= 1
			}
		}
	}

	assert(depth <= MAX_JSON_DEPTH, "returned true for nesting past the limit")
	assert(depth >= 0, "counted more closing brackets than were ever opened")
	return true
}

// A Cue set whose last offset is zero over a Recording that is not empty is the
// signature of an offset reader that matched nothing -- see read_millis. Every
// Cue is well-formed and the set is monotonic, so nothing else here can tell.
@(private)
@(require_results)
check_cue_set :: proc(cues: []Cue, recording_duration: Maybe(Millis)) -> (Parse_Fault, int) {
	assert(len(cues) > 0, "an empty cue set is No_Cues, settled before this point")
	disordered := first_disordered_cue(cues)
	fmt.assertf(
		disordered == 0,
		"cue %d broke the ordering before the set-wide checks",
		disordered,
	)

	duration, measured := recording_duration.?
	if !measured {
		return .None, 0
	}
	assert(duration >= 0, "a negative recording duration is a probe defect")

	if duration == 0 {
		return .None, 0
	}
	if cues[len(cues) - 1].end != 0 {
		return .None, 0
	}

	for cue in cues {
		assert(cue.start == 0, "an ordered set ending at zero has a cue starting after it")
	}
	return .Final_Offset_Is_Zero, len(cues)
}

@(private)
@(require_results)
read_transcription :: proc(root: json.Value) -> (json.Array, Parse_Fault) {
	body, is_object := root.(json.Object)
	if !is_object {
		return nil, .Not_An_Object
	}
	entries, present := field(json.Array, body, "transcription")
	if !present {
		return nil, .No_Transcription
	}
	if len(entries) == 0 {
		return nil, .No_Cues
	}
	return entries, .None
}

// One field of a json object, by name AND by type: a `text` that is a number and
// a `text` that is missing are one fault, because the Engine wrote neither.
@(private)
@(require_results)
field :: proc($T: typeid, object: json.Object, key: string) -> (value: T, present: bool) {
	assert(len(key) > 0, "a field is read by name; the empty key is a caller defect")

	found, exists := object[key]
	if !exists {
		return {}, false
	}
	value, present = found.(T)
	return
}

@(private)
@(require_results)
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

	built := make([dynamic]Cue, 0, len(entries), allocator)
	defer if cues == nil {
		for cue in built {
			delete(cue.text, allocator)
		}
		delete(built)
	}

	for entry, i in entries {
		cue, cue_fault := read_cue(entry, allocator)
		if cue_fault != .None {
			return nil, cue_fault, i + 1
		}
		append(&built, cue)

		order_fault := cue_follows(cue, built[:i])
		if order_fault != .None {
			return nil, order_fault, i + 1
		}
	}

	assert(len(built) == len(entries), "left a cue unread without reporting a fault")
	assert(cap(built) == len(built), "the returned slice does not own exactly the block it names")
	disordered := first_disordered_cue(built[:])
	fmt.assertf(
		disordered == 0,
		"built cue %d, which the per-cue checks should have rejected",
		disordered,
	)
	return built[:], .None, 0
}

@(private)
@(require_results)
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

@(private)
@(require_results)
read_cue :: proc(entry: json.Value, allocator: mem.Allocator) -> (cue: Cue, fault: Parse_Fault) {
	assert(allocator.procedure != nil, "a cue's text outlives this procedure")

	fields, is_object := entry.(json.Object)
	if !is_object {
		return Cue{}, .Cue_Not_An_Object
	}

	offsets, has_offsets := field(json.Object, fields, "offsets")
	if !has_offsets {
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

	text, has_text := field(json.String, fields, "text")
	if !has_text {
		return Cue{}, .No_Text
	}

	cue = Cue {
		start = start,
		end   = end,
		text  = strings.clone(text, allocator),
	}
	assert(len(cue.text) == len(text), "the clone lost bytes the engine wrote")
	return cue, .None
}

// Every offset arrives as an f64, which represents every integer exactly only
// below 2^53: at 2^53 the spacing becomes two, so the literal 2^53 + 1 rounds
// down onto it and a limit set there would read back a number nobody wrote.
@(private)
READABLE_MS :: (1 << 53) - 1

#assert(READABLE_MS <= max(i64))

// Why every offset is read as a float and range-checked: see CLAUDE.md, Odin
// notes: core:encoding/json.
@(private)
@(require_results)
read_millis :: proc(offsets: json.Object, key: string) -> (Millis, Parse_Fault) {
	assert(len(key) > 0, "an offset is read by name; the empty key is a caller defect")

	value, present := offsets[key]
	if !present {
		return 0, .Offset_Missing
	}
	number, is_number := value.(json.Float)
	if !is_number {
		return 0, .Offset_Not_A_Number
	}

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

@(require_results)
error_message :: proc(err: Parse_Error, allocator: mem.Allocator) -> string {
	assert(err.fault != .None, "there is no message for a parse that did not fail")
	assert(len(err.json_name) > 0, "an operating error must name the input it is reported against")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs a chosen allocator",
	)

	facts := fault_facts(err.fault)

	out: string
	if facts.scope == .Input {
		out = fmt.aprintf("%s: %s", err.json_name, facts.says, allocator = allocator)
	} else {
		out = fmt.aprintf(
			"%s: cue %d: %s",
			err.json_name,
			err.cue,
			facts.says,
			allocator = allocator,
		)
	}

	assert(strings.contains(out, err.json_name), "an operating error that does not name its input")
	return out
}

@(private)
@(require_results)
fault_at :: proc(fault: Parse_Fault, json_name: string, cue: int) -> Parse_Error {
	assert(fault != .None, "a fault of .None is the success value and reports nothing")
	assert(len(json_name) > 0, "an operating error must name the input it is reported against")

	scope := fault_facts(fault).scope

	if scope == .Input {
		assert(cue == 0, "a fault about the input as a whole blamed a cue")
	} else {
		assert(cue > 0, "a fault about one cue did not say which")
	}
	return Parse_Error{fault = fault, json_name = json_name, cue = cue}
}
