package transcript

import "core:mem"

// One Cue described the way a Recording is heard rather than the way the Engine
// writes it down: how much silence sits in front of it, how long it runs, and
// what was said in it.
//
// Absolute offsets are what a Cue carries and are the wrong thing for a test to
// state. Every threshold in this package reads a GAP -- the silence between one
// Cue and the next -- so a table of absolute offsets makes the quantity under
// test something a reader has to subtract out by hand, and a single edit to one
// row shifts every row after it. Stating the gap states the case.
@(private)
Shaped_Cue :: struct {
	gap_ms:      Millis,
	duration_ms: Millis,
	text:        string,
}

// Lays a shape out end to end into Cues, starting from offset zero.
//
// The Cues borrow their text from the shape, which is static, so the result is
// freed with `delete` and never with destroy_cues -- there is nothing behind
// those strings for destroy_cues to give back.
@(private)
shaped_cues :: proc(shape: []Shaped_Cue, allocator: mem.Allocator) -> []Cue {
	assert(len(shape) > 0, "a shape with nothing in it describes no cue set")
	assert(allocator.procedure != nil, "the cue set outlives this procedure")

	cues := make([]Cue, len(shape), allocator)
	at := Millis(0)
	for shaped, i in shape {
		assert(shaped.gap_ms >= 0, "silence cannot run backwards")
		assert(shaped.duration_ms >= 0, "a cue cannot end before it starts")

		start := at + shaped.gap_ms
		cues[i] = Cue {
			start = start,
			end   = start + shaped.duration_ms,
			text  = shaped.text,
		}
		at = cues[i].end
	}

	// What every consumer in this package asserts on the way in. A shape that
	// laid out backwards would have the procedure under test refusing the
	// FIXTURE, and the report would name the procedure (CLAUDE.md A4).
	assert(cues_are_ordered(cues), "a shape laid out end to end went backwards")
	return cues
}

// Appends one phrase said `count` times over, each saying the same length and
// separated by the same silence.
@(private)
say_repeatedly :: proc(shape: ^[dynamic]Shaped_Cue, text: string, count: int, duration, gap: Millis) {
	assert(count > 0, "a phrase said no times at all is not a repetition")
	assert(duration >= 0, "a cue cannot end before it starts")
	assert(gap >= 0, "silence cannot run backwards")

	for _ in 0 ..< count {
		append(shape, Shaped_Cue{gap_ms = gap, duration_ms = duration, text = text})
	}
}
