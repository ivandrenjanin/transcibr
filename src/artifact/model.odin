package artifact

import "core:crypto/sha2"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "transcibr:process"

// This file settles what the Model IS -- where it really lives, whether the
// Engine can be given that path at all, and the sixty-four characters that say
// which weights these are -- and it is answered ONCE PER BATCH, before any
// Recording starts.
//
// WHEN THE HASH IS COMPUTED IS A DECISION AND NOT AN ACCIDENT. A Model is
// upwards of a gigabyte; hashing one costs a pass over that file, which is
// seconds on a machine with SHA-NI and under a minute without it. Per Recording
// that is a tax on every Recording in a Batch for an answer that cannot have
// changed between two of them; once per Batch it is paid against a Batch
// measured in hours, before any GPU time is spent, and in the same pass that
// answers whether the Batch can start at all. Nothing here is ever loaded into
// memory: the file is read a chunk at a time into a buffer on the stack.
//
// WHY IT IS IN THIS PACKAGE AND NOT IN `transcibr:engine`. The Model is the
// Engine's input, and identifying it is not driving the Engine: what wants this
// answer is the Sidecar, which is what the identity is FOR (ADR-0003), and the
// pass that produces it is the same pass that refuses a path the Engine cannot
// open. `transcibr:engine` checks the three paths one invocation is about to be
// handed, which is A4's other route to the same property and is per Recording;
// this is the Batch's, and it is the one that says the Batch cannot start.
//
// ADR-0002 asks for the refusal loudly and once, in `doctor`. THERE IS NO
// `doctor` IN `src/` YET (issue #13), so this does what `transcibr:audio` did
// for the scratch cache and records the substitution the same way: check it once
// at Batch start rather than once per Recording, in the vocabulary `doctor` will
// use when it arrives.

// How much of a Model is read at a time.
//
// SIXTY-FOUR KILOBYTES, on the stack and never allocated -- the size
// `transcibr:audio` reads a WAV head into, for the same reason: a buffer whose
// whole life is one procedure. A megabyte would halve the number of reads over a
// gigabyte-and-a-half file and is a megabyte of stack on whichever worker thread
// happens to be running the Batch's opening checks.
MODEL_READ_BYTES :: 64 * 1024

// What transcibr knows about the Model a Batch is running.
//
// `path` and `digest` are OWNED and freed with destroy_model and the allocator
// that was handed in.
Model :: struct {
	// RESOLVED, which is both what the Engine will be handed and what the
	// Sidecar records -- so two Batches that spelled one Model two ways record
	// one Model rather than two, and a Sidecar comparison does not report a
	// change nobody made.
	path:   string,
	digest: Digest,
	bytes:  i64,
}

// How the Model itself could not be used.
//
// A BATCH-LEVEL VOCABULARY, the shape `transcibr:audio`'s Cache_Fault has and
// for the same reason: the culprit is not a Recording, the answer is the same
// for every Recording in the Batch, and the disposition is not "this Recording
// fails and the Batch carries on" -- there is nowhere for any Recording's Cues
// to come from, so the Batch does not start.
//
// Two members, so it carries an enumeration and one renderer and none of the
// rest of the apparatus. An exhaustive `switch` gives the identical compiler
// guard a table would -- a member added and left out of either one fails to
// compile, which is measured rather than assumed, and is what the argument for a
// table in sidecar.odin used to get backwards. What is left is what a deliberate
// hand can write, and a row spelled `= ""` and an arm that returns nothing are
// the same hazard caught the same way, by the renderer's own assertion. So this
// is a shape preference between two equals: this repository has four full copies
// of the fault-report shape already (issue #33) and this is deliberately not a
// fifth.
Model_Fault :: enum u8 {
	None = 0,
	// ADR-0002's own refusal, checked on the RESOLVED path and before the file
	// is opened: the Engine cannot open a path carrying a byte outside ASCII.
	Path_Not_Ascii,
	// It could not be resolved, opened or read to the end.
	Unreadable,
}

// Settles which Model a Batch is running, and whether it can run at all.
//
// A8: the Model's path is a settings field and the file is somebody else's, so
// every refusal here is a return value. Nothing about the file reaches an
// assertion.
//
// A MODEL PATH THAT IS NOT VALID UTF-8 ANSWERS `.Unreadable` AND NOT
// `.Path_Not_Ascii`, which is honest and is the less useful of the two
// sentences -- `get_absolute_path` refuses such a path before the ASCII check
// ever sees it, and NTFS permits an unpaired surrogate in a filename. Both
// answers stop the Batch and name the file, so what is lost is the reason, and
// the reason is the one that says what to rename. The same trade `open_cache`
// records next door, for the same cause.
identify_model :: proc(
	model: string,
	allocator: mem.Allocator,
) -> (
	identified: Model,
	fault: Model_Fault,
) {
	assert(len(model) > 0, "there is no Model here to identify")
	assert(
		allocator.procedure != nil,
		"the identity outlives this procedure and needs an allocator",
	)
	// Both halves of what a return means (A3): a refusal hands back nothing to
	// free and nothing to record, and an acceptance hands back a digest of the
	// length the type promises.
	defer if fault != .None {
		assert(len(identified.digest) == 0, "refused a Model and identified it anyway")
		assert(identified.bytes == 0, "refused a Model and measured it anyway")
	} else {
		assert(len(identified.digest) == DIGEST_CHARS, "identified a Model by a partial digest")
	}

	resolved, unresolvable := os.get_absolute_path(model, allocator)
	if unresolvable != nil {
		return {}, .Unreadable
	}
	defer if fault != .None {
		delete(resolved, allocator)
	}

	// BEFORE the file is opened, because a Model happily hashed under a path the
	// Engine cannot open is exactly the failure that shows up two stages later as
	// an Engine that produced nothing at exit code zero.
	if !process.ascii_only(resolved) {
		return {}, .Path_Not_Ascii
	}

	digest, bytes, unreadable := digest_of(resolved, allocator)
	if unreadable != .None {
		return {}, unreadable
	}
	return Model{path = resolved, digest = digest, bytes = bytes}, .None
}

// Frees what identify_model handed back. Safe on a refusal, which allocated
// nothing.
destroy_model :: proc(identified: Model, allocator: mem.Allocator) {
	delete(identified.path, allocator)
	delete(string(identified.digest), allocator)
}

// The SHA-256 of a file's contents, and how many bytes went into it.
//
// STREAMED and never loaded: a Model is upwards of a gigabyte, and reading one
// into memory to hash it would cost more than the Engine spends holding the
// weights.
//
// The handle is opened here and closed here, by this procedure's own `defer`,
// on every path out of it -- including the two that refuse.
@(private)
digest_of :: proc(
	path: string,
	allocator: mem.Allocator,
) -> (
	digest: Digest,
	bytes: i64,
	fault: Model_Fault,
) {
	assert(len(path) > 0, "there is no file here to hash")
	assert(allocator.procedure != nil, "the digest outlives this procedure and needs an allocator")

	handle, unopenable := os.open(path)
	if unopenable != nil {
		return "", 0, .Unreadable
	}
	defer os.close(handle)

	// The length off the SAME HANDLE the bytes come from, so it belongs to the
	// file that was hashed rather than to whatever a later stat would find under
	// that name -- and it is compared against what the loop actually read, which
	// is A4's second route to "the whole file went into this digest".
	length, unmeasurable := os.file_size(handle)
	if unmeasurable != nil {
		return "", 0, .Unreadable
	}

	context_256: sha2.Context_256
	sha2.init_256(&context_256)
	buffer: [MODEL_READ_BYTES]u8 = ---
	for {
		read, unreadable := os.read(handle, buffer[:])
		if read > 0 {
			assert(read <= len(buffer), "a read came back with more than there was room for")
			sha2.update(&context_256, buffer[:read])
			bytes += i64(read)
		}
		if unreadable == io.Error.EOF {
			break
		}
		if unreadable != nil {
			return "", 0, .Unreadable
		}
		// A read of nothing at all with no error and no end of stream is a file
		// this loop would spin on for ever. Nothing may block for ever (issue
		// #27), so it is refused rather than retried.
		if read == 0 {
			return "", 0, .Unreadable
		}
	}
	if bytes != length {
		return "", 0, .Unreadable
	}
	return hex_digest(&context_256, allocator), bytes, .None
}

// A finished SHA-256 as the lower-case hexadecimal a Sidecar carries.
//
// The relationship the format rests on, held by the COMPILER (A5): the digest is
// two characters per byte, so a Sidecar's DIGEST_CHARS and this hash's size are
// one claim rather than two that could drift.
#assert(DIGEST_CHARS == 2 * sha2.DIGEST_SIZE_256)

@(private)
hex_digest :: proc(context_256: ^sha2.Context_256, allocator: mem.Allocator) -> (digest: Digest) {
	assert(context_256 != nil, "there is no hash here to finish")
	assert(allocator.procedure != nil, "the digest outlives this procedure and needs an allocator")
	defer assert(
		len(digest) == DIGEST_CHARS,
		"a digest rendered to the wrong number of characters",
	)

	sum: [sha2.DIGEST_SIZE_256]u8
	sha2.final(context_256, sum[:])

	out := strings.builder_make(allocator)
	defer strings.builder_destroy(&out)
	for b in sum {
		// Lower case, which is what read_sidecar's own hexadecimal reader accepts
		// and nothing else -- one spelling, so a Sidecar always reads back.
		fmt.sbprintf(&out, "%02x", b)
	}
	return Digest(strings.clone(strings.to_string(out), allocator))
}

// What each Model fault reads as, without the file's name -- model_error_message
// supplies that, so no arm here can forget to.
@(private)
model_fault_says :: proc(fault: Model_Fault) -> string {
	switch fault {
	case .Path_Not_Ascii:
		return(
			"the Model is under a path the Engine cannot open, because it carries a byte outside ASCII" \
		)
	case .Unreadable:
		return "the Model could not be read"
	case .None:
	// The success value and not a fault. It has no sentence, and
	// model_error_message refuses it by name before ever asking for one.
	}
	return ""
}

// Renders a refused Model as a line, NAMING THE FILE and saying that the Batch
// does not start.
//
// The path is printed with %q for the reason `transcibr:audio`'s renderers give:
// a refusal reaches a user through a UTF-16 Win32 call, a raw NUL cuts the line
// off where it is printed, and a byte that is not UTF-8 makes the whole line
// convert to nil -- and a Model under such a path is exactly what this refuses.
//
// The allocator is explicit and never defaulted; free the answer with `delete`
// and the same one.
model_error_message :: proc(
	fault: Model_Fault,
	model: string,
	allocator: mem.Allocator,
) -> string {
	assert(fault != .None, "there is no message for a Model that was identified")
	assert(len(model) > 0, "a refusal must name the Model it is reported against")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs an allocator",
	)

	says := model_fault_says(fault)
	assert(len(says) > 0, "a fault was added to Model_Fault without a sentence")

	message := fmt.aprintf("%q: %s -- the Batch cannot start", model, says, allocator = allocator)
	assert(len(message) > 0, "a refusal rendered as nothing at all")
	return message
}
