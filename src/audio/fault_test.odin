package audio

import "core:strings"
import "core:testing"

// The shell half of this package -- running ffprobe and ffmpeg, reading the
// produced audio back off the disk, deleting what the sweep chose -- has no
// cases here, and that is ADR-0009's ceiling stated rather than an omission:
// "the pipeline, the subprocess layer, the Win32 window and the GPU path will
// never have unit tests". Every DECISION it makes is a pure procedure with its
// own suite next door; what is left is the wiring, and the wiring is verified by
// hand against real media, recorded in the pull request.
//
// One decision in that file is pure, and it is here.

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
	// Walked over the whole enumeration, which is the guard the other three
	// vocabularies in this repository carry: the compiler already refuses a
	// member added without a row, and what nothing catches is a row that is
	// PRESENT and EMPTY.
	//
	// The emptiness is read off the table BEFORE the render rather than left to
	// cache_fault_says's own assertion, because a test that trips an assertion
	// takes the whole runner down instead of naming a case (issue #22).
	for fault in Cache_Fault {
		if fault == .None {
			continue
		}
		if !testing.expectf(t, len(CACHE_FAULT[fault]) > 0, "%v has an empty row", fault) {
			continue
		}

		message := cache_error_message(fault, "C:\\cache", context.allocator)
		defer delete(message, context.allocator)
		testing.expectf(
			t,
			strings.contains(message, CACHE_FAULT[fault]),
			"%v rendered <%s>, which does not carry its own sentence",
			fault,
			message,
		)
	}
}
