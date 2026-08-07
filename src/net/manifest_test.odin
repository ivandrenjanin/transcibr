#+vet explicit-allocators
package net

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
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

@(private = "file")
MOVED_URL :: "https://example.invalid/moved.zip"

// One root object holding a run of `inner_depth` nested arrays, so the
// nesting the guard counts is `inner_depth + 1`. The URL rides along at the
// top level: a manifest the guard let through would apply it, which is what
// tells an accepted document from a refused one at the seam.
@(private = "file")
@(require_results)
nested_manifest :: proc(inner_depth: int, allocator: mem.Allocator) -> string {
	assert(inner_depth > 0, "a manifest nested no levels deep bounds nothing")
	assert(allocator.procedure != nil, "the manifest text outlives this procedure")

	out := strings.builder_make(allocator)
	strings.write_string(&out, `{"url":"` + MOVED_URL + `","extra":`)
	for _ in 0 ..< inner_depth {
		strings.write_byte(&out, '[')
	}
	for _ in 0 ..< inner_depth {
		strings.write_byte(&out, ']')
	}
	strings.write_string(&out, "}")

	text := strings.to_string(out)
	assert(len(text) > inner_depth * 2, "the nesting never reached the manifest")
	return text
}

// Either side of the bound, because a guard tested only past it survives
// being moved: at `MANIFEST_MAX_JSON_DEPTH` levels the manifest is still a
// manifest and its URL must be applied, and one level further it must not be.
@(test)
a_manifest_nested_past_the_depth_bound_is_rejected_rather_than_trusted :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "net", "manifest-too-deep", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	manifest_path := fmt.aprintf("%s\\engine.json", cache, allocator = context.allocator)
	defer delete(manifest_path, context.allocator)

	either_side := [2]int{MANIFEST_MAX_JSON_DEPTH - 1, MANIFEST_MAX_JSON_DEPTH}
	for inner_depth, i in either_side {
		manifest_json := nested_manifest(inner_depth, context.allocator)
		defer delete(manifest_json, context.allocator)
		testing.expect(
			t,
			os.write_entire_file(manifest_path, transmute([]u8)manifest_json) == nil,
			"could not write the fixture manifest",
		)

		spec, applied := manifest_override(DEFAULT_SPEC, manifest_path, context.allocator)
		defer destroy_spec(spec, context.allocator)

		want := i == 0
		testing.expectf(
			t,
			applied == want,
			"%d levels reported applied %v, want %v",
			inner_depth + 1,
			applied,
			want,
		)
		testing.expectf(
			t,
			spec.url == (MOVED_URL if want else DEFAULT_SPEC.url),
			"%d levels left the URL %v",
			inner_depth + 1,
			spec.url,
		)
	}
}

// The bound exists to stop core:encoding/json's unbounded recursion running
// the thread off its stack on a crafted manifest -- see CLAUDE.md, Odin
// notes: core:encoding/json, and `transcript.refuses_nesting_that_would_crash
// _the_decoder`, the same test one package over. The depth is counted off the
// decoder's own tokenizer, which is iterative and allocates nothing, so the
// refusal arrives through the return value at a nesting the decoder itself
// could not have survived being handed.
@(test)
a_manifest_nested_deep_enough_to_crash_the_decoder_is_refused_before_it_is_decoded :: proc(
	t: ^testing.T,
) {
	cache := testkit.made_scratch_cache(t, "net", "manifest-crash-deep", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	manifest_path := fmt.aprintf("%s\\engine.json", cache, allocator = context.allocator)
	defer delete(manifest_path, context.allocator)
	manifest_json := nested_manifest(1000, context.allocator)
	defer delete(manifest_json, context.allocator)
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
