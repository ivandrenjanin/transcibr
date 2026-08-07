#+vet explicit-allocators
package artifact

import "core:fmt"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"
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
// -- issue #216 gave `--doctor` its own cli-level call site
// (`doctor_engine_identified`, `src/cli/doctor.odin`) so its refusal could
// stop naming the Batch, but both it and `--batch`'s `engine_identified`
// still call this one hasher -- so a doctor pass and a Batch pass over the
// identical binary necessarily agree about what they looked at.
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

// Issue #216: `engine_error_message` used to hard-code
// `process.batch_setup_message`'s own "the Batch cannot start" ending
// unconditionally, so `--doctor` (and, until their fenced files migrate,
// `--plan` and `--transcribe`) told the user a Batch could not start when
// none was ever asked for. `framing` threads a caller's own consequence
// clause down to `batch_setup_message` in its place.
@(test)
an_engine_refusal_can_end_on_a_callers_own_framing_instead_of_the_batch :: proc(t: ^testing.T) {
	message := engine_error_message(
		.Unreadable,
		"C:\\engine\\whisper-cli.exe",
		context.allocator,
		"--doctor cannot verify this Engine",
	)
	defer delete(message, context.allocator)

	testing.expectf(
		t,
		strings.contains(message, "--doctor cannot verify this Engine"),
		"an Engine refusal ignored its caller-supplied framing: <%s>",
		message,
	)
	testing.expectf(
		t,
		!strings.contains(message, "the Batch cannot start"),
		"a caller-supplied framing still carries the Batch's own framing: <%s>",
		message,
	)
}

// The same primitive `planning`'s `a_transcript_locked_by_another_process_reads_as_unreadable_not_absent`
// uses: `share_mode = 0` conflicts with every other open handle, so this
// holds one open while `identify_engine` tries to read it.
@(private)
@(require_results)
locked_engine_fixture :: proc(t: ^testing.T, path: string) -> win32.HANDLE {
	wide := win32.utf8_to_utf16(path, context.allocator)
	defer delete(wide, context.allocator)
	handle := win32.CreateFileW(
		win32.wstring(raw_data(wide)),
		win32.GENERIC_READ,
		0,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	testing.expect(
		t,
		handle != win32.INVALID_HANDLE_VALUE,
		"could not lock the Engine fixture this case exists to test against",
	)
	return handle
}

// Issue #216's covering matrix: the #189 review's three unreadable shapes --
// a missing path, a directory passed as `--engine-exe`, and a locked file --
// re-driven here to prove a caller-supplied framing survives every one of
// them, not only the synthetic `.Unreadable` case above.
@(test)
an_unreadable_engine_carries_its_callers_framing_across_missing_directory_and_locked_shapes :: proc(
	t: ^testing.T,
) {
	directory := testkit.made_scratch_cache(
		t,
		"artifact",
		"engine-unreadable-shapes",
		context.allocator,
	)
	defer delete(directory, context.allocator)
	defer testkit.remove_cache(directory, context.allocator)

	missing := fmt.aprintf("%s\\never-written.exe", directory, allocator = context.allocator)
	defer delete(missing, context.allocator)

	as_directory := fmt.aprintf("%s\\not-a-file.exe", directory, allocator = context.allocator)
	defer delete(as_directory, context.allocator)
	testing.expect(
		t,
		os.make_directory_all(as_directory) == nil,
		"could not make the directory-as-exe fixture",
	)

	locked := testkit.fixture_file(t, directory, "locked.exe", "abc", context.allocator)
	defer delete(locked, context.allocator)
	handle := locked_engine_fixture(t, locked)
	defer win32.CloseHandle(handle)

	for shape in ([]string{missing, as_directory, locked}) {
		digest, fault := identify_engine(shape, context.allocator)
		defer delete(string(digest), context.allocator)
		if !testing.expectf(t, fault == .Unreadable, "%s did not report Unreadable", shape) {
			continue
		}

		message := engine_error_message(
			fault,
			shape,
			context.allocator,
			"--doctor cannot verify this Engine",
		)
		defer delete(message, context.allocator)
		testing.expectf(
			t,
			strings.contains(message, "--doctor cannot verify this Engine"),
			"%s's refusal ignored its caller-supplied framing: <%s>",
			shape,
			message,
		)
		testing.expectf(
			t,
			!strings.contains(message, "the Batch cannot start"),
			"%s's refusal still carries the Batch's own framing: <%s>",
			shape,
			message,
		)
	}
}
