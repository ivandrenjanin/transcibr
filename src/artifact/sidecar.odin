package artifact

import "core:fmt"
import "core:mem"
import "core:strings"

// This file holds the Sidecar: what it records, the bytes it is written as, and
// what makes a Transcript's staleness knowable when settings change (ADR-0003).
// It is pure -- no clock, no environment, no filesystem -- which is what lets a
// case pin the format byte for byte and check the comparison one field at a
// time. The writing of it into place is in place.odin, and happens LAST.
//
// A FORMAT OF ITS OWN, and deliberately not the front matter's YAML. The two
// share an escape rule because they face the same hazard -- a value carrying a
// newline closes the record half way -- and nothing else: front matter is read
// by a person and by ADR-0008's "is this transcibr's own Transcript" check,
// while this is read by transcibr and by nobody else, must round-trip exactly,
// and is refused whole the moment a byte of it is not what transcibr writes.
// `write_yaml_quoted` next door is a renderer for a document; this is a record.
//
// WHICH PUTS THIS FILE UNDER A1's AVERAGE, at 24 assertions across 19
// procedures, and the carve-out is recorded here rather than left for a reader
// to work out. Six carry none, and each is one of three shapes. `read_field` and
// `key_named` take a line off a disk, which is A8's own prohibition -- an
// assertion in either is a byte in a file crashing this program, and this whole
// half exists to answer that byte with "unknown, re-do it". `not_a_sidecar` and
// `destroy_sidecar` free what they were handed and claim nothing. `sidecar_of`
// and `recordable` are the two the count misreads: the first defers every one of
// its four to `assert_filled_in`, and the second IS the boundary check, so an
// assertion inside it would be the crash it exists to prevent. Raising the
// number would mean putting assertions where A8 forbids them, which is a worse
// file that counts better.

// What the first line of a Sidecar says, and the version of the format it
// stands for.
//
// A VERSION AND NOT A GUESS. A Sidecar is read back by a build that is not the
// one that wrote it, so the format is a contract with the future: a later
// transcibr that adds a field bumps this, every Sidecar written by an older
// build reads as unknown, and ADR-0003's disposition for unknown -- re-do it --
// is exactly right. What that costs is one Batch of GPU time on an upgrade,
// which is the honest price of not reading a record whose meaning has moved.
SIDECAR_VERSION_LINE :: "transcibr-sidecar 1"

// The Model's identity, as the sixty-four lower-case hexadecimal characters of
// its SHA-256.
//
// A DISTINCT TYPE AND NOT A NAME, which is rule T2 pointed at the one pair in
// this record that is two strings about the same file: the Model's PATH and the
// Model's CONTENT. They are both strings, they sit next to each other in the
// struct and in every constructor, and a path handed in where a digest belongs
// is a Sidecar that agrees with itself for ever -- the Model swapped underneath
// it goes unnoticed, which is the one thing the digest is here for. As a
// distinct type that is a compile error, and the cast at the storage edge is the
// one place a reader should slow down.
Digest :: distinct string

// How many characters one is, held by the COMPILER (A5). model.odin renders the
// digest and asserts this of what it produced; here it stands beside the type it
// is about, so the claim cannot drift from the definition.
DIGEST_CHARS :: 64

// What a beam size of nothing means: the Engine's own default, whatever that is.
//
// A SENTINEL RATHER THAN A NUMBER, because transcibr does not choose one.
// `transcibr:process` deliberately passes no `-bs` -- the spec says beam search
// stays at the Engine default -- so recording the number that Engine release
// happens to default to would be provenance transcibr invented, and ADR-0003 is
// explicit that absent provenance beats wrong provenance. The day a setting
// supplies one it is a positive number here, and a Sidecar written before that
// day correctly reads as having been made under different settings.
ENGINE_DEFAULT_BEAM :: u32(0)

// The record of how one Transcript was produced, written last and only on
// success.
//
// Every field is here because ADR-0003 names it, and every one of them is
// COMPARED by `changed` below -- a field recorded and never compared buys
// nothing, and the assertion in `changed` is what keeps the two in step.
//
// The strings are BORROWED in a Sidecar a caller built and OWNED in one
// read_sidecar handed back; destroy_sidecar is for the latter and only the
// latter. One rule, stated once, and the two are never mixed: nothing in this
// package reads a Sidecar and then edits it.
Sidecar :: struct {
	// The Engine, as transcibr's own record of it -- never read out of the
	// Engine's JSON, which does not carry it (ADR-0003).
	engine_version:     string,
	// The Model's path, and its content. The path alone cannot notice a Model
	// file replaced under the same name, and the Engine's output reports every
	// large Model as the bare string `large`.
	model:              string,
	model_digest:       Digest,
	model_bytes:        i64,
	beam:               u32,
	// The Merge Profile's NAME and not the enumeration member, because a Sidecar
	// written by a later build may name a profile this one has never heard of --
	// and "a profile I do not know" must read as "not the current one", which a
	// string comparison answers and a failed lookup would have to invent.
	merge_profile:      string,
	// The vocabulary prompt. Empty is a fact and not a gap: a Recording made
	// with no prompt and one made with a prompt are different settings.
	prompt:             string,
	// What the Recording itself was when it was transcribed. A source that has
	// changed size or been written to since is not the Recording this Transcript
	// came from, whatever else still matches.
	source_bytes:       i64,
	source_modified_ns: i64,
	// The container probe's answer, and never the scratch audio's own header
	// (spec).
	container_ms:       i64,
}

// One Recording's Sidecar, out of the things that settled it.
//
// A PROCEDURE AND NOT A STRUCT LITERAL AT THE CALL SITE, and the difference is
// the whole reason this exists: Odin fills a field a literal leaves out with a
// zero and says nothing, and a call cannot leave a parameter out at all. This
// record was built inline in `src/cli`, which ADR-0009 requires to collect no
// tests, and the suite next door had reimplemented it -- so the two agreed by
// authorship rather than by construction, and a builder that dropped
// `model_digest` would write `model_sha256: ""`, which round-trips, compares
// equal to the next empty one, and makes `changed` answer `.None` for two
// different Models. That is ADR-0003's exact failure arriving from the
// construction side, and nothing about it would look wrong on disk.
//
// The Model arrives WHOLE rather than as three strings and a number, so its path
// and its digest cannot be handed over the wrong way round -- which is the same
// pair rule T2 gave `Digest` its own type for.
//
// Every string is BORROWED, like every other Sidecar a caller builds. See
// Sidecar for the one lifetime rule.
sidecar_of :: proc(
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
	// The write side of what `complete` checks when it is handed one (A4). The
	// numbers are deliberately not here: a moment before 1970 is the filesystem's
	// answer and an operating error, which `recordable` refuses and this would
	// crash on.
	defer assert_filled_in(made)

	return Sidecar {
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

// What a Sidecar a caller built must already be true of.
//
// AN ASSERTION AND NOT A REFUSAL (A8), because every field here is this
// program's own answer and none of it is the outside's: `identify_model`
// produced the digest and asserts its length on the way out, `profile_name`
// produced the Merge Profile, and the shell defaults an Engine nobody named to
// UNKNOWN rather than to nothing. An empty one is transcibr having lost it.
//
// The digest is the one that matters and the one that would never crash: an
// empty one is a Sidecar that agrees with every other Sidecar whose Model was
// also lost. `hex_digest` asserts the length on the way OUT and there was
// nothing on the way in, so A4's pair was half built.
@(private)
assert_filled_in :: proc(made: Sidecar) {
	assert(len(made.engine_version) > 0, "an Engine nobody named is UNKNOWN, never empty")
	assert(len(made.model) > 0, "a Sidecar that names no Model cannot notice one changing")
	assert(len(made.model_digest) == DIGEST_CHARS, "a Model identified by a partial digest")
	assert(len(made.merge_profile) > 0, "a Sidecar that names no Merge Profile records nothing")
	// The prompt is deliberately absent: empty is a FACT there and not a gap.
}

// What about a Recording has changed since its Sidecar was written.
//
// THE ORDER OF THE MEMBERS IS THE DECISION and is not an accident of how the
// comparison happens to be written. Every change here but the last means the GPU
// time has to be spent again; a Merge Profile change alone re-renders from the
// retained Engine output in seconds (ADR-0003). `changed` answers with the FIRST
// of these that differs, so the answer names the most expensive change there is
// and a caller acting on `.Merge_Profile` can be sure nothing else moved.
Change :: enum u8 {
	None = 0,
	// The Recording is not the file that was transcribed.
	Source,
	Engine_Version,
	// Its path, its content or its size.
	Model,
	Beam,
	Prompt,
	Container_Duration,
	// The one change a re-render answers, which is why it is last.
	Merge_Profile,
}

// What has changed between the settings a Sidecar recorded and the ones in hand.
//
// Pure, and the whole of ADR-0003's "the artifact exists AND the recorded
// settings match the current ones". Presence-only resume skips every Recording
// in under a second on a Model change, leaving every Transcript on disk made
// with the old one and reporting success; this is what stops that.
changed :: proc(recorded, current: Sidecar) -> (answer: Change) {
	// THE PAIR THAT CATCHES A FIELD NOBODY COMPARED (A4, A3). The comparison
	// below is field by field, and a field added to `Sidecar` without a line here
	// would make two different records answer `.None` -- silently, and for ever,
	// which is the exact failure ADR-0003 exists to prevent. The whole-record
	// comparison is a second route to the same property, and it is a defect in
	// this package rather than anything external, so it is an assertion.
	defer if answer == .None {
		assert(recorded == current, "two Sidecars that differ somewhere were called unchanged")
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

// Whether every number in a Sidecar is one this format can carry.
//
// THE BOUNDARY (A8) FOR THE ONE FIELD THAT HAS AN OUTSIDE. Three of the four
// numbers below are this program's own arithmetic. `source_modified_ns` is not:
// it is `os.stat`'s answer about somebody else's file, and the filesystem really
// does report moments before 1970 -- a recorder whose clock never started and
// defaulted to "1970-01-01 00:00" local time, which is negative anywhere east of
// Greenwich; a file restored from an archive that kept its original time; a
// virtual filesystem answering FILETIME 0, which is 1601. This format writes a
// run of decimal digits with NO SIGN, so a negative number can be neither
// written nor read back, and a Recording carrying one is an operating error.
//
// Asked of the WHOLE RECORD rather than of that one field, so a number added to
// a Sidecar later is covered without anybody remembering to come here -- and it
// is what makes write_number's assertion an invariant rather than a hope (A4).
@(private)
recordable :: proc(s: Sidecar) -> bool {
	// `beam` is not here and cannot be: it is a u32, so the type says what these
	// four have to be checked for.
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

// Every field a Sidecar carries, as the name it is written under.
//
// An enumeration and a table rather than ten string literals scattered across a
// writer and a reader: the two halves must agree exactly or every Sidecar on
// disk becomes unreadable, and the only way to make that a compiler question is
// to give them one list to read from.
@(private)
Key :: enum u8 {
	Engine,
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

// An enumerated array rather than a switch, for the reason the FAULT tables
// elsewhere in this repository give -- and it is the reason `transcibr:audio`
// states rather than the one that used to be written here. Add a Key and leave
// this table alone and the COMPILER refuses the build outright: `Unhandled
// enumerated array case`. It does NOT quietly grow a row made of an empty
// string, which is what this comment claimed, and what three assertions below
// were placed to catch; measured against the pinned compiler, that row does not
// exist and the build does not happen.
//
// What is left for an assertion is only a row written EMPTY ON PURPOSE, which
// does compile -- `transcibr:audio` writes exactly one, for the success value its
// renderer refuses by name. This table has no such member and wants none, so the
// two assertions that remain say that, and the third, in key_named, is gone: an
// empty row there could only ever match an empty NAME, and an empty name is
// refused on the first line of that procedure.
@(private, rodata)
KEY := [Key]string {
	.Engine             = "engine",
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

// Renders a Sidecar as the bytes it is written to disk as.
//
// The field order is FIXED and is the order of `Key`, because a reader that had
// to cope with any order would also cope with a record missing half its fields.
// The caller owns the answer and frees it with `delete` and the same allocator.
sidecar_text :: proc(s: Sidecar, allocator: mem.Allocator) -> (written: string) {
	assert(allocator.procedure != nil, "the record outlives this procedure and needs an allocator")
	// The two shape claims every reader depends on and no sequence of writes
	// guarantees (A6): a record opens with the line that says what it is, and
	// ends on a line boundary so the last field is a whole field.
	defer {
		assert(
			strings.has_prefix(written, SIDECAR_VERSION_LINE),
			"a sidecar written without the line that says what it is",
		)
		assert(strings.has_suffix(written, "\n"), "a sidecar whose last field is not a whole line")
	}

	out := strings.builder_make(allocator)
	defer strings.builder_destroy(&out)

	strings.write_string(&out, SIDECAR_VERSION_LINE)
	strings.write_byte(&out, '\n')
	write_text(&out, .Engine, s.engine_version)
	write_text(&out, .Model, s.model)
	// The cast at the storage edge, and the one place a digest becomes an
	// ordinary string (T2).
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

// One `key: "value"` line, with everything in the value that could end it
// escaped.
@(private)
write_text :: proc(out: ^strings.Builder, key: Key, value: string) {
	assert(out != nil, "there is no record here to write a field into")
	assert(len(KEY[key]) > 0, "a key was given an empty name in KEY")

	strings.write_string(out, KEY[key])
	strings.write_string(out, ": \"")
	for at in 0 ..< len(value) {
		switch value[at] {
		case '\\':
			strings.write_string(out, `\\`)
		case '"':
			strings.write_string(out, `\"`)
		case '\n':
			strings.write_string(out, `\n`)
		case '\r':
			strings.write_string(out, `\r`)
		case '\t':
			strings.write_string(out, `\t`)
		case:
			// Every other byte a text editor renders as nothing at all, written
			// as its own hexadecimal escape rather than dropped: a Sidecar with a
			// byte quietly removed from a value would compare unequal to the
			// settings it was made under and re-run a Recording for ever.
			if value[at] < 0x20 || value[at] == 0x7F {
				fmt.sbprintf(out, `\x%02x`, value[at])
			} else {
				strings.write_byte(out, value[at])
			}
		}
	}
	strings.write_string(out, "\"\n")
}

// One `key: 123` line. Unquoted, so a reader can tell a number from a string by
// the byte after the space rather than by knowing what each field is.
@(private)
write_number :: proc(out: ^strings.Builder, key: Key, value: i64) {
	assert(out != nil, "there is no record here to write a field into")
	assert(len(KEY[key]) > 0, "a key was given an empty name in KEY")
	// The read side of what `recordable` refuses on the way in (A4). This comment
	// used to say every number here was this program's own arithmetic and nothing
	// external; that was FALSE and the falsehood was the bug. `source_modified_ns`
	// is the filesystem's answer, a Recording dated before 1970 carries a negative
	// one, and this assertion killed the process with two artifacts already
	// published. `complete` now refuses such a record before anything is written,
	// which is what leaves this as an invariant worth asserting.
	assert(value >= 0, "a sidecar was handed a count or a moment below zero")

	fmt.sbprintf(out, "%s: %d\n", KEY[key], value)
}

// Reads a Sidecar back, or says it is not one.
//
// A8, and ADR-0003 is why there is no fault vocabulary: anything at all may be
// in this file -- a half-written record from a crash, somebody's notes, a
// record a later transcibr wrote -- and "a missing or unparseable sidecar
// simply means unknown, re-do it" disposes of every one of them identically.
// A second vocabulary here would be nine sentences nobody could act on
// differently.
//
// REFUSED WHOLE and never half read: a record missing a field would compare
// equal to any other record missing the same field, which reports a Recording as
// matching settings nobody recorded.
//
// Every string in the answer is CLONED. Free it with destroy_sidecar and the
// same allocator; a refusal frees its own and hands back nothing to free.
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
	// Both ends of "this is a whole record" (A3): nothing after the last newline,
	// which is what a truncated file leaves, and every field present, which is
	// what a record written by another build does not have.
	if len(rest) > 0 || seen != every_key() {
		return not_a_sidecar(s, allocator)
	}
	return s, true
}

// The refusal, with whatever had already been cloned freed and the record
// zeroed.
//
// A PROCEDURE AND NOT A `defer` ON THE NAMED RETURN, which is what this was and
// which did not do what it says: the four refusals below all went through it,
// the strings were freed, and the caller was handed the record with its pointers
// still in it -- so every case that refused a Sidecar freed the same strings a
// second time, and `ODIN_TEST_FAIL_ON_BAD_MEMORY` is what said so. Written out,
// there is one place the refusal is spelled and no question about when it runs.
@(private)
not_a_sidecar :: proc(s: Sidecar, allocator: mem.Allocator) -> (Sidecar, bool) {
	destroy_sidecar(s, allocator)
	return Sidecar{}, false
}

// Frees a Sidecar that read_sidecar handed back. Never called on one a caller
// built out of borrowed strings -- see Sidecar.
destroy_sidecar :: proc(s: Sidecar, allocator: mem.Allocator) {
	delete(s.engine_version, allocator)
	delete(s.model, allocator)
	delete(string(s.model_digest), allocator)
	delete(s.merge_profile, allocator)
	delete(s.prompt, allocator)
}

// Every member of Key, worked out rather than spelled, so a field added to the
// record cannot be left out of the "is this whole" check.
@(private)
every_key :: proc() -> (all: bit_set[Key]) {
	for key in Key {
		all += {key}
	}
	assert(card(all) == len(Key), "a key went missing between the enumeration and the set")
	return
}

// The next whole line, and whether there was one. A trailing fragment with no
// newline behind it is left where it is, which is how read_sidecar tells a
// truncated record from a complete one.
@(private)
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

// One `key: value` line, split and named.
//
// The separator is a colon AND the space after it, so a key carrying a colon
// cannot be read as a shorter key with a longer value.
@(private)
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

// A field name as the Key it is, or nothing.
@(private)
key_named :: proc(name: string) -> (key: Key, known: bool) {
	if len(name) == 0 {
		return {}, false
	}
	// NOTHING IS ASSERTED ABOUT KEY IN HERE, and there was an assertion per
	// candidate -- around a hundred per Sidecar read. It could not fire: an empty
	// row would only ever match an empty name, and the line above has already
	// refused one. See KEY for what the two that remain are actually about.
	for candidate in Key {
		if KEY[candidate] == name {
			return candidate, true
		}
	}
	return {}, false
}

// One field's value, into the record.
//
// Every arm refuses rather than defaulting: a number this reader shrugged at
// would be stored as zero, and a zero compares equal to another zero -- so a
// corrupt Sidecar would report a Recording as still matching its settings, which
// is the one answer that can never be recovered from.
@(private)
store :: proc(s: ^Sidecar, key: Key, value: string, allocator: mem.Allocator) -> (ok: bool) {
	assert(s != nil, "there is no record here to read a field into")

	switch key {
	case .Engine:
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
		s.model_bytes, ok = whole(value)
	case .Source_Bytes:
		s.source_bytes, ok = whole(value)
	case .Source_Modified_Ns:
		s.source_modified_ns, ok = whole(value)
	case .Container_Ms:
		s.container_ms, ok = whole(value)
	case .Beam:
		beam: i64
		beam, ok = whole(value)
		ok = ok && beam <= i64(max(u32))
		s.beam = u32(beam) if ok else 0
	}
	return ok
}

// A quoted value, with its escapes undone. The caller owns the answer.
//
// Strict in both directions (A3): every escape this writer produces is
// understood, and nothing else is. A raw newline or a raw quotation mark inside
// the value is a record this package did not write, and reading one leniently
// would accept a file whose fields have run into each other.
@(private)
unquoted :: proc(value: string, allocator: mem.Allocator) -> (text: string, ok: bool) {
	assert(allocator.procedure != nil, "the value outlives this procedure and needs an allocator")
	// Nothing here needs unwinding: the builder is destroyed by its own defer on
	// every path, and `text` is assigned once, at the successful return.
	if len(value) < 2 || value[0] != '"' || value[len(value) - 1] != '"' {
		return "", false
	}
	body := value[1:len(value) - 1]

	out := strings.builder_make(allocator)
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

// One escape sequence, written out as the byte it stands for. Answers how many
// bytes of the input it consumed, and zero where it is not an escape this
// package writes.
@(private)
escape :: proc(from: string, out: ^strings.Builder) -> (taken: int) {
	assert(out != nil, "there is nowhere here to write an unescaped byte")
	// Two facts and not one conjunction (A2), so a failure names which of them
	// went: an empty slice and a slice that does not start an escape are
	// different bugs in the caller.
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

// One lower-case hexadecimal digit. Lower case only, because that is what this
// package writes and a reader that accepted both would accept a record it did
// not produce.
@(private)
hex :: proc(digit: u8) -> (value: u8, ok: bool) {
	switch digit {
	case '0' ..= '9':
		return digit - '0', true
	case 'a' ..= 'f':
		return digit - 'a' + 10, true
	}
	return 0, false
}

// The most decimal digits a number in a Sidecar may carry: nineteen, which is
// what `max(i64)` takes. A twentieth digit cannot fit whatever it says, and the
// overflow check below is what refuses the nineteen-digit numbers that do not.
@(private)
MAX_SIDECAR_DIGITS :: 19

#assert(MAX_SIDECAR_DIGITS == len("9223372036854775807"))

// A whole non-negative number, strictly.
//
// Stricter than `strconv.parse_int` for the reasons `transcibr:process`'s own
// reader gives: that procedure accepts `_` as a digit separator, accepts a
// leading sign, and OVERFLOWS SILENTLY -- and every one of those is a byte a
// corrupt Sidecar can carry. A number that wrapped would be a plausible small
// count, and a plausible small count compares equal to another one.
@(private)
whole :: proc(text: string) -> (value: i64, ok: bool) {
	if len(text) == 0 || len(text) > MAX_SIDECAR_DIGITS {
		return 0, false
	}
	for at in 0 ..< len(text) {
		digit := text[at]
		if digit < '0' || digit > '9' {
			return 0, false
		}
		// BEFORE the multiplication and not after it, which is the whole
		// difference between a refusal and a wrap.
		if value > (max(i64) - i64(digit - '0')) / 10 {
			return 0, false
		}
		value = value * 10 + i64(digit - '0')
	}
	assert(value >= 0, "a run of decimal digits added up to a negative number")
	return value, true
}
