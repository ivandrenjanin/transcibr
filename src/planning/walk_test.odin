package planning

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:testing"
import "transcibr:child"

// Names a place and does not create it. The caller frees the path and removes
// the tree.
@(private)
scratch_tree :: proc(t: ^testing.T, tag: string) -> string {
	directory := os.get_env("TEMP", context.allocator)
	defer delete(directory, context.allocator)
	testing.expect(t, len(directory) > 0, "TEMP names nowhere to put a tree to walk")

	made := fmt.aprintf(
		"%s\\transcibr-planning-%d-%s",
		directory,
		os.get_pid(),
		tag,
		allocator = context.allocator,
	)
	testing.expectf(t, os.make_directory_all(made) == nil, "could not make %s", made)
	return made
}

@(private)
in_tree :: proc(t: ^testing.T, tree: string, relative: string, content: string) -> string {
	path := fmt.aprintf("%s\\%s", tree, relative, allocator = context.allocator)

	at := strings.last_index_byte(path, '\\')
	if at > 0 {
		testing.expectf(
			t,
			os.make_directory_all(path[:at]) == nil,
			"could not make the directory holding %s",
			path,
		)
	}
	testing.expectf(
		t,
		os.write_entire_file(path, transmute([]u8)content) == nil,
		"could not write %s",
		path,
	)
	return path
}

@(private)
a_directory :: proc(t: ^testing.T, tree: string, relative: string) -> string {
	path := fmt.aprintf("%s\\%s", tree, relative, allocator = context.allocator)
	testing.expectf(t, os.make_directory_all(path) == nil, "could not make %s", path)
	return path
}

// Best effort, deepest first: a case that failed half-way should not fail a
// second time on the way out.
@(private)
remove_tree :: proc(path: string) {
	listing, unreadable := os.read_all_directory_by_path(path, context.allocator)
	if unreadable == nil {
		defer os.file_info_slice_delete(listing, context.allocator)
		for info in listing {
			if info.type == .Directory {
				remove_tree(info.fullpath)
				continue
			}
			os.remove(info.fullpath)
		}
	}
	os.remove(path)
}

@(private)
sources_of :: proc(inventory: Inventory) -> []string {
	names := make([]string, len(inventory.found), context.allocator)
	for entry, at in inventory.found {
		names[at] = entry.source
	}
	slice.sort(names)
	return names
}

@(private)
found_at :: proc(inventory: Inventory, path: string) -> (found: Found, yes: bool) {
	for entry in inventory.found {
		if strings.equal_fold(entry.source, path) {
			return entry, true
		}
	}
	return {}, false
}

@(private)
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
		}) {
		testing.expectf(t, is_a_recording(named), "%q was not taken for a Recording", named)
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
			testing.expect_value(t, short, c.note)
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

@(test)
a_tree_is_walked_into_an_inventory_of_every_recording_under_it :: proc(t: ^testing.T) {
	tree := scratch_tree(t, "walk")
	defer delete(tree, context.allocator)
	defer remove_tree(tree)

	top := in_tree(t, tree, "keynote.mp4", "video")
	defer delete(top, context.allocator)
	nested := in_tree(t, tree, "june\\deeper\\interview.m4a", "audio")
	defer delete(nested, context.allocator)
	notes := in_tree(t, tree, "june\\notes.txt", "not a Recording")
	defer delete(notes, context.allocator)
	stale := in_tree(t, tree, "june\\interview.json.bad", "quarantined")
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
	tree := scratch_tree(t, "foreign")
	defer delete(tree, context.allocator)
	defer remove_tree(tree)

	mine := in_tree(t, tree, "talk.mp4", "video")
	defer delete(mine, context.allocator)
	theirs := in_tree(t, tree, "notes.mp4", "video")
	defer delete(theirs, context.allocator)
	written := in_tree(t, tree, "talk.md", "---\ngenerator: \"transcibr 0.1.0\"\n---\n")
	defer delete(written, context.allocator)
	authored := in_tree(t, tree, "notes.md", "# Notes on the interview\n")
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

@(test)
a_root_that_is_not_there_is_reported_against_itself_and_never_as_empty :: proc(t: ^testing.T) {
	tree := scratch_tree(t, "missing")
	defer delete(tree, context.allocator)
	defer remove_tree(tree)

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
	tree := scratch_tree(t, "notadir")
	defer delete(tree, context.allocator)
	defer remove_tree(tree)

	file := in_tree(t, tree, "talk.mp4", "video")
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
a_spread_tree :: proc(t: ^testing.T, tag: string) -> string {
	tree := scratch_tree(t, tag)
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
		path := in_tree(t, tree, spelled, "video")
		delete(path, context.allocator)
	}
	return tree
}

@(test)
a_walk_reports_progress_as_it_goes_through_the_tree :: proc(t: ^testing.T) {
	tree := a_spread_tree(t, "progress")
	defer delete(tree, context.allocator)
	defer remove_tree(tree)

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
	defer remove_tree(tree)

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
	tree := scratch_tree(t, "deep")
	defer delete(tree, context.allocator)
	defer remove_tree(tree)

	out := strings.builder_make(context.allocator)
	defer strings.builder_destroy(&out)
	for _ in 0 ..< MAX_WALK_DEPTH + 1 {
		strings.write_string(&out, "d\\")
	}
	strings.write_string(&out, "talk.mp4")

	buried := in_tree(t, tree, strings.to_string(out), "video")
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

// The one thing no Odin call in `core` will do: make a reparse point. A junction
// needs no elevation, which a symbolic link does.
@(private)
junction :: proc(t: ^testing.T, link: string, target: string) -> bool {
	group, opening := child.job_object_open()
	defer child.job_object_close(&group)
	if !testing.expectf(t, opening.fault == .None, "no job object: %v", opening.fault) {
		return false
	}

	c, refusal := child.start(
		&group,
		CMD,
		[]string{"/c", "mklink", "/J", link, target},
		context.allocator,
	)
	if !testing.expectf(t, refusal.fault == .None, "mklink would not start: %v", refusal.fault) {
		return false
	}
	defer child.close(&c)

	if !testing.expect(t, child.wait(&c, CMD_BOUND_MS), "mklink did not finish in time") {
		child.stop(&c)
		return false
	}
	return testing.expect(t, os.exists(link), "mklink reported success and made no junction")
}

// Criterion six's last clause. `core:os` calls a directory carrying any reparse
// tag but SYMLINK or MOUNT_POINT a plain `.Directory`, so the walk reads the
// attribute rather than trusting the type (ADR-0026); a junction is what a case
// can actually make.
@(test)
a_reparse_point_is_not_followed_by_default_and_is_reported :: proc(t: ^testing.T) {
	tree := scratch_tree(t, "junction")
	defer delete(tree, context.allocator)
	defer remove_tree(tree)

	real := a_directory(t, tree, "real")
	defer delete(real, context.allocator)
	behind := in_tree(t, tree, "real\\behind.mp4", "video")
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
	tree := scratch_tree(t, "junctionroot")
	defer delete(tree, context.allocator)
	defer remove_tree(tree)

	real := a_directory(t, tree, "real")
	defer delete(real, context.allocator)
	behind := in_tree(t, tree, "real\\behind.mp4", "video")
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
	tree := scratch_tree(t, "followed")
	defer delete(tree, context.allocator)
	defer remove_tree(tree)

	real := a_directory(t, tree, "real")
	defer delete(real, context.allocator)
	behind := in_tree(t, tree, "real\\behind.mp4", "video")
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
