#+vet explicit-allocators
package doctor

import "core:fmt"
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
		{"/c", "echo ffmpeg version 6.1 1>&2"},
		context.allocator,
	)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, true)
	testing.expect_value(t, check.name, "ffmpeg")
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

@(test)
a_model_that_hashes_cleanly_passes :: proc(t: ^testing.T) {
	dir := testkit.made_scratch_cache(t, "Doctor", "modelcheck", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	path := fmt.aprintf("%s\\model.bin", dir, allocator = context.allocator)
	defer delete(path, context.allocator)
	handle, unopenable := os.open(path, {.Write, .Create, .Trunc})
	testing.expect(t, unopenable == nil, "the case could not write its own fixture")
	_, unwritable := os.write(handle, {1, 2, 3, 4})
	testing.expect(t, unwritable == nil, "the case could not write its own fixture")
	os.close(handle)

	check := model_check(path, context.allocator)
	defer destroy_check(check, context.allocator)

	testing.expect_value(t, check.ok, true)
}

@(test)
a_model_that_does_not_exist_fails_with_an_actionable_reason :: proc(t: ^testing.T) {
	check := model_check(`Z:\nothing\here.bin`, context.allocator)
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
