#+vet explicit-allocators
package artifact

import "core:fmt"
import "core:mem"
import "core:path/filepath"
import "core:strings"
import "transcibr:transcript"

// What things are called. Every answer here is a decision about a string, and
// nothing in this file touches the filesystem.

// Why an artifact replaces the Recording's extension: ADR-0008.
TRANSCRIPT_SUFFIX :: ".md"

// transcibr's name for the copy it keeps; the extension the Engine itself
// appends is `transcibr:process`'s, and the two agreeing is not a coupling.
ENGINE_OUTPUT_SUFFIX :: ".json"

SIDECAR_SUFFIX :: ".sidecar"

// Appended rather than replacing, because ADR-0002 names `.json.bad` exactly.
QUARANTINE_SUFFIX :: ".bad"

#assert(TRANSCRIPT_SUFFIX != ENGINE_OUTPUT_SUFFIX)
#assert(TRANSCRIPT_SUFFIX != SIDECAR_SUFFIX)
#assert(ENGINE_OUTPUT_SUFFIX != SIDECAR_SUFFIX)
#assert(len(QUARANTINE_SUFFIX) > 0)

// Every string is owned by the caller and freed with destroy_names and the
// allocator that was handed in. Why an enumerated array over `Artifact` rather
// than a struct of three fields: ADR-0024.
Names :: distinct [Artifact]string

// A refusal allocates nothing, so a caller frees what it was handed either way.
// Injectivity is a property of a whole Batch and is checked in planning:
// ADR-0008.
@(require_results)
names_of :: proc(source: string, allocator: mem.Allocator) -> (names: Names, ok: bool) {
	assert(allocator.procedure != nil, "the names outlive this procedure and need an allocator")
	defer if !ok {
		assert(len(names[.Transcript]) == 0, "refused a Recording and kept a name for it")
	}

	stem := path_stem_of(source)
	if len(stem) == 0 {
		return {}, false
	}
	return Names {
			.Transcript = strings.concatenate({stem, TRANSCRIPT_SUFFIX}, allocator),
			.Engine_Output = strings.concatenate({stem, ENGINE_OUTPUT_SUFFIX}, allocator),
			.Sidecar = strings.concatenate({stem, SIDECAR_SUFFIX}, allocator),
		},
		true
}

destroy_names :: proc(names: Names, allocator: mem.Allocator) {
	for path in names {
		delete(path, allocator)
	}
}

// Not `filepath.stem`: that reads `.talk` as an empty name with a `talk`
// extension, which maps every dotfile in one directory onto one artifact path.
@(private)
@(require_results)
name_bounds :: proc(source: string) -> (from: int, to: int) {
	defer {
		assert(to >= from, "a Recording's name was said to end before it begins")
		assert(to <= len(source), "a Recording's name was said to run past its own path")
	}

	cut := max(strings.last_index_byte(source, '\\'), strings.last_index_byte(source, '/'))
	from = cut + 1
	if from == len(source) {
		return 0, 0
	}

	dot := strings.last_index_byte(source[from:], '.')
	if dot <= 0 {
		return from, len(source)
	}
	return from, from + dot
}

// A prefix of the argument, so the caller's own separators survive:
// `filepath.dir` plus `filepath.join` would respell a Transcript for
// `C:/clips/talk.mp4` as `C:\clips\talk.md`, which is not what a diagnostic
// would then have to be searched for.
@(private)
@(require_results)
path_stem_of :: proc(source: string) -> string {
	_, to := name_bounds(source)
	return source[:to]
}

// The one answer to what a stem is: the scratch audio, the Engine's output
// prefix and the progress line are all named from it, so a second rule would
// refuse a Recording at one stage and accept it at the next.
@(require_results)
stem_of :: proc(source: string) -> string {
	from, to := name_bounds(source)
	return source[from:to]
}

// A Model's own display name, for a Transcript's header -- and `filepath.-`
// `stem` on purpose, unlike `stem_of` just above: a Model is never the
// dotfile `stem_of`'s own comment warns about, so the caller-facing name a
// Model was given is exactly what `filepath.stem` already reads. Empty is
// `transcript.UNKNOWN` and never the empty string, the same rule every other
// provenance field on a Transcript follows. `--transcribe` and `--batch` both
// called their own copy of this before PR #67's review, finding 5 -- one of
// them could drift and silently write a different `model:` line than the
// other.
@(require_results)
model_display_name :: proc(path: string) -> string {
	assert(len(path) > 0, "there is no Model here to name")

	return transcript.named_or_unknown(filepath.stem(path))
}

// The other half of the same cut, so a caller asking what kind of file this is
// and a caller naming its artifacts agree about where the name ends. Empty where
// there is no extension AND where the path names no file at all -- `.mp4` is a
// name and not an extension, exactly as `stem_of` reads it.
@(require_results)
extension_of :: proc(source: string) -> string {
	from, to := name_bounds(source)
	if to <= from {
		return ""
	}
	return source[to:]
}

// Why the temporary name appends to the destination, and why the process
// identifier is in it: ADR-0024. The caller owns the answer and frees it with
// `delete` and the same allocator.
@(require_results)
part_of :: proc(destination: string, pid: int, allocator: mem.Allocator) -> (part: string) {
	assert(len(destination) > 0, "there is nowhere here for an artifact to be published to")
	assert(allocator.procedure != nil, "the name outlives this procedure and needs an allocator")

	return fmt.aprintf("%s.%d.part", destination, pid, allocator = allocator)
}

// Appending keeps the answer in the same directory as the file it renames, for
// part_of's reason. The caller owns the answer and frees it with `delete` and
// the same allocator.
@(require_results)
quarantined :: proc(path: string, allocator: mem.Allocator) -> string {
	assert(len(path) > 0, "there is nothing here to move aside")
	assert(allocator.procedure != nil, "the name outlives this procedure and needs an allocator")

	return strings.concatenate({path, QUARANTINE_SUFFIX}, allocator)
}
