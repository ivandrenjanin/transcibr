#+vet explicit-allocators
package cliargs

import "core:testing"
import "transcibr:transcript"

@(private)
Batch_Options_Fixture :: struct {
	using common: Common_Options,
	root:         string,
	follow:       bool,
}

@(test)
common_options_embeds_by_using_and_exposes_its_fields_unqualified :: proc(t: ^testing.T) {
	o: Batch_Options_Fixture
	o.root = "recordings"
	o.model = "model.bin"
	o.engine = "engine.exe"
	o.cache = "cache-dir"
	o.tools.ffmpeg = "ffmpeg.exe"
	o.tools.ffprobe = "ffprobe.exe"
	o.prompt = "a prompt"
	o.profile = transcript.Merge_Profile.Conversation

	testing.expect_value(t, o.root, "recordings")
	testing.expect_value(t, o.common.model, "model.bin")
	testing.expect_value(t, o.common.engine, "engine.exe")
	testing.expect_value(t, o.common.cache, "cache-dir")
	testing.expect_value(t, o.common.tools.ffmpeg, "ffmpeg.exe")
	testing.expect_value(t, o.common.tools.ffprobe, "ffprobe.exe")
	testing.expect_value(t, o.common.prompt, "a prompt")
	testing.expect_value(t, o.common.profile, transcript.Merge_Profile.Conversation)
}

@(test)
tools_is_a_plain_two_string_struct_and_not_audio_dot_tools :: proc(t: ^testing.T) {
	tools := Tools {
		ffmpeg  = "ffmpeg.exe",
		ffprobe = "ffprobe.exe",
	}

	testing.expect_value(t, tools.ffmpeg, "ffmpeg.exe")
	testing.expect_value(t, tools.ffprobe, "ffprobe.exe")
}
