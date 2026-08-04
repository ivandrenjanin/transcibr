// Fixtures more than one suite in this package needs.
package transcript

import "core:mem"

// The Engine's silence written as BYTES rather than as spaces, which is the exact
// edge says_nothing draws. A Cue holding it is not a Saying.
@(private)
SILENCE_AS_BYTES :: " \x01\x7f "

// A GAP rather than an absolute offset, because every threshold in this package
// reads the silence between one Cue and the next -- and a table of absolute
// offsets shifts every row after the one edited.
@(private)
Shaped_Cue :: struct {
	gap_ms:      Millis,
	duration_ms: Millis,
	text:        string,
}

// The Cues borrow their text from the shape, which is static, so the result is
// freed with `delete` and never with destroy_cues -- there is nothing behind
// those strings for destroy_cues to give back.
@(private)
@(require_results)
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

	assert(cues_are_ordered(cues), "a shape laid out end to end went backwards")
	return cues
}

@(private)
say_repeatedly :: proc(
	shape: ^[dynamic]Shaped_Cue,
	text: string,
	count: int,
	duration, gap: Millis,
) {
	assert(count > 0, "a phrase said no times at all is not a repetition")
	assert(duration >= 0, "a cue cannot end before it starts")
	assert(gap >= 0, "silence cannot run backwards")

	for _ in 0 ..< count {
		append(shape, Shaped_Cue{gap_ms = gap, duration_ms = duration, text = text})
	}
}
