#+vet explicit-allocators
package artifact

import "core:fmt"
import "core:mem"
import "core:strings"
import "transcibr:process"
import "transcibr:transcript"

// The Sidecar: what it records, the bytes it is written as, and the comparison
// that answers whether a Transcript is stale (ADR-0003). Writing it into place
// is place.odin's, and happens last.

// A later transcibr that adds a field bumps this: every Sidecar an older build
// wrote then reads as unknown, and ADR-0003's disposition for unknown -- re-do
// it -- costs one Batch of GPU time rather than wrong provenance. Bumped to 2
// by issue #50's fix round: `engine` (the Engine's own path, the human half
// of its identity) is a field no version-1 Sidecar carries.
SIDECAR_VERSION_LINE :: "transcibr-sidecar 2"

// The Model's identity, as the sixty-four lower-case hexadecimal characters of
// its SHA-256. Distinct so the Model's path cannot be handed in where its
// digest belongs -- a Sidecar that would agree with itself for ever.
Digest :: distinct string

DIGEST_CHARS :: 64

// `path` and `digest` are OWNED and freed with destroy_model and the allocator
// that was handed in. identify_model and destroy_model stay in model.odin,
// the impure half that reads and hashes a Model file; the struct lives here
// because sidecar_of, the pure half, is what consumes it -- ADR-0032.
Model :: struct {
	// Resolved, so two Batches that spelled one Model two ways record one Model.
	path:   string,
	digest: Digest,
	bytes:  i64,
}

// A beam of nothing is the Engine's own default: `transcibr:process`
// deliberately passes no `-bs`, and recording the number an Engine release
// happens to default to would be provenance transcibr invented (ADR-0003).
ENGINE_DEFAULT_BEAM :: u32(0)

// The record of how one Transcript was produced, written last and only on
// success (ADR-0024). The strings are BORROWED in a Sidecar a caller built and
// OWNED in one read_sidecar handed back; destroy_sidecar is for the latter only.
Sidecar :: struct {
	// The Engine's own SHA-256, the same digest `changed` compares -- ADR-0027's
	// reopening clause, closed by issue #50.
	engine_version:     string,
	// The Engine binary's own path -- the human half of its identity, mirroring
	// `model` below exactly. Recorded and never compared: `changed` still
	// answers off `engine_version` alone, because identity by content-hash and
	// not by name or location is the whole point of ADR-0027's reopening
	// (ADR-0037) -- a relocated Engine binary with the same bytes is not a
	// changed Engine.
	engine:             string,
	// The path alone cannot notice a Model file replaced under the same name,
	// and the Engine's output reports every large Model as the bare string
	// `large`.
	model:              string,
	model_digest:       Digest,
	model_bytes:        i64,
	beam:               u32,
	// The NAME and not the enumeration member, because a Sidecar written by a
	// later build may name a profile this one has never heard of -- and "a
	// profile I do not know" must read as "not the current one".
	merge_profile:      string,
	// Empty is a fact and not a gap: a Recording made with no prompt and one
	// made with a prompt are different settings.
	prompt:             string,
	source_bytes:       i64,
	source_modified_ns: i64,
	// The container probe's answer, and never the scratch audio's own header.
	// `recordable` below accepts zero here because `planning.current_of`
	// writes exactly that zero (`known ? recorded.container_ms : 0`) into a
	// Sidecar it builds for a Recording with no Sidecar of its own, and
	// `recordable` has to keep accepting it or every unrecorded Recording's
	// plan falsely reports `.Dated_Before_1970`. Separately, and for a
	// different reason: every `container_ms > 0` assert elsewhere in this
	// repository (Issue #132, tracing to Issue #112) traces to
	// `process.read_probe`'s own guarantee, never to a value read out of a
	// Sidecar -- a Sidecar read back from a
	// file is external input (rule A8), not a fresh probe. A future resume
	// path that feeds a RECORDED `container_ms` into one of those asserts
	// must re-probe or re-check it first; this field alone does not carry
	// the guarantee.
	container_ms:       i64,
}

// Odin fills a field a struct literal leaves out with a zero and says nothing,
// and a call cannot leave a parameter out at all: a builder that dropped
// `model_digest` would write an empty one that compares equal to the next.
@(require_results)
sidecar_of :: proc(
	engine: string,
	engine_version: string,
	model: Model,
	beam: u32,
	merge_profile: string,
	prompt: string,
	source_bytes: i64,
	source_modified_ns: i64,
	container_ms: i64,
) -> (
	made: Sidecar,
) {
	defer assert_filled_in(made)

	return Sidecar {
		engine = engine,
		engine_version = engine_version,
		model = model.path,
		model_digest = model.digest,
		model_bytes = model.bytes,
		beam = beam,
		merge_profile = merge_profile,
		prompt = prompt,
		source_bytes = source_bytes,
		source_modified_ns = source_modified_ns,
		container_ms = container_ms,
	}
}

@(private)
assert_filled_in :: proc(made: Sidecar) {
	assert(len(made.engine_version) > 0, "an Engine nobody named is UNKNOWN, never empty")
	assert(
		len(made.engine) > 0,
		"a Sidecar that names no Engine records no human provenance for it",
	)
	assert(len(made.model) > 0, "a Sidecar that names no Model cannot notice one changing")
	assert(len(made.model_digest) == DIGEST_CHARS, "a Model identified by a partial digest")
	assert(len(made.merge_profile) > 0, "a Sidecar that names no Merge Profile records nothing")
}

// The order of the members is the decision: `changed` answers with the FIRST of
// them that differs, and every change but the last means the GPU time has to be
// spent again, where a Merge Profile alone re-renders in seconds (ADR-0003).
Change :: enum u8 {
	None = 0,
	Source,
	Engine_Version,
	Model,
	Beam,
	Prompt,
	Container_Duration,
	Merge_Profile,
}

// Why presence-only resume is not enough: ADR-0003. `engine` is NOT part of
// this comparison -- the Engine's identity is `engine_version`, its digest,
// alone (ADR-0027/ADR-0037); a relocated or differently spelled
// `--engine-exe` argument with the same bytes is not a changed Engine. The
// deferred assert below therefore compares every field but `engine`: a
// `.None` answer can legitimately disagree with `recorded == current` on
// that one field alone, which is the exact case this comparison exists to
// permit rather than to catch.
@(require_results)
changed :: proc(recorded, current: Sidecar) -> (answer: Change) {
	defer if answer == .None {
		ignoring_engine_path := current
		ignoring_engine_path.engine = recorded.engine
		assert(
			recorded == ignoring_engine_path,
			"two Sidecars that differ somewhere other than the Engine's path were called unchanged",
		)
	} else {
		assert(recorded != current, "two identical Sidecars were called changed")
	}

	if recorded.source_bytes != current.source_bytes {
		return .Source
	}
	if recorded.source_modified_ns != current.source_modified_ns {
		return .Source
	}
	if recorded.engine_version != current.engine_version {
		return .Engine_Version
	}
	if recorded.model != current.model {
		return .Model
	}
	if recorded.model_digest != current.model_digest {
		return .Model
	}
	if recorded.model_bytes != current.model_bytes {
		return .Model
	}
	if recorded.beam != current.beam {
		return .Beam
	}
	if recorded.prompt != current.prompt {
		return .Prompt
	}
	if recorded.container_ms != current.container_ms {
		return .Container_Duration
	}
	if recorded.merge_profile != current.merge_profile {
		return .Merge_Profile
	}
	return .None
}

// This format writes a run of decimal digits with NO SIGN, and `os.stat` really
// does date real files before 1970. Why the whole record rather than the one
// field that has an outside: ADR-0024. Planning asks it of the Sidecar a
// Recording WOULD get, which is the only place it is cheap to answer (ADR-0026).
@(require_results)
recordable :: proc(s: Sidecar) -> bool {
	if s.model_bytes < 0 {
		return false
	}
	if s.source_bytes < 0 {
		return false
	}
	if s.source_modified_ns < 0 {
		return false
	}
	if s.container_ms < 0 {
		return false
	}
	return true
}

@(private)
Key :: enum u8 {
	Engine,
	Engine_Sha256,
	Model,
	Model_Sha256,
	Model_Bytes,
	Beam,
	Merge_Profile,
	Prompt,
	Source_Bytes,
	Source_Modified_Ns,
	Container_Ms,
}

// Why the two assertions on this table are all that is left: ADR-0024.
@(private, rodata)
KEY := [Key]string {
	.Engine             = "engine",
	.Engine_Sha256      = "engine_sha256",
	.Model              = "model",
	.Model_Sha256       = "model_sha256",
	.Model_Bytes        = "model_bytes",
	.Beam               = "beam",
	.Merge_Profile      = "merge_profile",
	.Prompt             = "prompt",
	.Source_Bytes       = "source_bytes",
	.Source_Modified_Ns = "source_modified_ns",
	.Container_Ms       = "container_ms",
}

// The field order is FIXED and is the order of `Key`, because a reader that had
// to cope with any order would also cope with a record missing half its fields.
// The caller owns the answer and frees it with `delete` and the same allocator.
@(require_results)
sidecar_text :: proc(s: Sidecar, allocator: mem.Allocator) -> (written: string) {
	assert(allocator.procedure != nil, "the record outlives this procedure and needs an allocator")
	defer {
		assert(
			strings.has_prefix(written, SIDECAR_VERSION_LINE),
			"a sidecar written without the line that says what it is",
		)
		assert(strings.has_suffix(written, "\n"), "a sidecar whose last field is not a whole line")
	}

	out := strings.builder_make(0, 512, allocator)
	defer strings.builder_destroy(&out)

	strings.write_string(&out, SIDECAR_VERSION_LINE)
	strings.write_byte(&out, '\n')
	write_text(&out, .Engine, s.engine)
	write_text(&out, .Engine_Sha256, s.engine_version)
	write_text(&out, .Model, s.model)
	write_text(&out, .Model_Sha256, string(s.model_digest))
	write_number(&out, .Model_Bytes, s.model_bytes)
	write_number(&out, .Beam, i64(s.beam))
	write_text(&out, .Merge_Profile, s.merge_profile)
	write_text(&out, .Prompt, s.prompt)
	write_number(&out, .Source_Bytes, s.source_bytes)
	write_number(&out, .Source_Modified_Ns, s.source_modified_ns)
	write_number(&out, .Container_Ms, s.container_ms)

	return strings.clone(strings.to_string(out), allocator)
}

@(private)
write_text :: proc(out: ^strings.Builder, key: Key, value: string) {
	assert(out != nil, "there is no record here to write a field into")
	assert(len(KEY[key]) > 0, "a key was given an empty name in KEY")

	strings.write_string(out, KEY[key])
	strings.write_string(out, ": ")
	transcript.write_quoted_scalar(out, value)
	strings.write_byte(out, '\n')
}

// Unquoted, so a reader can tell a number from a string by the byte after the
// space rather than by knowing what each field is.
@(private)
write_number :: proc(out: ^strings.Builder, key: Key, value: i64) {
	assert(out != nil, "there is no record here to write a field into")
	assert(len(KEY[key]) > 0, "a key was given an empty name in KEY")
	assert(value >= 0, "a sidecar was handed a count or a moment below zero")

	fmt.sbprintf(out, "%s: %d\n", KEY[key], value)
}

// Refused WHOLE and never half read: a record missing a field would compare
// equal to any other record missing the same field. Every string in the answer
// is CLONED -- free it with destroy_sidecar; a refusal frees its own.
@(require_results)
read_sidecar :: proc(text: string, allocator: mem.Allocator) -> (s: Sidecar, ok: bool) {
	assert(allocator.procedure != nil, "the record outlives this procedure and needs an allocator")

	rest := text
	if line, present := next_line(&rest); !present || line != SIDECAR_VERSION_LINE {
		return not_a_sidecar(s, allocator)
	}

	seen: bit_set[Key]
	for {
		line, present := next_line(&rest)
		if !present {
			break
		}
		key, value, readable := read_field(line)
		if !readable || key in seen {
			return not_a_sidecar(s, allocator)
		}
		if !store(&s, key, value, allocator) {
			return not_a_sidecar(s, allocator)
		}
		seen += {key}
	}
	if len(rest) > 0 || seen != EVERY_KEY {
		return not_a_sidecar(s, allocator)
	}
	return s, true
}

@(private)
@(require_results)
not_a_sidecar :: proc(s: Sidecar, allocator: mem.Allocator) -> (Sidecar, bool) {
	destroy_sidecar(s, allocator)
	return Sidecar{}, false
}

// Frees a Sidecar that read_sidecar handed back. Never called on one a caller
// built out of borrowed strings -- see Sidecar.
destroy_sidecar :: proc(s: Sidecar, allocator: mem.Allocator) {
	delete(s.engine_version, allocator)
	delete(s.engine, allocator)
	delete(s.model, allocator)
	delete(string(s.model_digest), allocator)
	delete(s.merge_profile, allocator)
	delete(s.prompt, allocator)
}

@(private)
EVERY_KEY :: ~bit_set[Key]{}

// A trailing fragment with no newline behind it is left where it is, which is
// how read_sidecar tells a truncated record from a complete one.
@(private)
@(require_results)
next_line :: proc(rest: ^string) -> (line: string, present: bool) {
	assert(rest != nil, "there is no record here to read a line out of")

	at := strings.index_byte(rest^, '\n')
	if at < 0 {
		return "", false
	}
	line = rest^[:at]
	rest^ = rest^[at + 1:]
	return line, true
}

// The separator is a colon AND the space after it, so a key carrying a colon
// cannot be read as a shorter key with a longer value.
@(private)
@(require_results)
read_field :: proc(line: string) -> (key: Key, value: string, ok: bool) {
	at := strings.index(line, ": ")
	if at <= 0 {
		return {}, "", false
	}
	named, known := key_named(line[:at])
	if !known {
		return {}, "", false
	}
	return named, line[at + 2:], true
}

@(private)
@(require_results)
key_named :: proc(name: string) -> (key: Key, known: bool) {
	if len(name) == 0 {
		return {}, false
	}
	for candidate in Key {
		if KEY[candidate] == name {
			return candidate, true
		}
	}
	return {}, false
}

// Every arm refuses rather than defaulting: a number this reader shrugged at
// would be stored as zero, and a zero compares equal to another zero -- so a
// corrupt Sidecar would report a Recording as still matching its settings.
@(private)
@(require_results)
store :: proc(s: ^Sidecar, key: Key, value: string, allocator: mem.Allocator) -> (ok: bool) {
	assert(s != nil, "there is no record here to read a field into")

	switch key {
	case .Engine:
		s.engine, ok = unquoted(value, allocator)
	case .Engine_Sha256:
		s.engine_version, ok = unquoted(value, allocator)
	case .Model:
		s.model, ok = unquoted(value, allocator)
	case .Model_Sha256:
		text: string
		text, ok = unquoted(value, allocator)
		s.model_digest = Digest(text)
	case .Merge_Profile:
		s.merge_profile, ok = unquoted(value, allocator)
	case .Prompt:
		s.prompt, ok = unquoted(value, allocator)
	case .Model_Bytes:
		s.model_bytes, ok = process.read_natural(value, MAX_SIDECAR_DIGITS)
	case .Source_Bytes:
		s.source_bytes, ok = process.read_natural(value, MAX_SIDECAR_DIGITS)
	case .Source_Modified_Ns:
		s.source_modified_ns, ok = process.read_natural(value, MAX_SIDECAR_DIGITS)
	case .Container_Ms:
		s.container_ms, ok = process.read_natural(value, MAX_SIDECAR_DIGITS)
	case .Beam:
		beam: i64
		beam, ok = process.read_natural(value, MAX_SIDECAR_DIGITS)
		ok = ok && beam <= i64(max(u32))
		s.beam = u32(beam) if ok else 0
	}
	return ok
}

// The caller owns the answer. Strict in both directions: a raw newline or a raw
// quotation mark inside the value is a record this package did not write, and
// reading one leniently would accept a file whose fields have run into each other.
@(private)
@(require_results)
unquoted :: proc(value: string, allocator: mem.Allocator) -> (text: string, ok: bool) {
	assert(allocator.procedure != nil, "the value outlives this procedure and needs an allocator")
	if len(value) < 2 || value[0] != '"' || value[len(value) - 1] != '"' {
		return "", false
	}
	body := value[1:len(value) - 1]

	out := strings.builder_make(0, len(body), allocator)
	defer strings.builder_destroy(&out)
	for at := 0; at < len(body); at += 1 {
		if body[at] == '"' || body[at] < 0x20 || body[at] == 0x7F {
			return "", false
		}
		if body[at] != '\\' {
			strings.write_byte(&out, body[at])
			continue
		}
		taken := escape(body[at:], &out)
		if taken == 0 {
			return "", false
		}
		at += taken - 1
	}
	return strings.clone(strings.to_string(out), allocator), true
}

@(private)
@(require_results)
escape :: proc(from: string, out: ^strings.Builder) -> (taken: int) {
	assert(out != nil, "there is nowhere here to write an unescaped byte")
	assert(len(from) > 0, "an escape was read off the end of the value")
	assert(from[0] == '\\', "an escape was read where there is none")

	if len(from) < 2 {
		return 0
	}
	switch from[1] {
	case '\\', '"':
		strings.write_byte(out, from[1])
		return 2
	case 'n':
		strings.write_byte(out, '\n')
		return 2
	case 'r':
		strings.write_byte(out, '\r')
		return 2
	case 't':
		strings.write_byte(out, '\t')
		return 2
	case 'x':
		if len(from) < 4 {
			return 0
		}
		high, high_ok := hex(from[2])
		low, low_ok := hex(from[3])
		if !high_ok || !low_ok {
			return 0
		}
		strings.write_byte(out, high << 4 | low)
		return 4
	}
	return 0
}

// Lower case only, because that is what this package writes and a reader that
// accepted both would accept a record it did not produce.
@(private)
@(require_results)
hex :: proc(digit: u8) -> (value: u8, ok: bool) {
	switch digit {
	case '0' ..= '9':
		return digit - '0', true
	case 'a' ..= 'f':
		return digit - 'a' + 10, true
	}
	return 0, false
}

@(private)
MAX_SIDECAR_DIGITS :: 19

#assert(MAX_SIDECAR_DIGITS == len("9223372036854775807"))
