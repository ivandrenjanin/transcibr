package planning

import "core:strings"

// Whether a Markdown file beside a Recording is one of transcibr's own. The
// question the Sidecar deliberately does not answer: ADR-0026.

// The opening fence and the first field of the front matter `transcibr:transcript`
// writes, up to and including the space `version.banner` puts before the number --
// so a Transcript an OLDER transcibr wrote is still transcibr's, and a generator
// merely beginning with the same letters is not.
@(private)
TRANSCRIPT_MARKER :: "---\ngenerator: \"transcibr "

// A prefix and never a search: a hand-authored note that quotes a Transcript
// somewhere in its body carries these bytes too, and only a file that OPENS with
// them was written by this program (ADR-0008).
written_by_transcibr :: proc(head: string) -> bool {
	return strings.has_prefix(head, TRANSCRIPT_MARKER)
}
