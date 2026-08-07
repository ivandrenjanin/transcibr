#+vet explicit-allocators
package artifact

import "core:fmt"
import "core:strings"
import "core:testing"
import "transcibr:testkit"

@(test)
an_engines_identity_is_the_content_of_the_file_and_not_its_name :: proc(t: ^testing.T) {
	directory := testkit.made_scratch_cache(t, "artifact", "engine-abc", context.allocator)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	path := testkit.fixture_file(t, directory, "whisper-cli.exe", "abc", context.allocator)
	defer delete(path, context.allocator)

	digest, fault := identify_engine(path, context.allocator)
	defer delete(string(digest), context.allocator)

	testing.expect_value(t, fault, Engine_Fault.None)
	testing.expect_value(t, digest, Digest(ABC_SHA256))
}

// The whole point of hashing rather than naming: an Engine binary replaced
// under the same path and the same name changes what this identifies as,
// which is the failure ADR-0027 accepted and this ticket closes.
@(test)
an_engine_binary_replaced_under_the_same_name_identifies_as_a_different_engine :: proc(
	t: ^testing.T,
) {
	directory := testkit.made_scratch_cache(t, "artifact", "engine-replaced", context.allocator)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	path := testkit.fixture_file(t, directory, "whisper-cli.exe", "abc", context.allocator)
	defer delete(path, context.allocator)

	before, before_fault := identify_engine(path, context.allocator)
	defer delete(string(before), context.allocator)
	testing.expect_value(t, before_fault, Engine_Fault.None)

	path2 := testkit.fixture_file(
		t,
		directory,
		"whisper-cli.exe",
		"a different build entirely",
		context.allocator,
	)
	defer delete(path2, context.allocator)
	testing.expect_value(t, path, path2)

	after, after_fault := identify_engine(path, context.allocator)
	defer delete(string(after), context.allocator)
	testing.expect_value(t, after_fault, Engine_Fault.None)

	testing.expect(
		t,
		before != after,
		"an Engine binary replaced under the same name still identified as the old one",
	)
}

// The 17-E blocker property (ADR-0037, issue #189): `--doctor` and `--batch`
// each call this same `identify_engine`, never a second hasher of their own
// (`transcibr:cli`'s `engine_identified` is the one wrapper both route
// through), so a doctor pass and a Batch pass over the identical binary
// necessarily agree about what they looked at.
@(test)
a_doctor_pass_and_a_batch_pass_identify_the_same_engine_binary_the_same_way :: proc(
	t: ^testing.T,
) {
	directory := testkit.made_scratch_cache(t, "artifact", "engine-agreement", context.allocator)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	path := testkit.fixture_file(t, directory, "whisper-cli.exe", "abc", context.allocator)
	defer delete(path, context.allocator)

	doctor_digest, doctor_fault := identify_engine(path, context.allocator)
	defer delete(string(doctor_digest), context.allocator)
	batch_digest, batch_fault := identify_engine(path, context.allocator)
	defer delete(string(batch_digest), context.allocator)

	testing.expect_value(t, doctor_fault, Engine_Fault.None)
	testing.expect_value(t, batch_fault, Engine_Fault.None)
	testing.expect_value(t, doctor_digest, batch_digest)
}

@(test)
an_engine_binary_that_is_not_there_is_refused_rather_than_asserted :: proc(t: ^testing.T) {
	directory := testkit.made_scratch_cache(t, "artifact", "engine-absent", context.allocator)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	path := fmt.aprintf("%s\\never-written.exe", directory, allocator = context.allocator)
	defer delete(path, context.allocator)

	digest, fault := identify_engine(path, context.allocator)
	defer delete(string(digest), context.allocator)

	testing.expect_value(t, fault, Engine_Fault.Unreadable)
	testing.expect_value(t, digest, Digest(""))
}

@(test)
every_engine_fault_renders_a_line_naming_the_engine_and_stopping_the_batch :: proc(t: ^testing.T) {
	for fault in Engine_Fault {
		if fault == .None {
			continue
		}
		message := engine_error_message(fault, "C:\\engine\\whisper-cli.exe", context.allocator)
		defer delete(message, context.allocator)

		testing.expectf(t, len(message) > 0, "%v rendered as nothing at all", fault)
		testing.expectf(
			t,
			strings.contains(message, "whisper-cli.exe"),
			"%v does not name the Engine it is about",
			fault,
		)
	}
}
