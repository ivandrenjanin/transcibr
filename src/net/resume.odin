#+vet explicit-allocators
package net

import "core:fmt"
import "core:mem"
import "core:os"

// What the status line of a response, read against whether this request
// asked to resume, decides to do next. Pure and given the status as a plain
// int rather than a live handle, so it is provable without a socket
// (ADR-0015's "provable without network").
Resume_Outcome :: enum u8 {
	Fresh,
	Resumed,
	Restarted,
	Unavailable,
	Failed,
}

// A 200 to a request that asked to resume means the server ignored the
// Range header (ADR-0015's "assert the resume actually resumed"): the
// caller must not append the body onto the partial file, only replace it.
// A 206 to a request that never asked to resume is refused rather than
// trusted, because nothing here ever sent the Range header that would make
// one meaningful.
@(require_results)
classify_response :: proc(requested_resume: bool, status: int) -> Resume_Outcome {
	switch status {
	case 200:
		if requested_resume {
			return .Restarted
		}
		return .Fresh
	case 206:
		if requested_resume {
			return .Resumed
		}
		return .Failed
	case 401, 403:
		return .Unavailable
	case:
		return .Failed
	}
}

// The canonical URL is the only URL this package ever keeps: there is no
// field anywhere in this package for a redirect target, so resume can only
// ever re-request the one URL a caller supplied (ADR-0015's "never persist
// a redirected URL for resume").
@(require_results)
part_path :: proc(destination: string, allocator: mem.Allocator) -> string {
	assert(len(destination) > 0, "there is no destination here to name a part file beside")
	assert(
		allocator.procedure != nil,
		"the part path outlives this procedure and needs an allocator",
	)

	built := fmt.aprintf("%s.part", destination, allocator = allocator)
	assert(
		len(built) > len(destination),
		"a part path must be longer than the destination it sits beside",
	)
	return built
}

// Zero when the part file does not exist yet, which is also the answer a
// fresh download reads as "nothing to resume".
@(require_results)
existing_partial_bytes :: proc(part: string, allocator: mem.Allocator) -> i64 {
	assert(len(part) > 0, "there is no part file here to measure")
	assert(allocator.procedure != nil, "stat needs an allocator even for a size it throws away")

	info, unstattable := os.stat(part, allocator)
	defer os.file_info_delete(info, allocator)
	if unstattable != nil {
		return 0
	}
	assert(info.size >= 0, "a part file measured a negative size")
	return info.size
}

// "Range: bytes=<n>-\r\n", the header the request-sending seam adds before
// sending -- never built for a fresh download, which asks for nothing and
// sends no Range header at all.
@(require_results)
range_header :: proc(existing_bytes: i64, allocator: mem.Allocator) -> string {
	assert(existing_bytes > 0, "a fresh download has nothing to resume and builds no Range header")
	assert(allocator.procedure != nil, "the header outlives this procedure and needs an allocator")

	return fmt.aprintf("Range: bytes=%d-\r\n", existing_bytes, allocator = allocator)
}
