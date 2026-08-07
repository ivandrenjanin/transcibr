#+vet explicit-allocators
package net

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"

// One artifact this package can fetch: a canonical URL and what a finished
// download must look like before it is trusted. `magic` may be empty, which
// skips that one step of verify_download and nothing else -- an artifact
// with no distinctive header still gets the size and hash checks.
Download_Spec :: struct {
	url:             string,
	display_name:    string,
	expected_bytes:  i64,
	expected_sha256: string,
	magic:           []u8,
}

Verify_Fault :: enum u8 {
	None = 0,
	Unreadable,
	Size_Mismatch,
	Magic_Mismatch,
	Hash_Mismatch,
}

Verify_Result :: struct {
	fault:           Verify_Fault,
	expected_bytes:  i64,
	actual_bytes:    i64,
	expected_sha256: string,
	// Owned by the caller once returned; empty when the fault was decided
	// before a hash was ever computed (ADR-0014's verification order).
	actual_sha256:   string,
}

// A megabyte off the stack, as src/artifact/model.odin reads a Model with --
// large enough to make the streaming pass cheap, small enough to never be
// the reason a worker thread runs out of stack.
VERIFY_READ_BYTES :: 64 * 1024

// Expected size, then magic bytes, then a streaming hash over the whole
// file -- in that order, so a wrong-size file is refused before a byte of
// it is read for anything else, and a corrupted body is refused before the
// (much more expensive) hash finishes (ADR-0014). The hash is never
// computed by loading the file into memory: one pass, `VERIFY_READ_BYTES`
// at a time, same as `src/artifact/model.odin`'s `digest_of`.
@(require_results)
verify_download :: proc(
	path: string,
	spec: Download_Spec,
	allocator: mem.Allocator,
) -> (
	result: Verify_Result,
) {
	assert(len(path) > 0, "there is no file here to verify")
	assert(spec.expected_bytes > 0, "a spec with nothing expected verifies nothing")
	assert(len(spec.expected_sha256) > 0, "a spec with no expected hash verifies nothing")
	assert(allocator.procedure != nil, "a passing verification's hash outlives this procedure")
	result.expected_bytes = spec.expected_bytes
	result.expected_sha256 = spec.expected_sha256

	handle, unopenable := os.open(path)
	if unopenable != nil {
		result.fault = .Unreadable
		return
	}
	defer os.close(handle)

	length, unmeasurable := os.file_size(handle)
	if unmeasurable != nil {
		result.fault = .Unreadable
		return
	}
	result.actual_bytes = length
	if length != spec.expected_bytes {
		result.fault = .Size_Mismatch
		return
	}

	actual, read_total, fault := hash_and_check_magic(handle, spec.magic, allocator)
	if fault != .None {
		result.fault = fault
		return
	}
	if read_total != length {
		result.fault = .Unreadable
		return
	}

	result.actual_sha256 = actual
	if !strings.equal_fold(actual, spec.expected_sha256) {
		result.fault = .Hash_Mismatch
	}
	return
}

// One pass over the whole file: the magic bytes are read off the first
// chunk and never re-read, and the hash covers every byte including them.
@(private)
@(require_results)
hash_and_check_magic :: proc(
	handle: ^os.File,
	magic: []u8,
	allocator: mem.Allocator,
) -> (
	digest: string,
	read_total: i64,
	fault: Verify_Fault,
) {
	assert(handle != nil, "there is no open file here to hash")
	assert(allocator.procedure != nil, "the digest outlives this procedure and needs an allocator")

	context_256: sha2.Context_256
	sha2.init_256(&context_256)
	buffer: [VERIFY_READ_BYTES]u8 = ---
	magic_checked := false
	for {
		read, unreadable := os.read(handle, buffer[:])
		if read > 0 {
			assert(read <= len(buffer), "a read came back with more than there was room for")
			if !magic_checked {
				if len(magic) > 0 && !head_matches(buffer[:read], magic) {
					return "", read_total, .Magic_Mismatch
				}
				magic_checked = true
			}
			sha2.update(&context_256, buffer[:read])
			read_total += i64(read)
		}
		if unreadable == io.Error.EOF {
			break
		}
		if unreadable != nil {
			return "", read_total, .Unreadable
		}
		if read == 0 {
			return "", read_total, .Unreadable
		}
	}
	return hex_digest(&context_256, allocator), read_total, .None
}

@(private)
@(require_results)
head_matches :: proc(read: []u8, magic: []u8) -> bool {
	assert(len(magic) > 0, "there is no magic here to match against")

	if len(read) < len(magic) {
		return false
	}
	for b, i in magic {
		if read[i] != b {
			return false
		}
	}
	return true
}

// `DIGEST_HEX_CHARS`/`hex_digest` (below) twin `artifact.model.hex_digest`,
// reached through `artifact.digest_of_bounded` (src/artifact/model.odin) --
// recorded duplication per #188: this package must not import artifact's
// world, and a leaf package for this ~30-line procedure was refuted at the
// 2026-08-06 review.
#assert(DIGEST_HEX_CHARS == 2 * sha2.DIGEST_SIZE_256)

@(private)
DIGEST_HEX_CHARS :: 64

@(private)
@(require_results)
hex_digest :: proc(context_256: ^sha2.Context_256, allocator: mem.Allocator) -> (digest: string) {
	assert(context_256 != nil, "there is no hash here to finish")
	assert(allocator.procedure != nil, "the digest outlives this procedure and needs an allocator")
	defer assert(
		len(digest) == DIGEST_HEX_CHARS,
		"a digest rendered to the wrong number of characters",
	)

	sum: [sha2.DIGEST_SIZE_256]u8
	sha2.final(context_256, sum[:])
	return string(hex.encode(sum[:], allocator))
}
