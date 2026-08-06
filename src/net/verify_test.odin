#+vet explicit-allocators
package net

import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"
import "transcibr:testkit"

// The SHA-256 of the four bytes below ("abcd"), published far outside this
// repository so the expected value in these tests comes from an independent
// source rather than from the code under test.
ABCD_SHA256 :: "88d4266fd4e6338d13b845fcf289579d209c897823b9217da3e161936f031589"

@(test)
a_file_the_right_size_shape_and_hash_verifies :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "verify-ok", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	path := written_fixture(t, cache, "good.bin", []u8{'a', 'b', 'c', 'd'}, context.allocator)
	defer delete(path, context.allocator)

	spec := Download_Spec {
		url             = "https://example.invalid/good.bin",
		display_name    = "good",
		expected_bytes  = 4,
		expected_sha256 = ABCD_SHA256,
	}
	result := verify_download(path, spec, context.allocator)
	defer delete(result.actual_sha256, context.allocator)

	testing.expect_value(t, result.fault, Verify_Fault.None)
	testing.expect_value(t, result.actual_bytes, i64(4))
	testing.expect(
		t,
		os.exists(path),
		"a verified file must still be there for the caller to move",
	)
}

@(test)
a_file_the_wrong_size_fails_before_anything_else_and_is_reported :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "verify-size", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	path := written_fixture(t, cache, "short.bin", []u8{'a', 'b', 'c'}, context.allocator)
	defer delete(path, context.allocator)

	spec := Download_Spec {
		url             = "https://example.invalid/short.bin",
		display_name    = "short",
		expected_bytes  = 4,
		expected_sha256 = ABCD_SHA256,
	}
	result := verify_download(path, spec, context.allocator)
	defer delete(result.actual_sha256, context.allocator)

	testing.expect_value(t, result.fault, Verify_Fault.Size_Mismatch)
	testing.expect_value(t, result.expected_bytes, i64(4))
	testing.expect_value(t, result.actual_bytes, i64(3))
	testing.expect_value(t, len(result.actual_sha256), 0)
}

@(test)
a_file_the_right_size_but_wrong_magic_bytes_fails_before_the_hash_is_read :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "verify-magic", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	path := written_fixture(
		t,
		cache,
		"wrong-magic.bin",
		[]u8{'z', 'b', 'c', 'd'},
		context.allocator,
	)
	defer delete(path, context.allocator)

	spec := Download_Spec {
		url             = "https://example.invalid/wrong-magic.bin",
		display_name    = "wrong-magic",
		expected_bytes  = 4,
		expected_sha256 = ABCD_SHA256,
		magic           = []u8{'a'},
	}
	result := verify_download(path, spec, context.allocator)
	defer delete(result.actual_sha256, context.allocator)

	testing.expect_value(t, result.fault, Verify_Fault.Magic_Mismatch)
	testing.expect_value(t, len(result.actual_sha256), 0)
}

@(test)
a_file_the_right_size_and_magic_but_wrong_hash_fails_and_reports_both_hashes :: proc(
	t: ^testing.T,
) {
	cache := testkit.made_scratch_cache(t, "net", "verify-hash", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	path := written_fixture(t, cache, "swapped.bin", []u8{'a', 'b', 'c', 'e'}, context.allocator)
	defer delete(path, context.allocator)

	spec := Download_Spec {
		url             = "https://example.invalid/swapped.bin",
		display_name    = "swapped",
		expected_bytes  = 4,
		expected_sha256 = ABCD_SHA256,
		magic           = []u8{'a'},
	}
	result := verify_download(path, spec, context.allocator)
	defer delete(result.actual_sha256, context.allocator)

	testing.expect_value(t, result.fault, Verify_Fault.Hash_Mismatch)
	testing.expect_value(t, result.expected_sha256, ABCD_SHA256)
	testing.expect(
		t,
		result.actual_sha256 != ABCD_SHA256,
		"a mismatched file hashed to the expected value",
	)
	testing.expect_value(t, len(result.actual_sha256), len(ABCD_SHA256))
}

@(private)
@(require_results)
written_fixture :: proc(
	t: ^testing.T,
	cache: string,
	name: string,
	content: []u8,
	allocator: mem.Allocator,
) -> string {
	path := fmt.aprintf("%s\\%s", cache, name, allocator = allocator)
	testing.expect(t, os.write_entire_file(path, content) == nil, "could not write the fixture")
	return path
}
