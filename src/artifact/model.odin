#+vet explicit-allocators
package artifact

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:io"
import "core:mem"
import "core:os"
import "core:strings"
import "core:thread"
import "transcibr:child"
import "transcibr:crashlog"
import "transcibr:process"

// Hashing a Model costs a pass over upwards of a gigabyte, so its identity is
// settled once per Batch rather than once per Recording.

// On the stack and never allocated: a megabyte would halve the reads over a
// gigabyte-and-a-half file and is a megabyte of stack on a worker thread.
MODEL_READ_BYTES :: 64 * 1024

// The Model struct itself lives in sidecar.odin, the pure half sidecar_of
// consumes it from -- ADR-0032.

Model_Fault :: enum u8 {
	None = 0,
	// Why the Engine cannot open such a path: ADR-0025.
	Path_Not_Ascii,
	Unreadable,
	Did_Not_Finish,
	// A thread to hash it on could not be started at all -- distinct from
	// `.Unreadable`, which `digest_of_bounded` also returns for a Model that
	// genuinely will not open. Collapsing the two pointed an operator whose
	// Batch is thread-starved (issue #12's exhaustion case) at the NAS, when
	// nothing here has actually looked at the Model yet (PR #64's third
	// review, finding 11; `transcibr:child`'s `Read_Fault.Not_Started` is the
	// worked example this follows).
	Not_Started,
}

// `--model-file` is hand-typed, the same class of input `--from-json` is
// (issue #27), and a Model up to roughly 1.5 GB is the normal case rather
// than an edge one: weights kept on a NAS is how a shared machine stores
// them. Grounded rather than assumed: ten minutes only requires a sustained
// 2.6 MB/s to finish hashing 1.5 GB, generous margin against a real disk or
// a working network share -- the wedge this bound exists to catch is a share
// answering nothing at all, not one running slow.
MODEL_READ_BOUND_MS :: i64(10 * 60 * 1000)

#assert(MODEL_READ_BOUND_MS > 0)

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

	digest, bytes, unreadable := digest_of_bounded(resolved, MODEL_READ_BOUND_MS, allocator)
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

// `digest_of` opens the Model and reads the whole of it, so it runs on its
// own thread and this bound is what keeps a wedged one -- a NAS that stops
// answering mid-hash -- from blocking a Batch forever, the same way
// `child.read_bounded` bounds a read of an Engine's output (issue #27).
//
// The job's own fields live on `child.job_allocator`'s heap rather than the
// caller's `allocator`, for the identical reason `child.Read_Job` does
// (src/child/read.odin): a thread this package cannot safely stop needs
// somewhere to write that outlives whatever allocator the caller happens to
// have handed in.
@(private)
Digest_Job :: struct {
	path:   string,
	digest: Digest,
	bytes:  i64,
	fault:  Model_Fault,
}

// A fresh `core:thread` context arrives without the crash hook; see
// `transcibr:child`'s `read_worker` doc comment for why the line is written
// here rather than installed once by a helper.
@(private)
digest_worker :: proc(data: rawptr) {
	context.assertion_failure_proc = crashlog.assertion_hook
	job := (^Digest_Job)(data)
	assert(job != nil, "a digest thread was started with no job to hash")
	assert(len(job.path) > 0, "a digest thread was started with no path to hash")

	job.digest, job.bytes, job.fault = digest_of(job.path, child.job_allocator())
}

@(private)
@(require_results)
digest_of_bounded :: proc(
	path: string,
	bound_ms: i64,
	allocator: mem.Allocator,
) -> (
	digest: Digest,
	bytes: i64,
	fault: Model_Fault,
) {
	assert(len(path) > 0, "there is no file here to hash")
	assert(bound_ms > 0, "a hash given no time at all cannot do anything")
	assert(allocator.procedure != nil, "the digest outlives this procedure and needs an allocator")

	job := new(Digest_Job, child.job_allocator())
	job.path = strings.clone(path, child.job_allocator())

	context.allocator = child.job_allocator()
	t := thread.create_and_start_with_data(job, digest_worker)
	if t == nil {
		delete(job.path, child.job_allocator())
		free(job, child.job_allocator())
		return "", 0, .Not_Started
	}

	finished, reclaim := child.await_and_reclaim(t, bound_ms)
	if finished {
		return digest_finished(t, job, allocator)
	}
	if reclaim {
		release_digest_job(t, job)
	}
	return "", 0, .Did_Not_Finish
}

@(private)
release_digest_job :: proc(t: ^thread.Thread, job: ^Digest_Job) {
	assert(t != nil, "there is no thread here to release")
	assert(job != nil, "there is no job here to release")
	assert(thread.is_done(t), "release_digest_job called on a thread that never finished")

	delete(string(job.digest), child.job_allocator())
	delete(job.path, child.job_allocator())
	free(job, child.job_allocator())
	thread.destroy(t)
}

@(private)
@(require_results)
digest_finished :: proc(
	t: ^thread.Thread,
	job: ^Digest_Job,
	allocator: mem.Allocator,
) -> (
	digest: Digest,
	bytes: i64,
	fault: Model_Fault,
) {
	assert(t != nil, "there is no thread here to close out")
	assert(job != nil, "a finished hash has no job to read its answer from")

	fault = job.fault
	bytes = job.bytes
	if fault == .None {
		digest = Digest(strings.clone(string(job.digest), allocator))
	}
	release_digest_job(t, job)
	return
}

// `hex_digest` (below) twins `net.hex_digest` (src/net/verify.odin) --
// recorded duplication per #188's maintainer ruling. Both import directions
// were weighed, not just one: `net` must not import artifact's world; and
// the reverse -- `net` exporting `hex_digest` for `artifact` to import --
// has no cycle either, but was rejected because it makes model-identity
// hashing, a leaf concern of this package's own domain, depend on `net`'s
// whole download-integrity footprint (the network client, transfer, resume)
// for one hash-finishing helper artifact does not otherwise need. A leaf package
// for this ~12-line procedure buys net line growth and justfile/vet/test
// ceremony for no shared consumer either way.
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
	case .Did_Not_Finish:
		return child.DID_NOT_FINISH_SAYS
	case .Not_Started:
		return "a thread to hash it on could not be started"
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

	return process.batch_setup_message(model, says, allocator)
}
