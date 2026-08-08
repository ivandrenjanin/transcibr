#+vet explicit-allocators
package artifact

import "core:crypto/hash"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "transcibr:testkit"

// From FIPS 180-4's own worked example: a source of truth outside this
// repository rather than a value this package produced and compared with itself.
@(private)
ABC_SHA256 :: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

@(test)
a_models_identity_is_the_content_of_the_file_and_not_its_name :: proc(t: ^testing.T) {
	directory := testkit.made_scratch_cache(t, "artifact", "model-abc", context.allocator)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	path := testkit.fixture_file(t, directory, "ggml-large-v3.bin", "abc", context.allocator)
	defer delete(path, context.allocator)

	identified, fault := identify_model(path, context.allocator)
	defer destroy_model(identified, context.allocator)

	testing.expect_value(t, fault, Model_Fault.None)
	testing.expect_value(t, identified.digest, Digest(ABC_SHA256))
	testing.expect_value(t, identified.bytes, i64(3))
	testing.expect(
		t,
		os.exists(identified.path),
		"the Model was identified by a path nothing opens",
	)
}

// Issue #216, item 2: `model_error_message` hard-coded
// `process.batch_setup_message`'s own "the Batch cannot start" ending
// unconditionally, the identical defect `engine_error_message` carried until
// #237. `framing` threads a caller's own consequence clause down to
// `batch_setup_message` in its place, defaulted so every un-migrated call
// site (`--plan`, `--transcribe`, `--batch` through `main.odin`) keeps
// today's exact bytes without passing anything new.
@(test)
a_model_refusal_can_end_on_a_callers_own_framing_instead_of_the_batch :: proc(t: ^testing.T) {
	message := model_error_message(
		.Unreadable,
		"D:\\weights\\ggml-large-v3.bin",
		context.allocator,
		"--doctor cannot verify this Model",
	)
	defer delete(message, context.allocator)

	testing.expectf(
		t,
		strings.contains(message, "--doctor cannot verify this Model"),
		"a Model refusal ignored its caller-supplied framing: <%s>",
		message,
	)
	testing.expectf(
		t,
		!strings.contains(message, "the Batch cannot start"),
		"a caller-supplied framing still carries the Batch's own framing: <%s>",
		message,
	)
}

@(test)
an_empty_model_file_is_still_identified_rather_than_treated_as_absent :: proc(t: ^testing.T) {
	directory := testkit.made_scratch_cache(t, "artifact", "model-empty", context.allocator)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	path := testkit.fixture_file(t, directory, "empty.bin", "", context.allocator)
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
	directory := testkit.made_scratch_cache(t, "artifact", "model-big", context.allocator)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	written := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&written)
	for at := 0; strings.builder_len(written) < 3 * MODEL_READ_BYTES + 517; at += 1 {
		fmt.sbprintf(&written, "chunk %d of a Model that is bigger than one read\n", at)
	}
	content := strings.to_string(written)

	path := testkit.fixture_file(t, directory, "big.bin", content, context.allocator)
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
	directory := testkit.made_scratch_cache(t, "artifact", "model-\u5f55\u97f3", context.allocator)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	path := testkit.fixture_file(t, directory, "ggml-large-v3.bin", "abc", context.allocator)
	defer delete(path, context.allocator)
	testing.expect(t, os.exists(path), "the case could not put a Model where it meant to")

	identified, fault := identify_model(path, context.allocator)
	defer destroy_model(identified, context.allocator)

	testing.expect_value(t, fault, Model_Fault.Path_Not_Ascii)
	testing.expect_value(t, identified.digest, Digest(""))
	testing.expect_value(t, identified.bytes, i64(0))
}

@(test)
a_model_path_that_resolves_to_ascii_is_accepted_however_it_was_spelled :: proc(t: ^testing.T) {
	directory := testkit.made_scratch_cache(t, "artifact", "model-resolved", context.allocator)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	path := testkit.fixture_file(t, directory, "ggml-large-v3.bin", "abc", context.allocator)
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
	directory := testkit.made_scratch_cache(t, "artifact", "model-absent", context.allocator)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	path := fmt.aprintf("%s\\never-written.bin", directory, allocator = context.allocator)
	defer delete(path, context.allocator)

	identified, fault := identify_model(path, context.allocator)
	defer destroy_model(identified, context.allocator)

	testing.expect_value(t, fault, Model_Fault.Unreadable)
}

// Big enough that hashing it takes real, measurable time -- software SHA-256
// runs nowhere near a disk's own transfer rate, so 128 MiB of it stays well
// clear of a 1 ms bound on any machine this suite runs on, without paying
// the cost of writing something the size of a real Model.
@(private)
MODEL_TEST_BOUND_FILE_BYTES :: 128 * 1024 * 1024

// Finding 8 of PR #64's second review: this margin used to be a literal
// `5 * time.Second`, numerically equal to `transcibr:child`'s own
// (`@(private)`, unreachable from here) `CANCEL_BOUND_MS` by coincidence
// rather than by reference. A machine slow enough to make cancellation
// itself take close to five seconds would then fail this assertion at
// exactly the moment `digest_of_bounded` actually reached the `.Unstoppable`
// leak path -- two distinct failures, sharing one cause, with nothing here
// able to say which had happened. Generous against the worst case a
// correctly working bound could ever legitimately take -- the 1 ms this
// case hands `digest_of_bounded` plus a cancellation running its own full
// course -- rather than tuned to equal it, so a machine slow enough to trip
// this is slow enough that something is actually wrong.
@(private)
MODEL_BOUND_TEST_SLACK :: 30 * time.Second

// Finding 3 of the PR #64 review: `--model-file` is hand-typed, the same
// class of input `--from-json` is, and issue #27's read half was not closed
// for it. `digest_of_bounded` is the seam this pins directly, at a bound of
// 1 ms against a file large enough that no real machine finishes hashing it
// that fast -- proving the bound is actually wired through rather than
// merely declared, without needing a genuinely stalled network share to
// demonstrate it.
@(test)
a_model_that_cannot_be_hashed_within_its_bound_is_reported_rather_than_awaited_forever :: proc(
	t: ^testing.T,
) {
	directory := testkit.made_scratch_cache(t, "artifact", "model-bound", context.allocator)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	path := fmt.aprintf("%s\\slow.bin", directory, allocator = context.allocator)
	defer delete(path, context.allocator)
	defer os.remove(path)

	if !testkit.write_flood(
		t,
		path,
		MODEL_TEST_BOUND_FILE_BYTES,
		"a byte of a Model too big to hash inside a millisecond\n",
		context.allocator,
	) {
		return
	}

	started := time.tick_now()
	digest, bytes, fault := digest_of_bounded(path, 1, context.allocator)
	elapsed := time.tick_since(started)
	defer delete(string(digest), context.allocator)

	testing.expect_value(t, fault, Model_Fault.Did_Not_Finish)
	testing.expect_value(t, bytes, i64(0))
	testing.expect(t, len(digest) == 0, "an abandoned hash handed back a digest it never finished")
	testing.expectf(
		t,
		elapsed < MODEL_BOUND_TEST_SLACK,
		"a hash bounded at 1 ms took %v to be reported, which is not being bounded at all",
		elapsed,
	)
}

// Issue #249, item 3: the loop below used to call `model_error_message` on
// its default framing and never actually read it back -- the test's own name
// claimed "and_stopping_the_batch" but nothing here checked for it, so
// mutating `process.BATCH_CANNOT_START` to a different sentence left this
// package green (measured: src/process reds, src/artifact and src/audio do
// not). `" -- the Batch cannot start"` is hand-typed rather than built from
// `process.BATCH_CANNOT_START` itself -- comparing the constant against its
// own value is tautological and cannot fail no matter what the constant
// says.
@(test)
every_model_fault_renders_a_line_naming_the_model_and_stopping_the_batch :: proc(t: ^testing.T) {
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
		testing.expectf(
			t,
			strings.contains(message, " -- the Batch cannot start"),
			"%v's default framing does not say the Batch cannot start: <%s>",
			fault,
			message,
		)
	}
}

// Finding 11 of PR #64's third review: `digest_of_bounded`'s `t == nil`
// branch -- a thread to hash the Model on could not be started at all --
// used to answer `.Unreadable`, the identical fault a Model that genuinely
// will not open reports, so both rendered the identical sentence and pointed
// an operator whose Batch is thread-starved (issue #12's exhaustion case) at
// the NAS instead of at what actually happened. `.Not_Started` is a
// distinct member with a distinct sentence for exactly that reason; this
// pins the two apart so a future edit cannot quietly re-collapse them.
@(test)
a_model_hash_thread_that_could_not_start_is_distinguished_from_an_unreadable_model :: proc(
	t: ^testing.T,
) {
	unstarted := model_fault_says(.Not_Started)
	unreadable := model_fault_says(.Unreadable)

	testing.expect(t, len(unstarted) > 0, "a thread that could not start rendered no sentence")
	testing.expect(
		t,
		unstarted != unreadable,
		"a thread that could not start reads exactly like a Model that could not be read",
	)
}
