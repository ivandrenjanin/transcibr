#+vet explicit-allocators
package artifact

import "core:strings"
import "core:testing"

@(test)
artifacts_replace_the_recordings_extension_and_share_its_stem :: proc(t: ^testing.T) {
	names, ok := names_of("C:\\clips\\talk.mp4", context.allocator)
	defer destroy_names(names, context.allocator)

	testing.expect(t, ok, "a Recording with a name of its own made no artifacts")
	testing.expect_value(t, names[.Transcript], "C:\\clips\\talk.md")
	testing.expect_value(t, names[.Engine_Output], "C:\\clips\\talk.json")
	testing.expect_value(t, names[.Sidecar], "C:\\clips\\talk.sidecar")
}

@(test)
a_recording_beside_the_working_directory_keeps_its_bare_name :: proc(t: ^testing.T) {
	names, ok := names_of("talk.mkv", context.allocator)
	defer destroy_names(names, context.allocator)

	testing.expect(t, ok, "a Recording in the working directory made no artifacts")
	testing.expect_value(t, names[.Transcript], "talk.md")
	testing.expect_value(t, names[.Engine_Output], "talk.json")
	testing.expect_value(t, names[.Sidecar], "talk.sidecar")
}

@(test)
a_recording_with_no_extension_at_all_still_names_its_artifacts :: proc(t: ^testing.T) {
	names, ok := names_of("D:\\recordings\\2026-08-02", context.allocator)
	defer destroy_names(names, context.allocator)

	testing.expect(t, ok, "a Recording with no extension made no artifacts")
	testing.expect_value(t, names[.Transcript], "D:\\recordings\\2026-08-02.md")
}

@(test)
a_leading_dot_is_a_name_and_not_an_extension :: proc(t: ^testing.T) {
	names, ok := names_of("C:\\clips\\.talk", context.allocator)
	defer destroy_names(names, context.allocator)

	testing.expect(t, ok, "a Recording whose name begins with a dot made no artifacts")
	testing.expect_value(t, names[.Transcript], "C:\\clips\\.talk.md")
}

@(test)
the_stem_a_recording_is_named_from_is_the_one_the_shell_uses_too :: proc(t: ^testing.T) {
	testing.expect_value(t, stem_of("C:\\clips\\talk.mp4"), "talk")
	testing.expect_value(t, stem_of("talk.mkv"), "talk")
	testing.expect_value(t, stem_of("D:\\recordings\\2026-08-02"), "2026-08-02")
	testing.expect_value(t, stem_of("C:/clips/2026.08/talk"), "talk")
	testing.expect_value(t, stem_of("C:\\clips\\.talk"), ".talk")

	for named in ([?]string {
			"C:\\clips\\talk.mp4",
			"C:\\clips\\.talk",
			"C:\\clips\\",
			"",
			"/",
			"D:/",
		}) {
		names, ok := names_of(named, context.allocator)
		defer destroy_names(names, context.allocator)
		testing.expectf(
			t,
			ok == (len(stem_of(named)) > 0),
			"%q is a Recording to one half of this package and not to the other",
			named,
		)
	}
}

// The two halves of one cut: whatever a path is, its stem and its extension
// laid end to end are the name it actually carries.
@(test)
a_stem_and_an_extension_are_the_two_halves_of_one_cut :: proc(t: ^testing.T) {
	testing.expect_value(t, extension_of("C:\\clips\\talk.mp4"), ".mp4")
	testing.expect_value(t, extension_of("C:\\clips\\talk.tar.gz"), ".gz")
	testing.expect_value(t, extension_of("D:\\recordings\\2026-08-02"), "")
	testing.expect_value(t, extension_of("C:\\clips\\.talk"), "")
	testing.expect_value(t, extension_of("C:\\clips\\"), "")
	testing.expect_value(t, extension_of(""), "")

	for named in ([?]string {
			"C:\\clips\\talk.mp4",
			"C:\\clips\\talk.tar.gz",
			"D:\\recordings\\2026-08-02",
			"C:\\clips\\.talk",
			"talk.mkv",
			"C:/clips/2026.08/talk",
		}) {
		joined := strings.concatenate({stem_of(named), extension_of(named)}, context.allocator)
		defer delete(joined, context.allocator)
		testing.expectf(
			t,
			strings.has_suffix(named, joined),
			"%q cut into a stem and an extension that do not add back up to it",
			named,
		)
	}
}

@(test)
a_path_that_names_no_file_makes_no_artifacts_and_allocates_nothing :: proc(t: ^testing.T) {
	for named in ([?]string{"C:\\clips\\", "", "/", "D:/"}) {
		names, ok := names_of(named, context.allocator)
		testing.expectf(t, !ok, "%q names no file and was accepted anyway", named)
		testing.expectf(t, len(names[.Transcript]) == 0, "%q was refused and kept a name", named)
		testing.expectf(
			t,
			len(names[.Engine_Output]) == 0,
			"%q was refused and kept a name",
			named,
		)
		testing.expectf(t, len(names[.Sidecar]) == 0, "%q was refused and kept a name", named)
	}
}

@(test)
a_forward_slash_separates_a_directory_from_a_name_like_a_backslash :: proc(t: ^testing.T) {
	names, ok := names_of("C:/clips/2026.08/talk", context.allocator)
	defer destroy_names(names, context.allocator)

	testing.expect(t, ok, "a Recording named with forward slashes made no artifacts")
	testing.expect_value(t, names[.Transcript], "C:/clips/2026.08/talk.md")
}

@(test)
the_temporary_name_an_artifact_is_written_under_is_in_its_own_directory :: proc(t: ^testing.T) {
	for destination in ([?]string{"C:\\clips\\talk.md", "talk.json", "C:/clips/talk.sidecar"}) {
		part := part_of(destination, 4321, context.allocator)
		defer delete(part, context.allocator)

		testing.expectf(
			t,
			strings.has_prefix(part, destination),
			"%q is written under a name that does not start with it",
			destination,
		)
		testing.expectf(
			t,
			strings.last_index_byte(part, '\\') == strings.last_index_byte(destination, '\\'),
			"%q is written under a name in another directory",
			destination,
		)
		testing.expectf(
			t,
			strings.last_index_byte(part, '/') == strings.last_index_byte(destination, '/'),
			"%q is written under a name in another directory",
			destination,
		)
	}
}

@(test)
two_transcibrs_over_one_recording_write_under_different_temporary_names :: proc(t: ^testing.T) {
	mine := part_of("C:\\clips\\talk.md", 4321, context.allocator)
	defer delete(mine, context.allocator)
	theirs := part_of("C:\\clips\\talk.md", 8765, context.allocator)
	defer delete(theirs, context.allocator)

	testing.expect(t, mine != theirs, "two transcibrs write one artifact under one name")
}

@(test)
engine_output_that_will_not_parse_is_moved_aside_to_json_bad :: proc(t: ^testing.T) {
	aside := quarantined("C:\\cache\\talk.json", context.allocator)
	defer delete(aside, context.allocator)

	testing.expect_value(t, aside, "C:\\cache\\talk.json.bad")
}
