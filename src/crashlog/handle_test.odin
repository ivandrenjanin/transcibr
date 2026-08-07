#+vet explicit-allocators
package crashlog

import "base:runtime"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"
import "core:testing"
import "transcibr:testkit"

@(test)
open_log_opens_and_appends_under_a_fresh_directory :: proc(t: ^testing.T) {
	dir := testkit.scratch_cache(t, "crashlog", "open_log", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	h, rotation_refused, ok := open_log(dir, context.allocator)
	defer close_log(&h)

	testing.expect(t, ok, "open_log refused a directory it should have been able to create")
	testing.expect(t, handle_is_open(h), "open_log reported success with no open handle")
	testing.expect(t, !rotation_refused, "a fresh directory has nothing to rotate")
}

// Issue #76 review round 2: a `FILE_SHARE_READ`-only `open_log` refused a
// second concurrent opener of the same file outright (a sharing violation),
// which is exactly what two transcibr-cli invocations -- or a future #16 GUI
// alongside the CLI -- would do. Both opens are `open_log` itself, so this
// exercises the real sharing flags `CreateFileW` was given rather than a
// hand-rolled second open that could drift from them.
@(test)
open_log_allows_a_second_concurrent_open_log_call :: proc(t: ^testing.T) {
	dir := testkit.scratch_cache(t, "crashlog", "open_log_concurrent", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	h1, _, ok1 := open_log(dir, context.allocator)
	defer close_log(&h1)
	testing.expect(t, ok1, "the first open_log call should have succeeded")

	h2, _, ok2 := open_log(dir, context.allocator)
	defer close_log(&h2)
	testing.expect(
		t,
		ok2,
		"a second concurrent open_log call against the same directory should not be blocked by sharing",
	)
}

@(test)
record_assert_line_writes_prefix_message_and_location :: proc(t: ^testing.T) {
	dir := testkit.scratch_cache(t, "crashlog", "assert_line", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	h, _, ok := open_log(dir, context.allocator)
	testing.expect(t, ok, "open_log refused a directory it should have been able to create")

	loc := runtime.Source_Code_Location {
		file_path = "issue76.odin",
		line      = 42,
		procedure = "probe",
	}
	record_assert_line(h.file, "runtime assertion", "deliberate failure", loc)
	close_log(&h)

	text := read_log(t, dir)
	defer delete(text, context.allocator)
	testing.expect(
		t,
		strings.contains(text, "issue76.odin(42) runtime assertion: deliberate failure"),
		"the recorded line is missing prefix, location or message",
	)
}

@(test)
record_exception_line_writes_the_exception_code_and_address :: proc(t: ^testing.T) {
	dir := testkit.scratch_cache(t, "crashlog", "exception_line", context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	h, _, ok := open_log(dir, context.allocator)
	testing.expect(t, ok, "open_log refused a directory it should have been able to create")

	record: win32.EXCEPTION_RECORD
	record.ExceptionCode = 0xC000008C
	record.ExceptionAddress = rawptr(uintptr(0x1234))
	info := win32.EXCEPTION_POINTERS {
		ExceptionRecord = &record,
	}
	record_exception_line(h.file, &info)
	close_log(&h)

	text := read_log(t, dir)
	defer delete(text, context.allocator)
	testing.expect(
		t,
		strings.contains(text, "CRASH exception=0xc000008c"),
		"the exception code is missing from the recorded line",
	)
	testing.expect(
		t,
		strings.contains(text, "address=0x1234"),
		"the exception address is missing from the recorded line",
	)
}

@(private)
@(require_results)
read_log :: proc(t: ^testing.T, dir: string) -> string {
	assert(t != nil, "there is no test here to report a read failure through")
	assert(len(dir) > 0, "there is no log directory here to read from")

	path := strings.concatenate({dir, "\\", LOG_FILE_NAME}, context.allocator)
	defer delete(path, context.allocator)

	bytes, err := os.read_entire_file(path, context.allocator)
	testing.expect(t, err == nil, "the log file the test just wrote could not be read back")
	return string(bytes)
}
