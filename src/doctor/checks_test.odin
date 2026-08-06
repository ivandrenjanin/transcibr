#+vet explicit-allocators
package doctor

import "core:fmt"
import "core:io"
import "core:os"
import "core:strings"
import "core:testing"
import "transcibr:child"
import "transcibr:testkit"

@(test)
an_extraction_tool_that_reports_its_version_passes :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	check := extraction_tool_check(
		&group,
		"ffmpeg",
		CMD,
		{"/c", "echo usage: ffmpeg [options] input 1>&2"},
		context.allocator,
	)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, true)
	testing.expect_value(t, check.name, "ffmpeg")
}

// The exact failure mode measured live: `--ffmpeg` pointed at some other
// executable entirely (`whisper-cli.exe` in the reviewer's run), which still
// writes plenty to stderr, so the old "anything at all was captured" test
// passed it as a healthy ffmpeg. This one reports itself by a different name
// and must fail.
@(test)
review_a_non_ffmpeg_executable_must_not_pass_as_ffmpeg :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	check := extraction_tool_check(
		&group,
		"ffmpeg",
		CMD,
		{"/c", "echo whisper-cli.exe -h [options] 1>&2"},
		context.allocator,
	)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, false)
}

@(test)
an_extraction_tool_that_cannot_be_started_is_reported_rather_than_asserted :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	check := extraction_tool_check(
		&group,
		"ffmpeg",
		"there-is-no-such-tool.exe",
		FFMPEG_PROBE_ARGUMENTS,
		context.allocator,
	)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, false)
	testing.expect(t, strings.contains(check.reason, "no-such-tool"), "the tool is not named")
}

// The real reference toolchain this dev machine carries, exercised end to
// end so the probe argument is proved against a genuine ffmpeg/ffprobe
// build rather than only against cmd.exe, which writes to a different
// stream than either real tool does. Skipped, not failed, wherever that
// install is absent -- CI carries no such directory.
@(private)
REFERENCE_FFMPEG :: `C:\tools\ffmpeg\ffmpeg-master-latest-win64-gpl\bin\ffmpeg.exe`

@(private)
REFERENCE_FFPROBE :: `C:\tools\ffmpeg\ffmpeg-master-latest-win64-gpl\bin\ffprobe.exe`

@(test)
review_a_real_healthy_ffmpeg_passes_the_extraction_check :: proc(t: ^testing.T) {
	if !os.exists(REFERENCE_FFMPEG) {
		return
	}
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	check := extraction_tool_check(
		&group,
		"ffmpeg",
		REFERENCE_FFMPEG,
		FFMPEG_PROBE_ARGUMENTS,
		context.allocator,
	)
	defer destroy_check(check, context.allocator)

	if !check.ok {
		testing.expectf(t, false, "%s", check.reason)
		return
	}
	testing.expect_value(t, check.ok, true)
}

@(test)
review_a_real_healthy_ffprobe_passes_the_extraction_check :: proc(t: ^testing.T) {
	if !os.exists(REFERENCE_FFPROBE) {
		return
	}
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	check := extraction_tool_check(
		&group,
		"ffprobe",
		REFERENCE_FFPROBE,
		FFMPEG_PROBE_ARGUMENTS,
		context.allocator,
	)
	defer destroy_check(check, context.allocator)

	if !check.ok {
		testing.expectf(t, false, "%s", check.reason)
		return
	}
	testing.expect_value(t, check.ok, true)
}

// A sparse file, not a real 70 MiB write: writing the real magic bytes at
// the front, then seeking to the last byte of the floor and writing one
// byte there, gives the filesystem a file exactly at
// `MODEL_MIN_PLAUSIBLE_BYTES` with a genuine header without this test
// actually paying for the I/O a real Model's size would cost. It clears
// the size floor and the magic bytes, but it is not a real Model, and a
// round-5 review's own point is that a screen this cheap cannot be the
// verdict -- only the load probe below can tell this fixture apart from a
// genuine, truncated-past-70-MiB Model, so this fixture must now FAIL.
@(test)
a_fixture_that_only_clears_the_cheap_screen_still_fails_the_load_probe :: proc(t: ^testing.T) {
	dir := testkit.made_scratch_cache(t, "Doctor", "modelcheck", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	path := fmt.aprintf("%s\\model.bin", dir, allocator = context.allocator)
	defer delete(path, context.allocator)
	handle, unopenable := os.open(path, {.Write, .Create, .Trunc})
	testing.expect(t, unopenable == nil, "the case could not write its own fixture")
	magic := MODEL_MAGIC_BYTES
	_, unwritten_magic := os.write(handle, magic[:])
	testing.expect(t, unwritten_magic == nil, "the case could not write its own fixture")
	_, unseekable := os.seek(handle, MODEL_MIN_PLAUSIBLE_BYTES - 1, io.Seek_From.Start)
	testing.expect(t, unseekable == nil, "the case could not write its own fixture")
	_, unwritable := os.write(handle, {1})
	testing.expect(t, unwritable == nil, "the case could not write its own fixture")
	os.close(handle)

	check := model_check(&group, CMD, path, true, context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, false)
}

// The other half of the same fact, proved against the real reference Engine
// and a real, complete Model: a genuine Model still passes the load probe,
// so the screen above is refusing this fixture for being fake, not merely
// for being different. Skipped, not failed, wherever the reference install
// or the reference Model is absent -- CI carries neither.
@(private)
REFERENCE_MODEL :: `C:\Users\drenj\models\ggml-large-v3-turbo.bin`

@(test)
review_a_real_healthy_model_passes_the_full_check_including_the_load_probe :: proc(t: ^testing.T) {
	if !os.exists(REFERENCE_ENGINE) {
		return
	}
	if !os.exists(REFERENCE_MODEL) {
		return
	}
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	check := model_check(&group, REFERENCE_ENGINE, REFERENCE_MODEL, true, context.allocator)
	defer destroy_check(check, context.allocator)

	if !check.ok {
		testing.expectf(t, false, "%s", check.reason)
		return
	}
	testing.expect_value(t, check.ok, true)
}

// The exact defect a round-5 adversarial review measured live: a
// 209,715,200-byte (200 MiB) head-truncation of the real 1,624,555,275-byte
// ggml-large-v3-turbo.bin, well above the 70 MiB floor and carrying the
// genuine magic bytes, which the cheap screen alone passed while the real
// Engine refused the same file in well under a second. Skipped, not
// failed, wherever the reference install or Model is absent.
@(test)
review_a_200_mib_head_truncation_above_the_floor_must_not_pass_the_model_check :: proc(
	t: ^testing.T,
) {
	if !os.exists(REFERENCE_ENGINE) {
		return
	}
	if !os.exists(REFERENCE_MODEL) {
		return
	}
	dir := testkit.made_scratch_cache(t, "Doctor", "headtruncation200mib", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	path := fmt.aprintf("%s\\model.bin", dir, allocator = context.allocator)
	defer delete(path, context.allocator)
	testing.expect(
		t,
		wrote_head_truncation(REFERENCE_MODEL, path, 200 * 1024 * 1024),
		"the case could not write its own fixture",
	)

	check := model_check(&group, REFERENCE_ENGINE, path, true, context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, false)
	testing.expect(
		t,
		strings.contains(check.reason, "failed to load"),
		"a head truncation was refused for the wrong reason",
	)
}

@(private)
@(require_results)
wrote_head_truncation :: proc(source: string, destination: string, bytes: i64) -> bool {
	assert(len(source) > 0, "there is no source file here to truncate")
	assert(len(destination) > 0, "there is nowhere here to write a truncation")
	assert(bytes > 0, "a truncation of nothing is not a fixture")

	src, unopenable_src := os.open(source)
	if unopenable_src != nil {
		return false
	}
	defer os.close(src)

	dst, unopenable_dst := os.open(destination, {.Write, .Create, .Trunc})
	if unopenable_dst != nil {
		return false
	}
	defer os.close(dst)

	buffer := make([]u8, 4 * 1024 * 1024, context.allocator)
	defer delete(buffer, context.allocator)

	remaining := bytes
	for remaining > 0 {
		want := min(i64(len(buffer)), remaining)
		read, unreadable := os.read(src, buffer[:want])
		if unreadable != nil || read <= 0 {
			return false
		}
		_, unwritable := os.write(dst, buffer[:read])
		if unwritable != nil {
			return false
		}
		remaining -= i64(read)
	}
	return true
}

// The exact case a round-4 adversarial review measured live: a
// 67,108,864-byte (64 MiB) head-truncation of the real 1,624,555,275-byte
// ggml-large-v3-turbo.bin, which the round-3 8 MiB floor let through as
// PASS right before a real Engine run against the same file failed with
// "not all tensors loaded from model file". The magic bytes are genuine
// (only the tail is missing), so only a floor that sits above this size --
// and still below the smallest real Model -- refuses it.
@(test)
review_a_64_mib_head_truncation_must_not_pass_the_model_check :: proc(t: ^testing.T) {
	dir := testkit.made_scratch_cache(t, "Doctor", "headtruncated", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	path := fmt.aprintf("%s\\model.bin", dir, allocator = context.allocator)
	defer delete(path, context.allocator)
	handle, unopenable := os.open(path, {.Write, .Create, .Trunc})
	testing.expect(t, unopenable == nil, "the case could not write its own fixture")
	magic := MODEL_MAGIC_BYTES
	_, unwritten_magic := os.write(handle, magic[:])
	testing.expect(t, unwritten_magic == nil, "the case could not write its own fixture")
	_, unseekable := os.seek(handle, i64(64 * 1024 * 1024) - 1, io.Seek_From.Start)
	testing.expect(t, unseekable == nil, "the case could not write its own fixture")
	_, unwritable := os.write(handle, {1})
	testing.expect(t, unwritable == nil, "the case could not write its own fixture")
	os.close(handle)

	check := model_check(&group, CMD, path, true, context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, false)
}

// The other round-4 fixture: a file well past the size floor that is not a
// Model at all -- a 9,000,000-byte /dev/urandom-style file in the review,
// reproduced here as a sparse file whose first four bytes are zero rather
// than the real magic. The size floor alone cannot refuse this; only the
// magic check can.
@(test)
review_a_plausibly_sized_non_model_file_must_not_pass_the_model_check :: proc(t: ^testing.T) {
	dir := testkit.made_scratch_cache(t, "Doctor", "notamodel", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	path := fmt.aprintf("%s\\model.bin", dir, allocator = context.allocator)
	defer delete(path, context.allocator)
	handle, unopenable := os.open(path, {.Write, .Create, .Trunc})
	testing.expect(t, unopenable == nil, "the case could not write its own fixture")
	_, unseekable := os.seek(handle, MODEL_MIN_PLAUSIBLE_BYTES + 1_000, io.Seek_From.Start)
	testing.expect(t, unseekable == nil, "the case could not write its own fixture")
	_, unwritable := os.write(handle, {1})
	testing.expect(t, unwritable == nil, "the case could not write its own fixture")
	os.close(handle)

	check := model_check(&group, CMD, path, true, context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, false)
}

// The single most common broken-install shape a preflight doctor exists to
// catch, reproduced at the exact byte count a round-3 adversarial review
// measured live: a 1,048,576-byte head-truncation of a real 1,624,555,275-
// byte install, which the bare `bytes <= 0` guard let through as PASS right
// before a real `--transcribe` against the same file failed with "the Engine
// left no output at all".
@(test)
review_a_truncated_model_head_must_not_pass_the_model_check :: proc(t: ^testing.T) {
	dir := testkit.made_scratch_cache(t, "Doctor", "truncatedmodel", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	path := fmt.aprintf("%s\\model.bin", dir, allocator = context.allocator)
	defer delete(path, context.allocator)
	handle, unopenable := os.open(path, {.Write, .Create, .Trunc})
	testing.expect(t, unopenable == nil, "the case could not write its own fixture")
	buffer := make([]u8, 1_048_576, context.allocator)
	defer delete(buffer, context.allocator)
	_, unwritable := os.write(handle, buffer)
	testing.expect(t, unwritable == nil, "the case could not write its own fixture")
	os.close(handle)

	check := model_check(&group, CMD, path, true, context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, false)
}

// The single most common broken-install shape a preflight doctor exists to
// catch: an interrupted or truncated model download. `identify_model` hashes
// a zero-byte file cleanly (there is nothing wrong with hashing nothing), so
// the doctor has to guard on the byte count itself rather than trust that a
// clean hash means a real Model.
@(test)
review_a_zero_byte_model_must_not_pass_the_model_check :: proc(t: ^testing.T) {
	dir := testkit.made_scratch_cache(t, "Doctor", "zerobytemodel", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	path := fmt.aprintf("%s\\model.bin", dir, allocator = context.allocator)
	defer delete(path, context.allocator)
	handle, unopenable := os.open(path, {.Write, .Create, .Trunc})
	testing.expect(t, unopenable == nil, "the case could not write its own fixture")
	os.close(handle)

	check := model_check(&group, CMD, path, true, context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, false)
}

@(test)
a_model_that_does_not_exist_fails_with_an_actionable_reason :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	check := model_check(&group, CMD, `Z:\nothing\here.bin`, true, context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, false)
	testing.expect(t, len(check.reason) > 0, "a failed check gave nothing a user can act on")
}

@(test)
the_gpu_diagnostic_reports_what_windows_can_see_without_ever_blocking_a_run :: proc(
	t: ^testing.T,
) {
	check := gpu_diagnostic_check(context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect(t, len(check.name) > 0, "a check with no name reports nothing")
}

// The exact fixture an escalation review measured live: 104,857,604 bytes of
// genuine ggml magic followed by random noise, clearing the 70 MiB floor and
// the magic screen, which hard-aborts the real Engine in 0.92 s -- GGML_ASSERT,
// exit 0xC0000409, and the marker line never printed. A probe that reads the
// marker alone calls that PASS; only the exit status refuses it. Skipped, not
// failed, wherever the reference install is absent.
@(test)
review_a_garbage_model_that_aborts_the_engine_must_not_pass_the_model_check :: proc(
	t: ^testing.T,
) {
	if !os.exists(REFERENCE_ENGINE) {
		return
	}
	dir := testkit.made_scratch_cache(t, "Doctor", "garbagemodel", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	path := fmt.aprintf("%s\\model.bin", dir, allocator = context.allocator)
	defer delete(path, context.allocator)
	testing.expect(
		t,
		wrote_magic_headed_noise(path, 104_857_604),
		"the case could not write its own fixture",
	)

	check := model_check(&group, REFERENCE_ENGINE, path, true, context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, false)
	testing.expect_value(t, check.skip, false)
	testing.expectf(
		t,
		strings.contains(check.reason, "engine"),
		"a load refusal was not named as one: %s",
		check.reason,
	)
}

@(private)
@(require_results)
wrote_magic_headed_noise :: proc(destination: string, bytes: i64) -> bool {
	assert(len(destination) > 0, "there is nowhere here to write a fixture")
	assert(bytes > i64(len(MODEL_MAGIC_BYTES)), "a fixture smaller than its own header")

	handle, unopenable := os.open(destination, {.Write, .Create, .Trunc})
	if unopenable != nil {
		return false
	}
	defer os.close(handle)

	magic := MODEL_MAGIC_BYTES
	if _, unwritable := os.write(handle, magic[:]); unwritable != nil {
		return false
	}

	buffer := make([]u8, 4 * 1024 * 1024, context.allocator)
	defer delete(buffer, context.allocator)
	for at in 0 ..< len(buffer) {
		buffer[at] = u8(at * 31 + 7)
	}

	remaining := bytes - i64(len(magic))
	for remaining > 0 {
		want := min(i64(len(buffer)), remaining)
		written, unwritable := os.write(handle, buffer[:want])
		if unwritable != nil || written <= 0 {
			return false
		}
		remaining -= i64(written)
	}
	return true
}

// The engine's own failure is not the Model's fault. Measured live against a
// real install with ggml-cuda.dll removed: the Engine loads the real Model
// perfectly well on the CPU, and the doctor that failed the Model on that
// evidence sent a user to re-download 1.6 GB for nothing.
@(test)
review_a_model_is_skipped_rather_than_failed_when_the_engine_check_did_not_pass :: proc(
	t: ^testing.T,
) {
	dir := testkit.made_scratch_cache(t, "Doctor", "modelskipped", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	path := fmt.aprintf("%s\\model.bin", dir, allocator = context.allocator)
	defer delete(path, context.allocator)
	testing.expect(t, wrote_plausible_model(path), "the case could not write its own fixture")

	check := model_check(&group, CMD, path, false, context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.skip, true)
	testing.expect_value(t, check.ok, false)
	testing.expectf(
		t,
		strings.contains(check.reason, "engine"),
		"a skipped model check never said the engine is why: %s",
		check.reason,
	)
}

// A Model broken in its own right is still the Model's fault, whatever the
// Engine is doing, so the skip above must not swallow it.
@(test)
a_model_broken_in_its_own_right_still_fails_even_when_the_engine_check_did_not_pass :: proc(
	t: ^testing.T,
) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	check := model_check(&group, CMD, `Z:\nothing\here.bin`, false, context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.skip, false)
	testing.expect_value(t, check.ok, false)
}

@(private)
@(require_results)
wrote_plausible_model :: proc(destination: string) -> bool {
	assert(len(destination) > 0, "there is nowhere here to write a fixture")

	handle, unopenable := os.open(destination, {.Write, .Create, .Trunc})
	if unopenable != nil {
		return false
	}
	defer os.close(handle)

	magic := MODEL_MAGIC_BYTES
	if _, unwritable := os.write(handle, magic[:]); unwritable != nil {
		return false
	}
	if _, unseekable := os.seek(handle, MODEL_MIN_PLAUSIBLE_BYTES - 1, io.Seek_From.Start);
	   unseekable != nil {
		return false
	}
	_, unwritable := os.write(handle, {1})
	return unwritable == nil
}

// A directory named where a Model file belongs used to reach `identify_model`
// and read as an unreadable file; it has its own actionable sentence now that
// the doctor stats the path rather than hashing it.
@(test)
a_directory_passed_as_the_model_file_is_named_as_one :: proc(t: ^testing.T) {
	dir := testkit.made_scratch_cache(t, "Doctor", "modeldirectory", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	check := model_check(&group, CMD, dir, true, context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, false)
	testing.expect(
		t,
		strings.contains(check.reason, "directory"),
		"a directory was refused without being named as one",
	)
}
