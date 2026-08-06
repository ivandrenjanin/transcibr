#+vet explicit-allocators
package audio

import "core:fmt"
import "core:os"
import win32 "core:sys/windows"
import "core:testing"
import "core:time"
import "transcibr:child"
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

// The caller frees the path. The age is set and never waited for, which is what
// makes any of this a case at all: the sweep's ceilings are days and its floor
// is an hour.
@(private)
@(require_results)
aged_file :: proc(
	t: ^testing.T,
	cache: string,
	name: string,
	bytes: int,
	age: time.Duration,
) -> string {
	path := fmt.aprintf("%s\\%s", cache, name, allocator = context.allocator)

	content := make([]u8, bytes, context.allocator)
	defer delete(content, context.allocator)
	testing.expectf(t, os.write_entire_file(path, content) == nil, "could not write %s", path)

	dated := time.time_add(time.now(), -age)
	testing.expectf(t, os.change_times(path, dated, dated) == nil, "could not age %s", path)
	return path
}

// Spelled the same way at all three call sites (transcibr:testkit's own
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
// every test unchanged. `read_head_bounded_stalled` puts a real,
// `time.sleep`-stalled worker on the far side of a short bound, the same way
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
	head, bytes, err := read_head_bounded_stalled(
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
