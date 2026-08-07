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

// Rounds toward negative infinity, unlike Odin's `/` which truncates toward
// zero -- civil-calendar arithmetic on a FILETIME before 1970 (the epoch
// `win32.FILETIME_as_unix_nanoseconds` converts against) needs negative
// operands divided correctly or a leap day the wrong side of midnight lands
// on the wrong date.
@(private)
@(require_results)
floor_div :: proc "contextless" (a, b: i64) -> i64 {
	runtime.assert_contextless(b != 0, "cannot floor-divide by zero")

	q := a / b
	r := a % b
	if r != 0 && ((r < 0) != (b < 0)) {
		q -= 1
	}
	return q
}

// Howard Hinnant's `civil_from_days`, days since the Unix epoch
// (1970-01-01) to a proleptic-Gregorian (year, month, day) -- correct for
// any `z`, including the deeply negative values a 1601-01-01 FILETIME
// epoch produces. Pure integer arithmetic, no table, no libc call: exactly
// the kind of leaf math this file's `format_hex`/`format_int` already are.
@(private)
@(require_results)
civil_from_days :: proc "contextless" (z: i64) -> (year: i64, month: i64, day: i64) {
	zz := z + 719468
	era := floor_div(zz, 146097)
	doe := zz - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	y := yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d := doy - (153 * mp + 2) / 5 + 1
	m := (mp + 3) if mp < 10 else (mp - 9)
	year = (y + 1) if m <= 2 else y
	month = m
	day = d
	return
}

// Zero-pads `value` into `buf`, which must be exactly `width` bytes -- the
// same caller-owned-buffer discipline `format_hex`/`format_int` use, just
// fixed-width rather than shrink-to-fit, because `format_timestamp` below
// needs every field flush against its neighboring `-`/`T`/`:` separators.
@(private)
write_padded :: proc "contextless" (buf: []byte, value: i64, width: int) {
	runtime.assert_contextless(len(buf) == width, "padded field width does not match its buffer")
	runtime.assert_contextless(value >= 0, "a civil calendar field cannot be negative")

	v := value
	for i := width - 1; i >= 0; i -= 1 {
		buf[i] = '0' + u8(v % 10)
		v /= 10
	}
}

// UTC ISO-8601, second resolution: "YYYY-MM-DDTHH:MM:SSZ", always exactly
// 20 bytes (ADR-0039 D3). `win32.FILETIME_as_unix_nanoseconds` is
// `core:sys/windows`'s own epoch conversion -- bound at the pin -- so only
// the civil-calendar arithmetic on top of its result is this package's own
// to get right, which is why it is split into `floor_div`/`civil_from_days`
// and tested against fixed FILETIME values rather than the live clock.
@(require_results)
format_timestamp :: proc "contextless" (buf: []byte, ft: win32.FILETIME) -> string {
	runtime.assert_contextless(
		len(buf) >= 20,
		"timestamp buffer too small for YYYY-MM-DDTHH:MM:SSZ",
	)

	unix_seconds := floor_div(win32.FILETIME_as_unix_nanoseconds(ft), 1_000_000_000)
	days := floor_div(unix_seconds, 86400)
	secs_of_day := unix_seconds - days * 86400

	year, month, day := civil_from_days(days)
	hour := secs_of_day / 3600
	minute := (secs_of_day % 3600) / 60
	second := secs_of_day % 60

	write_padded(buf[0:4], year, 4)
	buf[4] = '-'
	write_padded(buf[5:7], month, 2)
	buf[7] = '-'
	write_padded(buf[8:10], day, 2)
	buf[10] = 'T'
	write_padded(buf[11:13], hour, 2)
	buf[13] = ':'
	write_padded(buf[14:16], minute, 2)
	buf[16] = ':'
	write_padded(buf[17:19], second, 2)
	buf[19] = 'Z'
	return string(buf[:20])
}
