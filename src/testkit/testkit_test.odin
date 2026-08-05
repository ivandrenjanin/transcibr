#+vet explicit-allocators
package testkit

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

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
