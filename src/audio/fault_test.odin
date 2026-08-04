package audio

import "core:strings"
import "core:testing"
import "transcibr:child"

// The two fault vocabularies this package refuses in, and the one pure decision
// that lives in the shell file beside them.
//
// The shell half's own cases -- real children under a bound, a real cache swept
// -- are in run_test.odin. What is left to hand verification there is what needs
// ffmpeg and ffprobe themselves.

@(test)
a_cache_path_transcibr_can_direct_the_engine_at_is_accepted :: proc(t: ^testing.T) {
	testing.expect(t, ascii_only("C:\\Users\\drenj\\AppData\\Local\\transcibr\\cache"))
	testing.expect(t, ascii_only(""))
}

@(test)
a_cache_path_the_engine_could_not_open_is_refused :: proc(t: ^testing.T) {
	// ADR-0002, measured: `whisper-cli` is `int main(int, char**)` under MSVC,
	// so argv arrives in the system ANSI code page and a path carrying a
	// non-ASCII byte fails to open with no output at all. A non-ASCII Windows
	// ACCOUNT NAME is enough, since the cache sits under %LOCALAPPDATA%.
	//
	// ffmpeg does not have this bug -- it re-reads GetCommandLineW -- which is
	// why the check belongs at the front of the whole cache and not beside the
	// Engine: testing the extraction step alone looks perfectly clean while
	// only the transcription step fails.
	testing.expect(t, !ascii_only("C:\\Users\\Bj\u00f6rn\\AppData\\Local\\transcibr\\cache"))
	// The property is CHOSEN and not sanitised for: 8.3 short-name generation
	// looks like the escape and is a per-volume policy that can be off.
	testing.expect(t, !ascii_only("D:\\\u5f55\u97f3\\cache"))
}

// Every fault renders a line naming the Recording and saying what happened.
//
// WALKED over the whole enumeration rather than written case by case, which is
// the half that rots -- the guard the other three fault vocabularies in this
// repository carry and this one was missing. The compiler already refuses a
// Fault added without a row in FAULT, because FAULT is an enumerated array and
// `Unhandled enumerated array case` is a build failure. What nothing caught was
// a row that is PRESENT and EMPTY: an empty row compiled, passed every test,
// and was found by fault_says's own assertion in front of a user, on a
// Recording that was already failing.
//
// The emptiness is read off the table BEFORE the render, and not left to
// fault_says, because a test that trips an assertion takes the whole runner down
// with it rather than naming a case (issue #22). For the same reason the error
// handed in carries a real child fault: the two `_Not_Started` arms delegate to
// `transcibr:child`, whose own renderer asserts it was given something to say.
//
// `.None` is skipped BY NAME, so it cannot be skipped by accident. It is the one
// row in the table that is deliberately empty, and it is the success value.
@(test)
every_fault_renders_a_line_a_recordings_failure_row_can_carry :: proc(t: ^testing.T) {
	for fault in Fault {
		if fault == .None {
			continue
		}
		if !testing.expectf(t, len(FAULT[fault]) > 0, "%v has an empty row in FAULT", fault) {
			continue
		}

		err := Error {
			fault = fault,
			child = child.Error{fault = .Not_Started},
			said = 48_000,
			got = 12_000,
		}
		message := error_message(err, "C:\\clips\\one talk.mp4", context.allocator)
		defer delete(message, context.allocator)

		testing.expectf(
			t,
			strings.contains(message, FAULT[fault]),
			"%v rendered <%s>, which does not carry its own sentence",
			fault,
			message,
		)
		testing.expectf(
			t,
			strings.contains(message, "one talk.mp4"),
			"%v rendered <%s>, which does not name the Recording",
			fault,
			message,
		)
	}
}

// ------------------------------------------- the cache is not a Recording --
//
// A refusal of the scratch cache ITSELF names the cache directory. The
// vocabulary is separate from `Fault` because both of the things `Fault`'s own
// comment claims about every one of its members -- that the culprit is the
// Recording, and that the disposition is "this Recording fails and the Batch
// carries on" -- are false of these two. See fault.odin.

@(test)
a_cache_refusal_names_the_cache_directory :: proc(t: ^testing.T) {
	// The reproduction: this used to come back as a `Fault` and render through
	// error_message, whose one job is documented as NAMING THE RECORDING. At
	// Batch start there is no Recording to name, so the cache directory was
	// passed in the Recording's slot.
	message := cache_error_message(
		.Path_Not_Ascii,
		"D:\\scratch-42\\\u5f55\u97f3",
		context.allocator,
	)
	defer delete(message, context.allocator)

	testing.expectf(
		t,
		strings.contains(message, "scratch-42"),
		"a refused cache does not name the directory that was refused: <%s>",
		message,
	)
	// %q and not %s, for the reason error_message gives: the line reaches a
	// user through a UTF-16 Win32 call, and a byte that is not UTF-8 makes the
	// whole line convert to nil. The offending runes come out escaped, which is
	// what makes the line safe to carry AND still readable.
	testing.expectf(
		t,
		strings.contains(message, "\\u5f55"),
		"the bytes that got the cache refused were not escaped out of the line: <%s>",
		message,
	)
	testing.expectf(
		t,
		strings.contains(message, "Batch"),
		"a refusal that stops the whole Batch does not say so: <%s>",
		message,
	)
	// The half that was wrong (A3): this is not a Recording's failure row.
	testing.expectf(
		t,
		!strings.contains(message, "Recording"),
		"a Batch-level refusal was rendered against a Recording: <%s>",
		message,
	)
}

@(test)
every_cache_fault_renders_a_line_a_batch_can_refuse_to_start_with :: proc(t: ^testing.T) {
	// The same walk as above and NOT the same guard, which is the difference the
	// two vocabularies are worth spelling. `Fault` reads a table, so what this has
	// to catch there is a row that is present and EMPTY. Cache_Fault reads an
	// exhaustive switch, so what is left to catch is an ARM that is present and
	// empty -- the compiler has the rest of it either way.
	//
	// Read off cache_fault_says before the render rather than left to
	// cache_error_message's own assertion, because a test that trips an assertion
	// takes the whole runner down instead of naming a case (issue #22).
	for fault in Cache_Fault {
		if fault == .None {
			continue
		}
		says := cache_fault_says(fault)
		if !testing.expectf(t, len(says) > 0, "%v has no sentence at all", fault) {
			continue
		}

		message := cache_error_message(fault, "C:\\cache", context.allocator)
		defer delete(message, context.allocator)
		testing.expectf(
			t,
			strings.contains(message, says),
			"%v rendered <%s>, which does not carry its own sentence",
			fault,
			message,
		)
	}
}
