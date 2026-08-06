#+vet explicit-allocators
package net

import "core:mem"
import "core:os"

@(private)
Fetch_Result :: struct {
	fault:  Download_Fault,
	status: int,
}

// A body's bytes, decoupled from any live network request handle so
// `receive_and_write` and `write_body` are provable against a local fixture
// rather than a socket (round 1 review finding 3): the file that spells the
// network API by name (README.md, Network access) is the only caller that
// ever fills `user` with a real request handle; a test fills it with
// whatever a fake `read` closes over instead.
Body_Source :: struct {
	read: proc(buffer: []u8, user: rawptr) -> (read: u32, ok: bool),
	user: rawptr,
}

// The status line decides whether the response is trusted at all before a
// single body byte is written -- an unauthorised response is reported as
// unavailable and never reaches anything that could prompt for credentials
// (ADR-0015). A stale, already-complete part file answering 416 is reported
// distinctly rather than folded into the generic unexpected-status fault,
// so a caller can tell the two apart.
@(private)
@(require_results)
receive_and_write :: proc(
	status: int,
	existing: i64,
	spec: Download_Spec,
	part: string,
	source: Body_Source,
	progress: Progress_Callback,
	progress_user: rawptr,
) -> (
	result: Fetch_Result,
) {
	assert(len(part) > 0, "there is nowhere here to write a received body")
	assert(source.read != nil, "there is no body source here to read a response from")

	result.status = status
	outcome := classify_response(existing > 0, status)
	switch outcome {
	case .Unavailable:
		result.fault = .Unavailable
	case .Failed:
		result.fault = .Unexpected_Status
	case .Range_Not_Satisfiable:
		result.fault = .Stale_Part
	case .Fresh, .Restarted:
		if !write_body(source, part, {.Write, .Create, .Trunc}, 0, spec, progress, progress_user) {
			result.fault = .Write_Failed
		}
	case .Resumed:
		if !write_body(source, part, {.Write, .Append}, existing, spec, progress, progress_user) {
			result.fault = .Write_Failed
		}
	}
	return
}

@(private)
VERIFY_READ_BYTES_NETWORK :: 64 * 1024

@(private)
@(require_results)
write_body :: proc(
	source: Body_Source,
	part: string,
	flags: os.File_Flags,
	base: i64,
	spec: Download_Spec,
	progress: Progress_Callback,
	progress_user: rawptr,
) -> bool {
	assert(source.read != nil, "there is no body source here to read a body from")
	assert(len(part) > 0, "there is nowhere here to write a body")

	handle, unopenable := os.open(part, flags)
	if unopenable != nil {
		return false
	}
	defer os.close(handle)

	buffer: [VERIFY_READ_BYTES_NETWORK]u8 = ---
	written := base
	for {
		read, ok := source.read(buffer[:], source.user)
		if !ok {
			return false
		}
		if read == 0 {
			break
		}
		put, unwritable := os.write(handle, buffer[:read])
		if unwritable != nil || put != int(read) {
			return false
		}
		written += i64(read)
		if progress != nil {
			progress(
				Download_Progress{bytes_received = written, total_bytes = spec.expected_bytes},
				progress_user,
			)
		}
	}
	return true
}

// Verification and placement, kept apart from `fetch_body` so both this
// procedure and the part-file deletion on a failed verification (round 1
// review finding 3) are provable without a socket: nothing below this line
// ever touches the network, only the fetched part file already on disk.
@(private)
@(require_results)
finalize_download :: proc(
	part: string,
	destination: string,
	spec: Download_Spec,
	allocator: mem.Allocator,
) -> (
	result: Download_Result,
) {
	assert(len(part) > 0, "there is no part file here to finalize")
	assert(len(destination) > 0, "there is nowhere here to place a finished download")

	result.verify = verify_download(part, spec, allocator)
	if result.verify.fault != .None {
		os.remove(part)
		result.fault = .Verify_Failed
		return
	}
	if os.rename(part, destination) != nil {
		os.remove(part)
		result.fault = .Not_Placed
	}
	return
}
