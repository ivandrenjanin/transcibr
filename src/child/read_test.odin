#+vet explicit-allocators
package child

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import win32 "core:sys/windows"
import "core:testing"
import "core:time"

// Far shorter than READ_BOUND_MS, so a case that wants the ceiling reached
// measures the bound rather than a real caller's patience.
@(private)
READ_SHORT_BOUND_MS :: i64(300)

// Windows' default timer resolution quantizes both `time.sleep` calls this
// case makes: the poll loop's own sleeps and the granularity `tick_since`
// is read against. See child/run_test.odin's `spin_for` comment for the
// figures this was measured against; the margin here is generous rather than
// tight because nothing in this case pins READ_POLL itself.
@(private)
READ_BOUND_SLACK :: 2 * time.Second

// A named pipe with a server end and nobody ever writing to it or closing
// it: the general case issue #27 names alongside a reserved device name, and
// the one this suite can reach without depending on a Windows device name at
// all. The caller closes `server` and frees `path`.
@(private)
@(require_results)
pipe_with_no_writer :: proc(
	t: ^testing.T,
	tag: string,
	allocator: mem.Allocator,
) -> (
	path: string,
	server: win32.HANDLE,
	ok: bool,
) {
	assert(t != nil, "there is no test here to report a refusal through")
	assert(len(tag) > 0, "a pipe name shared by two cases is a pipe one of them cannot claim")

	path = fmt.aprintf(
		`\\.\pipe\transcibr-read-bound-%d-%s`,
		win32.GetCurrentProcessId(),
		tag,
		allocator = allocator,
	)

	wide := win32.utf8_to_utf16(path, allocator)
	defer delete(wide, allocator)

	server = win32.CreateNamedPipeW(
		win32.wstring(raw_data(wide)),
		win32.PIPE_ACCESS_OUTBOUND,
		win32.PIPE_TYPE_BYTE | win32.PIPE_WAIT,
		1,
		4096,
		4096,
		0,
		nil,
	)
	if server == win32.INVALID_HANDLE_VALUE {
		delete(path, allocator)
		testing.expect(t, false, "could not create a named pipe with nobody writing to it")
		return "", nil, false
	}
	return path, server, true
}

@(test)
a_read_that_cannot_finish_is_abandoned_at_its_bound :: proc(t: ^testing.T) {
	path, server, ok := pipe_with_no_writer(t, "abandoned", context.allocator)
	if !ok {
		return
	}
	defer delete(path, context.allocator)
	defer win32.CloseHandle(server)

	started := time.tick_now()
	bytes, err := read_bounded(path, READ_SHORT_BOUND_MS, context.allocator)
	elapsed := time.tick_since(started)

	testing.expect_value(t, err.fault, Read_Fault.Did_Not_Finish)
	testing.expect(t, len(bytes) == 0, "an abandoned read handed back bytes it never finished")
	testing.expectf(
		t,
		elapsed < time.Duration(READ_SHORT_BOUND_MS) * time.Millisecond + READ_BOUND_SLACK,
		"the read ran %v past its %d ms bound instead of being abandoned at it",
		elapsed,
		READ_SHORT_BOUND_MS,
	)
}

@(test)
a_read_that_finishes_within_its_bound_returns_what_was_written :: proc(t: ^testing.T) {
	path := scratch_path(t, "readbound-ok", context.allocator)
	defer delete(path, context.allocator)
	defer os.remove(path)

	testing.expect(
		t,
		os.write_entire_file(path, transmute([]u8)string("said something")) == nil,
		"could not write the file this case reads back",
	)

	bytes, err := read_bounded(path, CHILD_RUN_BOUND_MS, context.allocator)
	defer delete(bytes, context.allocator)

	testing.expect_value(t, err.fault, Read_Fault.None)
	testing.expect_value(t, string(bytes), "said something")
}

@(test)
a_read_of_a_path_that_names_no_file_is_reported_rather_than_abandoned :: proc(t: ^testing.T) {
	path := scratch_path(t, "readbound-missing", context.allocator)
	defer delete(path, context.allocator)

	bytes, err := read_bounded(path, CHILD_RUN_BOUND_MS, context.allocator)
	defer delete(bytes, context.allocator)

	testing.expect_value(t, err.fault, Read_Fault.Unreadable)
	testing.expect(t, len(bytes) == 0, "a read of nothing at all handed back bytes")
}

@(test)
a_read_error_message_names_the_path_it_is_reported_against :: proc(t: ^testing.T) {
	err := Read_Error {
		fault = .Did_Not_Finish,
	}

	message := read_error_message(err, "C:/example/output.json", context.allocator)
	defer delete(message, context.allocator)

	testing.expect(
		t,
		strings.contains(message, "C:/example/output.json"),
		"a refusal did not name the path it was reported against",
	)
	testing.expect(
		t,
		strings.contains(message, "bound"),
		"a refusal for a read that timed out did not say so",
	)
}
