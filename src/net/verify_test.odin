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

// hash_and_check_magic's read loop is only exercised by files at or under
// VERIFY_READ_BYTES (64 KiB) elsewhere in this suite, so the loop that
// makes the hash streaming -- rather than the magic check that only needs
// to run once -- has no committed coverage of a second iteration (round 5
// review finding 2). This fixture is two chunks: chunk one is VERIFY_READ_BYTES
// bytes starting with the one-byte magic ('M') and otherwise 'A'; chunk two
// is LARGE_FIXTURE_TAIL_BYTES bytes starting with 'Z' -- a byte that does
// not match the magic. A build that only checks the magic once (HEAD)
// verifies; a build that re-checks it at the head of every chunk reports
// Magic_Mismatch on chunk two.
LARGE_FIXTURE_TAIL_BYTES :: 5000
LARGE_FIXTURE_TOTAL_BYTES :: VERIFY_READ_BYTES + LARGE_FIXTURE_TAIL_BYTES

// Published independently of this repository: SHA-256 of the exact byte
// pattern `large_fixture` below, computed with Windows' own
// `Get-FileHash -Algorithm SHA256` over a file written with that pattern,
// not derived from the code under test.
LARGE_FIXTURE_SHA256 :: "9bc85272af02121343fc7bc2a995d9d47a3ec8d7b4f2a22d5631aed0d2f4e499"

@(private)
@(require_results)
large_fixture :: proc(allocator: mem.Allocator) -> []u8 {
	data := make([]u8, LARGE_FIXTURE_TOTAL_BYTES, allocator)
	for i := 0; i < len(data); i += 1 {
		data[i] = 'A'
	}
	data[0] = 'M'
	data[VERIFY_READ_BYTES] = 'Z'
	return data
}

@(test)
a_file_spanning_more_than_one_read_chunk_verifies_and_the_magic_is_checked_only_once :: proc(
	t: ^testing.T,
) {
	cache := testkit.made_scratch_cache(t, "net", "verify-multi-chunk", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	data := large_fixture(context.allocator)
	defer delete(data, context.allocator)
	path := written_fixture(t, cache, "large.bin", data, context.allocator)
	defer delete(path, context.allocator)

	spec := Download_Spec {
		url             = "https://example.invalid/large.bin",
		display_name    = "large",
		expected_bytes  = i64(LARGE_FIXTURE_TOTAL_BYTES),
		expected_sha256 = LARGE_FIXTURE_SHA256,
		magic           = []u8{'M'},
	}
	result := verify_download(path, spec, context.allocator)
	defer delete(result.actual_sha256, context.allocator)

	testing.expect_value(t, result.fault, Verify_Fault.None)
	testing.expect_value(t, result.actual_bytes, i64(LARGE_FIXTURE_TOTAL_BYTES))
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
