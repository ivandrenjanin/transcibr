#+vet explicit-allocators
package testkit

import "core:fmt"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"
import "core:testing"
import "core:thread"
import "core:time"

@(test)
scratch_cache_names_a_place_it_does_not_create :: proc(t: ^testing.T) {
	cache := scratch_cache(t, "testkit", "names-only", context.allocator)
	defer delete(cache, context.allocator)

	testing.expect(t, !os.exists(cache), "scratch_cache created the directory it only names")
	testing.expect(
		t,
		strings.contains(cache, "transcibr-testkit-"),
		"scratch_cache did not name the scope it was given",
	)
}

@(test)
made_scratch_cache_creates_the_directory_it_names :: proc(t: ^testing.T) {
	cache := made_scratch_cache(t, "testkit", "made", context.allocator)
	defer delete(cache, context.allocator)
	defer remove_cache(cache, context.allocator)

	testing.expect(t, os.exists(cache), "made_scratch_cache did not create the directory it named")
}

@(test)
remove_cache_takes_the_directory_and_what_was_left_in_it :: proc(t: ^testing.T) {
	cache := made_scratch_cache(t, "testkit", "remove", context.allocator)
	defer delete(cache, context.allocator)

	inner := fmt.aprintf("%s\\left-behind.bin", cache, allocator = context.allocator)
	defer delete(inner, context.allocator)
	if !testing.expect(
		t,
		os.write_entire_file(inner, []u8{0}) == nil,
		"could not write a file to remove",
	) {
		return
	}

	remove_cache(cache, context.allocator)

	testing.expect(t, !os.exists(cache), "remove_cache left the directory behind")
}

// Holds a second handle open on a file inside the cache with no
// FILE_SHARE_DELETE, so Windows answers remove_cache's own DeleteFileW on it
// with a transient sharing violation -- the same shape a real-time scanner
// opening a just-written file produces, and the shape the #178 review's
// "just-deleted files [...] still in Windows' pending-delete state" names
// generically: the removal underneath remove_cache is not yet safe to run
// the instant the file exists, and only becomes so once every other handle
// on it lets go.
@(private)
Held_File_Job :: struct {
	handle:  win32.HANDLE,
	release: time.Duration,
}

@(private)
release_held_file :: proc(data: rawptr) {
	job := (^Held_File_Job)(data)
	assert(job != nil, "a held-file release thread was started with no job to release")
	time.sleep(job.release)
	win32.CloseHandle(job.handle)
}

// A fix with no retry at all fails this every time -- the very first
// DeleteFileW lands mid-lock -- and one bounded below RELEASE_DELAY fails it
// just as reliably, since the lock has not yet lifted when the budget runs
// out.
@(test)
remove_cache_survives_a_file_still_locked_when_removal_first_runs :: proc(t: ^testing.T) {
	cache := made_scratch_cache(t, "testkit", "locked-file", context.allocator)
	defer delete(cache, context.allocator)

	held := fmt.aprintf("%s\\held.bin", cache, allocator = context.allocator)
	defer delete(held, context.allocator)
	if !testing.expect(
		t,
		os.write_entire_file(held, []u8{0}) == nil,
		"could not write the file this case holds open",
	) {
		return
	}

	wide := win32.utf8_to_wstring(held, context.allocator)
	defer delete(wide, context.allocator)
	handle := win32.CreateFileW(
		wide,
		win32.GENERIC_READ,
		win32.FILE_SHARE_READ,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if !testing.expect(t, handle != win32.INVALID_HANDLE_VALUE, "could not open the held handle") {
		return
	}

	RELEASE_DELAY :: 40 * time.Millisecond
	job := Held_File_Job {
		handle  = handle,
		release = RELEASE_DELAY,
	}
	th := thread.create_and_start_with_data(&job, release_held_file)
	if !testing.expect(t, th != nil, "a thread this case needed to start would not start") {
		win32.CloseHandle(handle)
		return
	}

	remove_cache(cache, context.allocator)
	thread.destroy(th)

	testing.expectf(
		t,
		!os.exists(cache),
		"remove_cache gave up on %s before the held file's lock lifted",
		cache,
	)
}

// Issue #229: three consecutive `just ci` runs, instrumented, measured the
// existing budget (5 attempts * 20ms = 80ms of sleep before the last try)
// losing to a real lock-release window of 117-130ms under the disk load a
// full `just ci` produces -- src/planning's own locked-dead-run-tree case
// hit exactly this, consistently, all three runs. RELEASE_DELAY here sits
// above every one of those measured elapsed times, so this case fails
// against the pre-#229 budget for the same reason a real `just ci` run
// does, and only passes once the budget is widened to cover it.
@(test)
remove_cache_survives_a_lock_released_past_the_pre_229_budget :: proc(t: ^testing.T) {
	cache := made_scratch_cache(t, "testkit", "locked-file-229", context.allocator)
	defer delete(cache, context.allocator)

	held := fmt.aprintf("%s\\held.bin", cache, allocator = context.allocator)
	defer delete(held, context.allocator)
	if !testing.expect(
		t,
		os.write_entire_file(held, []u8{0}) == nil,
		"could not write the file this case holds open",
	) {
		return
	}

	wide := win32.utf8_to_wstring(held, context.allocator)
	defer delete(wide, context.allocator)
	handle := win32.CreateFileW(
		wide,
		win32.GENERIC_READ,
		win32.FILE_SHARE_READ,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if !testing.expect(t, handle != win32.INVALID_HANDLE_VALUE, "could not open the held handle") {
		return
	}

	RELEASE_DELAY :: 150 * time.Millisecond
	job := Held_File_Job {
		handle  = handle,
		release = RELEASE_DELAY,
	}
	th := thread.create_and_start_with_data(&job, release_held_file)
	if !testing.expect(t, th != nil, "a thread this case needed to start would not start") {
		win32.CloseHandle(handle)
		return
	}

	remove_cache(cache, context.allocator)
	thread.destroy(th)

	testing.expectf(
		t,
		!os.exists(cache),
		"remove_cache gave up on %s before a lock released past the measured just-ci window",
		cache,
	)
}

@(test)
lonely_signal_names_differ_by_scope_and_by_tag :: proc(t: ^testing.T) {
	first := lonely_signal("Audio", "one", context.allocator)
	defer delete(first, context.allocator)
	second := lonely_signal("Engine", "one", context.allocator)
	defer delete(second, context.allocator)
	third := lonely_signal("Audio", "two", context.allocator)
	defer delete(third, context.allocator)

	testing.expect(
		t,
		first != second,
		"two packages asking for the same tag got the same signal name",
	)
	testing.expect(t, first != third, "two cases in one package got the same signal name")
}

@(test)
write_flood_writes_at_least_the_bytes_it_was_asked_for :: proc(t: ^testing.T) {
	cache := made_scratch_cache(t, "testkit", "flood", context.allocator)
	defer delete(cache, context.allocator)
	defer remove_cache(cache, context.allocator)

	path := fmt.aprintf("%s\\flood.txt", cache, allocator = context.allocator)
	defer delete(path, context.allocator)

	testing.expect(
		t,
		write_flood(t, path, 100, "a line this case has no reading for\r\n", context.allocator),
		"write_flood reported a failure writing its own fixture",
	)

	written, unreadable := os.read_entire_file(path, context.allocator)
	defer delete(written, context.allocator)
	if !testing.expect(t, unreadable == nil, "write_flood did not leave a file behind") {
		return
	}
	testing.expect(
		t,
		len(written) >= 100,
		"write_flood stopped short of the bytes it was asked for",
	)
	testing.expect(
		t,
		strings.starts_with(string(written), "a line this case has no reading for"),
		"write_flood did not write the filler line it was given",
	)
}

@(test)
fixture_file_writes_content_into_a_subdirectory_it_creates :: proc(t: ^testing.T) {
	cache := made_scratch_cache(t, "testkit", "fixture-subdir", context.allocator)
	defer delete(cache, context.allocator)
	defer remove_tree(cache, context.allocator)

	path := fixture_file(t, cache, "nested\\deeper\\talk.mp4", "video", context.allocator)
	defer delete(path, context.allocator)

	written, unreadable := os.read_entire_file(path, context.allocator)
	defer delete(written, context.allocator)
	if !testing.expect(
		t,
		unreadable == nil,
		"fixture_file did not create the subdirectory it needed",
	) {
		return
	}
	as_text: string = string(written)
	testing.expect_value(t, as_text, "video")
}

@(test)
fixture_file_with_an_age_backdates_the_files_modified_time :: proc(t: ^testing.T) {
	cache := made_scratch_cache(t, "testkit", "fixture-aged", context.allocator)
	defer delete(cache, context.allocator)
	defer remove_cache(cache, context.allocator)

	content := make([]u8, 1024, context.allocator)
	defer delete(content, context.allocator)

	path := fixture_file(
		t,
		cache,
		"stale.wav",
		string(content),
		context.allocator,
		30 * 24 * time.Hour,
	)
	defer delete(path, context.allocator)

	info, unreadable := os.stat(path, context.allocator)
	defer os.file_info_delete(info, context.allocator)
	if !testing.expect(t, unreadable == nil, "fixture_file did not write the file to age") {
		return
	}
	testing.expect(
		t,
		time.since(info.modification_time) >= 29 * 24 * time.Hour,
		"fixture_file did not back-date the file it wrote",
	)
}

@(test)
remove_tree_takes_a_tree_and_every_directory_nested_in_it :: proc(t: ^testing.T) {
	cache := made_scratch_cache(t, "testkit", "remove-tree", context.allocator)
	defer delete(cache, context.allocator)

	nested := fixture_file(t, cache, "june\\deeper\\interview.m4a", "audio", context.allocator)
	defer delete(nested, context.allocator)

	remove_tree(cache, context.allocator)

	testing.expect(t, !os.exists(cache), "remove_tree left the tree it was given behind")
}

// remove_tree is planning's own consumer of the fix (#178 AC2): planning's
// suites walk real directory trees rather than flat caches, so this proves
// the same locked-file window closes through remove_tree's own final
// remove_settled and not only remove_cache's.
@(test)
remove_tree_survives_a_nested_file_still_locked_when_removal_first_runs :: proc(t: ^testing.T) {
	cache := made_scratch_cache(t, "testkit", "locked-tree", context.allocator)
	defer delete(cache, context.allocator)

	held := fixture_file(t, cache, "june\\held.bin", "x", context.allocator)
	defer delete(held, context.allocator)

	wide := win32.utf8_to_wstring(held, context.allocator)
	defer delete(wide, context.allocator)
	handle := win32.CreateFileW(
		wide,
		win32.GENERIC_READ,
		win32.FILE_SHARE_READ,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if !testing.expect(t, handle != win32.INVALID_HANDLE_VALUE, "could not open the held handle") {
		return
	}

	RELEASE_DELAY :: 40 * time.Millisecond
	job := Held_File_Job {
		handle  = handle,
		release = RELEASE_DELAY,
	}
	th := thread.create_and_start_with_data(&job, release_held_file)
	if !testing.expect(t, th != nil, "a thread this case needed to start would not start") {
		win32.CloseHandle(handle)
		return
	}

	remove_tree(cache, context.allocator)
	thread.destroy(th)

	testing.expectf(
		t,
		!os.exists(cache),
		"remove_tree gave up on %s before the held file's lock lifted",
		cache,
	)
}

@(test)
flood_type_command_names_the_file_the_wait_and_the_signal :: proc(t: ^testing.T) {
	command := flood_type_command("C:\\cache\\flood.txt", 25, "NoSignal", context.allocator)
	defer delete(command, context.allocator)

	testing.expect(
		t,
		strings.contains(command, "type C:\\cache\\flood.txt"),
		"flood_type_command did not type the path it was given",
	)
	testing.expect(
		t,
		strings.contains(command, "waitfor /t 25 NoSignal"),
		"flood_type_command did not wait on the signal it was given",
	)
}
