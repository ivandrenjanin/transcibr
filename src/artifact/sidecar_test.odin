#+vet explicit-allocators
package artifact

import "core:strings"
import "core:testing"

// The digest is the SHA-256 of the empty input, a constant published far outside
// this repository -- an independent value rather than one this package computed
// and then compared with itself.
@(private)
EXAMPLE :: Sidecar {
	engine             = "C:\\tools\\whisper-cli.exe",
	engine_version     = "whisper.cpp v1.9.1",
	model              = "C:\\models\\ggml-large-v3.bin",
	model_digest       = Digest(EMPTY_SHA256),
	model_bytes        = 3_094_623_691,
	beam               = ENGINE_DEFAULT_BEAM,
	merge_profile      = "monologue",
	prompt             = "",
	source_bytes       = 402_653_184,
	source_modified_ns = 1_754_136_000_000_000_000,
	container_ms       = 253_949,
}

@(private)
EMPTY_SHA256 :: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

// Spelled a line at a time with explicit newlines rather than as a raw string,
// because `.gitattributes` checks every `.odin` file out with CRLF endings: a
// raw literal spanning lines would pin a format nothing writes.
@(private)
GOLDEN_SIDECAR ::
	"transcibr-sidecar 2\n" +
	"engine: \"C:\\\\tools\\\\whisper-cli.exe\"\n" +
	"engine_sha256: \"whisper.cpp v1.9.1\"\n" +
	"model: \"C:\\\\models\\\\ggml-large-v3.bin\"\n" +
	"model_sha256: \"" +
	EMPTY_SHA256 +
	"\"\n" +
	"model_bytes: 3094623691\n" +
	"beam: 0\n" +
	"merge_profile: \"monologue\"\n" +
	"prompt: \"\"\n" +
	"source_bytes: 402653184\n" +
	"source_modified_ns: 1754136000000000000\n" +
	"container_ms: 253949\n"

@(test)
a_sidecar_is_written_in_one_fixed_order_a_later_run_can_read :: proc(t: ^testing.T) {
	written := sidecar_text(EXAMPLE, context.allocator)
	defer delete(written, context.allocator)

	testing.expect_value(t, written, GOLDEN_SIDECAR)
}

@(test)
the_one_constructor_carries_every_field_through_to_the_record :: proc(t: ^testing.T) {
	built := sidecar_of(
		engine = EXAMPLE.engine,
		engine_version = EXAMPLE.engine_version,
		model = Model {
			path = EXAMPLE.model,
			digest = EXAMPLE.model_digest,
			bytes = EXAMPLE.model_bytes,
		},
		beam = EXAMPLE.beam,
		merge_profile = EXAMPLE.merge_profile,
		prompt = EXAMPLE.prompt,
		source_bytes = EXAMPLE.source_bytes,
		source_modified_ns = EXAMPLE.source_modified_ns,
		container_ms = EXAMPLE.container_ms,
	)
	testing.expect_value(t, changed(built, EXAMPLE), Change.None)
}

@(test)
a_sidecar_reads_back_as_the_record_that_was_written :: proc(t: ^testing.T) {
	written := sidecar_text(EXAMPLE, context.allocator)
	defer delete(written, context.allocator)

	read, ok := read_sidecar(written, context.allocator)
	defer destroy_sidecar(read, context.allocator)

	testing.expect(t, ok, "a Sidecar this package wrote could not be read back")
	testing.expect_value(t, changed(read, EXAMPLE), Change.None)
	testing.expect_value(t, read.engine_version, EXAMPLE.engine_version)
	testing.expect_value(t, read.engine, EXAMPLE.engine)
	testing.expect_value(t, read.model, EXAMPLE.model)
	testing.expect_value(t, read.model_digest, EXAMPLE.model_digest)
	testing.expect_value(t, read.model_bytes, EXAMPLE.model_bytes)
	testing.expect_value(t, read.beam, EXAMPLE.beam)
	testing.expect_value(t, read.merge_profile, EXAMPLE.merge_profile)
	testing.expect_value(t, read.prompt, EXAMPLE.prompt)
	testing.expect_value(t, read.source_bytes, EXAMPLE.source_bytes)
	testing.expect_value(t, read.source_modified_ns, EXAMPLE.source_modified_ns)
	testing.expect_value(t, read.container_ms, EXAMPLE.container_ms)
}

@(test)
a_prompt_carrying_a_newline_survives_being_written_and_read_back :: proc(t: ^testing.T) {
	awkward := EXAMPLE
	awkward.prompt = "acronyms: RFC 3339\r\n\"quoted\" and a \\ backslash\ttabbed"

	written := sidecar_text(awkward, context.allocator)
	defer delete(written, context.allocator)
	testing.expect_value(t, strings.count(written, "\n"), 12)

	read, ok := read_sidecar(written, context.allocator)
	defer destroy_sidecar(read, context.allocator)
	testing.expect(t, ok, "a Sidecar carrying an awkward prompt could not be read back")
	testing.expect_value(t, read.prompt, awkward.prompt)
}

@(test)
a_sidecar_that_is_not_what_transcibr_writes_is_unknown_rather_than_half_read :: proc(
	t: ^testing.T,
) {
	rejected := [?]string {
		"",
		"transcibr-sidecar 1\n",
		"transcibr-sidecar 3\n" + GOLDEN_SIDECAR[len("transcibr-sidecar 1\n"):],
		GOLDEN_SIDECAR[len("transcibr-sidecar 1\n"):],
		GOLDEN_SIDECAR[:len(GOLDEN_SIDECAR) / 2],
		GOLDEN_SIDECAR + "beam: 4\n",
		GOLDEN_SIDECAR + "unheard_of: \"1\"\n",
		strings.concatenate({GOLDEN_SIDECAR, "\n"}, context.temp_allocator),
	}
	for text, at in rejected {
		read, ok := read_sidecar(text, context.allocator)
		defer destroy_sidecar(read, context.allocator)

		testing.expectf(t, !ok, "rejected case %d was read as a Sidecar", at)
		testing.expectf(t, len(read.model) == 0, "rejected case %d was half read", at)
	}
}

@(test)
a_sidecar_whose_numbers_are_not_numbers_is_unknown :: proc(t: ^testing.T) {
	golden := GOLDEN_SIDECAR
	for spoiled in ([?]string{"beam: four\n", "beam: -1\n", "beam: \"0\"\n", "beam: 0 \n"}) {
		text := strings.concatenate(
			{golden[:strings.index(golden, "beam: ")], spoiled},
			context.temp_allocator,
		)
		whole := strings.concatenate(
			{text, golden[strings.index(golden, "merge_profile"):]},
			context.temp_allocator,
		)

		read, ok := read_sidecar(whole, context.allocator)
		defer destroy_sidecar(read, context.allocator)
		testing.expectf(t, !ok, "%q was read as a beam size", spoiled)
	}
}

@(test)
a_recording_made_under_the_same_settings_is_not_stale :: proc(t: ^testing.T) {
	testing.expect_value(t, changed(EXAMPLE, EXAMPLE), Change.None)
}

@(test)
every_setting_a_sidecar_records_names_itself_when_it_changes :: proc(t: ^testing.T) {
	moved := EXAMPLE
	moved.source_bytes += 1
	testing.expect_value(t, changed(moved, EXAMPLE), Change.Source)

	moved = EXAMPLE
	moved.source_modified_ns += 1
	testing.expect_value(t, changed(moved, EXAMPLE), Change.Source)

	moved = EXAMPLE
	moved.engine_version = "whisper.cpp v1.9.2"
	testing.expect_value(t, changed(moved, EXAMPLE), Change.Engine_Version)

	moved = EXAMPLE
	moved.model = "C:\\models\\ggml-large-v3-turbo.bin"
	testing.expect_value(t, changed(moved, EXAMPLE), Change.Model)

	moved = EXAMPLE
	moved.model_bytes += 1
	testing.expect_value(t, changed(moved, EXAMPLE), Change.Model)

	moved = EXAMPLE
	moved.beam = 8
	testing.expect_value(t, changed(moved, EXAMPLE), Change.Beam)

	moved = EXAMPLE
	moved.prompt = "ACL, RFC, GDPR"
	testing.expect_value(t, changed(moved, EXAMPLE), Change.Prompt)

	moved = EXAMPLE
	moved.container_ms += 1
	testing.expect_value(t, changed(moved, EXAMPLE), Change.Container_Duration)

	moved = EXAMPLE
	moved.merge_profile = "conversation"
	testing.expect_value(t, changed(moved, EXAMPLE), Change.Merge_Profile)
}

// The Engine is identified by digest, never by path (ADR-0027/ADR-0037): a
// relocated or differently spelled `--engine-exe` argument with the same
// bytes is not a changed Engine, even though `engine` itself is a recorded
// field that legitimately differs between two runs of the very same binary.
@(test)
an_engine_recorded_under_a_different_spelling_of_the_same_path_is_not_a_changed_engine :: proc(
	t: ^testing.T,
) {
	moved := EXAMPLE
	moved.engine = "C:\\tools\\.\\whisper-cli.exe"
	testing.expect_value(t, changed(moved, EXAMPLE), Change.None)
}

@(test)
a_model_swapped_for_one_of_the_same_name_and_size_is_still_a_changed_model :: proc(t: ^testing.T) {
	swapped := EXAMPLE
	swapped.model_digest = Digest(
		"0000000000000000000000000000000000000000000000000000000000000000",
	)
	testing.expect_value(t, changed(swapped, EXAMPLE), Change.Model)
}

@(test)
a_changed_model_beats_a_changed_merge_profile :: proc(t: ^testing.T) {
	both := EXAMPLE
	both.model_digest = Digest("1111111111111111111111111111111111111111111111111111111111111111")
	both.merge_profile = "conversation"
	testing.expect_value(t, changed(both, EXAMPLE), Change.Model)
}
