package audio

import "core:fmt"
import "core:os"
import win32 "core:sys/windows"
import "core:testing"
import "core:time"
import "transcibr:child"

@(private)
CMD :: "cmd.exe"

@(private)
RUN_BOUND_MS :: i64(60_000)

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

// Names a place and does not create it -- the procedures under test do that.
// The caller frees the path and removes the directory.
@(private)
@(require_results)
scratch_cache :: proc(t: ^testing.T, tag: string) -> string {
	directory := os.get_env("TEMP", context.allocator)
	defer delete(directory, context.allocator)
	testing.expect(t, len(directory) > 0, "TEMP names nowhere to put a scratch cache")

	return fmt.aprintf(
		"%s\\transcibr-audio-%d-%s",
		directory,
		os.get_pid(),
		tag,
		allocator = context.allocator,
	)
}

// Best effort: a case that failed half-way should not fail a second time on the
// way out.
@(private)
remove_cache :: proc(cache: string) {
	listing, unreadable := os.read_all_directory_by_path(cache, context.allocator)
	if unreadable == nil {
		defer os.file_info_slice_delete(listing, context.allocator)
		for info in listing {
			os.remove(info.fullpath)
		}
	}
	os.remove(cache)
}

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

// `waitfor` registers its signal name machine-wide, and a second instance asking
// for a name already registered fails at once -- so cases that share one name
// make a different one red on each run. The process id keeps two sweeps apart;
// the tag keeps two cases apart.
@(private)
@(require_results)
lonely_signal :: proc(tag: string) -> string {
	assert(len(tag) > 0, "a signal name shared by two cases is a signal one of them cannot have")

	return fmt.aprintf(
		"transcibrAudioNoSignal%d%s",
		os.get_pid(),
		tag,
		allocator = context.allocator,
	)
}

@(private)
@(require_results)
open_group :: proc(t: ^testing.T) -> (group: child.Job_Object, ok: bool) {
	err: child.Error
	group, err = child.job_object_open()
	if !testing.expectf(t, err.fault == .None, "no job object: %v", err.fault) {
		return group, false
	}
	return group, true
}

@(test)
a_sweep_of_a_real_cache_takes_what_it_chose_and_nothing_else :: proc(t: ^testing.T) {
	cache := scratch_cache(t, "sweep")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)
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

	cache := scratch_cache(t, "directory")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)
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
	cache := scratch_cache(t, "held")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)
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
	cache := scratch_cache(t, "head")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)
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
	cache := scratch_cache(t, "missing")
	defer delete(cache, context.allocator)
	path := fmt.aprintf("%s\\never-written.wav", cache, allocator = context.allocator)
	defer delete(path, context.allocator)

	buffer: [64]u8 = ---
	_, _, err := read_head(path, buffer[:])
	testing.expect_value(t, err.fault, Fault.Audio_Unreadable)
}

@(test)
a_recording_looked_at_too_soon_is_looked_at_again_rather_than_refused :: proc(t: ^testing.T) {
	cache := scratch_cache(t, "settle")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)
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
	cache := scratch_cache(t, "unsettled")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)
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
	cache := scratch_cache(t, "part")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)
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

@(test)
a_child_that_exits_inside_its_bound_ran_to_completion :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	ending, err := run_bounded(&group, CMD, {"/c", "exit 3"}, RUN_BOUND_MS, context.allocator)
	testing.expect_value(t, err.fault, child.Fault.None)
	testing.expect_value(t, ending, Run.Finished)
}

@(test)
a_child_that_outlives_its_bound_is_stopped_rather_than_waited_for :: proc(t: ^testing.T) {
	signal := lonely_signal("bound")
	defer delete(signal, context.allocator)
	command := fmt.aprintf(
		"waitfor /t %d %s",
		LONGER_SECONDS,
		signal,
		allocator = context.allocator,
	)
	defer delete(command, context.allocator)

	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	ending, err := run_bounded(&group, CMD, {"/c", command}, SHORT_BOUND_MS, context.allocator)
	testing.expect_value(t, err.fault, child.Fault.None)
	testing.expect_value(t, ending, Run.Stopped)
}

@(test)
a_child_that_will_not_start_is_reported_rather_than_asserted :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	ending, err := run_bounded(
		&group,
		"transcibr-no-such-executable.exe",
		{},
		RUN_BOUND_MS,
		context.allocator,
	)
	testing.expect_value(t, ending, Run.Not_Started)
	testing.expect_value(t, err.fault, child.Fault.Not_Started)

	message := error_message(
		Error{fault = .Extraction_Not_Started, child = err},
		"C:\\clips\\one.mp4",
		context.allocator,
	)
	defer delete(message, context.allocator)
	testing.expect(t, len(message) > 0, "a refusal rendered as nothing at all")
}
