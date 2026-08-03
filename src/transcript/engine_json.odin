package transcript

import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"

// What was wrong with a piece of Engine output.
//
// Every one of these is an OPERATING error (CLAUDE.md A8): the Engine is
// outside this program, and nothing outside may crash it. What happens next is
// not the same for all of them -- ADR-0002 quarantines and re-runs output that
// will not parse, but calls "exit 0 with no or empty output" a hard
// per-Recording failure -- so it is answered by disposition_of rather than left
// for a caller to infer from the name.
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

// One rejected piece of Engine output, named against the input that carried it.
//
// The name is borrowed, never owned: it is the caller's spelling of the file,
// and it lives at least as long as the report.
Parse_Error :: struct {
	fault:     Parse_Fault,
	json_name: string,
	// The 1-based position of the offending Cue, or 0 when the fault is about
	// the input as a whole. Which of the two it is follows from the fault and
	// is checked in fault_at -- never guessed at from the number.
	cue:       int,
}

// What ADR-0002 does with the input a fault was reported against.
//
// Not something a caller can work out from the fault: "a validated JSON that
// fails to parse is treated as ABSENT -- quarantine it and re-run the full
// pipeline, rather than reporting a permanent failure", while "exit 0 but no or
// empty output is a hard per-Recording failure". Two of the sixteen fall on the
// second side and nothing in their names says so.
//
// Public and answered from the table below, because the alternative is the
// shell reconstructing this from a sixteen-way switch in another package that
// nothing keeps in step with the enumeration.
Disposition :: enum u8 {
	// The file is not what the Engine writes, which says nothing about whether
	// the Engine can write it. Quarantine it to `.json.bad` and re-run.
	Quarantine_And_Rerun = 0,
	// The Engine exited having transcribed nothing, and re-running it
	// transcribes nothing again.
	Fail_The_Recording,
}

// Whether a fault is about the input as a whole or about one Cue in it.
//
// Carried by Parse_Fault rather than by Parse_Error.cue being zero or not. The
// number was doing two jobs -- a Cue's position, and a flag for whether there
// was one -- so the convention had to be remembered at every call site, and
// FAULT silently held two grammars because of it: "the engine wrote nothing" is
// a sentence about a file, and "ends before it starts" is a sentence about a
// Cue, and only the ordinal said which was about to be printed.
//
// Unset is the zero value and no row may carry it: FAULT is an enumerated array,
// so a Parse_Fault added without a row still HAS a row, made of zeroes, and
// `.Input` sitting on zero would make that row a plausible answer rather than a
// detectable one. fault_at asserts against it, which is the check its two
// siblings already make against an empty `says`.
@(private)
Fault_Scope :: enum u8 {
	Unset = 0,
	Input,
	Cue,
}

// Everything this package knows about a fault beyond its name.
//
// One record per fault rather than three parallel tables: they are three
// answers to the same question and a fault added to one but not the others is
// the drift they exist to prevent.
@(private)
Fault_Facts :: struct {
	// What the fault reads as, WITHOUT the input's name or the Cue's position
	// -- error_message supplies those, so no entry here can forget to.
	says:        string,
	scope:       Fault_Scope,
	disposition: Disposition,
}

// An enumerated array rather than a switch: adding a Parse_Fault without an
// entry here leaves an empty sentence, which the assertion in error_message
// catches on the first report rather than shipping a diagnostic that says
// nothing -- and takes the scope and the disposition down with it, so one
// missing row is caught by one check.
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
		says = "every cue is empty or silence; the engine transcribed no speech at all",
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

// What ADR-0002 does with the input this fault was reported against.
disposition_of :: proc(fault: Parse_Fault) -> Disposition {
	assert(fault != .None, "a parse that did not fail has nothing to dispose of")
	// The same missing-row check error_message makes, at the other place the
	// table is read (CLAUDE.md A4). A fault added without an entry answers
	// "quarantine and re-run" here, which is a sentence nobody wrote.
	assert(len(FAULT[fault].says) > 0, "a fault was added to Parse_Fault without a row in FAULT")
	return FAULT[fault].disposition
}

// Parses the Engine's JSON into Cues.
//
// `json_name` is what to report an operating error against -- the path the
// Engine wrote, as the caller spells it. `recording_duration` is what the shell
// probed off the container (ADR-0009), or nothing where the probe could not
// settle it -- a Maybe rather than a zero, because a Recording measured at zero
// and a Recording nobody measured are different facts and the check that reads
// this is the one place the difference matters.
//
// The allocator is explicit and never defaulted: the Cue set outlives this
// procedure and crosses a worker boundary (ADR-0010). Free it with
// destroy_cues, passing the same allocator.
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

	// The one promise about the returned set that nothing else has said yet.
	// The ordering is NOT re-checked here: read_cues asserted it on the way out
	// of building and check_cue_set asserted it on the way in, on this exact
	// slice, five lines ago -- that is A4's pair, and a third scan is a third
	// copy of one claim rather than a second route to it.
	assert(len(built) > 0, "returned an empty cue set without reporting No_Cues")
	return built, Parse_Error{}
}

// The language the Engine DETECTED, out of the same output the Cues came from,
// or nothing where it did not say.
//
// `result.language` and never `params.language`. The Engine writes what it was
// ASKED for in `params` -- which is `auto` on every Recording nobody chose a
// language for -- and what it decided in `result`. A Transcript stamped `auto`
// says nothing at all, and one stamped the request when the two disagree says
// something false.
//
// This is the ONLY front matter fact the Engine's own output can settle
// (ADR-0001). The Engine version is not in there, and the Model is reported as
// the bare name `large` whichever large Model was loaded, so both come from
// transcibr's own record instead (ADR-0003).
//
// It decodes the document a SECOND time rather than being folded into
// parse_cues, and the cost is stated rather than hidden: about twenty
// microseconds over the fixture, against a Recording that took minutes on a GPU
// and a re-render ADR-0003 measures in seconds. Folding it in would change what
// parse_cues hands back to every caller and every case that already reads it, to
// save an amount of time nobody can perceive.
//
// Nothing here is an operating error, because there is nothing to report: a
// document that is not Engine output has no language in it, and parse_cues is
// what refuses that document and names it (CLAUDE.md A8).
//
// A document that settles nothing is answered with UNKNOWN and never with an
// empty string or a flag beside one. ADR-0003's rule is that absent provenance
// beats wrong provenance, and UNKNOWN is how every front matter field spells
// absent -- so the fold that turned "nothing" into that word was written at
// every call site, four times, and every one of them also had to remember that
// only one of the two answers owned memory.
//
// The language ALWAYS comes back CLONED, including the word for nobody knowing,
// and is always freed with `delete` and the same allocator. One lifetime rule,
// no fold anywhere. Explicit and never defaulted: it outlives this procedure and
// crosses a worker boundary (ADR-0010).
parse_language :: proc(json_text: string, allocator: mem.Allocator) -> (language: string) {
	assert(
		allocator.procedure != nil,
		"the language outlives this procedure and needs a chosen allocator",
	)
	// What every caller depends on and no path below states on its own: there is
	// always something to write into a front matter field, and always something
	// to free (CLAUDE.md A3, A6).
	defer assert(len(language) > 0, "handed back a front matter field with nothing in it")

	if len(strings.trim_space(json_text)) == 0 {
		return strings.clone(UNKNOWN, allocator)
	}

	// The caller's allocator and never `context.temp_allocator`, which is
	// thread-local and belongs to whichever worker is running this (ADR-0010).
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
// `.JSON` rather than the package default of JSON5: the Engine writes strict
// JSON, so a trailing comma or a comment means this is not what the Engine
// wrote, and ADR-0002 wants that quarantined rather than guessed at.
//
// `parse_integers` is FALSE, stated rather than left to a default that happens
// to agree. It is not a performance knob: with it on, an integer token that
// overflows wraps silently to a plausible small offset and there is nothing left
// to detect it with, while every number this decode produces without it is an
// f64 whose magnitude read_millis can check. That procedure is where the whole
// argument is written down.
@(private)
decode_engine_json :: proc(
	json_text: string,
	scratch: mem.Allocator,
) -> (
	json.Value,
	Parse_Fault,
) {
	assert(len(json_text) > 0, "an empty input is Empty_Input, settled before this point")
	assert(scratch.procedure != nil, "the decoded tree has to live somewhere")

	// BEFORE the decode, because this is the one thing wrong with a file that
	// the decode cannot survive to report -- see json_nesting_is_bounded.
	if !json_nesting_is_bounded(json_text) {
		return nil, .Too_Deeply_Nested
	}

	root, decode_err := json.parse(json_text, .JSON, false, scratch)
	if decode_err != nil {
		return nil, .Malformed_Json
	}
	return root, .None
}

// The deepest nesting this parser will hand to core:encoding/json.
//
// That decoder is a recursive descent with NO depth limit of its own, so a file
// nested deeply enough runs the thread off its stack and takes the process down
// -- 0xC00000FD, measured, from 1694 bytes of input: 751 levels decoded fine and
// 801 ended the run. There is no error return to catch, which makes it the one
// piece of external input that can crash this program, and CLAUDE.md A8 says
// nothing outside it may.
//
// The Engine writes five levels at the deepest: the root object, the
// `transcription` array, a Cue, its `tokens` array, and a token. 64 leaves an
// order of magnitude of headroom over anything an Engine release could
// plausibly add, and sits an order of magnitude BELOW where the stack gives
// out -- which is the gap the limit has to fall in, because the depth the stack
// survives is not a constant: it moves with the build configuration and with
// the stack the calling thread happens to have.
@(private)
MAX_JSON_DEPTH :: 64

// Whether the nesting in a piece of JSON stays inside MAX_JSON_DEPTH.
//
// Counted off the decoder's OWN tokenizer, given the same specification and the
// same integer setting decode_engine_json gives the parser. That tokenizer is
// iterative and allocates nothing, so none of what makes the decoder unsafe on
// this input is being run: what would crash is parse_value's recursion, and the
// point of counting the open brackets in the token stream is that the recursion
// takes one level per open bracket in exactly that stream and can therefore
// never go deeper than this counts.
//
// Not a hand-rolled byte scan, and that is the whole reason. Such a scan has to
// know where a string ends -- a bracket inside one is text the Engine
// transcribed, and a scan that could not tell would refuse a Recording for
// containing "[[[" -- and a second answer to that question is only as good as
// the day it last agreed with the first. Deliberately NOT a validator otherwise:
// everything it lets through still has to parse, and an unbalanced or trailing
// bracket is Malformed_Json from the decoder exactly as it was before.
//
// It costs about half again what a hand-rolled byte scan over the same bytes
// costs -- 20.6 us against 13.8 us for a whole parse_cues over the fixture,
// measured across 200,000 of them. That is microseconds against a Recording that
// took minutes to transcribe, and CLAUDE.md orders these goals safety first.
@(private)
json_nesting_is_bounded :: proc(json_text: string) -> bool {
	assert(len(json_text) > 0, "an empty input is Empty_Input, settled before this point")

	tokenizer := json.make_tokenizer(json_text, .JSON, false)
	depth := 0
	for {
		// The token KIND and never the error. An illegal character is reported
		// with a token and the tokenizer walks on past it, and a scan that
		// stopped at the first error would measure none of the brackets after
		// it -- which the decoder still descends into before it reaches the
		// error and gives up. Only .EOF means there is nothing further to read,
		// and it is also what stops this loop advancing.
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
			// Never below zero. An unbalanced closer is the decoder's to
			// report, and a depth allowed to go negative here would let the
			// brackets after it run as deep as they liked.
			if depth > 0 {
				depth -= 1
			}
		}
	}

	// The two facts a `true` here stands for, asserted where it is returned
	// rather than left to a reader to trace back through the loop (A6). The
	// second is the one that is easy to lose: without the guard on the way
	// down, a file of nothing but `]` drives depth negative and every bracket
	// after it is measured from the wrong floor.
	assert(depth <= MAX_JSON_DEPTH, "returned true for nesting past the limit")
	assert(depth >= 0, "counted more closing brackets than were ever opened")
	return true
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
check_cue_set :: proc(cues: []Cue, recording_duration: Maybe(Millis)) -> (Parse_Fault, int) {
	assert(len(cues) > 0, "an empty cue set is No_Cues, settled before this point")
	// The read side of the ordering read_cues enforced per Cue as it built
	// (CLAUDE.md A4). The implication below is sound only on an ordered set.
	disordered := first_disordered_cue(cues)
	fmt.assertf(
		disordered == 0,
		"cue %d broke the ordering before the set-wide checks",
		disordered,
	)

	// A comparison against an unknown has nothing to say, and inventing a
	// failure out of missing information is how a working Recording gets
	// quarantined forever.
	duration, measured := recording_duration.?
	if !measured {
		return .None, 0
	}
	assert(duration >= 0, "a negative recording duration is a probe defect")

	// A Recording MEASURED at zero is a different statement with the same
	// answer: a Cue set covering none of it covers all of it.
	if duration == 0 {
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
	entries, present := field(json.Array, body, "transcription")
	if !present {
		return nil, .No_Transcription
	}
	if len(entries) == 0 {
		return nil, .No_Cues
	}
	return entries, .None
}

// One field of a json object, by name AND by type.
//
// "Is there a `text` string here" is one question, and asking it in two steps
// -- look the key up, then assert the type -- is two places for the answers to
// drift apart. All three of its call sites report the same fault for both
// halves: a `text` that is a number and a `text` that is missing are both
// No_Text, because the Engine wrote neither.
//
// read_millis is the fourth lookup and deliberately does NOT use this. An offset
// that is missing and an offset that is a string are Offset_Missing and
// Offset_Not_A_Number, two different sentences pointing at two different Engine
// defects, and collapsing them would cost a reader the only clue they have.
//
// Leaf lookup over external data; the callers carry the assertions (A1, A8).
@(private)
field :: proc($T: typeid, object: json.Object, key: string) -> (value: T, present: bool) {
	assert(len(key) > 0, "a field is read by name; the empty key is a caller defect")

	found, exists := object[key]
	if !exists {
		return {}, false
	}
	value, present = found.(T)
	return
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

	// How far it got is the array's own length, and whether it was handed over
	// is whether the return carries it. Both were tracked in locals beside the
	// values that already knew, which is two more things to keep in step on
	// every path out of the loop.
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
		// APPENDED before it is checked, and the order is load-bearing: read_cue
		// cloned this Cue's text, so a Cue rejected while it is still a local is
		// a leak on every rejection path. Owned first, judged second -- the defer
		// above frees whatever the array holds, and it holds this one now.
		append(&built, cue)

		// Everything built BEFORE this Cue, which is what it has to follow.
		order_fault := cue_follows(cue, built[:i])
		if order_fault != .None {
			return nil, order_fault, i + 1
		}
	}

	assert(len(built) == len(entries), "left a cue unread without reporting a fault")
	// destroy_cues frees the returned SLICE, so the block behind it has to be
	// exactly as long as the slice says. It is, because nothing here appends
	// past the capacity reserved above -- asserted rather than trusted, since a
	// grown array would be freed at the wrong size and stay silent until an
	// unrelated allocation came back corrupted.
	assert(cap(built) == len(built), "the returned slice does not own exactly the block it names")
	disordered := first_disordered_cue(built[:])
	fmt.assertf(
		disordered == 0,
		"built cue %d, which the per-cue checks should have rejected",
		disordered,
	)
	return built[:], .None, 0
}

// Whether a Cue may follow the ones already built, and why not if it may not.
//
// The write side of the ordering first_disordered_cue is asked about on the
// read side (CLAUDE.md A4), stated per Cue so the report can name which one.
// Leaf comparison over external data; read_cues carries the assertions (A8).
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

	// The Engine's escaping is already undone by the decode; this is the copy
	// that outlives the json tree parse_cues destroys on the way out.
	cue = Cue {
		start = start,
		end   = end,
		text  = strings.clone(text, allocator),
	}
	assert(len(cue.text) == len(text), "the clone lost bytes the engine wrote")
	return cue, .None
}

// The widest offset this parser will read, either sign: 2^53 - 1 milliseconds,
// about 285,000 years.
//
// Every number in the Engine's JSON reaches read_millis as an f64, and an f64
// represents every integer up to 2^53 exactly. The limit sits one BELOW that,
// and the gap is the entire guard: at 2^53 the spacing between representable
// values becomes two, so the literal 2^53 + 1 rounds DOWN onto 2^53, and a limit
// set there would read back a number nobody wrote. Below 2^53 rounding is
// monotonic and exact, so no literal outside this range can arrive inside it and
// no literal inside it arrives as anything else.
@(private)
READABLE_MS :: (1 << 53) - 1

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
// THE ESCAPE IS NOT TO PASS THE FLAG. Passing it trades an offset that is
// silently ZERO for one that is silently WRONG, which is strictly worse:
// `core:encoding/json` reads an integer token with `strconv.parse_i64`, and
// parse_i64 WRAPS on overflow and reports ok = true, so there is no failure to
// read even if the discarded error were read. `99999999999999999999999` arrives
// as 200376420520689663 -- about six million years, which a range check can at
// least see -- and `18446744073709556616`, which is 2^64 + 5000, arrives as
// 5000. Nothing can see that one: 5000 is an ordinary offset, and the token text
// it was written as is gone by the time this sees the value.
//
// A float carries no such branch. Rounding to f64 is monotonic, so a literal
// outside READABLE_MS arrives as a number outside READABLE_MS -- that same
// 2^64 + 5000 arrives as 1.8446744073709556e19 and is refused here -- and a
// literal inside it arrives exactly. So decode_engine_json asks for no integers
// at all, and every offset is read from the one form that cannot lie about its
// own magnitude. `integer-offset-wraps-into-range.json` in the rejected table is
// what holds that shut.
@(private)
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

// Renders one operating error as a line naming the input it came from.
//
// The allocator is explicit and never defaulted: the line outlives this
// procedure and is written by a worker other than the one that reads it
// (ADR-0010).
error_message :: proc(err: Parse_Error, allocator: mem.Allocator) -> string {
	assert(err.fault != .None, "there is no message for a parse that did not fail")
	assert(len(err.json_name) > 0, "an operating error must name the input it is reported against")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs a chosen allocator",
	)

	facts := FAULT[err.fault]
	assert(len(facts.says) > 0, "a fault was added to Parse_Fault without a row in FAULT")

	// Which sentence is being printed decides the grammar, and the fault says
	// which sentence it is. Reading that off the ordinal instead made an
	// ordinal accidentally left at zero print a Cue's half-sentence as though
	// it were about the file.
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

	// The same missing-row check disposition_of and error_message make, at the
	// third place the table is read (CLAUDE.md A4).
	scope := FAULT[fault].scope
	assert(scope != .Unset, "a fault was added to Parse_Fault without a row in FAULT")

	// The ordinal against the scope the fault declares, at the one place a
	// Parse_Error is written, so no call site has to remember the convention
	// and error_message can print by scope without checking the number. Both
	// sides of it (CLAUDE.md A3): a fault about the file may not blame a Cue,
	// and a fault about a Cue must say which one.
	if scope == .Input {
		assert(cue == 0, "a fault about the input as a whole blamed a cue")
	} else {
		assert(cue > 0, "a fault about one cue did not say which")
	}
	return Parse_Error{fault = fault, json_name = json_name, cue = cue}
}
