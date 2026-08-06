#+vet explicit-allocators
package net

import "core:fmt"
import "core:os"
import "core:testing"
import "transcibr:testkit"

DEFAULT_SPEC := Download_Spec {
	url             = "https://example.invalid/default.zip",
	display_name    = "engine",
	expected_bytes  = 1000,
	expected_sha256 = "0000000000000000000000000000000000000000000000000000000000000000",
}

@(test)
a_manifest_that_does_not_exist_leaves_the_compiled_in_defaults_alone :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "net", "no-manifest", context.allocator)
	defer delete(cache, context.allocator)

	manifest_path := fmt.aprintf("%s.json", cache, allocator = context.allocator)
	defer delete(manifest_path, context.allocator)

	spec, applied := manifest_override(DEFAULT_SPEC, manifest_path, context.allocator)
	defer destroy_spec(spec, context.allocator)

	testing.expect(t, !applied, "a manifest that was never written must not report itself applied")
	testing.expect_value(t, spec.url, DEFAULT_SPEC.url)
	testing.expect_value(t, spec.expected_bytes, DEFAULT_SPEC.expected_bytes)
	testing.expect_value(t, spec.expected_sha256, DEFAULT_SPEC.expected_sha256)
}

@(test)
a_manifest_on_disk_overrides_the_url_size_and_hash :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "manifest-override", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	manifest_path := fmt.aprintf("%s\\engine.json", cache, allocator = context.allocator)
	defer delete(manifest_path, context.allocator)
	manifest_json := `{"url":"https://example.invalid/moved.zip","expected_bytes":2000,"expected_sha256":"1111111111111111111111111111111111111111111111111111111111111111"}`
	testing.expect(
		t,
		os.write_entire_file(manifest_path, transmute([]u8)manifest_json) == nil,
		"could not write the fixture manifest",
	)

	spec, applied := manifest_override(DEFAULT_SPEC, manifest_path, context.allocator)
	defer destroy_spec(spec, context.allocator)

	testing.expect(t, applied, "a manifest that parsed clean must report itself applied")
	testing.expect_value(t, spec.url, "https://example.invalid/moved.zip")
	testing.expect_value(t, spec.expected_bytes, i64(2000))
	testing.expect_value(
		t,
		spec.expected_sha256,
		"1111111111111111111111111111111111111111111111111111111111111111",
	)
	testing.expect_value(t, spec.display_name, DEFAULT_SPEC.display_name)
}

@(test)
a_malformed_manifest_is_ignored_rather_than_trusted :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "manifest-malformed", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	manifest_path := fmt.aprintf("%s\\bad.json", cache, allocator = context.allocator)
	defer delete(manifest_path, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(manifest_path, transmute([]u8)string("not json at all")) == nil,
		"could not write the fixture manifest",
	)

	spec, applied := manifest_override(DEFAULT_SPEC, manifest_path, context.allocator)
	defer destroy_spec(spec, context.allocator)

	testing.expect(t, !applied, "a malformed manifest must not report itself applied")
	testing.expect_value(t, spec.url, DEFAULT_SPEC.url)
}

@(test)
a_negative_expected_bytes_is_rejected_rather_than_stored :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "manifest-negative-bytes", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	manifest_path := fmt.aprintf("%s\\engine.json", cache, allocator = context.allocator)
	defer delete(manifest_path, context.allocator)
	manifest_json := `{"expected_bytes":-1}`
	testing.expect(
		t,
		os.write_entire_file(manifest_path, transmute([]u8)manifest_json) == nil,
		"could not write the fixture manifest",
	)

	spec, applied := manifest_override(DEFAULT_SPEC, manifest_path, context.allocator)
	defer destroy_spec(spec, context.allocator)

	testing.expect(t, applied, "a manifest that parsed clean must report itself applied")
	testing.expect_value(t, spec.expected_bytes, DEFAULT_SPEC.expected_bytes)
}

@(test)
an_absurdly_large_expected_bytes_is_rejected_rather_than_stored :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "manifest-huge-bytes", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	manifest_path := fmt.aprintf("%s\\engine.json", cache, allocator = context.allocator)
	defer delete(manifest_path, context.allocator)
	manifest_json := `{"expected_bytes":1e300}`
	testing.expect(
		t,
		os.write_entire_file(manifest_path, transmute([]u8)manifest_json) == nil,
		"could not write the fixture manifest",
	)

	spec, applied := manifest_override(DEFAULT_SPEC, manifest_path, context.allocator)
	defer destroy_spec(spec, context.allocator)

	testing.expect(t, applied, "a manifest that parsed clean must report itself applied")
	testing.expect_value(t, spec.expected_bytes, DEFAULT_SPEC.expected_bytes)
}

@(test)
an_empty_url_field_is_rejected_rather_than_stored :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "manifest-empty-url", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	manifest_path := fmt.aprintf("%s\\engine.json", cache, allocator = context.allocator)
	defer delete(manifest_path, context.allocator)
	manifest_json := `{"url":""}`
	testing.expect(
		t,
		os.write_entire_file(manifest_path, transmute([]u8)manifest_json) == nil,
		"could not write the fixture manifest",
	)

	spec, applied := manifest_override(DEFAULT_SPEC, manifest_path, context.allocator)
	defer destroy_spec(spec, context.allocator)

	testing.expect(t, applied, "a manifest that parsed clean must report itself applied")
	testing.expect_value(t, spec.url, DEFAULT_SPEC.url)
}

@(test)
a_manifest_nested_past_the_depth_bound_is_rejected_rather_than_trusted :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "manifest-too-deep", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	manifest_path := fmt.aprintf("%s\\engine.json", cache, allocator = context.allocator)
	defer delete(manifest_path, context.allocator)
	manifest_json := `{"url":"https://example.invalid/moved.zip","extra":[[[[[[[[[[1]]]]]]]]]]}`
	testing.expect(
		t,
		os.write_entire_file(manifest_path, transmute([]u8)manifest_json) == nil,
		"could not write the fixture manifest",
	)

	spec, applied := manifest_override(DEFAULT_SPEC, manifest_path, context.allocator)
	defer destroy_spec(spec, context.allocator)

	testing.expect(t, !applied, "a manifest nested past the bound must not report itself applied")
	testing.expect_value(t, spec.url, DEFAULT_SPEC.url)
}
