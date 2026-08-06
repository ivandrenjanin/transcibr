#+vet explicit-allocators
package net

import "core:fmt"
import "core:os"
import "core:testing"
import "transcibr:testkit"

// A canned body, read a whole-buffer chunk at a time, standing in for a
// live network request handle -- what makes `receive_and_write` and
// `write_body` provable against a fixture (round 1 review finding 3).
@(private = "file")
Fixture_Body :: struct {
	data:   []u8,
	cursor: int,
}

@(private = "file")
@(require_results)
fixture_read :: proc(buffer: []u8, user: rawptr) -> (read: u32, ok: bool) {
	body := cast(^Fixture_Body)user
	remaining := body.data[body.cursor:]
	if len(remaining) == 0 {
		return 0, true
	}
	n := len(buffer)
	if len(remaining) < n {
		n = len(remaining)
	}
	copy(buffer[:n], remaining[:n])
	body.cursor += n
	return u32(n), true
}

@(test)
a_resumed_206_response_appends_onto_the_existing_part_file :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "transfer-append", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	part := fmt.aprintf("%s\\resumed.part", cache, allocator = context.allocator)
	defer delete(part, context.allocator)
	testing.expect(t, os.write_entire_file(part, []u8{1, 2}) == nil, "could not write the fixture")

	body := Fixture_Body {
		data = []u8{3, 4, 5},
	}
	source := Body_Source {
		read = fixture_read,
		user = &body,
	}
	spec := Download_Spec {
		expected_bytes = 5,
	}
	result := receive_and_write(206, 2, spec, part, source, nil, nil)

	testing.expect_value(t, result.fault, Download_Fault.None)
	written, unreadable := os.read_entire_file(part, context.allocator)
	defer delete(written, context.allocator)
	testing.expect(t, unreadable == nil, "could not read the part file back")
	testing.expect_value(t, len(written), 5)
	testing.expect_value(t, written[0], u8(1))
	testing.expect_value(t, written[4], u8(5))
}

@(test)
a_server_ignoring_range_and_answering_200_replaces_the_part_file_rather_than_appending :: proc(
	t: ^testing.T,
) {
	cache := testkit.made_scratch_cache(t, "net", "transfer-no-append-on-200", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	part := fmt.aprintf("%s\\restarted.part", cache, allocator = context.allocator)
	defer delete(part, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(part, []u8{9, 9, 9, 9, 9, 9, 9, 9, 9, 9}) == nil,
		"could not write the fixture",
	)

	body := Fixture_Body {
		data = []u8{1, 2, 3},
	}
	source := Body_Source {
		read = fixture_read,
		user = &body,
	}
	spec := Download_Spec {
		expected_bytes = 3,
	}
	result := receive_and_write(200, 10, spec, part, source, nil, nil)

	testing.expect_value(t, result.fault, Download_Fault.None)
	written, unreadable := os.read_entire_file(part, context.allocator)
	defer delete(written, context.allocator)
	testing.expect(t, unreadable == nil, "could not read the part file back")
	testing.expect_value(t, len(written), 3)
	testing.expect_value(t, written[0], u8(1))
	testing.expect_value(t, written[2], u8(3))
}

@(test)
a_416_status_is_reported_as_a_stale_part_rather_than_the_generic_unexpected_status :: proc(
	t: ^testing.T,
) {
	body := Fixture_Body{}
	source := Body_Source {
		read = fixture_read,
		user = &body,
	}
	spec := Download_Spec {
		expected_bytes = 4,
	}
	result := receive_and_write(416, 4, spec, "unused.part", source, nil, nil)

	testing.expect_value(t, result.fault, Download_Fault.Stale_Part)
}

@(test)
a_failed_verification_deletes_the_part_file_rather_than_leaving_it_on_disk :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "finalize-verify-fail", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	part := fmt.aprintf("%s\\bad.part", cache, allocator = context.allocator)
	defer delete(part, context.allocator)
	destination := fmt.aprintf("%s\\bad.zip", cache, allocator = context.allocator)
	defer delete(destination, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(part, []u8{'w', 'r', 'o', 'n', 'g'}) == nil,
		"could not write the fixture",
	)

	spec := Download_Spec {
		expected_bytes  = 5,
		expected_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
	}
	result := finalize_download(part, destination, spec, context.allocator)
	defer delete(result.verify.actual_sha256, context.allocator)

	testing.expect_value(t, result.fault, Download_Fault.Verify_Failed)
	testing.expect(t, !os.exists(part), "a part file that failed verification must be removed")
	testing.expect(
		t,
		!os.exists(destination),
		"a failed verification must never reach the destination",
	)
}

@(test)
a_passed_verification_moves_the_part_file_to_the_destination :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "finalize-verify-pass", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	part := fmt.aprintf("%s\\good.part", cache, allocator = context.allocator)
	defer delete(part, context.allocator)
	destination := fmt.aprintf("%s\\good.bin", cache, allocator = context.allocator)
	defer delete(destination, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(part, []u8{'a', 'b', 'c', 'd'}) == nil,
		"could not write the fixture",
	)

	spec := Download_Spec {
		expected_bytes  = 4,
		expected_sha256 = "88d4266fd4e6338d13b845fcf289579d209c897823b9217da3e161936f031589",
	}
	result := finalize_download(part, destination, spec, context.allocator)
	defer delete(result.verify.actual_sha256, context.allocator)

	testing.expect_value(t, result.fault, Download_Fault.None)
	testing.expect(t, !os.exists(part), "a placed download must not leave its part file behind")
	testing.expect(t, os.exists(destination), "a passed verification must reach the destination")
}
