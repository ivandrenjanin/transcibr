package planning

import "core:testing"
import "core:time"
import "transcibr:transcript"

// The marker is a claim about what `transcibr:transcript` writes, and this is
// what stops it going stale: a renderer that moved the generator field turns
// THIS red rather than turning every Transcript on disk into a stranger.
@(test)
what_the_renderer_actually_writes_is_what_this_package_recognises :: proc(t: ^testing.T) {
	rendered := transcript.render_markdown(
		[]transcript.Paragraph{{start = 0, end = 1_000, text = "hello"}},
		transcript.Render_Context {
			now = time.unix(1_754_000_000, 0),
			source_display = "C:\\clips\\talk.mp4",
			engine_version = "whisper.cpp 1.9.1",
			model = "ggml-large-v3-turbo",
			language = "en",
			profile = transcript.DEFAULT_PROFILE,
		},
		transcript.ANCHOR_INTERVAL_MS,
		context.allocator,
	)
	defer delete(rendered, context.allocator)

	testing.expectf(
		t,
		written_by_transcibr(rendered),
		"a Transcript straight out of the renderer is not recognised as transcibr's: <%s>",
		rendered[:min(len(rendered), 64)],
	)
}

@(test)
a_transcript_transcibr_wrote_is_recognised_by_its_own_first_bytes :: proc(t: ^testing.T) {
	testing.expect(
		t,
		written_by_transcibr(
			"---\ngenerator: \"transcibr 0.1.0\"\nsource: \"C:\\\\clips\\\\talk.mp4\"\n",
		),
		"a Transcript this program wrote was not recognised as its own",
	)
}

@(test)
a_markdown_file_transcibr_did_not_write_is_never_taken_for_a_transcript :: proc(t: ^testing.T) {
	for stranger in ([?]string {
			"",
			"# Notes on the interview\n",
			"---\ntitle: \"my notes\"\ngenerator: \"transcibr 0.1.0\"\n",
			"---\ngenerator: \"transcribr 0.1.0\"\n",
			"---\ngenerator: \"transcibrator 0.1.0\"\n",
			"\n---\ngenerator: \"transcibr 0.1.0\"\n",
			"---\r\ngenerator: \"transcibr 0.1.0\"\n",
			"---\ngenerator: \"transcibr",
		}) {
		testing.expectf(
			t,
			!written_by_transcibr(stranger),
			"%q was mistaken for a Transcript transcibr wrote",
			stranger,
		)
	}
}
