#+vet explicit-allocators
package crashlog

import win32 "core:sys/windows"
import "core:testing"

// Fixed FILETIME values, computed independently of this package (issue #176
// / ADR-0039 D3): each pair is a UTC wall-clock instant hand-converted to
// 100ns ticks since 1601-01-01, split into the DWORD halves `FILETIME`
// carries. None of these round-trip through `GetSystemTimeAsFileTime` --
// that would make the test check the formatter against itself.

@(test)
format_timestamp_renders_a_leap_day :: proc(t: ^testing.T) {
	buf: [20]byte
	ft := win32.FILETIME {
		dwLowDateTime  = 1021902848,
		dwHighDateTime = 31091362,
	}
	testing.expect_value(t, format_timestamp(buf[:], ft), "2024-02-29T00:00:00Z")
}

@(test)
format_timestamp_renders_a_year_boundary_going_forward :: proc(t: ^testing.T) {
	buf: [20]byte
	ft := win32.FILETIME {
		dwLowDateTime  = 627916800,
		dwHighDateTime = 29316075,
	}
	testing.expect_value(t, format_timestamp(buf[:], ft), "2000-01-01T00:00:00Z")
}

@(test)
format_timestamp_renders_a_year_boundary_going_backward :: proc(t: ^testing.T) {
	buf: [20]byte
	ft := win32.FILETIME {
		dwLowDateTime  = 617916800,
		dwHighDateTime = 29316075,
	}
	testing.expect_value(t, format_timestamp(buf[:], ft), "1999-12-31T23:59:59Z")
}

// Not tested against the FILETIME epoch itself (1601-01-01, ticks=0):
// `win32.FILETIME_as_unix_nanoseconds` multiplies its 100ns tick count by
// 100 to reach nanoseconds, and 369 years of nanoseconds overflows i64
// (measured: ticks=0 comes back as 2185-07-21, not 1601-01-01). That
// overflow lives in `core:sys/windows` itself, not in this file's own
// arithmetic, and no FILETIME `GetSystemTimeAsFileTime` ever returns is
// within three centuries of it -- the two year-boundary fixtures above and
// the leap day already cover the civil-calendar arithmetic this file adds.

@(test)
format_timestamp_renders_an_ordinary_instant :: proc(t: ^testing.T) {
	buf: [20]byte
	ft := win32.FILETIME {
		dwLowDateTime  = 655595520,
		dwHighDateTime = 31270505,
	}
	testing.expect_value(t, format_timestamp(buf[:], ft), "2026-08-07T12:34:56Z")
}
