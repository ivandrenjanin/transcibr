// REFERENCE PROTOTYPE - not part of the build.
//
// A minimal WinHTTP ranged GET, compiled and run against Odin
// dev-2026-07-nightly:819fdc7. It performed a real HTTP 206 range request
// through GitHub's cross-host redirect and read back the requested bytes.
//
// Kept because it establishes facts that are otherwise expensive to rediscover:
//   - Odin core has no HTTP client and no TLS. core:net is Berkeley sockets
//     only; there is no core:http. core:sys/windows binds no WinHTTP at all
//     (the only "winhttp" hits in the package are error-code comments in
//     winerror.odin), so every entry point below is hand-declared.
//   - win32.LPWSTR is ^u16 while LPCWSTR is cstring16 in this compiler, so
//     URL_COMPONENTS string fields must be win32.wstring and buffer pointers
//     must be cast - otherwise call sites do not typecheck.
//   - Content-Range is read with WINHTTP_QUERY_CUSTOM (65535) plus the header
//     name. A WINHTTP_QUERY_CONTENT_RANGE constant of 16 was removed from this
//     file: 16 is WINHTTP_QUERY_LINK. Verify any query constant against
//     winhttp.h before using it.
//   - The Range header set before WinHttpSendRequest survives the redirect;
//     manual redirect chasing is unnecessary.
//
// Not yet handled here: resume against a .part file, SHA-256 verification,
// cancellation, and the fact that redirected CDN URLs expire in about an hour
// and must never be persisted for resume.
package whtest

import "core:fmt"
import win32 "core:sys/windows"

foreign import winhttp "system:Winhttp.lib"

HINTERNET :: win32.LPVOID

WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY :: 4
WINHTTP_FLAG_SECURE :: 0x00800000
WINHTTP_QUERY_CONTENT_LENGTH :: 5
WINHTTP_QUERY_CUSTOM :: 65535
WINHTTP_QUERY_STATUS_CODE :: 19
WINHTTP_QUERY_FLAG_NUMBER :: 0x20000000
WINHTTP_ADDREQ_FLAG_ADD :: 0x20000000
INTERNET_DEFAULT_HTTPS_PORT :: 443

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

// One URL cracked into CALLER-owned buffers.
//
// The buffers are the caller's on purpose: URL_COMPONENTS holds pointers into
// them, so returning the struct by value carries pointers out of this frame and
// they must outlive it.
crack_url :: proc(
	url: string,
	host_buf: []u16,
	path_buf: []u16,
) -> (
	uc: URL_COMPONENTS,
	ok: bool,
) {
	uc.dwStructSize = size_of(URL_COMPONENTS)
	uc.lpszHostName = cast(win32.wstring)&host_buf[0]
	uc.dwHostNameLength = win32.DWORD(len(host_buf))
	uc.lpszUrlPath = cast(win32.wstring)&path_buf[0]
	uc.dwUrlPathLength = win32.DWORD(len(path_buf))
	if !WinHttpCrackUrl(win32.utf8_to_wstring(url), 0, 0, &uc) {
		fmt.println("CrackUrl FAILED", win32.GetLastError())
		return uc, false
	}
	fmt.printf(
		"CrackUrl ok: host=%s port=%d\n",
		win32.wstring_to_utf8_alloc(uc.lpszHostName, int(uc.dwHostNameLength)) or_else "?",
		uc.nPort,
	)
	return uc, true
}

// The GET, with the header this spike exists to test. Added BEFORE
// WinHttpSendRequest, which is what makes it survive the cross-host redirect.
send_ranged_request :: proc(hRequest: HINTERNET, header: string) -> bool {
	if !WinHttpAddRequestHeaders(
		hRequest,
		win32.utf8_to_wstring(header),
		max(u32),
		WINHTTP_ADDREQ_FLAG_ADD,
	) {
		fmt.println("AddRequestHeaders FAILED", win32.GetLastError())
		return false
	}
	if !WinHttpSendRequest(hRequest, nil, 0, nil, 0, 0, 0) {
		fmt.println("SendRequest FAILED", win32.GetLastError())
		return false
	}
	if !WinHttpReceiveResponse(hRequest, nil) {
		fmt.println("ReceiveResponse FAILED", win32.GetLastError())
		return false
	}
	return true
}

// The status line as a number, which is what WINHTTP_QUERY_FLAG_NUMBER buys:
// without it the same query hands back the status as text.
response_status :: proc(hRequest: HINTERNET) -> win32.DWORD {
	status: win32.DWORD
	sz := win32.DWORD(size_of(win32.DWORD))
	WinHttpQueryHeaders(
		hRequest,
		WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
		nil,
		&status,
		&sz,
		nil,
	)
	return status
}

// Read with WINHTTP_QUERY_CUSTOM plus the header NAME, because there is no
// WINHTTP_QUERY_CONTENT_RANGE constant: 16, which looks like one, is
// WINHTTP_QUERY_LINK.
report_content_range :: proc(hRequest: HINTERNET) {
	cr_buf: [256]u16
	cr_sz := win32.DWORD(size_of(cr_buf))
	if WinHttpQueryHeaders(
		hRequest,
		WINHTTP_QUERY_CUSTOM,
		win32.utf8_to_wstring("Content-Range"),
		&cr_buf[0],
		&cr_sz,
		nil,
	) {
		fmt.println(
			"Content-Range =",
			win32.wstring_to_utf8_alloc(cast(win32.wstring)&cr_buf[0], 256) or_else "?",
		)
	} else {
		fmt.println("no Content-Range header")
	}
}

// Everything the response body holds, counted and thrown away. A read of zero
// bytes is the end of it; a failed read is reported and ends it too.
drain_body :: proc(hRequest: HINTERNET) -> (total: int) {
	buf: [8192]byte
	for {
		read: win32.DWORD
		if !WinHttpReadData(hRequest, &buf[0], len(buf), &read) {
			fmt.println("ReadData FAILED", win32.GetLastError())
			break
		}
		if read == 0 {
			break
		}
		total += int(read)
	}
	return total
}

main :: proc() {
	URL :: "https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-cublas-12.4.0-bin-x64.zip"
	RANGE :: "Range: bytes=1000-1099\r\n"

	// The three handles stay here, and so do their defers: a handle closed by
	// the procedure that opened it is closed before the next call needs it.
	host_buf: [256]u16
	path_buf: [1024]u16
	uc, cracked := crack_url(URL, host_buf[:], path_buf[:])
	if !cracked {
		return
	}

	hSession := WinHttpOpen(
		win32.utf8_to_wstring("transcibr/0.1"),
		WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
		nil,
		nil,
		0,
	)
	if hSession == nil {
		fmt.println("WinHttpOpen FAILED", win32.GetLastError())
		return
	}
	defer WinHttpCloseHandle(hSession)
	WinHttpSetTimeouts(hSession, 10_000, 20_000, 30_000, 60_000)

	hConnect := WinHttpConnect(hSession, uc.lpszHostName, INTERNET_DEFAULT_HTTPS_PORT, 0)
	if hConnect == nil {
		fmt.println("WinHttpConnect FAILED", win32.GetLastError())
		return
	}
	defer WinHttpCloseHandle(hConnect)

	hRequest := WinHttpOpenRequest(
		hConnect,
		win32.utf8_to_wstring("GET"),
		uc.lpszUrlPath,
		nil,
		nil,
		nil,
		WINHTTP_FLAG_SECURE,
	)
	if hRequest == nil {
		fmt.println("WinHttpOpenRequest FAILED", win32.GetLastError())
		return
	}
	defer WinHttpCloseHandle(hRequest)

	if !send_ranged_request(hRequest, RANGE) {
		return
	}

	fmt.println(
		"HTTP status =",
		response_status(hRequest),
		"  (206 => Range survived the cross-host redirect)",
	)
	report_content_range(hRequest)
	fmt.println("bytes read =", drain_body(hRequest))
}
