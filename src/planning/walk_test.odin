#+vet explicit-allocators
package planning

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"
import "core:testing"
import "core:time"
import "transcibr:child"
import "transcibr:testkit"

@(private)
@(require_results)
a_directory :: proc(t: ^testing.T, tree: string, relative: string) -> string {
	path := fmt.aprintf("%s\\%s", tree, relative, allocator = context.allocator)
	testing.expectf(t, os.make_directory_all(path) == nil, "could not make %s", path)
	return path
}

@(private)
@(require_results)
sources_of :: proc(inventory: Inventory) -> []string {
	names := make([]string, len(inventory.found), context.allocator)
	for entry, at in inventory.found {
		names[at] = entry.source
	}
	slice.sort(names)
	return names
}

@(private)
@(require_results)
found_at :: proc(inventory: Inventory, path: string) -> (found: Found, yes: bool) {
	for entry in inventory.found {
		if strings.equal_fold(entry.source, path) {
			return entry, true
		}
	}
	return {}, false
}

@(private)
@(require_results)
noted :: proc(inventory: Inventory, what: Note) -> (path: string, yes: bool) {
	for note in inventory.notes {
		if note.note == what {
			return note.path, true
		}
	}
	return "", false
}

@(test)
what_counts_as_a_recording_is_decided_on_the_extension_alone :: proc(t: ^testing.T) {
	for named in ([?]string {
			"talk.mp4",
			"talk.MP4",
			"C:\\clips\\keynote.mkv",
			"interview.m4a",
			"lecture.Wav",
			"call.opus",
			"camcorder.m2ts",
			"camcorder.mts",
		}) {
		testing.expectf(t, is_a_recording(named), "%q was not taken for a Recording", named)
	}
}

// A dry run pointed at a source checkout planned a Transcript for every file in
// it, because the extension is all this test has and `.ts` is TypeScript as
// often as it is a transport stream. The same container is still found under
// `.m2ts` and `.mts`, which nothing else uses.
@(test)
an_extension_a_source_tree_uses_is_never_taken_for_a_recording :: proc(t: ^testing.T) {
	for named in ([?]string {
			"C:\\src\\app\\main.ts",
			"C:\\src\\app\\component.tsx",
			"C:\\src\\app\\main.js",
			"C:\\src\\walk.odin",
		}) {
		testing.expectf(t, !is_a_recording(named), "%q was taken for a Recording", named)
	}
}

// transcibr's own artifacts sit beside their Recording, so a walk that took them
// for Recordings would plan a Transcript of a Transcript.
@(test)
nothing_transcibr_writes_is_ever_taken_for_a_recording :: proc(t: ^testing.T) {
	for named in ([?]string {
			"talk.md",
			"talk.json",
			"talk.sidecar",
			"talk.json.bad",
			"talk.md.4321.part",
			"notes.txt",
			"talk",
			"",
			".mp4",
			"C:\\clips\\",
		}) {
		testing.expectf(t, !is_a_recording(named), "%q was taken for a Recording", named)
	}
}

// What the reparse rule must NOT reach. A file is a candidate whatever type the
// listing gave it: `.Symlink` is a file symbolic link, and `.Undetermined` is
// both what a file another process holds open reads as and what a non-directory
// reparse point falls through to (ADR-0023) -- which is every OneDrive
// Files-On-Demand placeholder. A machine with no reparse point to make still
// holds this rule.
@(test)
a_file_is_a_candidate_recording_whatever_type_the_listing_gave_it :: proc(t: ^testing.T) {
	Case :: struct {
		type: os.File_Type,
		path: string,
		yes:  bool,
	}

	for c in ([?]Case {
			{.Regular, "C:\\clips\\talk.mp4", true},
			{.Undetermined, "C:\\clips\\talk.mp4", true},
			{.Symlink, "C:\\clips\\talk.mp4", true},
			{.Regular, "C:\\clips\\notes.txt", false},
			{.Symlink, "C:\\clips\\talk.md", false},
			{.Directory, "C:\\clips\\talk.mp4", false},
			{.Named_Pipe, "C:\\clips\\talk.mp4", false},
			{.Socket, "C:\\clips\\talk.mp4", false},
			{.Block_Device, "C:\\clips\\talk.mp4", false},
			{.Character_Device, "C:\\clips\\talk.mp4", false},
		}) {
		testing.expectf(
			t,
			a_candidate(c.type, c.path) == c.yes,
			"a %v entry at %q was %v, which is not what this walk considers",
			c.type,
			c.path,
			a_candidate(c.type, c.path) ? "taken" : "dropped",
		)
	}
}

// A Recording nothing looked at is indistinguishable from one that is not
// there, and only the walk knows which happened. Anything that leaves the
// inventory short of the tree has to be answerable AFTER the walk, or a caller
// reports success over a plan missing half its Recordings (ADR-0009).
@(test)
a_walk_that_did_not_see_the_whole_tree_says_so_afterwards :: proc(t: ^testing.T) {
	Case :: struct {
		note:  Note,
		whole: bool,
	}

	for c in ([?]Case {
			{.Root_Unreadable, false},
			{.Directory_Unreadable, false},
			{.Too_Deep, false},
			{.Reparse_Point_Not_Followed, true},
		}) {
		inventory := Inventory {
			notes = []Walk_Note{{note = c.note, path = "D:\\archive"}},
		}
		short, yes := left_unlooked_at(inventory)
		testing.expectf(
			t,
			yes == !c.whole,
			"%v was called %v, which is not what it means for an inventory",
			c.note,
			yes ? "incomplete" : "complete",
		)
		if !c.whole {
			left_out, named := short.?
			testing.expect(t, named, "an inventory was called partial and named nothing")
			testing.expect_value(t, left_out.note, c.note)
			testing.expect_value(t, left_out.path, "D:\\archive")
		}
	}
}

@(test)
a_walk_that_saw_the_whole_tree_says_nothing_was_left_out :: proc(t: ^testing.T) {
	_, short := left_unlooked_at(Inventory{})
	testing.expect(t, !short, "a walk that left nothing out reported that it had")

	cancelled := Inventory {
		cancelled = true,
	}
	_, stopped := left_unlooked_at(cancelled)
	testing.expect(t, stopped, "a walk that was stopped part way called itself whole")
}

// A walk that was STOPPED left no note behind, and there is no note to name: it
// answered `Root_Unreadable` -- the zero value -- over a tree it had been
// reading perfectly well, and the dry run printed that at a user. Latent only
// while the CLI never sets the flag, and reachable the moment the window (#16)
// drives the seam this package exists to provide.
@(test)
a_walk_that_was_stopped_part_way_blames_no_directory_for_it :: proc(t: ^testing.T) {
	short, yes := left_unlooked_at(Inventory{cancelled = true})
	testing.expect(t, yes, "a walk that was stopped part way called itself whole")

	_, named := short.?
	testing.expect(t, !named, "a walk that was stopped blamed a directory nothing was wrong with")
}

@(test)
a_tree_is_walked_into_an_inventory_of_every_recording_under_it :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "planning", "walk", context.allocator)
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	top := testkit.fixture_file(
		t,
		tree,
		"keynote.mp4",
		transmute([]u8)string("video"),
		nil,
		context.allocator,
	)
	defer delete(top, context.allocator)
	nested := testkit.fixture_file(
		t,
		tree,
		"june\\deeper\\interview.m4a",
		transmute([]u8)string("audio"),
		nil,
		context.allocator,
	)
	defer delete(nested, context.allocator)
	notes := testkit.fixture_file(
		t,
		tree,
		"june\\notes.txt",
		transmute([]u8)string("not a Recording"),
		nil,
		context.allocator,
	)
	defer delete(notes, context.allocator)
	stale := testkit.fixture_file(
		t,
		tree,
		"june\\interview.json.bad",
		transmute([]u8)string("quarantined"),
		nil,
		context.allocator,
	)
	defer delete(stale, context.allocator)

	inventory := discover([]string{tree}, Walk{}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	names := sources_of(inventory)
	defer delete(names, context.allocator)
	testing.expectf(t, len(names) == 2, "the walk found %v rather than the two Recordings", names)

	_, took_top := found_at(inventory, top)
	_, took_nested := found_at(inventory, nested)
	testing.expect(t, took_top, "a Recording at the top of the tree was not found")
	testing.expect(t, took_nested, "a Recording two directories down was not found")
	testing.expect(t, !inventory.cancelled, "a walk nobody stopped reported itself cancelled")
}

// Criterion five, end to end: the bytes decide, and a Sidecar beside a stranger
// does not make it transcibr's.
@(test)
a_markdown_file_transcibr_did_not_write_is_left_alone_and_reported :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "planning", "foreign", context.allocator)
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	mine := testkit.fixture_file(
		t,
		tree,
		"talk.mp4",
		transmute([]u8)string("video"),
		nil,
		context.allocator,
	)
	defer delete(mine, context.allocator)
	theirs := testkit.fixture_file(
		t,
		tree,
		"notes.mp4",
		transmute([]u8)string("video"),
		nil,
		context.allocator,
	)
	defer delete(theirs, context.allocator)
	written := testkit.fixture_file(
		t,
		tree,
		"talk.md",
		transmute([]u8)string("---\ngenerator: \"transcibr 0.1.0\"\n---\n"),
		nil,
		context.allocator,
	)
	defer delete(written, context.allocator)
	authored := testkit.fixture_file(
		t,
		tree,
		"notes.md",
		transmute([]u8)string("# Notes on the interview\n"),
		nil,
		context.allocator,
	)
	defer delete(authored, context.allocator)

	inventory := discover([]string{tree}, Walk{}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	ours, took_ours := found_at(inventory, mine)
	strangers, took_theirs := found_at(inventory, theirs)
	testing.expect(t, took_ours, "a Recording with a Transcript beside it was not found")
	testing.expect(t, took_theirs, "a Recording with a stranger beside it was not found")
	testing.expect_value(t, ours.transcript, Transcript_State.Transcibrs)
	testing.expect_value(t, strangers.transcript, Transcript_State.Foreign)

	testing.expect_value(t, decide(strangers, settings()).reason, Reason.Foreign_Transcript)
	left, still_there := os.read_entire_file_from_path(authored, context.allocator)
	defer delete(left, context.allocator)
	testing.expect(
		t,
		still_there == nil,
		"the Markdown file transcibr did not write was not left where it was",
	)
	testing.expect_value(t, string(left), "# Notes on the interview\n")
}

// Finding 1 of PR #64's third review: `os.open` failing on a Transcript held
// open elsewhere used to read exactly like `os.open` failing because nothing
// is there at all -- both answered `.Absent`, which plans the Recording
// fresh and risks the Sidecar and Transcript-head reads discovery makes at
// exactly the moment a locked file (an editor, an antivirus scan, OneDrive,
// a backup agent) is the ordinary and not the exceptional case on Windows.
// `share_mode = 0` conflicts with every other open handle whatever sharing
// that handle allowed, the same primitive `transcibr:child`'s
// `taken_exclusively` uses to prove a read released its own handle -- here
// used the other way, to hold one open while the walk tries to read it.
@(test)
a_transcript_locked_by_another_process_reads_as_unreadable_not_absent :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "planning", "locked", context.allocator)
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	recording := testkit.fixture_file(
		t,
		tree,
		"talk.mp4",
		transmute([]u8)string("video"),
		nil,
		context.allocator,
	)
	defer delete(recording, context.allocator)
	written := testkit.fixture_file(
		t,
		tree,
		"talk.md",
		transmute([]u8)string("---\ngenerator: \"transcibr 0.1.0\"\n---\n"),
		nil,
		context.allocator,
	)
	defer delete(written, context.allocator)

	wide := win32.utf8_to_utf16(written, context.allocator)
	defer delete(wide, context.allocator)
	locked := win32.CreateFileW(
		win32.wstring(raw_data(wide)),
		win32.GENERIC_READ,
		0,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if !testing.expect(
		t,
		locked != win32.INVALID_HANDLE_VALUE,
		"could not lock the Transcript this case exists to test against",
	) {
		return
	}
	defer win32.CloseHandle(locked)

	inventory := discover([]string{tree}, Walk{}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	found, took := found_at(inventory, recording)
	testing.expect(t, took, "a Recording beside a locked Transcript was not found")
	testing.expect_value(t, found.transcript, Transcript_State.Unreadable)
	testing.expect_value(t, decide(found, settings()).reason, Reason.Transcript_Unreadable)
}

// PR #64's fourth review, finding 2: round 4 widened `os.read_at` failure
// with `read == 0` to `.Unreadable` to close the locked-Transcript case
// above, and swept a genuinely EMPTY Transcript into the same answer along
// the way -- `os.open` succeeds, `os.read_at` answers `io.Error.EOF`, and
// nothing was ever unreadable. A 0-byte `.md` is what an interrupted run or
// a failed copy leaves beside a Recording, and round 3's answer for it --
// `.Foreign`, since `written_by_transcibr` never matches an empty head --
// was the accurate one.
@(test)
a_zero_byte_transcript_reads_as_foreign_and_not_unreadable :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "planning", "zerobyte", context.allocator)
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	recording := testkit.fixture_file(
		t,
		tree,
		"talk.mp4",
		transmute([]u8)string("video"),
		nil,
		context.allocator,
	)
	defer delete(recording, context.allocator)
	empty := testkit.fixture_file(
		t,
		tree,
		"talk.md",
		transmute([]u8)string(""),
		nil,
		context.allocator,
	)
	defer delete(empty, context.allocator)

	inventory := discover([]string{tree}, Walk{}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	found, took := found_at(inventory, recording)
	testing.expect(t, took, "a Recording beside an empty Transcript was not found")
	testing.expect_value(t, found.transcript, Transcript_State.Foreign)
	testing.expect_value(t, decide(found, settings()).reason, Reason.Foreign_Transcript)
}

// The third live case `.Transcript_Unreadable`'s sentence has to stay true
// for: a directory occupying the path a Transcript would be at fails
// `os.open` outright (measured: `ERROR_ACCESS_DENIED`, not
// `ERROR_FILE_NOT_FOUND`), so this reads as `.Unreadable` the same as a
// locked file does, and never as `.Absent` -- planning fresh over a
// directory transcibr cannot write a Transcript to is refused, not guessed.
@(test)
a_transcript_path_that_names_a_directory_reads_as_unreadable :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "planning", "transcriptdir", context.allocator)
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	recording := testkit.fixture_file(
		t,
		tree,
		"talk.mp4",
		transmute([]u8)string("video"),
		nil,
		context.allocator,
	)
	defer delete(recording, context.allocator)
	as_directory := a_directory(t, tree, "talk.md")
	defer delete(as_directory, context.allocator)

	inventory := discover([]string{tree}, Walk{}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	found, took := found_at(inventory, recording)
	testing.expect(
		t,
		took,
		"a Recording beside a directory named like its Transcript was not found",
	)
	testing.expect_value(t, found.transcript, Transcript_State.Unreadable)
	testing.expect_value(t, decide(found, settings()).reason, Reason.Transcript_Unreadable)
}

@(test)
a_root_that_is_not_there_is_reported_against_itself_and_never_as_empty :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "planning", "missing", context.allocator)
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	gone := fmt.aprintf("%s\\never-made", tree, allocator = context.allocator)
	defer delete(gone, context.allocator)

	inventory := discover([]string{gone}, Walk{}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	path, said := noted(inventory, .Root_Unreadable)
	testing.expect(t, said, "a root that is not there was walked as though it were empty")
	testing.expect_value(t, path, gone)
	testing.expect_value(t, len(inventory.found), 0)
}

// A file is not a tree, and a Batch pointed at one must say so rather than
// answer with nothing.
@(test)
a_root_that_is_a_file_rather_than_a_directory_is_an_operating_error :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "planning", "notadir", context.allocator)
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	file := testkit.fixture_file(
		t,
		tree,
		"talk.mp4",
		transmute([]u8)string("video"),
		nil,
		context.allocator,
	)
	defer delete(file, context.allocator)

	inventory := discover([]string{file}, Walk{}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	_, said := noted(inventory, .Root_Unreadable)
	testing.expect(t, said, "a root that is a file was walked as though it were an empty tree")
}

@(test)
an_empty_list_of_roots_walks_nothing_and_reports_nothing :: proc(t: ^testing.T) {
	inventory := discover(nil, Walk{}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	testing.expect_value(t, len(inventory.found), 0)
	testing.expect_value(t, len(inventory.notes), 0)
	testing.expect(t, !inventory.cancelled, "a walk over nothing reported itself cancelled")
}

// A root spelled as the empty string is external input like any other path, and
// must be refused rather than resolved into the working directory.
@(test)
a_root_spelled_as_nothing_at_all_is_refused :: proc(t: ^testing.T) {
	inventory := discover([]string{""}, Walk{}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	_, said := noted(inventory, .Root_Unreadable)
	testing.expect(t, said, "a root spelled as nothing at all was not refused")
	testing.expect_value(t, len(inventory.found), 0)
}
// Cancellation and progress are the same seam driven from one end: the callback
// the window issue #16 will pass sets the flag the walk reads, and no thread is
// started to prove either.
@(private)
Watcher :: struct {
	calls:       int,
	directories: int,
	recordings:  int,
	stop_after:  int,
	cancelled:   ^bool,
}

@(private)
watch :: proc(progress: Progress, user: rawptr) {
	w := (^Watcher)(user)
	w.calls += 1
	w.directories = progress.directories
	w.recordings = progress.recordings
	if w.stop_after > 0 && w.calls >= w.stop_after {
		sync.atomic_store(w.cancelled, true)
	}
}

@(private)
@(require_results)
a_spread_tree :: proc(t: ^testing.T, tag: string) -> string {
	tree := testkit.made_scratch_cache(t, "planning", tag, context.allocator)
	for relative in ([?]string {
			"one.mp4",
			"june|two.mp4",
			"june|deeper|three.mp4",
			"july|four.mp4",
			"august|five.mp4",
		}) {
		spelled, allocated := strings.replace_all(relative, "|", "\\", context.allocator)
		defer if allocated {
			delete(spelled, context.allocator)
		}
		path := testkit.fixture_file(
			t,
			tree,
			spelled,
			transmute([]u8)string("video"),
			nil,
			context.allocator,
		)
		delete(path, context.allocator)
	}
	return tree
}

@(test)
a_walk_reports_progress_as_it_goes_through_the_tree :: proc(t: ^testing.T) {
	tree := a_spread_tree(t, "progress")
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	stop := false
	seen := Watcher {
		cancelled = &stop,
	}
	inventory := discover(
		[]string{tree},
		Walk{on_progress = watch, user = &seen},
		context.allocator,
	)
	defer destroy_inventory(inventory, context.allocator)

	testing.expectf(t, seen.calls >= 5, "a walk of five directories reported %d times", seen.calls)
	testing.expect_value(t, seen.directories, 5)
	testing.expect_value(t, len(inventory.found), 5)
	testing.expect(t, !inventory.cancelled, "a walk nobody stopped reported itself cancelled")
}

@(test)
a_walk_asked_to_stop_stops_and_answers_with_what_it_had_got_to :: proc(t: ^testing.T) {
	tree := a_spread_tree(t, "cancel")
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	stop := false
	seen := Watcher {
		stop_after = 1,
		cancelled  = &stop,
	}
	inventory := discover(
		[]string{tree},
		Walk{on_progress = watch, user = &seen, cancelled = &stop},
		context.allocator,
	)
	defer destroy_inventory(inventory, context.allocator)

	testing.expect(t, inventory.cancelled, "a walk that was asked to stop did not say it had")
	testing.expectf(
		t,
		len(inventory.found) < 5,
		"a walk stopped at its first directory still found all %d Recordings",
		len(inventory.found),
	)
	testing.expect_value(t, seen.calls, 1)
}

// A tree deeper than the walk will go is reported and never silently truncated.
@(test)
a_tree_deeper_than_the_walk_will_go_says_so_rather_than_stopping_quietly :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "planning", "deep", context.allocator)
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	out := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&out)
	for _ in 0 ..< MAX_WALK_DEPTH + 1 {
		strings.write_string(&out, "d\\")
	}
	strings.write_string(&out, "talk.mp4")

	buried := testkit.fixture_file(
		t,
		tree,
		strings.to_string(out),
		transmute([]u8)string("video"),
		nil,
		context.allocator,
	)
	defer delete(buried, context.allocator)

	inventory := discover([]string{tree}, Walk{}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	_, said := noted(inventory, .Too_Deep)
	testing.expect(t, said, "a tree deeper than the walk goes was truncated without a word")
	testing.expect_value(t, len(inventory.found), 0)
}

@(private)
CMD :: "cmd.exe"

@(private)
CMD_BOUND_MS :: u32(20_000)

// One bounded child, started and stopped the one way. The two things no Odin
// call in `core` will do -- make a reparse point, set an ACL -- are the same
// five steps of child lifecycle, so they are the same procedure.
//
// Whether the tool DID anything is the caller's to check: `mklink` refused for
// want of a privilege exits non-zero having started and finished perfectly well.
@(private)
@(require_results)
ran :: proc(t: ^testing.T, program: string, arguments: []string) -> bool {
	group, opening := child.job_object_open()
	defer child.job_object_close(&group)
	if !testing.expectf(t, opening.fault == .None, "no job object: %v", opening.fault) {
		return false
	}

	c, refusal := child.start(&group, program, arguments, context.allocator)
	if !testing.expectf(
		t,
		refusal.fault == .None,
		"%s would not start: %v",
		program,
		refusal.fault,
	) {
		return false
	}
	defer child.close(&c)

	if !testing.expect(t, child.wait(&c, CMD_BOUND_MS), "a child did not finish in time") {
		testing.expect(t, child.stop(&c), "a child overran and may still hold this tree open")
		return false
	}
	return true
}

// A DIRECTORY reparse point, which needs no elevation.
@(private)
@(require_results)
junction :: proc(t: ^testing.T, link: string, target: string) -> bool {
	if !ran(t, CMD, []string{"/c", "mklink", "/J", link, target}) {
		return false
	}
	return testing.expect(t, os.exists(link), "mklink reported success and made no junction")
}

// A FILE reparse point, which needs Developer Mode or elevation where a junction
// needs neither. A machine that will not make one is not a failing case, so this
// answers false and the case stops -- what holds the rule everywhere is
// `taken_for`, which needs no privilege at all.
@(private)
@(require_results)
file_symlink :: proc(t: ^testing.T, link: string, target: string) -> bool {
	if !ran(t, CMD, []string{"/c", "mklink", link, target}) {
		return false
	}
	return os.exists(link)
}

// Criterion six's last clause. `core:os` calls a directory carrying any reparse
// tag but SYMLINK or MOUNT_POINT a plain `.Directory`, so the walk reads the
// attribute rather than trusting the type (ADR-0026); a junction is what a case
// can actually make.
@(test)
a_reparse_point_is_not_followed_by_default_and_is_reported :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "planning", "junction", context.allocator)
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	real := a_directory(t, tree, "real")
	defer delete(real, context.allocator)
	behind := testkit.fixture_file(
		t,
		tree,
		"real\\behind.mp4",
		transmute([]u8)string("video"),
		nil,
		context.allocator,
	)
	defer delete(behind, context.allocator)

	link := fmt.aprintf("%s\\link", tree, allocator = context.allocator)
	defer delete(link, context.allocator)
	if !junction(t, link, real) {
		return
	}
	defer os.remove(link)

	testing.expect(
		t,
		is_a_reparse_point(link, context.allocator),
		"a junction was not recognised as a reparse point",
	)
	testing.expect(
		t,
		!is_a_reparse_point(real, context.allocator),
		"an ordinary directory was called a reparse point",
	)

	inventory := discover([]string{tree}, Walk{}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	testing.expectf(
		t,
		len(inventory.found) == 1,
		"the walk followed a reparse point and found %d Recordings",
		len(inventory.found),
	)
	path, said := noted(inventory, .Reparse_Point_Not_Followed)
	testing.expect(t, said, "a reparse point was skipped without a word")
	testing.expect_value(t, path, link)
}

// A root that is itself a reparse point is refused for the same reason, and the
// refusal names the root rather than answering with an empty tree.
@(test)
a_root_that_is_a_reparse_point_is_not_walked_either :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "planning", "junctionroot", context.allocator)
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	real := a_directory(t, tree, "real")
	defer delete(real, context.allocator)
	behind := testkit.fixture_file(
		t,
		tree,
		"real\\behind.mp4",
		transmute([]u8)string("video"),
		nil,
		context.allocator,
	)
	defer delete(behind, context.allocator)

	link := fmt.aprintf("%s\\link", tree, allocator = context.allocator)
	defer delete(link, context.allocator)
	if !junction(t, link, real) {
		return
	}
	defer os.remove(link)

	inventory := discover([]string{link}, Walk{}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	testing.expect_value(t, len(inventory.found), 0)
	path, said := noted(inventory, .Root_Unreadable)
	testing.expect(t, said, "a root that is a reparse point was walked as though it were empty")
	testing.expect_value(t, path, link)
}

// Turning it on is the whole of the difference, so the default is a decision a
// caller can see rather than a limitation.
@(test)
a_walk_told_to_follow_reparse_points_walks_through_one :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "planning", "followed", context.allocator)
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	real := a_directory(t, tree, "real")
	defer delete(real, context.allocator)
	behind := testkit.fixture_file(
		t,
		tree,
		"real\\behind.mp4",
		transmute([]u8)string("video"),
		nil,
		context.allocator,
	)
	defer delete(behind, context.allocator)

	link := fmt.aprintf("%s\\link", tree, allocator = context.allocator)
	defer delete(link, context.allocator)
	if !junction(t, link, real) {
		return
	}
	defer os.remove(link)

	inventory := discover([]string{link}, Walk{follow_reparse_points = true}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	testing.expect_value(t, len(inventory.found), 1)
	testing.expect_value(t, len(inventory.notes), 0)
}

// The path a user actually hits. A junction passed as a ROOT never reaches
// `took` at all -- `enumerable` asks `os.is_dir`, which resolves it -- so the
// case above proves the flag and not the walk. Turning following ON must never
// be less safe than leaving it off, and a junction dropped in silence is exactly
// that: the default at least reports the skip.
@(test)
a_junction_inside_the_tree_is_walked_through_when_following_is_turned_on :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "planning", "followedinside", context.allocator)
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	real := a_directory(t, tree, "real")
	defer delete(real, context.allocator)
	behind := testkit.fixture_file(
		t,
		tree,
		"real\\behind.mp4",
		transmute([]u8)string("video"),
		nil,
		context.allocator,
	)
	defer delete(behind, context.allocator)
	under := a_directory(t, tree, "sub")
	defer delete(under, context.allocator)

	link := fmt.aprintf("%s\\link", under, allocator = context.allocator)
	defer delete(link, context.allocator)
	if !junction(t, link, real) {
		return
	}
	defer os.remove(link)

	inventory := discover([]string{tree}, Walk{follow_reparse_points = true}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	testing.expectf(
		t,
		len(inventory.found) == 2,
		"a walk told to follow reparse points found %d Recordings through a junction it was given",
		len(inventory.found),
	)
	testing.expectf(
		t,
		len(inventory.notes) == 0,
		"a walk told to follow reparse points reported %d note(s) anyway",
		len(inventory.notes),
	)
}

// A reparse point is not TRAVERSED; that rule says nothing about a file, where
// there is nothing to traverse. Every OneDrive Files-On-Demand placeholder
// carries FILE_ATTRIBUTE_REPARSE_POINT, so a walk that skipped one planned a
// corpus in OneDrive as empty and exited zero -- ADR-0009's silently short file
// list, reached through this program's own opt-out.
@(test)
a_recording_that_is_itself_a_reparse_point_is_planned_and_never_skipped :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "planning", "reparsefile", context.allocator)
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	real := testkit.fixture_file(
		t,
		tree,
		"real.mp4",
		transmute([]u8)string("video"),
		nil,
		context.allocator,
	)
	defer delete(real, context.allocator)

	link := fmt.aprintf("%s\\link.mp4", tree, allocator = context.allocator)
	defer delete(link, context.allocator)
	if !file_symlink(t, link, real) {
		return
	}
	defer os.remove(link)

	inventory := discover([]string{tree}, Walk{}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	_, took := found_at(inventory, link)
	testing.expect(t, took, "a Recording that is itself a reparse point was dropped from the plan")
	testing.expectf(
		t,
		len(inventory.notes) == 0,
		"a Recording that is itself a reparse point was reported as a skipped directory",
	)
}

// Enough entries that even a fast NTFS enumeration takes real, measurable
// time -- a single FindNextFileW call is cheap, but several thousand of them
// are not free, and that is what stands in here for the stalled share issue
// #27 names: this suite has no way to make a real network drive stop
// answering, so the bound is proven against real wall-clock cost instead.
@(private)
DIRECTORY_BOUND_TEST_ENTRIES :: 3000

@(test)
a_directory_listing_that_cannot_finish_within_its_bound_is_reported_rather_than_awaited_forever :: proc(
	t: ^testing.T,
) {
	tree := testkit.made_scratch_cache(t, "planning", "dirbound", context.allocator)
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	for i in 0 ..< DIRECTORY_BOUND_TEST_ENTRIES {
		name := fmt.aprintf("f%d.txt", i, allocator = context.allocator)
		path := testkit.fixture_file(
			t,
			tree,
			name,
			transmute([]u8)string(""),
			nil,
			context.allocator,
		)
		delete(path, context.allocator)
		delete(name, context.allocator)
	}

	state := Walking {
		allocator = context.allocator,
		worker    = child.spawn_worker(),
	}
	if !testing.expect(
		t,
		state.worker != nil,
		"a worker this case needed to start would not start",
	) {
		return
	}
	defer child.release_worker(state.worker)

	started := time.tick_now()
	listing, ok := directory_listing_bounded(&state, tree, 1)
	elapsed := time.tick_since(started)
	defer if ok {
		os.file_info_slice_delete(listing, context.allocator)
	}

	testing.expect(t, !ok, "a directory listing bounded at 1 ms was not abandoned at all")
	testing.expect(
		t,
		len(listing) == 0,
		"an abandoned listing handed back entries it never finished",
	)
	testing.expectf(
		t,
		elapsed < 5 * time.Second,
		"a directory listing bounded at 1 ms took %v to be reported, which is not being bounded at all",
		elapsed,
	)
}

@(test)
a_directory_listing_within_its_bound_returns_every_entry :: proc(t: ^testing.T) {
	tree := testkit.made_scratch_cache(t, "planning", "dirboundok", context.allocator)
	defer delete(tree, context.allocator)
	defer testkit.remove_tree(tree)

	a := testkit.fixture_file(t, tree, "a.mp4", transmute([]u8)string("a"), nil, context.allocator)
	defer delete(a, context.allocator)
	b := testkit.fixture_file(t, tree, "b.mp4", transmute([]u8)string("b"), nil, context.allocator)
	defer delete(b, context.allocator)

	state := Walking {
		allocator = context.allocator,
		worker    = child.spawn_worker(),
	}
	if !testing.expect(
		t,
		state.worker != nil,
		"a worker this case needed to start would not start",
	) {
		return
	}
	defer child.release_worker(state.worker)

	listing, ok := directory_listing_bounded(&state, tree, child.READ_BOUND_MS)
	defer if ok {
		os.file_info_slice_delete(listing, context.allocator)
	}

	testing.expect(t, ok, "a directory listing within its bound was reported as unreadable")
	testing.expect_value(t, len(listing), 2)
}

// `clone_listing`'s own double-free regression case -- and the probe
// allocator it needed to reach `os.file_info_clone`'s allocation failure
// without a real out-of-memory condition -- used to be duplicated here
// (issue #66). This package now goes through
// `child.clone_directory_listing`, so the one copy of that case is
// `a_directory_listing_that_cannot_be_cloned_under_memory_pressure_frees_-`
// `what_it_cloned_exactly_once` in `src/child/directory_test.odin`.

// Findings 3 and 4 of PR #64's second review: a Transcript-head read that
// hit its bound used to answer `.Foreign`, which routes to
// `Reason.Foreign_Transcript` in plan.odin -- a confident wrong diagnosis,
// since the truth is that discovery does not know what is there. A thread
// that could not even be started (walk.odin's `t == nil` branch, reached by
// exactly the resource exhaustion issue #12's pipeline over hundreds of
// Recordings can produce) used to answer `.Absent`, which plans the
// Recording fresh and risks overwriting a Transcript this walk never read.
// Both now answer `.Unreadable`, checked here against every member of
// `child.Wait` directly -- `transcript_state_of` is the pure mapping
// `transcript_state_bounded` reads its answer through, so this does not
// need a thread that can be made to hang to prove it.
@(test)
transcript_state_of_never_lets_a_bound_reached_read_as_absent_or_foreign :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		transcript_state_of(.Finished, .Transcibrs),
		Transcript_State.Transcibrs,
	)
	testing.expect_value(t, transcript_state_of(.Finished, .Foreign), Transcript_State.Foreign)
	testing.expect_value(t, transcript_state_of(.Finished, .Absent), Transcript_State.Absent)
	testing.expect_value(t, transcript_state_of(.Stopped, {}), Transcript_State.Unreadable)
	testing.expect_value(t, transcript_state_of(.Unstoppable, {}), Transcript_State.Unreadable)
}
