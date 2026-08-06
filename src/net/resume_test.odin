#+vet explicit-allocators
package net

import "core:fmt"
import "core:os"
import "core:testing"
import "transcibr:testkit"

@(test)
a_fresh_request_that_answers_200_is_fresh :: proc(t: ^testing.T) {
	testing.expect_value(t, classify_response(false, 200), Resume_Outcome.Fresh)
}

@(test)
a_resume_request_that_answers_206_is_resumed :: proc(t: ^testing.T) {
	testing.expect_value(t, classify_response(true, 206), Resume_Outcome.Resumed)
}

@(test)
a_resume_request_the_server_answers_200_is_restarted_not_appended :: proc(t: ^testing.T) {
	testing.expect_value(t, classify_response(true, 200), Resume_Outcome.Restarted)
}

@(test)
a_401_is_unavailable_whether_or_not_resume_was_requested :: proc(t: ^testing.T) {
	testing.expect_value(t, classify_response(false, 401), Resume_Outcome.Unavailable)
	testing.expect_value(t, classify_response(true, 401), Resume_Outcome.Unavailable)
}

@(test)
a_403_is_also_unavailable :: proc(t: ^testing.T) {
	testing.expect_value(t, classify_response(false, 403), Resume_Outcome.Unavailable)
}

@(test)
a_fresh_request_answered_206_is_unexpected :: proc(t: ^testing.T) {
	testing.expect_value(t, classify_response(false, 206), Resume_Outcome.Failed)
}

@(test)
a_server_error_is_failed :: proc(t: ^testing.T) {
	testing.expect_value(t, classify_response(false, 500), Resume_Outcome.Failed)
	testing.expect_value(t, classify_response(true, 500), Resume_Outcome.Failed)
}

@(test)
a_part_path_sits_beside_the_destination :: proc(t: ^testing.T) {
	built := part_path(`C:\dest\engine.zip`, context.allocator)
	defer delete(built, context.allocator)
	testing.expect_value(t, built, `C:\dest\engine.zip.part`)
}

@(test)
a_missing_part_file_has_nothing_to_resume :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "net", "missing-part", context.allocator)
	defer delete(cache, context.allocator)

	missing := fmt.aprintf("%s\\nothing.part", cache, allocator = context.allocator)
	defer delete(missing, context.allocator)
	testing.expect_value(t, existing_partial_bytes(missing, context.allocator), i64(0))
}

@(test)
an_existing_part_file_reports_its_own_size :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "existing-part", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	part := fmt.aprintf("%s\\partial.part", cache, allocator = context.allocator)
	defer delete(part, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(part, []u8{1, 2, 3, 4, 5}) == nil,
		"could not write the fixture",
	)

	testing.expect_value(t, existing_partial_bytes(part, context.allocator), i64(5))
}

@(test)
a_range_header_names_the_bytes_already_held :: proc(t: ^testing.T) {
	built := range_header(1000, context.allocator)
	defer delete(built, context.allocator)
	testing.expect_value(t, built, "Range: bytes=1000-\r\n")
}

@(test)
a_416_is_range_not_satisfiable :: proc(t: ^testing.T) {
	testing.expect_value(t, classify_response(true, 416), Resume_Outcome.Range_Not_Satisfiable)
}

@(test)
a_part_file_at_the_expected_size_is_discarded_rather_than_left_stale :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "discard-exact", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	part := fmt.aprintf("%s\\stuck.part", cache, allocator = context.allocator)
	defer delete(part, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(part, []u8{1, 2, 3, 4}) == nil,
		"could not write the fixture",
	)

	spec := Download_Spec {
		expected_bytes = 4,
	}
	kept := discard_stale_part(part, existing_partial_bytes(part, context.allocator), spec)

	testing.expect_value(t, kept, i64(0))
	testing.expect(t, !os.exists(part), "a stale exact-size part file must be removed")
}

@(test)
an_oversized_part_file_is_also_discarded :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "discard-oversized", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	part := fmt.aprintf("%s\\stuck.part", cache, allocator = context.allocator)
	defer delete(part, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(part, []u8{1, 2, 3, 4, 5, 6}) == nil,
		"could not write the fixture",
	)

	spec := Download_Spec {
		expected_bytes = 4,
	}
	kept := discard_stale_part(part, existing_partial_bytes(part, context.allocator), spec)

	testing.expect_value(t, kept, i64(0))
	testing.expect(t, !os.exists(part), "an oversized part file must be removed")
}

@(test)
a_genuinely_partial_part_file_is_kept_for_resume :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "discard-keep", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	part := fmt.aprintf("%s\\partial.part", cache, allocator = context.allocator)
	defer delete(part, context.allocator)
	testing.expect(t, os.write_entire_file(part, []u8{1, 2}) == nil, "could not write the fixture")

	spec := Download_Spec {
		expected_bytes = 4,
	}
	kept := discard_stale_part(part, existing_partial_bytes(part, context.allocator), spec)

	testing.expect_value(t, kept, i64(2))
	testing.expect(t, os.exists(part), "a genuinely partial part file must not be removed")
}
