package artifact

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

// The Model's identity, against real files on a real disk.
//
// TWO THINGS ARE BEING CHECKED HERE AND THEY ARE NOT THE SAME THING. One is the
// digest: a Model swapped for another under the same name is the case the path
// cannot notice and the whole reason ADR-0003 records a hash at all. The other
// is ADR-0002's ASCII rule, which is not about hashing anything -- the Engine is
// `int main(int, char**)` under MSVC, so argv reaches it in the system ANSI code
// page, and a Model path carrying a byte outside ASCII fails to open with no
// output at all and exit code zero.
//
// HOW THE ASCII REFUSAL IS CHECKED WITHOUT A NON-ASCII WINDOWS ACCOUNT, which is
// the scenario ADR-0002 actually names: the account name is only one way a
// non-ASCII byte gets into a resolved path, and a directory this suite makes for
// itself is another. What the account-name case adds is that the path can be
// perfectly ASCII AS SPELLED and non-ASCII once resolved, and that half is
// checked from the other direction -- a path spelled with a non-ASCII component
// that resolves away is ACCEPTED, which is only true of a check on the resolved
// path.

// The SHA-256 of `abc`, from FIPS 180-4's own worked example, and of the empty
// input. Both are constants published far outside this repository: an
// independent source of truth rather than a value this package produced and then
// compared with itself.
@(private)
ABC_SHA256 :: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

@(test)
a_models_identity_is_the_content_of_the_file_and_not_its_name :: proc(t: ^testing.T) {
	directory := scratch(t, "model-abc")
	defer delete(directory, context.allocator)
	defer remove_scratch(directory)

	path := file_in(t, directory, "ggml-large-v3.bin", "abc")
	defer delete(path, context.allocator)

	identified, fault := identify_model(path, context.allocator)
	defer destroy_model(identified, context.allocator)

	testing.expect_value(t, fault, Model_Fault.None)
	testing.expect_value(t, identified.digest, Digest(ABC_SHA256))
	testing.expect_value(t, identified.bytes, i64(3))
	// The RESOLVED path, which is what the Engine will be handed and what a
	// Sidecar records -- so two Batches that named one Model two ways record one
	// Model rather than two.
	testing.expect(
		t,
		os.exists(identified.path),
		"the Model was identified by a path nothing opens",
	)
}

@(test)
an_empty_model_file_is_still_identified_rather_than_treated_as_absent :: proc(t: ^testing.T) {
	// The negative space of the case above (A3), and not a curiosity: a Model
	// file of no bytes is what an interrupted download leaves, and it has an
	// identity like any other file. What must NOT happen is that it reads as
	// unreadable, because then the Batch's diagnostic sends a user looking for a
	// missing file that is sitting right there.
	directory := scratch(t, "model-empty")
	defer delete(directory, context.allocator)
	defer remove_scratch(directory)

	path := file_in(t, directory, "empty.bin", "")
	defer delete(path, context.allocator)

	identified, fault := identify_model(path, context.allocator)
	defer destroy_model(identified, context.allocator)

	testing.expect_value(t, fault, Model_Fault.None)
	testing.expect_value(t, identified.bytes, i64(0))
	testing.expect_value(
		t,
		identified.digest,
		Digest("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
	)
}

@(test)
a_model_bigger_than_one_read_hashes_the_same_as_the_whole_of_it_at_once :: proc(t: ^testing.T) {
	// THE STREAMING LOOP, which is the only part of the hash this package wrote.
	// A real Model is upwards of a gigabyte and is never loaded into memory, so
	// it is hashed a chunk at a time -- and a loop that dropped a chunk, or
	// re-hashed one, would still produce a perfectly plausible digest that
	// nothing but this case could tell from the right one.
	//
	// Compared against the one-shot hash of the same bytes: the same algorithm
	// through a different entry point, which is an answer this package did not
	// compute. THE INDEPENDENCE IS ABOUT THE HASH and not about the hexadecimal,
	// which used to be written out a third time here by hand; what pins the
	// rendering is the two published constants above and in sidecar_test, both
	// compared against what identify_model really produced.
	directory := scratch(t, "model-big")
	defer delete(directory, context.allocator)
	defer remove_scratch(directory)

	// Not a run of one byte repeated: a loop that hashed the same chunk twice
	// would agree with itself over that. Every chunk here differs from every
	// other, and the file is deliberately not a whole number of chunks.
	written := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&written)
	for at := 0; strings.builder_len(written) < 3 * MODEL_READ_BYTES + 517; at += 1 {
		fmt.sbprintf(&written, "chunk %d of a Model that is bigger than one read\n", at)
	}
	content := strings.to_string(written)

	path := file_in(t, directory, "big.bin", content)
	defer delete(path, context.allocator)

	at_once := hash.hash_bytes(.SHA256, transmute([]u8)content, context.allocator)
	defer delete(at_once, context.allocator)
	expected := hex.encode(at_once, context.allocator)
	defer delete(expected, context.allocator)

	identified, fault := identify_model(path, context.allocator)
	defer destroy_model(identified, context.allocator)

	testing.expect_value(t, fault, Model_Fault.None)
	testing.expect_value(t, string(identified.digest), string(expected))
	testing.expect_value(t, identified.bytes, i64(len(content)))
}

@(test)
a_model_under_a_path_the_engine_cannot_open_is_refused_and_never_read :: proc(t: ^testing.T) {
	// ADR-0002's rule, and it is a refusal rather than a repair: 8.3 short-name
	// generation can be disabled per volume, so there is no sanitised spelling of
	// this path that can be relied on to exist. The ASCII property is CHOSEN.
	directory := scratch(t, "model-\u5f55\u97f3")
	defer delete(directory, context.allocator)
	defer remove_scratch(directory)

	// The file really is there, so the refusal below is the ASCII rule and not a
	// Model nobody could find.
	path := file_in(t, directory, "ggml-large-v3.bin", "abc")
	defer delete(path, context.allocator)
	testing.expect(t, os.exists(path), "the case could not put a Model where it meant to")

	identified, fault := identify_model(path, context.allocator)
	defer destroy_model(identified, context.allocator)

	testing.expect_value(t, fault, Model_Fault.Path_Not_Ascii)
	// And it was not read (A3). The refusal comes before the file is opened,
	// because a Model happily hashed under a path the Engine cannot open is the
	// failure that shows up two stages later as an Engine that produced nothing.
	testing.expect_value(t, identified.digest, Digest(""))
	testing.expect_value(t, identified.bytes, i64(0))
}

@(test)
a_model_path_that_resolves_to_ascii_is_accepted_however_it_was_spelled :: proc(t: ^testing.T) {
	// THE RESOLVED PATH IS WHAT IS CHECKED, from the direction a suite can
	// actually reach. ADR-0002 asks that the check be on the resolved path and
	// names a non-ASCII Windows ACCOUNT name inside %LOCALAPPDATA% as the
	// scenario -- a path that is perfectly ASCII as spelled and is not once
	// resolved. This is that claim from the other side: a path spelled with a
	// non-ASCII component that resolves AWAY is accepted, which is true of a
	// check on the resolved path and false of a check on the spelling.
	directory := scratch(t, "model-resolved")
	defer delete(directory, context.allocator)
	defer remove_scratch(directory)

	path := file_in(t, directory, "ggml-large-v3.bin", "abc")
	defer delete(path, context.allocator)

	spelled := fmt.aprintf(
		"%s\\\u5f55\u97f3\\..\\ggml-large-v3.bin",
		directory,
		allocator = context.allocator,
	)
	defer delete(spelled, context.allocator)

	identified, fault := identify_model(spelled, context.allocator)
	defer destroy_model(identified, context.allocator)

	testing.expect_value(t, fault, Model_Fault.None)
	testing.expect_value(t, identified.digest, Digest(ABC_SHA256))
	testing.expect(
		t,
		!strings.contains(identified.path, "\u5f55"),
		"a Model was identified by a path that still carries what it resolved away",
	)
}

@(test)
a_model_that_is_not_there_is_refused_rather_than_asserted :: proc(t: ^testing.T) {
	// A8: the Model's path is a settings field, so one naming nothing that exists
	// is an operating error. It stops the Batch -- there is nowhere for any
	// Recording's Cues to come from -- and it does so by saying so.
	directory := scratch(t, "model-absent")
	defer delete(directory, context.allocator)
	defer remove_scratch(directory)

	path := fmt.aprintf("%s\\never-written.bin", directory, allocator = context.allocator)
	defer delete(path, context.allocator)

	identified, fault := identify_model(path, context.allocator)
	defer destroy_model(identified, context.allocator)

	testing.expect_value(t, fault, Model_Fault.Unreadable)
}

@(test)
every_model_fault_renders_a_line_naming_the_model_and_stopping_the_batch :: proc(t: ^testing.T) {
	// The guard an exhaustive switch cannot give on its own: an arm that is
	// present and says nothing compiles, and is then found by the renderer's own
	// assertion in front of a user, on a Batch that is already refusing to start.
	for fault in Model_Fault {
		if fault == .None {
			continue
		}
		message := model_error_message(fault, "C:\\models\\ggml-large-v3.bin", context.allocator)
		defer delete(message, context.allocator)

		testing.expectf(t, len(message) > 0, "%v rendered as nothing at all", fault)
		testing.expectf(
			t,
			strings.contains(message, "ggml-large-v3.bin"),
			"%v does not name the Model it is about",
			fault,
		)
	}
}
