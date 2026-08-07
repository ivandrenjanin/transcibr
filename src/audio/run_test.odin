#+vet explicit-allocators
package audio

import "core:fmt"
import "core:mem"
import "core:os"
import win32 "core:sys/windows"
import "core:testing"
import "core:time"
import "transcibr:child"
import "transcibr:process"
import "transcibr:testkit"

@(private)
CMD :: "cmd.exe"

// Far shorter than the child that has to outlive it, so the case that wants a
// stopped child measures the bound rather than the child's patience.
@(private)
SHORT_BOUND_MS :: i64(500)

// The child ends itself whatever this suite does or fails to do.
@(private)
LONGER_SECONDS :: 25

// Deliberately not MINIMUM_SETTLING_GAP_NS: long enough that the first look
// cannot land past it by accident, short enough to spend in a suite.
@(private)
SETTLING_GAP_NS :: i64(2_000_000_000)

@(private)
UNSETTLED_GAP_NS :: i64(50_000_000)

// A thin adapter over testkit.fixture_file's own age twist: every call site
// in this suite wants a fixture of a given SIZE, aged by a given amount,
// never real content, so this is the one place that turns `bytes` into the
// zero-filled buffer fixture_file actually writes. The caller frees the path.
@(private)
@(require_results)
aged_file :: proc(
	t: ^testing.T,
	cache: string,
	name: string,
	bytes: int,
	age: time.Duration,
) -> string {
	content := make([]u8, bytes, context.allocator)
	defer delete(content, context.allocator)
	return testkit.fixture_file(t, cache, name, string(content), context.allocator, age)
}

// Spelled the same way at all four call sites (transcibr:testkit's own
// header explains why this one is not among them): child_test.odin is part of
// package child, and a testkit that imported child could not be imported back
// by child's own tests without a cycle.
@(private)
@(require_results)
open_group :: proc(t: ^testing.T) -> (group: child.Job_Object, ok: bool) {
	opened, err := child.job_object_open()
	if !testing.expectf(t, err.fault == .None, "no job object: %v", err.fault) {
		return {}, false
	}
	return opened, true
}

@(test)
a_sweep_of_a_real_cache_takes_what_it_chose_and_nothing_else :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "audio", "sweep", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	stale := aged_file(t, cache, "stale.wav", 1024, 30 * 24 * time.Hour)
	defer delete(stale, context.allocator)
	in_flight := aged_file(t, cache, "in-flight.wav.part", 1024, 5 * time.Minute)
	defer delete(in_flight, context.allocator)

	taken, fault := sweep_cache(cache, DEFAULT_SWEEP_LIMITS, context.allocator)
	testing.expect_value(t, fault, Cache_Fault.None)
	testing.expect_value(t, taken, 1)
	testing.expect(t, !os.exists(stale), "the sweep left thirty-day-old audio behind")
	testing.expect(t, os.exists(in_flight), "the sweep took a file a run in progress is writing")
}

@(test)
a_sweep_leaves_a_directory_in_the_cache_alone :: proc(t: ^testing.T) {
	everything := Sweep_Limits {
		max_bytes    = 0,
		max_age_ns   = 1,
		spare_age_ns = 0,
	}

	cache := testkit.scratch_cache(t, "audio", "directory", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	inner := fmt.aprintf("%s\\somebody-elses", cache, allocator = context.allocator)
	defer delete(inner, context.allocator)
	defer os.remove(inner)
	testing.expect(t, os.make_directory_all(inner) == nil, "could not make a directory to spare")

	audio := aged_file(t, cache, "audio.wav", 512, time.Minute)
	defer delete(audio, context.allocator)

	taken, fault := sweep_cache(cache, everything, context.allocator)
	testing.expect_value(t, fault, Cache_Fault.None)
	testing.expect_value(t, taken, 1)
	testing.expect(t, !os.exists(audio), "the sweep left a file over both ceilings behind")
	testing.expect(t, os.exists(inner), "the sweep took a directory out of the cache")
}

@(test)
a_cache_file_nothing_can_open_still_counts_towards_the_size_ceiling :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "audio", "held", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	held := aged_file(t, cache, "held.bin", 2048, 30 * 24 * time.Hour)
	defer delete(held, context.allocator)
	older := aged_file(t, cache, "older.bin", 1024, 31 * 24 * time.Hour)
	defer delete(older, context.allocator)

	wide := win32.utf8_to_wstring(held, context.allocator)
	defer delete(wide, context.allocator)
	handle := win32.CreateFileW(
		wide,
		win32.GENERIC_READ,
		0,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if !testing.expect(t, handle != win32.INVALID_HANDLE_VALUE, "could not hold a file open") {
		return
	}
	defer win32.CloseHandle(handle)

	limits := Sweep_Limits {
		max_bytes    = 2048,
		max_age_ns   = i64(365 * 24 * 60 * 60) * 1_000_000_000,
		spare_age_ns = i64(60 * 60) * 1_000_000_000,
	}
	taken, fault := sweep_cache(cache, limits, context.allocator)
	testing.expect_value(t, fault, Cache_Fault.None)

	testing.expect_value(t, taken, 1)
	testing.expect(t, !os.exists(older), "the oldest file over the size ceiling stayed")
	testing.expect(t, os.exists(held), "the sweep took the one file it could not open")
}

@(test)
a_cache_under_a_path_the_engine_cannot_open_is_refused_before_it_is_created :: proc(
	t: ^testing.T,
) {
	directory := os.get_env("TEMP", context.allocator)
	defer delete(directory, context.allocator)
	cache := fmt.aprintf(
		"%s\\transcibr-audio-%d-\u5f55\u97f3",
		directory,
		os.get_pid(),
		allocator = context.allocator,
	)
	defer delete(cache, context.allocator)
	defer os.remove(cache)

	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.Path_Not_Ascii)
	testing.expect(t, !os.exists(cache), "a cache the Engine cannot open was created anyway")
}

@(test)
a_cache_pointing_at_an_existing_regular_file_is_refused_before_extraction :: proc(t: ^testing.T) {
	directory := os.get_env("TEMP", context.allocator)
	defer delete(directory, context.allocator)
	cache := fmt.aprintf(
		"%s\\transcibr-audio-%d-not-a-directory",
		directory,
		os.get_pid(),
		allocator = context.allocator,
	)
	defer delete(cache, context.allocator)
	defer os.remove(cache)

	testing.expect(
		t,
		os.write_entire_file(cache, []u8{}) == nil,
		"could not plant the blocking file",
	)

	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.Not_A_Directory)
}

@(test)
a_cache_whose_immediate_parent_directory_already_exists_is_created :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "audio", "new-leaf", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	testing.expect(t, !os.exists(cache), "the fixture already made the cache this case creates")
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)
	testing.expect(
		t,
		os.exists(cache),
		"open_cache did not create a leaf under an existing parent",
	)
}

@(test)
a_cache_with_a_trailing_separator_under_an_existing_parent_is_created :: proc(t: ^testing.T) {
	parent := testkit.made_scratch_cache(t, "audio", "trailing-sep-parent", context.allocator)
	defer delete(parent, context.allocator)
	defer testkit.remove_cache(parent, context.allocator)

	cache := fmt.aprintf("%s\\leaf\\", parent, allocator = context.allocator)
	defer delete(cache, context.allocator)

	testing.expect(t, !os.exists(cache), "the fixture already made the leaf this case creates")
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)
	testing.expect(
		t,
		os.exists(cache),
		"open_cache did not create a trailing-separator leaf under an existing parent",
	)
}

@(test)
a_cache_whose_parent_directory_is_also_missing_is_refused_rather_than_invented :: proc(
	t: ^testing.T,
) {
	root := testkit.scratch_cache(t, "audio", "missing-parent", context.allocator)
	defer delete(root, context.allocator)
	defer testkit.remove_cache(root, context.allocator)

	cache := fmt.aprintf("%s\\nested\\deeper", root, allocator = context.allocator)
	defer delete(cache, context.allocator)

	testing.expect(t, !os.exists(root), "the fixture already made the tree this case must refuse")
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.Parent_Missing)
	testing.expect(t, !os.exists(cache), "a cache with no plausible parent was created anyway")
	testing.expect(
		t,
		!os.exists(root),
		"open_cache invented an implausible tree instead of refusing it",
	)
}

@(test)
the_head_of_a_real_wav_on_disk_walks_to_its_data_chunk :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "audio", "head", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	path := fmt.aprintf("%s\\audio.wav", cache, allocator = context.allocator)
	defer delete(path, context.allocator)
	testing.expect(t, os.write_entire_file(path, FFMPEG_WAV) == nil, "could not write the fixture")

	buffer: [AUDIO_HEAD_BYTES]u8 = ---
	head, bytes, err := read_head(path, buffer[:])
	testing.expect_value(t, err.fault, Fault.None)
	testing.expect_value(t, bytes, i64(FFMPEG_WAV_BYTES))
	testing.expect_value(t, len(head), FFMPEG_WAV_BYTES)

	facts, malformed := read_wav_facts(head, bytes)
	testing.expect_value(t, malformed, Riff_Fault.None)
	testing.expect_value(t, facts.data_bytes, i64(6400))
	testing.expect(t, as_asked_for(facts), "the fixture off the disk is not what was asked for")
}

@(test)
a_head_read_from_a_file_that_is_not_there_is_refused :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "audio", "missing", context.allocator)
	defer delete(cache, context.allocator)
	path := fmt.aprintf("%s\\never-written.wav", cache, allocator = context.allocator)
	defer delete(path, context.allocator)

	buffer: [64]u8 = ---
	_, _, err := read_head(path, buffer[:])
	testing.expect_value(t, err.fault, Fault.Audio_Unreadable)
}

// The #101 review evidence used a named pipe with no writer; a zero-byte
// file on disk reaches the same zero-length answer through `os.read_at`
// without a second process to arrange.
@(test)
a_head_read_from_a_zero_byte_file_is_refused_as_unreadable :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "audio", "empty-head", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	path := fmt.aprintf("%s\\empty.wav", cache, allocator = context.allocator)
	defer delete(path, context.allocator)
	testing.expect(t, os.write_entire_file(path, []u8{}) == nil, "could not write the fixture")

	buffer: [64]u8 = ---
	head, bytes, err := read_head(path, buffer[:])
	testing.expect_value(t, err.fault, Fault.Audio_Unreadable)
	testing.expect_value(t, bytes, i64(0))
	testing.expect_value(t, len(head), 0)
}

@(test)
the_bounded_head_of_a_real_wav_on_disk_walks_to_its_data_chunk :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "audio", "head-bounded", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	path := fmt.aprintf("%s\\audio.wav", cache, allocator = context.allocator)
	defer delete(path, context.allocator)
	testing.expect(t, os.write_entire_file(path, FFMPEG_WAV) == nil, "could not write the fixture")

	head, bytes, err := read_head_bounded(path, child.READ_BOUND_MS, context.allocator)
	defer delete(head, context.allocator)
	testing.expect_value(t, err.fault, Fault.None)
	testing.expect_value(t, bytes, i64(FFMPEG_WAV_BYTES))
	testing.expect_value(t, len(head), FFMPEG_WAV_BYTES)

	facts, malformed := read_wav_facts(head, bytes)
	testing.expect_value(t, malformed, Riff_Fault.None)
	testing.expect_value(t, facts.data_bytes, i64(6400))
	testing.expect(t, as_asked_for(facts), "the fixture off the disk is not what was asked for")
}

@(test)
a_bounded_head_read_from_a_file_that_is_not_there_is_refused :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "audio", "missing-bounded", context.allocator)
	defer delete(cache, context.allocator)
	path := fmt.aprintf("%s\\never-written.wav", cache, allocator = context.allocator)
	defer delete(path, context.allocator)

	head, _, err := read_head_bounded(path, child.READ_BOUND_MS, context.allocator)
	defer delete(head, context.allocator)
	testing.expect_value(t, err.fault, Fault.Audio_Unreadable)
}

// Short enough that a worker stalled `HEAD_STALL_MS` past it forces
// `read_head_bounded`'s wait to time out rather than finish, without the
// suite waiting long for it.
@(private)
HEAD_STALL_BOUND_MS :: i64(50)

// Comfortably past `HEAD_STALL_BOUND_MS`, and comfortably inside
// `transcibr:child`'s own `CANCEL_BOUND_MS` (5 s), so the worker's real
// `time.sleep` finishes -- and `await_or_abandon`'s poll notices it done --
// well before the `.Unstoppable` leak path would ever be reached.
@(private)
HEAD_STALL_MS :: i64(1_500)

// Generous against the worst case a correctly working bound could ever
// legitimately take -- `HEAD_STALL_BOUND_MS` plus a cancellation running its
// own full course -- rather than tuned to equal it, the same reasoning
// `artifact.model_test.odin`'s `MODEL_BOUND_TEST_SLACK` documents.
@(private)
HEAD_STALL_SLACK :: 30 * time.Second

// Finding of the PR #99 review: nothing in this suite before this case ran a
// `read_head_bounded` worker for longer than its own bound, so a mutant that
// multiplied `bound_ms` by 1000 -- an effectively unbounded wait -- passed
// every test unchanged. `read_head_bounded`'s own `stall_ms` parameter puts
// a real, `time.sleep`-stalled worker on the far side of a short bound, the same way
// `child`'s own `a_read_that_cannot_finish_is_abandoned_at_its_bound` puts a
// real stalled pipe read on the far side of one.
@(test)
a_head_read_that_cannot_finish_within_its_bound_is_reported_rather_than_awaited_forever :: proc(
	t: ^testing.T,
) {
	cache := testkit.scratch_cache(t, "audio", "head-stalled", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	path := fmt.aprintf("%s\\audio.wav", cache, allocator = context.allocator)
	defer delete(path, context.allocator)
	testing.expect(t, os.write_entire_file(path, FFMPEG_WAV) == nil, "could not write the fixture")

	started := time.tick_now()
	head, bytes, err := read_head_bounded(
		path,
		HEAD_STALL_BOUND_MS,
		context.allocator,
		HEAD_STALL_MS,
	)
	elapsed := time.tick_since(started)
	defer delete(head, context.allocator)

	testing.expect_value(t, err.fault, Fault.Audio_Unreadable)
	testing.expect_value(t, bytes, i64(0))
	testing.expect(t, len(head) == 0, "an abandoned head read handed back bytes it never finished")
	testing.expectf(
		t,
		elapsed < HEAD_STALL_SLACK,
		"a head read bounded at %d ms took %v to be reported, which is not being bounded at all",
		HEAD_STALL_BOUND_MS,
		elapsed,
	)
}

@(test)
a_recording_looked_at_too_soon_is_looked_at_again_rather_than_refused :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "audio", "settle", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	source := aged_file(t, cache, "source.mp4", 4096, 0)
	defer delete(source, context.allocator)

	planned, unreadable := read_source(source, context.allocator)
	testing.expect_value(t, unreadable.fault, Fault.None)

	started := time.tick_now()
	err := settle(source, planned, SETTLING_GAP_NS, context.allocator)
	waited := time.tick_since(started)

	testing.expect_value(t, err.fault, Fault.None)
	testing.expect(
		t,
		waited >= time.Duration(SETTLING_GAP_NS / 2),
		"settle answered without ever taking the second look",
	)
}

@(test)
a_recording_that_was_never_shown_to_stop_changing_is_refused_not_accepted :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "audio", "unsettled", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	source := aged_file(t, cache, "source.mp4", 4096, 0)
	defer delete(source, context.allocator)

	planned, unreadable := read_source(source, context.allocator)
	testing.expect_value(t, unreadable.fault, Fault.None)
	planned.taken_ns += i64(time.Hour)

	err := settle(source, planned, UNSETTLED_GAP_NS, context.allocator)
	testing.expect_value(t, err.fault, Fault.Still_Unsettled)
}

@(test)
the_one_failure_that_leaves_a_part_behind_is_an_ffmpeg_that_would_not_stop :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "audio", "part", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	part := fmt.aprintf("%s\\one.wav.part", cache, allocator = context.allocator)
	defer delete(part, context.allocator)

	for fault in Fault {
		if fault == .None {
			continue
		}
		testing.expectf(t, os.write_entire_file(part, []u8{0}) == nil, "could not write %s", part)
		discard_part(part, fault)
		testing.expectf(
			t,
			os.exists(part) == (fault == .Extraction_Not_Stopped),
			"%v left the half-written audio in the wrong state",
			fault,
		)
		os.remove(part)
	}
}

// The caller frees the path; remove_cache takes the file.
@(private)
@(require_results)
flood_file :: proc(t: ^testing.T, cache: string, bytes: int) -> string {
	path := fmt.aprintf("%s\\flood.txt", cache, allocator = context.allocator)
	_ = testkit.write_flood(
		t,
		path,
		bytes,
		"ffmpeg: a line this reader has no reading for\r\n",
		context.allocator,
	)
	return path
}

// Proves the bound is still reached despite a flood, not that a single drain
// has a ceiling at all: mutating child.MAX_DRAIN_BYTES away leaves this
// green, because an unbounded drain still runs out of flood to read and hands
// control back the same way. Only
// child.a_single_drain_stops_at_its_ceiling_even_with_a_steady_flood pins the
// ceiling itself. What this fulfils is the ticket's own acceptance criterion
// (issue #33): before it, nothing here went red when src/audio/run.odin's
// drain was the one copy of the two with no ceiling on it at all.
@(test)
a_flood_on_the_diagnostic_stream_does_not_stop_the_bound_from_being_reached :: proc(
	t: ^testing.T,
) {
	cache := testkit.scratch_cache(t, "audio", "flood", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	flood := flood_file(t, cache, 1 << 20)
	defer delete(flood, context.allocator)
	signal := testkit.lonely_signal("Audio", "flood", context.allocator)
	defer delete(signal, context.allocator)
	command := testkit.flood_type_command(flood, LONGER_SECONDS, signal, context.allocator)
	defer delete(command, context.allocator)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	started := time.tick_now()
	ending, _, err := child.run_bounded(
		&group,
		CMD,
		{"/c", command},
		SHORT_BOUND_MS,
		context.allocator,
	)
	elapsed := time.tick_since(started)

	testing.expect_value(t, err.fault, child.Fault.None)
	testing.expect_value(t, ending, child.Run.Stopped)
	testing.expect(
		t,
		elapsed < time.Duration(SHORT_BOUND_MS) * time.Millisecond + testkit.FLOOD_STOP_SLACK,
		"the flood delayed the bound from being reached at all",
	)
}

// Far shorter than child.READ_BOUND_MS, so this case measures the bound
// rather than a real caller's patience -- the same reasoning
// `child.READ_SHORT_BOUND_MS` states for itself, duplicated here for the
// identical reason `open_group` above is: a testkit shared with `child`
// would import back into the package whose own tests define this bound.
@(private)
PROBE_ANSWER_WEDGE_BOUND_MS :: i64(300)

// A named pipe with a server end and nobody ever writing to it or closing
// it -- the same idiom `child.read_test.odin`'s `pipe_with_no_writer` uses
// for its own package, duplicated rather than shared for the reason
// `open_group` above states. The caller closes `server` and frees `path`.
@(private)
@(require_results)
answer_pipe_with_no_writer :: proc(
	t: ^testing.T,
	tag: string,
) -> (
	path: string,
	server: win32.HANDLE,
	ok: bool,
) {
	assert(t != nil, "there is no test here to report a refusal through")
	assert(len(tag) > 0, "a pipe name shared by two cases is a pipe one of them cannot claim")

	path = fmt.aprintf(
		`\\.\pipe\transcibr-probe-answer-%d-%s`,
		win32.GetCurrentProcessId(),
		tag,
		allocator = context.allocator,
	)

	wide := win32.utf8_to_utf16(path, context.allocator)
	defer delete(wide, context.allocator)

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
		delete(path, context.allocator)
		testing.expect(t, false, "could not create a named pipe with nobody writing to it")
		return "", nil, false
	}
	return path, server, true
}

// `answer_read_settled` is `probe`'s own ordering guard, pulled out so it can
// be proven without spawning ffprobe at all: `child.read_bounded` answers
// `Read_Fault.Did_Not_Finish` for BOTH a cancelled-and-reclaimed worker and
// one `child.await_or_abandon` gave up on, and `Read_Error` carries nothing
// that tells those two apart from here -- so this treats the fault
// conservatively, leaking the answer file deliberately the same way
// `child.Read_Job`'s own doc comment states its worker leaks for the
// identical reason (issue #125, filed from the #66 review).
@(test)
a_probe_answer_read_that_is_known_done_is_settled_for_removal :: proc(t: ^testing.T) {
	testing.expect(
		t,
		answer_read_settled(child.Read_Fault.None),
		"a finished read was not settled",
	)
	testing.expect(
		t,
		answer_read_settled(child.Read_Fault.Not_Started),
		"a read whose thread never started was not settled",
	)
	testing.expect(
		t,
		answer_read_settled(child.Read_Fault.Unreadable),
		"a read that finished with an OS error was not settled",
	)
}

@(test)
an_abandoned_probe_answer_read_is_never_settled_for_removal :: proc(t: ^testing.T) {
	testing.expect(
		t,
		!answer_read_settled(child.Read_Fault.Did_Not_Finish),
		"an abandoned read was treated as settled, which would remove a file a live worker might still hold open",
	)

	path, server, ok := answer_pipe_with_no_writer(t, "abandoned")
	if !ok {
		return
	}
	defer win32.CloseHandle(server)
	defer delete(path, context.allocator)

	_, unreadable := child.read_bounded(path, PROBE_ANSWER_WEDGE_BOUND_MS, context.allocator)
	testing.expect_value(t, unreadable.fault, child.Read_Fault.Did_Not_Finish)
	testing.expect(
		t,
		!answer_read_settled(unreadable.fault),
		"a real abandoned read's own fault was treated as settled for removal",
	)
}

// `answer_read_settled` on its own only ever proves the BOOLEAN is right --
// nothing above reaches the file-system effect that boolean is supposed to
// gate. `remove_answer_if_settled` is the exact code `probe` calls with that
// boolean, so handing it a real, disk-backed answer file and a genuine
// `settled` value proves the removal itself, not only the predicate that
// decides it (issue #125's round-1 review, finding 1).
@(test)
a_settled_probe_answer_is_actually_removed_from_disk :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "audio", "answer-settled", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	answer := fmt.aprintf("%s\\answer.json", cache, allocator = context.allocator)
	defer delete(answer, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(answer, []u8{'{', '}'}) == nil,
		"could not write the fixture",
	)

	remove_answer_if_settled(answer, true, os_remove_answer)
	testing.expect(t, !os.exists(answer), "a settled answer was left on disk")
}

@(test)
an_unsettled_probe_answer_is_left_on_disk :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "audio", "answer-unsettled", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	answer := fmt.aprintf("%s\\answer.json", cache, allocator = context.allocator)
	defer delete(answer, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(answer, []u8{'{', '}'}) == nil,
		"could not write the fixture",
	)

	remove_answer_if_settled(answer, false, os_remove_answer)
	testing.expect(
		t,
		os.exists(answer),
		"an unsettled answer was removed, which would race a worker that might still hold it open",
	)
}

// A real, fast-exiting stand-in for ffprobe that always exits zero: `cmd.exe`
// given `probe_arguments`'s ffprobe-shaped flags neither understands nor
// misreads them as an interactive session, because `child.start` wires its
// standard input to the null device -- `cmd.exe` reads that as an immediate
// end of file and exits 0 (measured ~55 ms), the same way a real ffprobe run
// that succeeds does. Any short-lived process reachable off PATH stands in
// for a probe whose own call site never inspects what its child prints, only
// whether it exited and how, without a committed fixture.
@(private)
FFPROBE_STAND_IN :: "cmd.exe"

// A real, fast-exiting stand-in for ffprobe that always refuses: `where.exe`
// treats `probe_arguments`'s ffprobe-shaped flags as search patterns nothing
// on PATH matches, prints "INFO: Could not find files..." to its own
// standard output, and exits 1 (measured ~13 ms) -- deterministic against
// real `probe_arguments`, unlike a mocked exit code this suite would have to
// wire through a stub run instead of proving at `probe`'s real call site.
@(private)
FFPROBE_REFUSING_STAND_IN :: "where.exe"

// Drives `probe` itself onto its guarded-removal branch, rather than only
// `remove_answer_if_settled` directly: a real answer file, read to
// completion, must vanish through `probe`'s own call site, not merely
// through a test that hands the helper a hand-picked `settled` value.
@(test)
a_probe_whose_answer_read_finishes_removes_the_answer_file_at_the_call_site :: proc(
	t: ^testing.T,
) {
	cache := testkit.scratch_cache(t, "audio", "probe-call-site-settled", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	answer := fmt.aprintf("%s\\answer.json", cache, allocator = context.allocator)
	defer delete(answer, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(answer, []u8{'{', '}'}) == nil,
		"could not write the fixture",
	)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	tools := Tools {
		ffprobe = FFPROBE_STAND_IN,
	}
	_, err := probe(&group, tools, "source.mp4", answer, context.allocator)
	testing.expect_value(t, err.fault, Fault.Probe_Unreadable)
	testing.expect(
		t,
		!os.exists(answer),
		"probe's own call site left a settled answer file on disk",
	)
}

// The abandoned-read counterpart: `probe` hard-codes `child.READ_BOUND_MS`
// (30 s), so this genuinely pays that bound rather than a shortened stand-in
// -- the same trade `a_worst_case_sized_engine_output_reads_well_within_its_bound`
// makes in `child\read_test.odin` for the identical constant. Proves `probe`
// itself, not only `answer_read_settled`, reaches `Read_Fault.Did_Not_Finish`
// deterministically off a real abandoned worker (issue #125's round-1
// review, finding 1).
@(test)
a_probe_whose_answer_read_is_abandoned_is_reported_at_the_call_site :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	path, server, ok2 := answer_pipe_with_no_writer(t, "call-site")
	if !ok2 {
		return
	}
	defer win32.CloseHandle(server)
	defer delete(path, context.allocator)

	tools := Tools {
		ffprobe = FFPROBE_STAND_IN,
	}
	started := time.tick_now()
	_, err := probe(&group, tools, "source.mp4", path, context.allocator)
	elapsed := time.tick_since(started)

	testing.expect_value(t, err.fault, Fault.Probe_Answer_Unreadable)
	testing.expectf(
		t,
		elapsed >= time.Duration(child.READ_BOUND_MS) * time.Millisecond,
		"probe reported an abandoned answer read faster than its own %d ms bound: %v",
		child.READ_BOUND_MS,
		elapsed,
	)
}

// A named pipe's `DeleteFileW` failure is a no-op whether or not it was ever
// attempted (measured: `ERROR_INVALID_PARAMETER` with no reader connected,
// `ERROR_PIPE_BUSY` with one blocked inside it, and the pipe is left exactly
// as it was either way) -- so no file-system effect can tell the two apart
// from outside a pipe path. `probe_using`'s `remove` parameter is `probe`'s
// only route to removing `answer`; passing a counting spy through it is
// what reads the ordering off the call site the file-existence checks above
// cannot reach for the abandoned arm. The count lives behind
// `context.user_ptr`, which `odin test`'s 12 concurrent test threads each
// carry their own copy of, rather than a package variable every other test
// calling `probe` would race (issue #125's round-1 review, finding 1).
@(private)
spy_answer_remove :: proc(path: string) {
	calls := (^int)(context.user_ptr)
	calls^ += 1
}

@(test)
a_probe_whose_answer_read_finishes_calls_the_remover_exactly_once :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "audio", "probe-spy-settled", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	answer := fmt.aprintf("%s\\answer.json", cache, allocator = context.allocator)
	defer delete(answer, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(answer, []u8{'{', '}'}) == nil,
		"could not write the fixture",
	)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	calls := 0
	context.user_ptr = &calls
	tools := Tools {
		ffprobe = FFPROBE_STAND_IN,
	}
	_, err := probe_using(
		&group,
		tools,
		"source.mp4",
		answer,
		context.allocator,
		spy_answer_remove,
		run_probe_child,
	)
	testing.expect_value(t, err.fault, Fault.Probe_Unreadable)
	testing.expect_value(t, calls, 1)
	testing.expect(
		t,
		os.exists(answer),
		"the spy stood in for removal but the real answer still vanished",
	)
}

@(test)
a_probe_whose_answer_read_is_abandoned_never_calls_the_remover :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	path, server, ok2 := answer_pipe_with_no_writer(t, "spy-abandoned")
	if !ok2 {
		return
	}
	defer win32.CloseHandle(server)
	defer delete(path, context.allocator)

	calls := 0
	context.user_ptr = &calls
	tools := Tools {
		ffprobe = FFPROBE_STAND_IN,
	}
	_, err := probe_using(
		&group,
		tools,
		"source.mp4",
		path,
		context.allocator,
		spy_answer_remove,
		run_probe_child,
	)
	testing.expect_value(t, err.fault, Fault.Probe_Answer_Unreadable)
	testing.expectf(
		t,
		calls == 0,
		"probe called its remover %d time(s) on an abandoned answer read, which would race a worker that might still hold it open",
		calls,
	)
}

// `a_probe_whose_answer_read_finishes_calls_the_remover_exactly_once` and
// `a_probe_whose_answer_read_is_abandoned_never_calls_the_remover` above
// only ever reach ffprobe's `.Finished` ending -- neither of them, nor
// anything else in this package, ever drives `probe_using` onto its own
// `.Stopped` branch, so a mutation deleting that branch's removal call left
// the whole 588-test suite green (issue #125's round-4 review, finding 2).
// This stub supplies ffprobe's run OUTCOME directly (`child.Run.Stopped`,
// with no real 60 s `PROBE_BOUND_MS` wait needed), while `probe_using`
// itself still supplies the DECISION -- the guarded removal on that branch
// -- the same way `src\doctor\model_probe.odin`'s `stub_unstoppable_probe`
// already does for its own otherwise-unconstructible ending.
@(private)
@(require_results)
stub_stopped_probe_run :: proc(
	group: ^child.Job_Object,
	executable: string,
	arguments: []string,
	bound_ms: i64,
	allocator: mem.Allocator,
	callbacks: child.Run_Callbacks,
) -> (
	ending: child.Run,
	reason: child.Stop_Reason,
	err: child.Error,
) {
	return .Stopped, .Bound_Expired, child.Error{}
}

@(test)
a_probe_whose_ffprobe_run_stops_calls_the_remover_exactly_once :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	calls := 0
	context.user_ptr = &calls
	tools := Tools {
		ffprobe = FFPROBE_STAND_IN,
	}
	_, err := probe_using(
		&group,
		tools,
		"source.mp4",
		"answer.json",
		context.allocator,
		spy_answer_remove,
		stub_stopped_probe_run,
	)
	testing.expect_value(t, err.fault, Fault.Probe_Did_Not_Finish)
	testing.expectf(
		t,
		calls == 1,
		"probe called its remover %d time(s) for a stopped ffprobe run, wanted 1",
		calls,
	)
}

// Issue #109: a finished ffprobe that exited nonzero was read for a probe
// answer it never wrote, arriving at `.Probe_Unreadable` -- the same fault a
// malformed answer from a probe that genuinely succeeded reports. A caller
// could not tell "ffprobe refused this Recording" from "ffprobe answered with
// something this program cannot parse" apart. Driven through `probe` itself,
// the real call site, rather than a stub: `FFPROBE_REFUSING_STAND_IN` is a
// real process that really exits 1, so this proves the refusal at the same
// seam a genuinely broken ffprobe would reach.
@(test)
a_probe_whose_ffprobe_exits_nonzero_is_refused_with_its_exit_code :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	tools := Tools {
		ffprobe = FFPROBE_REFUSING_STAND_IN,
	}
	_, err := probe(&group, tools, "source.mp4", "answer.json", context.allocator)
	testing.expect_value(t, err.fault, Fault.Probe_Refused)
	testing.expect(t, err.exit_code != 0, "a refused probe carried a zero exit code")
}

// Issue #109 fix round 1: a refused probe has provably exited (the assert
// just above this branch in `probe_using` already establishes that), so the
// answer file it left is provably safe to remove -- unlike the `.Stopped`
// branch, which removes unconditionally even though ffprobe may still hold
// the file. Driven through `probe_using` with a real pre-written answer file
// and a spy remover, the same way
// `a_probe_whose_ffprobe_run_stops_calls_the_remover_exactly_once` proves the
// `.Stopped` branch's removal.
@(test)
a_probe_whose_ffprobe_exits_nonzero_calls_the_remover_exactly_once :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "audio", "probe-refused-spy", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	answer := fmt.aprintf("%s\\answer.json", cache, allocator = context.allocator)
	defer delete(answer, context.allocator)
	testing.expect(
		t,
		os.write_entire_file(answer, []u8{'{', '}'}) == nil,
		"could not write the fixture",
	)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	calls := 0
	context.user_ptr = &calls
	tools := Tools {
		ffprobe = FFPROBE_REFUSING_STAND_IN,
	}
	_, err := probe_using(
		&group,
		tools,
		"source.mp4",
		answer,
		context.allocator,
		spy_answer_remove,
		run_probe_child,
	)
	testing.expect_value(t, err.fault, Fault.Probe_Refused)
	testing.expectf(
		t,
		calls == 1,
		"a refused probe called its remover %d time(s); the answer file it left is never removed",
		calls,
	)
}

// The same stand-in `probe`'s own tests use, aimed at `produce`: `where.exe`
// given `extract_arguments`'s ffmpeg-shaped flags treats them as search
// patterns nothing on PATH matches and exits 1.
@(private)
FFMPEG_REFUSING_STAND_IN :: "where.exe"

// Issue #109: a finished ffmpeg that exited nonzero left no `.wav` behind,
// and `check_audio` read whatever a stale or half-written `part` happened to
// hold rather than the fault ffmpeg itself already reported. Driven through
// `produce` at the point extraction actually spawns a child, before
// `check_audio` ever runs, so a caller can tell "ffmpeg refused this
// Recording" from "the audio ffmpeg wrote does not check out".
@(test)
an_extraction_whose_ffmpeg_exits_nonzero_is_refused_with_its_exit_code :: proc(t: ^testing.T) {
	cache := testkit.scratch_cache(t, "audio", "extraction-refused", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	tools := Tools {
		ffmpeg = FFMPEG_REFUSING_STAND_IN,
	}
	job := Job {
		source = "source.mp4",
		cache  = cache,
		name   = "recording",
	}
	_, err := produce(&group, tools, job, 1000, DEFAULT_TOLERANCE, context.allocator)
	testing.expect_value(t, err.fault, Fault.Extraction_Refused)
	testing.expect(t, err.exit_code != 0, "a refused extraction carried a zero exit code")
}

// `probe_using`'s own `.Unstoppable` arm returns before it ever reaches
// `remove_answer_if_settled` -- an ffprobe run that could not be stopped may
// still be running and may still hold `answer` open, exactly as the member
// comment on `child.Run.Unstoppable` (`src\child\run.odin`) states, so the
// answer file is leaked deliberately, the same way `child.read_bounded`'s
// own doc comment (`src\child\read.odin`) states its worker leaks for the
// identical reason. Nothing before this test
// ever drove `probe_using` onto its own `.Unstoppable` branch, so a mutation
// adding an unconditional `remove(answer)` there left the whole suite green
// (issue #150, the #125 recipe applied to the one arm its own round-4 review
// left uncovered). This stub supplies ffprobe's run OUTCOME directly
// (`child.Run.Unstoppable`, with no real unstoppable ffprobe constructible
// on Windows), while `probe_using` itself still supplies the DECISION -- the
// same way `stub_stopped_probe_run` above does for `.Stopped`, and
// `src\doctor\model_probe_test.odin`'s `stub_unstoppable_probe` does for its
// own otherwise-unconstructible ending.
@(private)
@(require_results)
stub_unstoppable_probe_run :: proc(
	group: ^child.Job_Object,
	executable: string,
	arguments: []string,
	bound_ms: i64,
	allocator: mem.Allocator,
	callbacks: child.Run_Callbacks,
) -> (
	ending: child.Run,
	reason: child.Stop_Reason,
	err: child.Error,
) {
	return .Unstoppable, .Bound_Expired, child.Error {
		fault = .Bad_Command_Line,
		build = process.Build_Error{fault = .Empty_Executable},
	}
}

@(test)
a_probe_whose_ffprobe_run_is_unstoppable_never_calls_the_remover :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	calls := 0
	context.user_ptr = &calls
	tools := Tools {
		ffprobe = FFPROBE_STAND_IN,
	}
	_, err := probe_using(
		&group,
		tools,
		"source.mp4",
		"answer.json",
		context.allocator,
		spy_answer_remove,
		stub_unstoppable_probe_run,
	)
	testing.expect_value(t, err.fault, Fault.Probe_Not_Stopped)
	testing.expectf(
		t,
		calls == 0,
		"probe called its remover %d time(s) for an unstoppable ffprobe run, wanted 0",
		calls,
	)
}

// `probe_using`'s `run` parameter is an injectable seam (issue #125's round-4
// finding 2), so `child.run_bounded`'s own guard test
// (`a_child_that_will_not_start_is_reported_rather_than_asserted`, issue
// #208) cannot see the probe arm -- it never calls through `probe_using` at
// all. This drives the real production wiring instead: `run_probe_child`
// (`probe`'s only production runner, `run.odin:271`) against an executable
// that cannot start, the same way the child-package test drives
// `run_bounded` directly, and then renders the resulting `Error` the way a
// real caller would -- closing the gap `error_message`'s own doc comment
// otherwise only asserts.
@(test)
a_probe_that_will_not_start_carries_a_child_fault_through_its_real_wiring :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	calls := 0
	context.user_ptr = &calls
	tools := Tools {
		ffprobe = "transcibr-no-such-executable.exe",
	}
	_, err := probe_using(
		&group,
		tools,
		"source.mp4",
		"answer.json",
		context.allocator,
		spy_answer_remove,
		run_probe_child,
	)
	testing.expect_value(t, err.fault, Fault.Probe_Not_Started)
	testing.expect(
		t,
		err.child.fault != .None,
		"a Probe_Not_Started error carried no child fault, which error_message relies on",
	)
	if err.child.fault != .None {
		message := error_message(err, "source.mp4", context.allocator)
		defer delete(message, context.allocator)
		testing.expect(t, len(message) > 0, "a Probe_Not_Started error rendered nothing")
	}
}
