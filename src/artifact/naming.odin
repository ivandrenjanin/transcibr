package artifact

import "core:fmt"
import "core:mem"
import "core:strings"

// This file holds what things are CALLED, and nothing else. It reads no
// directory, opens no file and asks the filesystem nothing: every answer in it
// is a decision about a string, which is what lets a case check the one property
// that no filesystem this machine has could demonstrate -- see part_of.
//
// WHICH PUTS THIS FILE UNDER A1's AVERAGE, at 8 assertions across 7 procedures,
// and the carve-out is recorded here rather than left for a reader to work out.
// It used to count 14, and the six that went did not go quietly: four were
// claims about CONSTANTS -- that the three artifact suffixes differ, that the
// quarantine suffix is not empty -- and A5 says those belong to the compiler, so
// they are `#assert`s above rather than checks re-run per Recording. The other
// two were part_of's, and they could not fire for any input this program can
// produce; what they guarded was an edit to one format string, which
// naming_test guards over three destinations.
//
// The three that carry none are `destroy_names`, which frees what it was handed,
// and `path_stem_of` and `stem_of`, which are two lines each over `name_bounds`
// -- and `name_bounds` holds the pair that is actually about them. A1's own
// wording is the licence: pure leaf math may carry fewer when its callers carry
// more, and `names_of` and `part_of` carry it on the way in.

// What a Transcript is called, ADR-0008's rule spelled once: a Recording at
// `<dir>\<stem>.<ext>` produces `<dir>\<stem>.md`.
TRANSCRIPT_SUFFIX :: ".md"

// And its retained Engine output, under the same stem. The extension the ENGINE
// appends is spelled in `transcibr:process`, which is where the Engine's own
// choice belongs; this is transcibr's choice of what to call the copy it keeps,
// and the two agreeing is a convenience rather than a coupling.
ENGINE_OUTPUT_SUFFIX :: ".json"

// And the Sidecar. A suffix of its own rather than a dotted second extension on
// the Transcript, because ADR-0008's rule is that artifacts REPLACE the source
// extension, and `talk.md.sidecar` would make one artifact's name depend on
// another's.
SIDECAR_SUFFIX :: ".sidecar"

// What a piece of Engine output that will not parse is moved aside to.
//
// ADR-0002 names this file exactly -- "quarantine it to `.json.bad` and re-run
// the full pipeline" -- and appending rather than replacing is what makes the
// name say so: `<stem>.json.bad` reads as a `.json` that went wrong, where
// `<stem>.bad` reads as nothing at all.
QUARANTINE_SUFFIX :: ".bad"

// The two relationships every name above rests on, held by the COMPILER (A5)
// rather than re-checked on every Recording. Both were run-time assertions --
// one in names_of and one in quarantined -- and neither is about a value: three
// artifacts sharing one stem are three different files exactly when their three
// suffixes differ, and a quarantined file is named differently from the original
// exactly when the suffix is not empty.
#assert(TRANSCRIPT_SUFFIX != ENGINE_OUTPUT_SUFFIX)
#assert(TRANSCRIPT_SUFFIX != SIDECAR_SUFFIX)
#assert(ENGINE_OUTPUT_SUFFIX != SIDECAR_SUFFIX)
#assert(len(QUARANTINE_SUFFIX) > 0)

// The three names one Recording's completion writes.
//
// Every string is OWNED by the caller and freed with destroy_names and the
// allocator that was handed in.
//
// A record rather than three returns, so a caller cannot get two of them the
// wrong way round -- and so that the one thing ADR-0008 requires of the set,
// that they all come from one stem, is visible at the type rather than asserted
// at three call sites.
Names :: struct {
	transcript:    string,
	engine_output: string,
	sidecar:       string,
}

// What one Recording's artifacts are called, or nothing where its path names no
// file to make artifacts from.
//
// A8: the Recording's path comes from a command line or from discovery, so a
// path that names a directory is an operating error and never an assertion. A
// refusal allocates nothing, which is the half a caller depends on: it frees
// what it was handed either way.
//
// THE INJECTIVITY OF THIS MAPPING IS NOT CHECKED HERE and cannot be. Two
// Recordings differing only by extension -- `interview.mp4` and `interview.m4a`
// -- both map to `interview.md`, and ADR-0008 puts that check in planning, over
// the whole Batch, where there is a PAIR to name. Over one Recording there is
// nothing to compare.
names_of :: proc(source: string, allocator: mem.Allocator) -> (names: Names, ok: bool) {
	assert(allocator.procedure != nil, "the names outlive this procedure and need an allocator")
	// A refusal hands back nothing to free, which is the half a caller depends on
	// and the half that is about a value rather than about a constant. That the
	// three names differ is the other half, and it is not asserted here any more:
	// all three are one stem plus a suffix, so it is a claim about the three
	// SUFFIXES and the compiler settles it beside their definitions (A5).
	defer if !ok {
		assert(len(names.transcript) == 0, "refused a Recording and kept a name for it")
	}

	stem := path_stem_of(source)
	if len(stem) == 0 {
		return {}, false
	}
	return Names {
			transcript = strings.concatenate({stem, TRANSCRIPT_SUFFIX}, allocator),
			engine_output = strings.concatenate({stem, ENGINE_OUTPUT_SUFFIX}, allocator),
			sidecar = strings.concatenate({stem, SIDECAR_SUFFIX}, allocator),
		},
		true
}

// Frees what names_of handed back. Safe on a refusal, which allocated nothing.
destroy_names :: proc(names: Names, allocator: mem.Allocator) {
	delete(names.transcript, allocator)
	delete(names.engine_output, allocator)
	delete(names.sidecar, allocator)
}

// Where a Recording's own name begins in its path and where its extension
// starts: the whole of ADR-0008's rule about names, in ONE place, as two indices
// into the argument. Both are zero where the path names no file at all.
//
// One rule and not two, which is the point of it being here rather than spelled
// at each of the two callers. It was two: this package answered one way and the
// command line asked `filepath.stem`, which reads `.talk` as an empty name with
// a `talk` extension -- so a dotfile Recording was refused by the shell and
// accepted here, and the case that pins the acceptance had no production caller.
@(private)
name_bounds :: proc(source: string) -> (from: int, to: int) {
	defer {
		assert(to >= from, "a Recording's name was said to end before it begins")
		assert(to <= len(source), "a Recording's name was said to run past its own path")
	}

	// Both separators, because Windows accepts both and a command line carrying
	// forward slashes is an ordinary thing to be handed. Only the LAST of either
	// matters, so the two are asked separately and the further one wins.
	cut := max(strings.last_index_byte(source, '\\'), strings.last_index_byte(source, '/'))
	from = cut + 1
	if from == len(source) {
		return 0, 0
	}

	// A LEADING DOT IS A NAME. `.talk` is a file called `.talk` and not an empty
	// name with a `talk` extension, and reading it the other way would map every
	// dotfile in one directory onto one artifact path.
	dot := strings.last_index_byte(source[from:], '.')
	if dot <= 0 {
		return from, len(source)
	}
	return from, from + dot
}

// A Recording's path with its extension taken off, DIRECTORY AND ALL, or the
// empty string where it names no file.
//
// The directory is kept because artifacts go beside their Recording (ADR-0008),
// and it is kept BY NOT BEING TOUCHED -- the answer is a prefix of the argument.
// `filepath.dir` and `filepath.join` would decide the answer's separators, and a
// caller who typed `C:/clips/talk.mp4` would get their Transcript at
// `C:\clips\talk.md`: the same file, spelled a way they did not choose and would
// not find in a diagnostic.
@(private)
path_stem_of :: proc(source: string) -> string {
	_, to := name_bounds(source)
	return source[:to]
}

// The stem every artifact of one Recording is named from: the Recording's own
// name with its extension taken off, and the directory left behind. Empty where
// the path names no file, which is the same refusal names_of makes.
//
// THE SHELL'S COPY OF THIS RULE IS WHAT THIS REPLACES. Everything named from one
// Recording -- the scratch audio, the Engine's output prefix, the progress line,
// and through names_of the three artifacts themselves -- has to come from one
// answer, or a Recording is refused at one stage and accepted at the next.
// ADR-0008's injectivity check over a Batch is still planning's: over one
// Recording there is no pair for it to be about.
stem_of :: proc(source: string) -> string {
	from, to := name_bounds(source)
	return source[from:to]
}

// The temporary name an artifact is written under before it is moved into place.
//
// THE CROSS-VOLUME ANSWER, and it is a naming decision rather than a filesystem
// one. `MoveFileExW` is atomic within a volume and is NOT across one, and
// `core:os`'s rename passes `MOVEFILE_REPLACE_EXISTING` and no
// `MOVEFILE_COPY_ALLOWED` -- so a rename across a volume fails outright rather
// than quietly becoming a copy and a delete, which is the shape that publishes a
// half-written artifact. This program never asks for one: the temporary name is
// the artifact's own path with a suffix on the end, so the two are always in one
// directory and therefore always on one volume, and the scratch cache being on
// another drive from the Recording cannot reach the rename at all. The bytes
// cross the volume boundary BEFORE the artifact has a name, which is the whole
// trick.
//
// The process identifier is in it for the reason `transcibr:audio` gives about
// its own two intermediates: a Recording's directory is shared, and two
// transcibr windows over one Recording under one temporary name had one
// window's rename publishing the file the other was still writing.
//
// WHERE THAT CLAIM IS CHECKED is naming_test, over three destinations, and not
// in a `defer` here -- which is what it was. The property is about the FORMAT
// STRING below and not about any argument: for every input this procedure can be
// handed, an answer that appends to the destination has the destination's own
// last separator, so a run-time assertion on it could never fire. What it
// guarded was an EDIT to the format, and three destinations guard that exactly
// as well as infinitely many, because the answer does not depend on the input.
//
// The caller owns the answer and frees it with `delete` and the same allocator.
part_of :: proc(destination: string, pid: int, allocator: mem.Allocator) -> (part: string) {
	assert(len(destination) > 0, "there is nowhere here for an artifact to be published to")
	assert(allocator.procedure != nil, "the name outlives this procedure and needs an allocator")

	return fmt.aprintf("%s.%d.part", destination, pid, allocator = allocator)
}

// Where a piece of Engine output that will not parse is moved aside to.
//
// The whole original name is kept in front of the suffix, so what was
// quarantined is readable off what is left -- and so that the answer is in the
// same directory as the file it renames, for part_of's reason.
//
// The caller owns the answer and frees it with `delete` and the same allocator.
quarantined :: proc(path: string, allocator: mem.Allocator) -> string {
	assert(len(path) > 0, "there is nothing here to move aside")
	assert(allocator.procedure != nil, "the name outlives this procedure and needs an allocator")

	return strings.concatenate({path, QUARANTINE_SUFFIX}, allocator)
}
