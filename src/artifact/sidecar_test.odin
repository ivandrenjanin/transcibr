package artifact

import "core:strings"
import "core:testing"

// The Sidecar, checked as the two things it is: bytes a later run can read back,
// and a comparison that says whether a Recording still matches the settings it
// was made under (ADR-0003).
//
// Both halves are needed to hold the promise up. Presence-only resume "looks
// simpler and is wrong": a user who transcribes a Batch on one Model, judges the
// accuracy insufficient, selects another and re-runs gets every Recording
// skipped in under a second, with every Transcript on disk still the first
// Model's and the UI reporting success. That only fails to happen if what the
// Sidecar records is enough to notice -- so the record is written, read back and
// compared here, and none of the three is taken on trust from the other two.

// One filled-in Sidecar, and the bytes it must be written as.
//
// The digest is the SHA-256 of the empty input, which is a constant published
// far outside this repository -- an independent value rather than one this
// package computed and then compared with itself.
@(private)
EXAMPLE :: Sidecar {
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
// raw literal spanning lines would carry a carriage return into the comparison
// and pin a format nothing writes.
@(private)
GOLDEN_SIDECAR ::
	"transcibr-sidecar 1\n" +
	"engine: \"whisper.cpp v1.9.1\"\n" +
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
	// The bytes, pinned. A Sidecar is read back by a build that is not the one
	// that wrote it, so the format is a contract with the future and not an
	// implementation detail -- and a field quietly renamed or reordered would
	// make every Sidecar on disk unreadable, which reads to a user as every
	// Recording needing the GPU again.
	written := sidecar_text(EXAMPLE, context.allocator)
	defer delete(written, context.allocator)

	testing.expect_value(t, written, GOLDEN_SIDECAR)
}

@(test)
a_sidecar_reads_back_as_the_record_that_was_written :: proc(t: ^testing.T) {
	written := sidecar_text(EXAMPLE, context.allocator)
	defer delete(written, context.allocator)

	read, ok := read_sidecar(written, context.allocator)
	defer destroy_sidecar(read, context.allocator)

	testing.expect(t, ok, "a Sidecar this package wrote could not be read back")
	testing.expect_value(t, changed(read, EXAMPLE), Change.None)
	// Field by field as well as through `changed`, because `changed` is what is
	// under test in the cases below and a comparison that ignored a field would
	// agree with a reader that lost it.
	testing.expect_value(t, read.engine_version, EXAMPLE.engine_version)
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
	// The vocabulary prompt is the one field a user types, so it is the one that
	// can carry a byte that ends a line. Written raw it would close the record
	// half way and every field after it would be lost -- which reads back as a
	// Sidecar that will not parse, which re-runs a Recording that was finished.
	awkward := EXAMPLE
	awkward.prompt = "acronyms: RFC 3339\r\n\"quoted\" and a \\ backslash\ttabbed"

	written := sidecar_text(awkward, context.allocator)
	defer delete(written, context.allocator)
	// One line per field, whatever a field contains: a reader splits on newlines
	// and a value that added one would be read as a field of its own.
	testing.expect_value(t, strings.count(written, "\n"), 11)

	read, ok := read_sidecar(written, context.allocator)
	defer destroy_sidecar(read, context.allocator)
	testing.expect(t, ok, "a Sidecar carrying an awkward prompt could not be read back")
	testing.expect_value(t, read.prompt, awkward.prompt)
}

@(test)
a_sidecar_that_is_not_what_transcibr_writes_is_unknown_rather_than_half_read :: proc(
	t: ^testing.T,
) {
	// A8: a Sidecar is read back off a disk, so anything at all may be in it --
	// a half-written file from a crash, somebody's notes, a record a later
	// transcibr wrote. ADR-0003 disposes of every one of them the same way:
	// "a missing or unparseable sidecar simply means unknown, re-do it". So
	// there is no fault vocabulary here, and the answer is refused whole rather
	// than handed back with the fields that happened to parse.
	rejected := [?]string {
		"",
		"transcibr-sidecar 1\n",
		"transcibr-sidecar 2\n" + GOLDEN_SIDECAR[len("transcibr-sidecar 1\n"):],
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
	// The other half of the same claim, and the one a strict reader is FOR: a
	// number this reader shrugged at would be read as zero, and a zero
	// `source_bytes` compares equal to another zero -- so a corrupt Sidecar
	// would report a Recording as still matching its settings.
	// A local, because a constant cannot be sliced at an index worked out at run
	// time -- and the indices are worked out rather than spelled so that a change
	// to a field above this one does not silently move the cut into the middle of
	// another line.
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
	// ADR-0003's whole purpose, one field at a time. A field recorded but never
	// compared is a field that buys nothing, and a field compared under the
	// wrong name sends a user to change the wrong setting.
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

@(test)
a_model_swapped_for_one_of_the_same_name_and_size_is_still_a_changed_model :: proc(t: ^testing.T) {
	// The case the PATH cannot catch and the hash exists for: a Model file
	// replaced in place, under the same name. The Engine's own output cannot
	// settle it either -- it reports every large Model as the bare string
	// `large` (ADR-0003) -- so the content is what has to be recorded.
	swapped := EXAMPLE
	swapped.model_digest = Digest(
		"0000000000000000000000000000000000000000000000000000000000000000",
	)
	testing.expect_value(t, changed(swapped, EXAMPLE), Change.Model)
}

@(test)
a_changed_model_beats_a_changed_merge_profile :: proc(t: ^testing.T) {
	// THE ORDER IS THE DECISION, not an accident of how the comparison is
	// written. Every change but one means the GPU time has to be spent again;
	// a Merge Profile change alone re-renders from the retained Engine output in
	// seconds (ADR-0003). So the answer names the most expensive change there
	// is, and a caller acting on `.Merge_Profile` can be sure nothing else moved.
	both := EXAMPLE
	both.model_digest = Digest("1111111111111111111111111111111111111111111111111111111111111111")
	both.merge_profile = "conversation"
	testing.expect_value(t, changed(both, EXAMPLE), Change.Model)
}
