#+vet explicit-allocators
// Package net drives the one HTTPS download transcibr performs -- the
// engine archive and the model, each behind a confirmation dialog
// (ADR-0014) -- resumably, and refuses to use what it fetched unless it
// verifies (ADR-0015). This file is the only one that ever spells the
// network API by name; `manifest.odin`, `verify.odin` and `resume.odin`
// hold everything provable without a socket, and carry this package's
// tests. `docs/reference/winhttp-download.odin` was the working prototype
// this absorbs; see its own header for the facts it established about this
// compiler's WinHTTP bindings.
package net

import "core:mem"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"

HINTERNET :: win32.LPVOID

WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY :: 4
WINHTTP_FLAG_SECURE :: 0x00800000
WINHTTP_QUERY_STATUS_CODE :: 19
WINHTTP_QUERY_FLAG_NUMBER :: 0x20000000
WINHTTP_ADDREQ_FLAG_ADD :: 0x20000000
INTERNET_DEFAULT_HTTPS_PORT :: 443

// Buffers the caller owns: URL_COMPONENTS holds pointers into them, so
// returning the struct by value carries pointers out of whichever frame
// filled it and they must outlive it.
URL_COMPONENTS :: struct {
	dwStructSize:      win32.DWORD,
	lpszScheme:        win32.wstring,
	dwSchemeLength:    win32.DWORD,
	nScheme:           win32.DWORD,
	lpszHostName:      win32.wstring,
	dwHostNameLength:  win32.DWORD,
	nPort:             win32.WORD,
	lpszUserName:      win32.wstring,
	dwUserNameLength:  win32.DWORD,
	lpszPassword:      win32.wstring,
	dwPasswordLength:  win32.DWORD,
	lpszUrlPath:       win32.wstring,
	dwUrlPathLength:   win32.DWORD,
	lpszExtraInfo:     win32.wstring,
	dwExtraInfoLength: win32.DWORD,
}

foreign import winhttp "system:Winhttp.lib"

@(default_calling_convention = "system")
foreign winhttp {
	WinHttpOpen :: proc(pszAgentW: win32.LPCWSTR, dwAccessType: win32.DWORD, pszProxyW: win32.LPCWSTR, pszProxyBypassW: win32.LPCWSTR, dwFlags: win32.DWORD) -> HINTERNET ---
	WinHttpConnect :: proc(hSession: HINTERNET, pswzServerName: win32.LPCWSTR, nServerPort: win32.WORD, dwReserved: win32.DWORD) -> HINTERNET ---
	WinHttpOpenRequest :: proc(hConnect: HINTERNET, pwszVerb: win32.LPCWSTR, pwszObjectName: win32.LPCWSTR, pwszVersion: win32.LPCWSTR, pwszReferrer: win32.LPCWSTR, ppwszAcceptTypes: ^win32.LPCWSTR, dwFlags: win32.DWORD) -> HINTERNET ---
	WinHttpAddRequestHeaders :: proc(hRequest: HINTERNET, lpszHeaders: win32.LPCWSTR, dwHeadersLength: win32.DWORD, dwModifiers: win32.DWORD) -> win32.BOOL ---
	WinHttpSendRequest :: proc(hRequest: HINTERNET, lpszHeaders: win32.LPCWSTR, dwHeadersLength: win32.DWORD, lpOptional: win32.LPVOID, dwOptionalLength: win32.DWORD, dwTotalLength: win32.DWORD, dwContext: win32.DWORD_PTR) -> win32.BOOL ---
	WinHttpReceiveResponse :: proc(hRequest: HINTERNET, lpReserved: win32.LPVOID) -> win32.BOOL ---
	WinHttpQueryHeaders :: proc(hRequest: HINTERNET, dwInfoLevel: win32.DWORD, pwszName: win32.LPCWSTR, lpBuffer: win32.LPVOID, lpdwBufferLength: ^win32.DWORD, lpdwIndex: ^win32.DWORD) -> win32.BOOL ---
	WinHttpReadData :: proc(hRequest: HINTERNET, lpBuffer: win32.LPVOID, dwNumberOfBytesToRead: win32.DWORD, lpdwNumberOfBytesRead: ^win32.DWORD) -> win32.BOOL ---
	WinHttpCloseHandle :: proc(hInternet: HINTERNET) -> win32.BOOL ---
	WinHttpSetTimeouts :: proc(hInternet: HINTERNET, nResolveTimeout: i32, nConnectTimeout: i32, nSendTimeout: i32, nReceiveTimeout: i32) -> win32.BOOL ---
	WinHttpCrackUrl :: proc(pwszUrl: win32.LPCWSTR, dwUrlLength: win32.DWORD, dwFlags: win32.DWORD, lpUrlComponents: ^URL_COMPONENTS) -> win32.BOOL ---
}

Download_Fault :: enum u8 {
	None = 0,
	Not_Secure,
	Unreachable,
	Unavailable,
	Unexpected_Status,
	Write_Failed,
	Verify_Failed,
	Not_Placed,
}

Download_Progress :: struct {
	bytes_received: i64,
	total_bytes:    i64,
}

Progress_Callback :: #type proc(progress: Download_Progress, user: rawptr)

Download_Result :: struct {
	fault:  Download_Fault,
	status: int,
	verify: Verify_Result,
}

// The one entry point this package exposes for actually moving bytes.
// Resumes when `destination`'s part file already holds some, always
// against `spec.url` -- never a redirect WinHTTP followed on an earlier
// attempt, because nothing in this package ever stores one (ADR-0015).
@(require_results)
download :: proc(
	spec: Download_Spec,
	destination: string,
	allocator: mem.Allocator,
	progress: Progress_Callback = nil,
	progress_user: rawptr = nil,
) -> (
	result: Download_Result,
) {
	assert(len(spec.url) > 0, "there is nothing here to download")
	assert(len(destination) > 0, "there is nowhere here to download to")
	assert(
		allocator.procedure != nil,
		"a finished download's verification outlives this procedure",
	)

	if !strings.has_prefix(spec.url, "https://") {
		result.fault = .Not_Secure
		return
	}

	part := part_path(destination, allocator)
	defer delete(part, allocator)
	existing := existing_partial_bytes(part, allocator)

	fetched := fetch_body(spec, existing, part, progress, progress_user)
	if fetched.fault != .None {
		result.fault = fetched.fault
		result.status = fetched.status
		return
	}

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

@(private)
Fetch_Result :: struct {
	fault:  Download_Fault,
	status: int,
}

// The WinHTTP conversation, session through response body, kept to one
// procedure so the three handles it opens are each closed by the code that
// opened them rather than smeared across openers of their own (the same
// call this repository's prototype made). Split out from `download` purely
// to hold the 70-line procedure limit; the two together are the seam.
@(private)
@(require_results)
fetch_body :: proc(
	spec: Download_Spec,
	existing: i64,
	part: string,
	progress: Progress_Callback,
	progress_user: rawptr,
) -> (
	result: Fetch_Result,
) {
	assert(len(spec.url) > 0, "there is nothing here to fetch")
	assert(len(part) > 0, "there is nowhere here to write a fetched body")

	host_buf: [256]u16
	path_buf: [1024]u16
	uc, cracked := crack_canonical_url(spec.url, host_buf[:], path_buf[:])
	if !cracked {
		result.fault = .Unreachable
		return
	}

	session := WinHttpOpen(
		win32.utf8_to_wstring("transcibr/0.1", context.temp_allocator),
		WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
		nil,
		nil,
		0,
	)
	if session == nil {
		result.fault = .Unreachable
		return
	}
	defer WinHttpCloseHandle(session)
	WinHttpSetTimeouts(session, 10_000, 20_000, 30_000, 60_000)

	request, opened := open_and_send(session, uc, existing)
	if !opened {
		result.fault = .Unreachable
		return
	}
	defer WinHttpCloseHandle(request)

	return receive_and_write(request, existing, spec, part, progress, progress_user)
}

@(private)
@(require_results)
open_and_send :: proc(
	session: HINTERNET,
	uc: URL_COMPONENTS,
	existing: i64,
) -> (
	request: HINTERNET,
	ok: bool,
) {
	assert(session != nil, "there is no session here to connect through")

	connect := WinHttpConnect(session, uc.lpszHostName, INTERNET_DEFAULT_HTTPS_PORT, 0)
	if connect == nil {
		return nil, false
	}
	defer WinHttpCloseHandle(connect)

	request = WinHttpOpenRequest(
		connect,
		win32.utf8_to_wstring("GET", context.temp_allocator),
		uc.lpszUrlPath,
		nil,
		nil,
		nil,
		WINHTTP_FLAG_SECURE,
	)
	if request == nil {
		return nil, false
	}

	if existing > 0 {
		header := range_header(existing, context.temp_allocator)
		defer delete(header, context.temp_allocator)
		if !WinHttpAddRequestHeaders(
			request,
			win32.utf8_to_wstring(header, context.temp_allocator),
			max(u32),
			WINHTTP_ADDREQ_FLAG_ADD,
		) {
			WinHttpCloseHandle(request)
			return nil, false
		}
	}

	if !WinHttpSendRequest(request, nil, 0, nil, 0, 0, 0) ||
	   !WinHttpReceiveResponse(request, nil) {
		WinHttpCloseHandle(request)
		return nil, false
	}
	return request, true
}

// The status line decides whether the response is trusted at all before a
// single body byte is written -- an unauthorised response is reported as
// unavailable and never reaches anything that could prompt for
// credentials (ADR-0015).
@(private)
@(require_results)
receive_and_write :: proc(
	request: HINTERNET,
	existing: i64,
	spec: Download_Spec,
	part: string,
	progress: Progress_Callback,
	progress_user: rawptr,
) -> (
	result: Fetch_Result,
) {
	assert(request != nil, "there is no request here to read a response from")

	result.status = response_status(request)
	outcome := classify_response(existing > 0, result.status)
	switch outcome {
	case .Unavailable:
		result.fault = .Unavailable
		return
	case .Failed:
		result.fault = .Unexpected_Status
		return
	case .Fresh, .Restarted:
		if !write_body(
			request,
			part,
			{.Write, .Create, .Trunc},
			0,
			spec,
			progress,
			progress_user,
		) {
			result.fault = .Write_Failed
		}
	case .Resumed:
		if !write_body(request, part, {.Write, .Append}, existing, spec, progress, progress_user) {
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
	request: HINTERNET,
	part: string,
	flags: os.File_Flags,
	base: i64,
	spec: Download_Spec,
	progress: Progress_Callback,
	progress_user: rawptr,
) -> bool {
	assert(request != nil, "there is no request here to read a body from")
	assert(len(part) > 0, "there is nowhere here to write a body")

	handle, unopenable := os.open(part, flags)
	if unopenable != nil {
		return false
	}
	defer os.close(handle)

	buffer: [VERIFY_READ_BYTES_NETWORK]u8 = ---
	written := base
	for {
		read: win32.DWORD
		if !WinHttpReadData(request, &buffer[0], len(buffer), &read) {
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

@(private)
@(require_results)
response_status :: proc(request: HINTERNET) -> int {
	assert(request != nil, "there is no response here to read a status from")

	status: win32.DWORD
	size := win32.DWORD(size_of(win32.DWORD))
	WinHttpQueryHeaders(
		request,
		WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
		nil,
		&status,
		&size,
		nil,
	)
	return int(status)
}

@(private)
@(require_results)
crack_canonical_url :: proc(
	url: string,
	host_buf: []u16,
	path_buf: []u16,
) -> (
	uc: URL_COMPONENTS,
	ok: bool,
) {
	assert(len(url) > 0, "there is no URL here to crack")
	assert(len(host_buf) > 0, "a cracked URL needs somewhere to write the host name")
	assert(len(path_buf) > 0, "a cracked URL needs somewhere to write the path")

	uc.dwStructSize = size_of(URL_COMPONENTS)
	uc.lpszHostName = cast(win32.wstring)&host_buf[0]
	uc.dwHostNameLength = win32.DWORD(len(host_buf))
	uc.lpszUrlPath = cast(win32.wstring)&path_buf[0]
	uc.dwUrlPathLength = win32.DWORD(len(path_buf))
	if !WinHttpCrackUrl(win32.utf8_to_wstring(url, context.temp_allocator), 0, 0, &uc) {
		return uc, false
	}
	return uc, true
}
