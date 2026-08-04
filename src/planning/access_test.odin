package planning

import "core:fmt"
import "core:os"
import "core:testing"
import "transcibr:child"

// A directory this account may not list, and one it may not write into. Neither
// state can be reached from `core:os`, and both are what the two criteria about
// access are actually about -- so the ACL is set with the tool Windows ships.
@(private)
ICACLS :: "icacls.exe"

@(private)
denied :: proc(t: ^testing.T, path: string, rights: string) -> bool {
	who := os.get_env("USERNAME", context.allocator)
	defer delete(who, context.allocator)
	if !testing.expect(t, len(who) > 0, "USERNAME names nobody to deny anything to") {
		return false
	}

	rule := fmt.aprintf("%s:%s", who, rights, allocator = context.allocator)
	defer delete(rule, context.allocator)
	return icacls(t, []string{path, "/deny", rule})
}

@(private)
undenied :: proc(t: ^testing.T, path: string) {
	who := os.get_env("USERNAME", context.allocator)
	defer delete(who, context.allocator)
	if len(who) == 0 {
		return
	}

	icacls(t, []string{path, "/remove:d", who})
}

@(private)
icacls :: proc(t: ^testing.T, arguments: []string) -> bool {
	group, opening := child.job_object_open()
	defer child.job_object_close(&group)
	if !testing.expectf(t, opening.fault == .None, "no job object: %v", opening.fault) {
		return false
	}

	c, refusal := child.start(&group, ICACLS, arguments, context.allocator)
	if !testing.expectf(t, refusal.fault == .None, "icacls would not start: %v", refusal.fault) {
		return false
	}
	defer child.close(&c)

	if !testing.expect(t, child.wait(&c, CMD_BOUND_MS), "icacls did not finish in time") {
		child.stop(&c)
		return false
	}
	return true
}

// ADR-0009 names this one exactly: a silently short file list is the one
// discovery failure a user cannot detect.
@(test)
a_sub_directory_that_cannot_be_enumerated_is_an_operating_error :: proc(t: ^testing.T) {
	tree := scratch_tree(t, "unlistable")
	defer delete(tree, context.allocator)
	defer remove_tree(tree)

	open := in_tree(t, tree, "open.mp4", "video")
	defer delete(open, context.allocator)
	shut := a_directory(t, tree, "shut")
	defer delete(shut, context.allocator)
	hidden := in_tree(t, tree, "shut\\hidden.mp4", "video")
	defer delete(hidden, context.allocator)

	if !denied(t, shut, "(RD)") {
		return
	}
	defer undenied(t, shut)

	inventory := discover([]string{tree}, Walk{}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	path, said := noted(inventory, .Directory_Unreadable)
	if !testing.expect(t, said, "a directory that would not list was treated as empty") {
		return
	}
	testing.expect_value(t, path, shut)
	testing.expectf(
		t,
		len(inventory.found) == 1,
		"the walk read %d Recordings out of a directory it could not list",
		len(inventory.found),
	)
}

// Criterion eight: the check is at plan time, so the Batch learns it cannot
// publish before it has spent anything finding out.
@(test)
a_directory_nothing_may_be_written_to_is_refused_before_any_gpu_time :: proc(t: ^testing.T) {
	tree := scratch_tree(t, "unwritable")
	defer delete(tree, context.allocator)
	defer remove_tree(tree)

	locked := a_directory(t, tree, "locked")
	defer delete(locked, context.allocator)
	inside := in_tree(t, tree, "locked\\talk.mp4", "video")
	defer delete(inside, context.allocator)

	if !denied(t, locked, "(WD)") {
		return
	}
	defer undenied(t, locked)

	inventory := discover([]string{tree}, Walk{}, context.allocator)
	defer destroy_inventory(inventory, context.allocator)

	found, took := found_at(inventory, inside)
	if !testing.expect(t, took, "a Recording in a locked directory was not found at all") {
		return
	}
	testing.expect(
		t,
		!found.directory_writable,
		"a directory nothing may be written to was called writable",
	)
	testing.expect_value(t, decide(found, settings()).decision, Decision.Refuse)
	testing.expect_value(t, decide(found, settings()).reason, Reason.Directory_Not_Writable)
}

// The probe is a file, and a walk that left one behind would litter every
// directory a Batch was ever pointed at.
@(test)
the_probe_that_asks_whether_a_directory_is_writable_leaves_nothing_behind :: proc(t: ^testing.T) {
	tree := scratch_tree(t, "probe")
	defer delete(tree, context.allocator)
	defer remove_tree(tree)

	talk := in_tree(t, tree, "talk.mp4", "video")
	defer delete(talk, context.allocator)

	testing.expect(
		t,
		directory_writable(tree, context.allocator),
		"a directory this account owns was called unwritable",
	)

	listing, unreadable := os.read_all_directory_by_path(tree, context.allocator)
	defer os.file_info_slice_delete(listing, context.allocator)
	testing.expect(t, unreadable == nil, "the tree would not list")
	testing.expect_value(t, len(listing), 1)
}

@(test)
a_directory_that_is_not_there_is_never_called_writable :: proc(t: ^testing.T) {
	tree := scratch_tree(t, "nodir")
	defer delete(tree, context.allocator)
	defer remove_tree(tree)

	gone := fmt.aprintf("%s\\never-made", tree, allocator = context.allocator)
	defer delete(gone, context.allocator)

	testing.expect(
		t,
		!directory_writable(gone, context.allocator),
		"a directory that is not there was called writable",
	)
}
