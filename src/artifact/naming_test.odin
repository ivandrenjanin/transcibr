package artifact

import "core:strings"
import "core:testing"

// The pure half of this package's naming rules: what one Recording's artifacts
// are called (ADR-0008), what each is written under before it is moved into
// place, and what a piece of Engine output that will not parse is moved aside to
// (ADR-0002).
//
// Nothing here touches a disk. Every one of these is a decision about a STRING,
// which is what makes the cross-volume property below checkable at all: a case
// cannot conjure a second volume, and it can check that no name this package
// produces ever names a different directory from the artifact it belongs to.

@(test)
artifacts_replace_the_recordings_extension_and_share_its_stem :: proc(t: ^testing.T) {
	// ADR-0008: `<dir>/<stem>.<ext>` produces `<dir>/<stem>.md`, and its retained
	// Engine output and its Sidecar under the same stem.
	names, ok := names_of("C:\\clips\\talk.mp4", context.allocator)
	defer destroy_names(names, context.allocator)

	testing.expect(t, ok, "a Recording with a name of its own made no artifacts")
	testing.expect_value(t, names[.Transcript], "C:\\clips\\talk.md")
	testing.expect_value(t, names[.Engine_Output], "C:\\clips\\talk.json")
	testing.expect_value(t, names[.Sidecar], "C:\\clips\\talk.sidecar")
}

@(test)
a_recording_beside_the_working_directory_keeps_its_bare_name :: proc(t: ^testing.T) {
	// No separator anywhere, so nothing may be PREPENDED either: a `.\` invented
	// here would be a path the Batch never chose, and ADR-0008's rule is that the
	// extension is replaced and nothing else about the name moves.
	names, ok := names_of("talk.mkv", context.allocator)
	defer destroy_names(names, context.allocator)

	testing.expect(t, ok, "a Recording in the working directory made no artifacts")
	testing.expect_value(t, names[.Transcript], "talk.md")
	testing.expect_value(t, names[.Engine_Output], "talk.json")
	testing.expect_value(t, names[.Sidecar], "talk.sidecar")
}

@(test)
a_recording_with_no_extension_at_all_still_names_its_artifacts :: proc(t: ^testing.T) {
	// A file with no extension is an ordinary thing to be handed, and it has a
	// stem: the whole name. Nothing is replaced, and a suffix is added.
	names, ok := names_of("D:\\recordings\\2026-08-02", context.allocator)
	defer destroy_names(names, context.allocator)

	testing.expect(t, ok, "a Recording with no extension made no artifacts")
	testing.expect_value(t, names[.Transcript], "D:\\recordings\\2026-08-02.md")
}

@(test)
a_leading_dot_is_a_name_and_not_an_extension :: proc(t: ^testing.T) {
	// `.talk` is a file called `.talk`, not an empty name with a `talk`
	// extension -- and reading it the other way would make every dotfile in a
	// directory map to the SAME artifact path, which is precisely the collision
	// ADR-0008's injectivity assertion exists to catch and would rather never
	// have to.
	names, ok := names_of("C:\\clips\\.talk", context.allocator)
	defer destroy_names(names, context.allocator)

	testing.expect(t, ok, "a Recording whose name begins with a dot made no artifacts")
	testing.expect_value(t, names[.Transcript], "C:\\clips\\.talk.md")
}

@(test)
the_stem_a_recording_is_named_from_is_the_one_the_shell_uses_too :: proc(t: ^testing.T) {
	// ONE ANSWER TO "WHAT IS A STEM" AND NOT TWO. The scratch audio, the Engine's
	// output prefix and the progress line are all named from this, and the three
	// artifacts beside the Recording come from names_of; they used to be two
	// different rules, because the shell asked `filepath.stem` -- which reads
	// `.talk` as an empty name with a `talk` extension and answers nothing. A
	// dotfile Recording was refused at one stage and accepted at the next, and
	// the case that pins the acceptance had no production caller at all.
	testing.expect_value(t, stem_of("C:\\clips\\talk.mp4"), "talk")
	testing.expect_value(t, stem_of("talk.mkv"), "talk")
	testing.expect_value(t, stem_of("D:\\recordings\\2026-08-02"), "2026-08-02")
	testing.expect_value(t, stem_of("C:/clips/2026.08/talk"), "talk")
	// The one the two rules disagreed about.
	testing.expect_value(t, stem_of("C:\\clips\\.talk"), ".talk")

	// And it refuses exactly what names_of refuses, which is the property that
	// makes them one rule rather than two that happen to agree today.
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

@(test)
a_path_that_names_no_file_makes_no_artifacts_and_allocates_nothing :: proc(t: ^testing.T) {
	// A8: the Recording's path arrives from a command line or from discovery, so
	// one that names a directory rather than a file is an operating error and
	// never an assertion. Both halves (A3): the refusal, and that it handed back
	// nothing for a caller to free or to write to.
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
	// Windows accepts both, and a command line carrying the other one is an
	// ordinary thing to be handed. A separator this package could not see would
	// make `C:/clips/talk.mp4` produce an artifact called `C:/clips/talk.md`
	// only by accident -- and would read `C:/clips/2026.08/talk` as an
	// extension.
	names, ok := names_of("C:/clips/2026.08/talk", context.allocator)
	defer destroy_names(names, context.allocator)

	testing.expect(t, ok, "a Recording named with forward slashes made no artifacts")
	testing.expect_value(t, names[.Transcript], "C:/clips/2026.08/talk.md")
}

@(test)
the_temporary_name_an_artifact_is_written_under_is_in_its_own_directory :: proc(t: ^testing.T) {
	// THE CROSS-VOLUME ANSWER, and the reason it is a naming case rather than a
	// filesystem one. MoveFileExW is atomic within a volume and is not across
	// one, and `core:os`'s rename passes no MOVEFILE_COPY_ALLOWED -- so a rename
	// that crossed a volume would FAIL rather than quietly become a copy. This
	// program never asks it to: the temporary name is the artifact's own path
	// with a suffix, so the two are always in one directory and therefore always
	// on one volume.
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
	// The process identifier, for the reason `transcibr:audio` gives about its
	// own two intermediates: the scratch cache and a Recording's directory are
	// both shared, and two windows over one Recording under one temporary name
	// had one worker's rename publishing the file the other was still writing.
	mine := part_of("C:\\clips\\talk.md", 4321, context.allocator)
	defer delete(mine, context.allocator)
	theirs := part_of("C:\\clips\\talk.md", 8765, context.allocator)
	defer delete(theirs, context.allocator)

	testing.expect(t, mine != theirs, "two transcibrs write one artifact under one name")
}

@(test)
engine_output_that_will_not_parse_is_moved_aside_to_json_bad :: proc(t: ^testing.T) {
	// ADR-0002 names this file exactly: "quarantine it to `.json.bad` and re-run
	// the full pipeline". The whole original name is kept in front of the
	// suffix, so what was quarantined is readable off the name that is left.
	aside := quarantined("C:\\cache\\talk.json", context.allocator)
	defer delete(aside, context.allocator)

	testing.expect_value(t, aside, "C:\\cache\\talk.json.bad")
}
