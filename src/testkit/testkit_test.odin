#+vet explicit-allocators
package testkit

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
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
	defer remove_cache(cache, context.allocator)

	path := fixture_file(
		t,
		cache,
		"nested\\deeper\\talk.mp4",
		transmute([]u8)string("video"),
		nil,
		context.allocator,
	)
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

	path := fixture_file(t, cache, "stale.wav", content, 30 * 24 * time.Hour, context.allocator)
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

	nested := fixture_file(
		t,
		cache,
		"june\\deeper\\interview.m4a",
		transmute([]u8)string("audio"),
		nil,
		context.allocator,
	)
	defer delete(nested, context.allocator)

	remove_tree(cache)

	testing.expect(t, !os.exists(cache), "remove_tree left the tree it was given behind")
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
