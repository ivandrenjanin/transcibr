#+vet explicit-allocators
package crashlog

import "core:strings"
import "core:testing"
import "transcibr:testkit"

// The fourth line shape's golden byte pin (ADR-0039 D1): exact bytes, not a
// substring check, because `record_note_line` is new and has no drift risk
// yet to guard against -- the three crash line shapes' own tests are all
// `strings.contains` only because the crash-drill process around them adds
// bytes this package's tests do not control (a real stack trace's addresses,
// a real PDB path). Nothing outside this call adds anything to a `note`
// line, so the golden can be exact.
@(test)
record_note_line_writes_the_exact_pinned_bytes :: proc(t: ^testing.T) {
	dir := testkit.scratch_cache(t, "crashlog", "note_line", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	h, _, ok := open_log(dir, context.allocator)
	testing.expect(t, ok, "open_log refused a directory it should have been able to create")

	record_note_line(h.file, "2026-08-07T12:34:56Z", .Warn, "doctor", "ffmpeg not found")
	close_log(&h)

	text := read_log(t, dir)
	defer delete(text, context.allocator)
	testing.expect_value(t, text, "2026-08-07T12:34:56Z WARN doctor: ffmpeg not found\n")
}

@(test)
record_note_line_omits_the_colon_and_detail_when_detail_is_empty :: proc(t: ^testing.T) {
	dir := testkit.scratch_cache(t, "crashlog", "note_line_no_detail", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	h, _, ok := open_log(dir, context.allocator)
	testing.expect(t, ok, "open_log refused a directory it should have been able to create")

	record_note_line(h.file, "2026-08-07T12:34:56Z", .Info, "process start", "")
	close_log(&h)

	text := read_log(t, dir)
	defer delete(text, context.allocator)
	testing.expect_value(t, text, "2026-08-07T12:34:56Z INFO process start\n")
}

// `note` is the public, contextless entry point: it stamps the current
// time itself (through `format_timestamp`/`GetSystemTimeAsFileTime`), so
// this checks the shape around the stamp rather than the stamp's own exact
// value -- `format_timestamp`'s own tests already pin that arithmetic
// against fixed FILETIMEs.
@(test)
note_writes_a_line_through_the_open_handle :: proc(t: ^testing.T) {
	dir := testkit.scratch_cache(t, "crashlog", "note_call", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	h, _, ok := open_log(dir, context.allocator)
	testing.expect(t, ok, "open_log refused a directory it should have been able to create")

	previous := g_log
	g_log = h
	note(.Error, "batch start", "engine digest mismatch")
	g_log = previous
	close_log(&h)

	text := read_log(t, dir)
	defer delete(text, context.allocator)
	testing.expect(
		t,
		strings.contains(text, " ERROR batch start: engine digest mismatch\n"),
		"note did not write the expected level, subject and detail",
	)
	testing.expect(t, strings.contains(text, "T"), "note's line carries no timestamp at all")
}

// `note` is a fourth caller of the same writer the crash hooks use, and it
// has to tolerate being called before `install`/`register` ever ran --
// exactly the state every process starts in -- without asserting on a nil
// handle the way `write_bytes` itself would (A8 does not apply here since
// this is this package's own internal state, but the crash path's own "no
// handle, no write" discipline (hooks.odin's assertion_hook) is what this
// mirrors).
@(test)
note_is_silently_a_no_op_with_no_log_open :: proc(t: ^testing.T) {
	previous := g_log
	g_log = Log_Handle{}
	note(.Info, "process start", "")
	g_log = previous
}
