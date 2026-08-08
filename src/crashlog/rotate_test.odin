#+vet explicit-allocators
package crashlog

import "core:os"
import "core:strings"
import win32 "core:sys/windows"
import "core:testing"
import "transcibr:testkit"

// ADR-0039 D2, rotation at the bound: a log already at or over
// `LOG_CEILING_BYTES` when `open_log` runs is renamed to `transcibr.log.1`
// before the new handle is opened, leaving `transcibr.log` itself fresh.
@(test)
open_log_rotates_an_over_bound_log_to_generation_one :: proc(t: ^testing.T) {
	dir := testkit.made_scratch_cache(t, "crashlog", "rotate_over", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	path := strings.concatenate({dir, "\\", LOG_FILE_NAME}, context.allocator)
	defer delete(path, context.allocator)
	old := make([]byte, LOG_CEILING_BYTES + 1, context.allocator)
	defer delete(old, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(path, old) == nil,
		"could not plant an over-bound log fixture",
	)

	h, refusal, ok := open_log(dir, context.allocator)
	defer close_log(&h)
	testing.expect(t, ok, "open_log refused a directory it should have been able to create")
	testing.expect_value(t, refusal, Rotation_Refusal.None)

	generation_path := strings.concatenate({dir, "\\", LOG_FILE_NAME, ".1"}, context.allocator)
	defer delete(generation_path, context.allocator)
	gen_bytes, gen_err := os.read_entire_file(generation_path, context.allocator)
	defer delete(gen_bytes, context.allocator)
	testing.expect(t, gen_err == nil, "the rotated generation file was not created")
	testing.expect_value(t, len(gen_bytes), LOG_CEILING_BYTES + 1)

	fresh_bytes, fresh_err := os.read_entire_file(path, context.allocator)
	defer delete(fresh_bytes, context.allocator)
	testing.expect(t, fresh_err == nil, "open_log did not leave a fresh log file behind")
	testing.expect_value(t, len(fresh_bytes), 0)
}

// The companion case: a log under the bound is left exactly where it was,
// and never produces a generation file.
@(test)
open_log_leaves_an_under_bound_log_untouched :: proc(t: ^testing.T) {
	dir := testkit.made_scratch_cache(t, "crashlog", "rotate_under", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	path := strings.concatenate({dir, "\\", LOG_FILE_NAME}, context.allocator)
	defer delete(path, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(path, transmute([]byte)string("small")) == nil,
		"could not plant an under-bound log fixture",
	)

	h, refusal, ok := open_log(dir, context.allocator)
	defer close_log(&h)
	testing.expect(t, ok, "open_log refused a directory it should have been able to create")
	testing.expect_value(t, refusal, Rotation_Refusal.None)

	generation_path := strings.concatenate({dir, "\\", LOG_FILE_NAME, ".1"}, context.allocator)
	defer delete(generation_path, context.allocator)
	_, gen_err := os.read_entire_file(generation_path, context.allocator)
	testing.expect(t, gen_err != nil, "an under-bound log should never produce a generation file")

	text_bytes, text_err := os.read_entire_file(path, context.allocator)
	defer delete(text_bytes, context.allocator)
	testing.expect(t, text_err == nil, "the untouched log could not be read back")
	testing.expect_value(t, string(text_bytes), "small")
}

// ADR-0039 D2's "honest part": a second live transcibr already holding
// `transcibr.log` open (no `FILE_SHARE_DELETE`, by design) makes the rename
// fail. `open_log` still succeeds -- the new process opens the existing,
// still-oversize file in append mode -- and reports the refusal back rather
// than repairing it. The master plan's R25 row names this test.
@(test)
open_log_refuses_rotation_while_a_second_opener_holds_the_log :: proc(t: ^testing.T) {
	dir := testkit.made_scratch_cache(t, "crashlog", "rotate_refused", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	holder, holder_refusal, holder_ok := open_log(dir, context.allocator)
	defer close_log(&holder)
	testing.expect(t, holder_ok, "could not open the holder handle this fixture needs")
	testing.expect_value(t, holder_refusal, Rotation_Refusal.None)

	padding := make([]byte, LOG_CEILING_BYTES + 1, context.allocator)
	defer delete(padding, context.allocator)
	write_bytes(holder.file, padding)

	h, refusal, ok := open_log(dir, context.allocator)
	defer close_log(&h)
	testing.expect(
		t,
		ok,
		"a second opener should still get a usable log even when rotation is refused",
	)
	testing.expect_value(t, refusal, Rotation_Refusal.Second_Opener)

	previous := g_log
	g_log = h
	note(.Warn, "rotation refused", "a second process holds transcibr.log open")
	g_log = previous

	text := read_log(t, dir)
	defer delete(text, context.allocator)
	testing.expect(
		t,
		strings.contains(text, "WARN rotation refused"),
		"the refusal did not log a WARN line",
	)
}

// Fix round 1, issue #270 finding 2: a live probe against the real binary
// held only the DESTINATION generation file open (no `FILE_SHARE_DELETE`,
// with nothing at all holding the source), and the prior code still
// answered `.Second_Opener`'s fixed wording -- MoveFileExW's own
// `MOVEFILE_REPLACE_EXISTING` delete fails on the held destination with
// `ERROR_ACCESS_DENIED`, not `ERROR_SHARING_VIOLATION`, and no second
// transcibr exists in this scenario at all. This reproduces that exact
// shape and pins the classification to `.Unknown`.
@(test)
open_log_reports_an_unknown_cause_when_only_the_destination_is_held :: proc(t: ^testing.T) {
	dir := testkit.made_scratch_cache(t, "crashlog", "rotate_dest_held", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	path := strings.concatenate({dir, "\\", LOG_FILE_NAME}, context.allocator)
	defer delete(path, context.allocator)
	old := make([]byte, LOG_CEILING_BYTES + 1, context.allocator)
	defer delete(old, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(path, old) == nil,
		"could not plant an over-bound log fixture",
	)

	generation_path := strings.concatenate({dir, "\\", LOG_FILE_NAME, ".1"}, context.allocator)
	defer delete(generation_path, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(generation_path, transmute([]byte)string("stale generation")) == nil,
		"could not plant a stale generation fixture",
	)

	generation_wide := win32.utf8_to_utf16(generation_path, context.allocator)
	defer delete(generation_wide, context.allocator)
	testing.expect(t, generation_wide != nil, "could not encode the generation path")
	dest_handle := win32.CreateFileW(
		win32.wstring(raw_data(generation_wide)),
		win32.GENERIC_READ,
		win32.FILE_SHARE_READ | win32.FILE_SHARE_WRITE,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	testing.expect(
		t,
		dest_handle != win32.INVALID_HANDLE_VALUE,
		"could not hold the destination generation file open for this fixture",
	)
	defer win32.CloseHandle(dest_handle)

	h, refusal, ok := open_log(dir, context.allocator)
	defer close_log(&h)
	testing.expect(t, ok, "a second opener should still get a usable log even when rotation fails")
	testing.expect_value(t, refusal, Rotation_Refusal.Unknown)
}
