#+vet explicit-allocators
package artifact

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:os"
import "transcibr:process"

// Hashing a Model costs a pass over upwards of a gigabyte, so its identity is
// settled once per Batch rather than once per Recording.

// On the stack and never allocated: a megabyte would halve the reads over a
// gigabyte-and-a-half file and is a megabyte of stack on a worker thread.
MODEL_READ_BYTES :: 64 * 1024

// `path` and `digest` are OWNED and freed with destroy_model and the allocator
// that was handed in.
Model :: struct {
	// Resolved, so two Batches that spelled one Model two ways record one Model.
	path:   string,
	digest: Digest,
	bytes:  i64,
}

Model_Fault :: enum u8 {
	None = 0,
	// Why the Engine cannot open such a path: ADR-0025.
	Path_Not_Ascii,
	Unreadable,
}

// A path that is not valid UTF-8 answers `.Unreadable` and not
// `.Path_Not_Ascii`, because get_absolute_path refuses it before the ASCII
// check sees it; the trade is ADR-0025's.
@(require_results)
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

	if !process.ascii_only(resolved) {
		return {}, .Path_Not_Ascii
	}

	digest, bytes, unreadable := digest_of(resolved, allocator)
	if unreadable != .None {
		return {}, unreadable
	}
	return Model{path = resolved, digest = digest, bytes = bytes}, .None
}

// Safe on a refusal, which allocated nothing.
destroy_model :: proc(identified: Model, allocator: mem.Allocator) {
	delete(identified.path, allocator)
	delete(string(identified.digest), allocator)
}

@(private)
@(require_results)
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
		if read == 0 {
			return "", 0, .Unreadable
		}
	}
	if bytes != length {
		return "", 0, .Unreadable
	}
	return hex_digest(&context_256, allocator), bytes, .None
}

#assert(DIGEST_CHARS == 2 * sha2.DIGEST_SIZE_256)

@(private)
@(require_results)
hex_digest :: proc(context_256: ^sha2.Context_256, allocator: mem.Allocator) -> (digest: Digest) {
	assert(context_256 != nil, "there is no hash here to finish")
	assert(allocator.procedure != nil, "the digest outlives this procedure and needs an allocator")
	defer assert(
		len(digest) == DIGEST_CHARS,
		"a digest rendered to the wrong number of characters",
	)

	sum: [sha2.DIGEST_SIZE_256]u8
	sha2.final(context_256, sum[:])
	return Digest(string(hex.encode(sum[:], allocator)))
}

@(private)
@(require_results)
model_fault_says :: proc(fault: Model_Fault) -> string {
	switch fault {
	case .Path_Not_Ascii:
		return(
			"the Model is under a path the Engine cannot open, because it carries a byte outside ASCII" \
		)
	case .Unreadable:
		return "the Model could not be read"
	case .None:
	}
	return ""
}

// %q because a refusal reaches a user through a UTF-16 Win32 call: a raw NUL
// cuts the line off, and a byte that is not UTF-8 converts the whole line to
// nil. Free the answer with `delete` and the allocator handed in.
@(require_results)
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
