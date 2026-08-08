#+vet explicit-allocators
package process

import "core:strings"
import "core:testing"

// Issue #275: `cache_key_prefix` relocated here from `src/audio/run.odin` so
// both `transcibr:audio` (the wav and probe intermediates, #256/#268) and
// `transcibr:engine` (the Engine's own `<name>.json`, this ticket) key
// against the identical seam rather than each holding its own copy. The
// #258/#268 two-recordings shape, applied to the shared seam directly.
@(test)
two_recordings_sharing_a_stem_key_to_different_cache_prefixes :: proc(t: ^testing.T) {
	first := cache_key_prefix(
		"C:\\cache",
		"interview",
		"C:\\talks\\june\\interview.mp4",
		context.allocator,
	)
	defer delete(first, context.allocator)
	second := cache_key_prefix(
		"C:\\cache",
		"interview",
		"C:\\talks\\july\\interview.mp4",
		context.allocator,
	)
	defer delete(second, context.allocator)

	testing.expectf(
		t,
		first != second,
		"two Recordings sharing a stem still keyed to the same cache prefix: %s",
		first,
	)
	testing.expect(
		t,
		strings.has_prefix(first, "C:\\cache\\interview."),
		"the cache key dropped the artifact stem a human reads the cache by",
	)
}

// The key has to be the same prefix twice in a row, or a retry of the same
// Recording would scatter its cache entries under a new name every time it
// is asked for.
@(test)
the_same_source_keys_to_the_same_cache_prefix_every_time :: proc(t: ^testing.T) {
	once := cache_key_prefix(
		"C:\\cache",
		"interview",
		"C:\\talks\\june\\interview.mp4",
		context.allocator,
	)
	defer delete(once, context.allocator)
	again := cache_key_prefix(
		"C:\\cache",
		"interview",
		"C:\\talks\\june\\interview.mp4",
		context.allocator,
	)
	defer delete(again, context.allocator)

	testing.expect_value(t, once, again)
}
