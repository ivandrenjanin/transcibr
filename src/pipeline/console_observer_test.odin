#+vet explicit-allocators
package pipeline

// Fix round 1 (PR #285's review, finding 2, Important): the PR body and
// ADR-0041 both claimed `transcribe_cli_test.odin`'s three real-binary
// drills "pin this by construction". They do not -- they are
// `strings.contains` substring checks, and the reviewer mutated
// `write_event_to_console`'s `.Failed`/`.Refused`/`.Note` arm from
// `fmt.eprintln(event.message)` to
// `fmt.eprintfln("REVIEW-MUTANT %s", event.message)`, rebuilt, and ran the
// full `just test`: exit 0, all suites green. This test is the missing
// byte-identity pin: it redirects `os.stderr` to a pipe for the length of
// one `write_event_to_console` call and asserts the EXACT bytes written,
// for every `Event_Kind` this sink renders today.
import "core:os"
import "core:testing"

@(private)
@(require_results)
console_bytes_of :: proc(t: ^testing.T, event: Event) -> string {
	r, w, opened := os.pipe()
	testing.expect(t, opened == nil, "the case could not open its own capture pipe")

	previous := os.stderr
	os.stderr = w
	write_event_to_console(event, nil)
	os.stderr = previous
	testing.expect(t, os.close(w) == nil, "the case could not close its own pipe's write end")

	got, read_err := os.read_entire_file_from_file(r, context.allocator)
	testing.expect(t, read_err == nil, "the case could not read back its own captured bytes")
	testing.expect(t, os.close(r) == nil, "the case could not close its own pipe's read end")
	return string(got)
}

@(test)
write_event_to_console_pins_the_exact_stderr_bytes_for_every_wired_kind :: proc(t: ^testing.T) {
	failed := console_bytes_of(t, Event{kind = .Failed, message = "ffprobe could not be started"})
	defer delete(failed, context.allocator)
	testing.expect_value(t, failed, "ffprobe could not be started\n")

	refused := console_bytes_of(t, Event{kind = .Refused, message = "two Recordings share a stem"})
	defer delete(refused, context.allocator)
	testing.expect_value(t, refused, "two Recordings share a stem\n")

	note := console_bytes_of(t, Event{kind = .Note, message = "a note about the plan"})
	defer delete(note, context.allocator)
	testing.expect_value(t, note, "a note about the plan\n")

	health := console_bytes_of(
		t,
		Event{kind = .Health, source = "clip.mp4", message = "container looks unhealthy"},
	)
	defer delete(health, context.allocator)
	testing.expect_value(t, health, "clip.mp4: container looks unhealthy\n")
}

// The negative half: a kind this sink does not yet wire renders nothing at
// all, not an empty line -- a mutation that made `.Progress` fall into the
// `.Failed`/`.Refused`/`.Note` arm by mistake would print `event.message`
// (empty here) plus a newline, which this catches and the substring drills
// never could.
@(test)
write_event_to_console_renders_nothing_for_a_kind_it_does_not_yet_wire :: proc(t: ^testing.T) {
	progress := console_bytes_of(t, Event{kind = .Progress, percent = 50})
	defer delete(progress, context.allocator)
	testing.expect_value(t, progress, "")
}
