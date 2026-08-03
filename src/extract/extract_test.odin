package extract

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
