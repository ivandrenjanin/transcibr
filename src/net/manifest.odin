#+vet explicit-allocators
package net

import "core:encoding/json"
import "core:mem"
import "core:os"
import "core:strings"

// A manifest names only what it means to change: any field a caller's
// spec already carries stays put unless the file on disk names it too, so a
// manifest correcting a moved URL does not also have to repeat a hash that
// never changed (ADR-0014's "an upstream URL change is repairable without a
// new build").
@(require_results)
manifest_override :: proc(
	defaults: Download_Spec,
	manifest_path: string,
	allocator: mem.Allocator,
) -> (
	spec: Download_Spec,
	applied: bool,
) {
	assert(len(manifest_path) > 0, "there is no manifest path here to read an override from")
	assert(
		allocator.procedure != nil,
		"an overridden spec outlives this procedure and needs an allocator",
	)
	spec = clone_spec(defaults, allocator)
	defer if !applied {
		assert(spec.url == defaults.url, "reported no override applied but changed the URL anyway")
	}

	bytes, unreadable := os.read_entire_file(manifest_path, context.temp_allocator)
	if unreadable != nil {
		return spec, false
	}
	if len(bytes) == 0 {
		return spec, false
	}

	fields, malformed := decode_manifest(string(bytes))
	if malformed {
		return spec, false
	}

	apply_field(fields, "url", &spec.url, allocator)
	apply_field(fields, "display_name", &spec.display_name, allocator)
	apply_int_field(fields, "expected_bytes", &spec.expected_bytes)
	apply_field(fields, "expected_sha256", &spec.expected_sha256, allocator)
	return spec, true
}

@(require_results)
clone_spec :: proc(spec: Download_Spec, allocator: mem.Allocator) -> Download_Spec {
	assert(
		allocator.procedure != nil,
		"a cloned spec outlives this procedure and needs an allocator",
	)

	return Download_Spec {
		url = strings.clone(spec.url, allocator),
		display_name = strings.clone(spec.display_name, allocator),
		expected_bytes = spec.expected_bytes,
		expected_sha256 = strings.clone(spec.expected_sha256, allocator),
		magic = spec.magic,
	}
}

destroy_spec :: proc(spec: Download_Spec, allocator: mem.Allocator) {
	delete(spec.url, allocator)
	delete(spec.display_name, allocator)
	delete(spec.expected_sha256, allocator)
}

// A manifest is flat -- one object, string and number fields, nothing
// nested -- so this bound is deliberately far tighter than the Engine
// output reader's; anything past a handful of levels is not a manifest.
@(private)
MANIFEST_MAX_JSON_DEPTH :: 8

@(private)
@(require_results)
decode_manifest :: proc(text: string) -> (fields: json.Object, malformed: bool) {
	assert(len(text) > 0, "there is no manifest text here to decode")

	if !manifest_nesting_is_bounded(text) {
		return nil, true
	}
	root, decode_err := json.parse(transmute([]u8)text, .JSON, false, context.temp_allocator)
	if decode_err != nil {
		return nil, true
	}
	object, is_object := root.(json.Object)
	if !is_object {
		return nil, true
	}
	return object, false
}

// Counted off the decoder's own tokenizer, exactly as
// `transcript.json_nesting_is_bounded` does and for the identical reason:
// see CLAUDE.md, Odin notes: core:encoding/json.
@(private)
@(require_results)
manifest_nesting_is_bounded :: proc(text: string) -> bool {
	assert(len(text) > 0, "there is no manifest text here to bound the nesting of")

	tokenizer := json.make_tokenizer(text, .JSON, false)
	depth := 0
	for {
		token, _ := json.get_token(&tokenizer)
		if token.kind == .EOF {
			break
		}
		#partial switch token.kind {
		case .Open_Brace, .Open_Bracket:
			depth += 1
			if depth > MANIFEST_MAX_JSON_DEPTH {
				return false
			}
		case .Close_Brace, .Close_Bracket:
			if depth > 0 {
				depth -= 1
			}
		}
	}
	assert(depth <= MANIFEST_MAX_JSON_DEPTH, "returned true for nesting past the limit")
	return true
}

// A string field present and typed correctly replaces the default; anything
// else -- missing, or present under a different type -- leaves the default
// alone rather than blanking it out.
@(private)
apply_field :: proc(fields: json.Object, key: string, into: ^string, allocator: mem.Allocator) {
	assert(len(key) > 0, "a manifest field is read by name; the empty key is a caller defect")
	assert(into != nil, "there is nowhere here to write an overridden field")

	value, present := fields[key]
	if !present {
		return
	}
	text, is_text := value.(json.String)
	if !is_text || len(text) == 0 {
		return
	}
	delete(into^, allocator)
	into^ = strings.clone(text, allocator)
}

// core:encoding/json reads every number as a Float unless parse_integers is
// requested, and that flag wraps silently on overflow -- see CLAUDE.md,
// Odin notes: core:encoding/json. A manifest's byte count is read as a
// Float and range-checked well below where an f64 stops representing every
// integer exactly.
@(private)
MANIFEST_MAX_BYTES :: i64(1) << 53

@(private)
apply_int_field :: proc(fields: json.Object, key: string, into: ^i64) {
	assert(len(key) > 0, "a manifest field is read by name; the empty key is a caller defect")
	assert(into != nil, "there is nowhere here to write an overridden field")

	value, present := fields[key]
	if !present {
		return
	}
	number, is_number := value.(json.Float)
	if !is_number {
		return
	}
	if number <= 0 || number > f64(MANIFEST_MAX_BYTES) {
		return
	}
	into^ = i64(number)
}
