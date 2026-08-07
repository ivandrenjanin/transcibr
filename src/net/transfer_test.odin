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

@(private = "file")
Progress_Collector :: struct {
	ticks: [dynamic]Download_Progress,
}

@(private = "file")
record_progress :: proc(progress: Download_Progress, user: rawptr) {
	collector := cast(^Progress_Collector)user
	append(&collector.ticks, progress)
}

// write_body's buffer is VERIFY_READ_BYTES_NETWORK (64 KiB), and
// fixture_read fills a whole buffer per call -- a fixture at or under that
// size reaches exactly one tick regardless of whether the callback lives
// inside or outside the read loop, which is why round 3's coverage of this
// guard was reviewed and found not to pin "after every chunk" (round 5
// review finding 1). Three chunks (two full 64 KiB buffers plus a
// remainder) forces three ticks, and the count plus the monotonically
// increasing running total is what a once-at-the-end report cannot satisfy.
@(private = "file")
PROGRESS_FIXTURE_BYTES :: 2 * VERIFY_READ_BYTES_NETWORK + 100

@(test)
write_body_reports_progress_after_every_chunk_received :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "transfer-progress", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	part := fmt.aprintf("%s\\progress.part", cache, allocator = context.allocator)
	defer delete(part, context.allocator)

	data := make([]u8, PROGRESS_FIXTURE_BYTES, context.allocator)
	defer delete(data, context.allocator)
	body := Fixture_Body {
		data = data,
	}
	source := Body_Source {
		read = fixture_read,
		user = &body,
	}
	spec := Download_Spec {
		expected_bytes = i64(PROGRESS_FIXTURE_BYTES),
	}
	collector: Progress_Collector
	defer delete(collector.ticks)
	result := receive_and_write(200, 0, spec, part, source, record_progress, &collector)

	testing.expect_value(t, result.fault, Download_Fault.None)
	testing.expect_value(t, len(collector.ticks), 3)
	testing.expect_value(t, collector.ticks[0].bytes_received, i64(VERIFY_READ_BYTES_NETWORK))
	testing.expect_value(t, collector.ticks[1].bytes_received, i64(2 * VERIFY_READ_BYTES_NETWORK))
	testing.expect_value(t, collector.ticks[2].bytes_received, i64(PROGRESS_FIXTURE_BYTES))
	for i := 0; i < len(collector.ticks); i += 1 {
		testing.expectf(
			t,
			collector.ticks[i].total_bytes == i64(PROGRESS_FIXTURE_BYTES),
			"tick %d reported a total of %d, want the expected size %d",
			i,
			collector.ticks[i].total_bytes,
			i64(PROGRESS_FIXTURE_BYTES),
		)
		if i > 0 {
			testing.expect(
				t,
				collector.ticks[i].bytes_received > collector.ticks[i - 1].bytes_received,
				"progress must increase monotonically, one tick per chunk",
			)
		}
	}
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

// write_body counts a body against `spec.expected_bytes` from the offset the
// part file already holds, and the resume path is the only one where that
// offset is not zero. Every other resume fixture here lands exactly at the
// expected size and so can never overrun, which left the `existing` half of
// the bound unpinned (round 6 review mutation X): counted from zero instead,
// five more bytes appended onto a four-byte part file pass the guard and read
// back as a complete five-byte artifact that is nine bytes long.
@(test)
a_resumed_body_overrunning_what_is_left_is_refused_before_any_byte_is_appended :: proc(
	t: ^testing.T,
) {
	cache := testkit.made_scratch_cache(t, "net", "transfer-resume-overrun", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	part := fmt.aprintf("%s\\overrun.part", cache, allocator = context.allocator)
	defer delete(part, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(part, []u8{1, 2, 3, 4}) == nil,
		"could not write the fixture",
	)

	body := Fixture_Body {
		data = []u8{5, 6, 7, 8, 9},
	}
	source := Body_Source {
		read = fixture_read,
		user = &body,
	}
	spec := Download_Spec {
		expected_bytes = 5,
	}
	result := receive_and_write(206, 4, spec, part, source, nil, nil)

	testing.expect_value(t, result.fault, Download_Fault.Write_Failed)
	written, unreadable := os.read_entire_file(part, context.allocator)
	defer delete(written, context.allocator)
	testing.expect(t, unreadable == nil, "could not read the part file back")
	testing.expect_value(t, len(written), 4)
	testing.expect_value(t, written[3], u8(4))
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
a_download_over_plain_http_is_refused_before_any_request_is_sent :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "transfer-insecure-url", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	destination := fmt.aprintf("%s\\insecure.bin", cache, allocator = context.allocator)
	defer delete(destination, context.allocator)

	spec := Download_Spec {
		url             = "http://host.example/file.bin",
		expected_bytes  = 4,
		expected_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
	}
	result := download(spec, destination, context.allocator)

	testing.expect_value(t, result.fault, Download_Fault.Not_Secure)
	testing.expect_value(t, result.status, 0)
	testing.expect(
		t,
		!os.exists(destination),
		"a refused download must never reach the destination",
	)
}

@(test)
a_stale_part_file_at_the_expected_size_is_discarded_before_any_request_is_sent :: proc(
	t: ^testing.T,
) {
	cache := testkit.made_scratch_cache(t, "net", "transfer-stale-part-entry", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	destination := fmt.aprintf("%s\\stale.bin", cache, allocator = context.allocator)
	defer delete(destination, context.allocator)
	part := fmt.aprintf("%s.part", destination, allocator = context.allocator)
	defer delete(part, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(part, []u8{1, 2, 3, 4}) == nil,
		"could not write the fixture",
	)

	spec := Download_Spec {
		url             = "https://",
		expected_bytes  = 4,
		expected_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
	}
	result := download(spec, destination, context.allocator)

	testing.expect_value(t, result.fault, Download_Fault.Unreachable)
	testing.expect_value(t, result.status, 0)
	testing.expect(
		t,
		!os.exists(part),
		"a stale part file at the expected size must be discarded before the request is even sent",
	)
}

@(test)
a_body_larger_than_expected_is_refused_rather_than_written_in_full :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "transfer-body-too-long", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	part := fmt.aprintf("%s\\flood.part", cache, allocator = context.allocator)
	defer delete(part, context.allocator)

	body := Fixture_Body {
		data = []u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20},
	}
	source := Body_Source {
		read = fixture_read,
		user = &body,
	}
	spec := Download_Spec {
		expected_bytes = 10,
	}
	result := receive_and_write(200, 0, spec, part, source, nil, nil)

	testing.expect_value(t, result.fault, Download_Fault.Write_Failed)
	written, unreadable := os.read_entire_file(part, context.allocator)
	defer delete(written, context.allocator)
	testing.expect(t, unreadable == nil, "could not read the part file back")
	testing.expect(
		t,
		i64(len(written)) <= spec.expected_bytes,
		"a body longer than expected must not be written past the expected size",
	)
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
