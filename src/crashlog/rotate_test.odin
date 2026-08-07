#+vet explicit-allocators
package crashlog

import "core:os"
import "core:strings"
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

	h, rotation_refused, ok := open_log(dir, context.allocator)
	defer close_log(&h)
	testing.expect(t, ok, "open_log refused a directory it should have been able to create")
	testing.expect(t, !rotation_refused, "rotation should not be refused with no second opener")

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

	h, rotation_refused, ok := open_log(dir, context.allocator)
	defer close_log(&h)
	testing.expect(t, ok, "open_log refused a directory it should have been able to create")
	testing.expect(
		t,
		!rotation_refused,
		"rotation should not be refused when nothing needed rotating",
	)

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

	holder, holder_refused, holder_ok := open_log(dir, context.allocator)
	defer close_log(&holder)
	testing.expect(t, holder_ok, "could not open the holder handle this fixture needs")
	testing.expect(t, !holder_refused, "the holder's own open should not see anything to rotate")

	padding := make([]byte, LOG_CEILING_BYTES + 1, context.allocator)
	defer delete(padding, context.allocator)
	write_bytes(holder.file, padding)

	h, rotation_refused, ok := open_log(dir, context.allocator)
	defer close_log(&h)
	testing.expect(
		t,
		ok,
		"a second opener should still get a usable log even when rotation is refused",
	)
	testing.expect(
		t,
		rotation_refused,
		"rotation should be refused while a handle without FILE_SHARE_DELETE is open on the log",
	)

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
