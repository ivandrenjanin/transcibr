#+vet explicit-allocators
package audio

// The one testable claim issue #74 asks to be held here: `FFMPEG` and
// `FFPROBE` are the bare names a Process contract passes to CreateProcessW,
// and a space or a quote in either would need a quoting rule this package
// has never had to write. `defaulted_tools` itself is exercised beside it,
// now that the decision moved from src/cli (finding 4 of the 2026-08-06
// review).

import "core:strings"
import "core:testing"

@(test)
the_bare_tool_names_carry_no_quoting_hazard :: proc(t: ^testing.T) {
	for name in ([]string{FFMPEG, FFPROBE}) {
		testing.expectf(
			t,
			!strings.contains_any(name, " \t\"'"),
			"%q carries a character that would need quoting on a command line",
			name,
		)
	}
}

@(test)
defaulted_tools_fills_only_what_the_caller_left_empty :: proc(t: ^testing.T) {
	named := Tools {
		ffmpeg  = "C:\\bundled\\ffmpeg.exe",
		ffprobe = "C:\\bundled\\ffprobe.exe",
	}
	defaulted_tools(&named)
	testing.expect_value(t, named.ffmpeg, "C:\\bundled\\ffmpeg.exe")
	testing.expect_value(t, named.ffprobe, "C:\\bundled\\ffprobe.exe")

	bare := Tools{}
	defaulted_tools(&bare)
	testing.expect_value(t, bare.ffmpeg, FFMPEG)
	testing.expect_value(t, bare.ffprobe, FFPROBE)
}
