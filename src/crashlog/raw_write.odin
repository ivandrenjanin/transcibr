#+vet explicit-allocators
package crashlog

import "base:runtime"
import win32 "core:sys/windows"

// Every helper in this file is `"contextless"` and allocates nothing, because
// every caller of it is either the exception filter (no context at all, and
// possibly running with a corrupt heap) or the assertion hook, which the
// maintainer ruling holds to the same no-allocation bar even though it does
// have a context. `win32.WriteFile` on the handle `install` opened ahead of
// time is the entire mechanism -- CLAUDE.md's Windows notes name a
// pre-opened handle as one of MiniDumpWriteDump's documented constraints, and
// the same constraint is why this package never opens a handle inside a
// hook.

@(private)
write_bytes :: proc "contextless" (h: win32.HANDLE, bytes: []byte) {
	runtime.assert_contextless(h != nil, "cannot write a crash log line with no open handle")

	written: win32.DWORD
	win32.WriteFile(h, raw_data(bytes), win32.DWORD(len(bytes)), &written, nil)
}

@(private)
write_str :: proc "contextless" (h: win32.HANDLE, s: string) {
	write_bytes(h, transmute([]byte)s)
}

// Formats into the caller's own buffer, never the heap: `buf` must outlive
// the returned string, which borrows it. 20 bytes covers "0x" plus sixteen
// hex digits, the widest a 64-bit value ever needs.
@(private)
@(require_results)
format_hex :: proc "contextless" (buf: []byte, value: u64) -> string {
	runtime.assert_contextless(
		len(buf) >= 18,
		"hex buffer too small for a 64-bit value with its 0x prefix",
	)

	digits := "0123456789abcdef"
	i := len(buf)
	v := value
	for {
		i -= 1
		buf[i] = digits[v & 0xf]
		v >>= 4
		if v == 0 {
			break
		}
	}
	i -= 1
	buf[i] = 'x'
	i -= 1
	buf[i] = '0'
	return string(buf[i:])
}

// 20 bytes covers every i64, sign included.
@(private)
@(require_results)
format_int :: proc "contextless" (buf: []byte, value: i64) -> string {
	runtime.assert_contextless(
		len(buf) >= 20,
		"decimal buffer too small for a 64-bit value with its sign",
	)

	neg := value < 0
	v := u64(-value) if neg else u64(value)
	i := len(buf)
	for {
		i -= 1
		buf[i] = '0' + u8(v % 10)
		v /= 10
		if v == 0 {
			break
		}
	}
	if neg {
		i -= 1
		buf[i] = '-'
	}
	return string(buf[i:])
}
