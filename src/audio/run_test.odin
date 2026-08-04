package audio

import "core:fmt"
import "core:os"
import win32 "core:sys/windows"
import "core:testing"
import "core:time"
import "transcibr:child"

// THE SHELL HALF, against real children and a real directory.
//
// ADR-0009 puts a ceiling on what is worth testing here -- "the pipeline, the
// subprocess layer, the Win32 window and the GPU path will never have unit
// tests" -- and this file is not that ceiling being ignored. It is the part of
// `run.odin` that `src/child` already showed can be checked: children started
// under a bound, and files in a directory. run.odin spawns two children, deletes
// files out of the scratch cache and renames the artifact, and it had no
// automated coverage at all -- sweep_cache included, which is the code that
// DELETES.
//
// WHAT IS STILL VERIFIED BY HAND, and recorded in the pull request, is
// everything that needs ffmpeg and ffprobe themselves: `probe`, `produce` and
// `extract` end to end against real media. A stand-in that answered ffprobe's
// argument list would be a test of the stand-in, and the argument lists are
// already pinned in `transcibr:process`.
//
// EVERY CHILD HERE IS BOUNDED, which is a rule rather than a habit: `odin test`
// runs what it builds, and a case that starts a child which never exits wedges
// the whole sweep behind scripts\common.ps1's ten-minute ceiling with nothing
// naming the case that did it (issue #27). Every machine-wide name carries the
// process id for the same reason `src/child` gives: two sweeps in one checkout
// must not be able to reach each other's objects.

// Found on PATH rather than spelled absolutely, which is what a bare name asks
// CreateProcessW to do -- and safely, because argv[0] is always quoted.
@(private)
CMD :: "cmd.exe"

// The ceiling on waiting for any child to exit. Generous against a cold or
// loaded machine and far under the sweep's own budget: what it bounds is a HANG.
@(private)
RUN_BOUND_MS :: i64(60_000)

// A bound far SHORTER than the child that has to outlive it, so the case that
// wants a stopped child measures the bound rather than the child's patience.
@(private)
SHORT_BOUND_MS :: i64(500)

// How long the child that must outlive its bound waits before ending itself,
// whatever this suite does or fails to do.
@(private)
LONGER_SECONDS :: 25

// A scratch cache of this run's own. The caller frees the path and removes the
// directory.
@(private)
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

// Everything a case left in the cache, and then the cache. Best effort: a case
// that failed half-way should not fail a second time on the way out.
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

// One file in the cache, of a given size and a given age. The caller frees the
// path.
//
// The age is SET and never waited for, which is what makes any of this a case at
// all: the sweep's ceilings are days and its floor is an hour.
@(private)
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

// A job object, or a case that gives up rather than starting a child outside
// one.
@(private)
open_group :: proc(t: ^testing.T) -> (group: child.Job_Object, ok: bool) {
	err: child.Error
	group, err = child.job_object_open()
	if !testing.expectf(t, err.fault == .None, "no job object: %v", err.fault) {
		return group, false
	}
	return group, true
}

// ------------------------------------------------------------- the sweep --

@(test)
a_sweep_of_a_real_cache_takes_what_it_chose_and_nothing_else :: proc(t: ^testing.T) {
	cache := scratch_cache(t, "sweep")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	stale := aged_file(t, cache, "stale.wav", 1024, 30 * 24 * time.Hour)
	defer delete(stale, context.allocator)
	// A `.part` minutes old is what a second transcibr window mid-Batch looks
	// like, and the floor is the whole reason it survives.
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
	// Limits under which EVERYTHING is over both ceilings and nothing at all is
	// protected, so a directory surviving is the entry filter doing it rather
	// than the floor. The cache holds files transcibr wrote; anything else in it
	// is somebody else's.
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
	// THE REPRODUCTION. os.read_all_directory_by_path opens a handle per entry
	// to decide what it is, and a file another process holds without sharing
	// cannot be opened -- so its type comes back `.Undetermined`, the entry
	// filter dropped it, and its bytes never entered the total. A cache
	// dominated by in-flight `.part` files therefore measured well under its
	// ceiling and swept nothing at all, which is the leak the ceiling exists to
	// stop.
	cache := scratch_cache(t, "held")
	defer delete(cache, context.allocator)
	defer remove_cache(cache)
	testing.expect_value(t, open_cache(cache, context.allocator), Cache_Fault.None)

	held := aged_file(t, cache, "held.bin", 2048, 30 * 24 * time.Hour)
	defer delete(held, context.allocator)
	older := aged_file(t, cache, "older.bin", 1024, 31 * 24 * time.Hour)
	defer delete(older, context.allocator)

	// No sharing at all, which is what an extraction's `.part` looks like from
	// outside while ffmpeg has it.
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

	// Two kibibytes of ceiling against three in the cache, an age ceiling out of
	// reach so nothing goes for being old, and both files well past the floor.
	limits := Sweep_Limits {
		max_bytes    = 2048,
		max_age_ns   = i64(365 * 24 * 60 * 60) * 1_000_000_000,
		spare_age_ns = i64(60 * 60) * 1_000_000_000,
	}
	taken, fault := sweep_cache(cache, limits, context.allocator)
	testing.expect_value(t, fault, Cache_Fault.None)

	// One file, and it is the older. Had the held file's two kibibytes been
	// dropped from the total, the cache would have measured one kibibyte against
	// a two kibibyte ceiling and NOTHING would have gone.
	testing.expect_value(t, taken, 1)
	testing.expect(t, !os.exists(older), "the oldest file over the size ceiling stayed")
	testing.expect(t, os.exists(held), "the sweep took the one file it could not open")
}

// ------------------------------------------------------- the scratch cache --

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
	// The half that matters (A3): it was not created either. A directory happily
	// made under a non-ASCII path is the failure that shows up three stages
	// later as an Engine that produced nothing (ADR-0002).
	testing.expect(t, !os.exists(cache), "a cache the Engine cannot open was created anyway")
}

@(test)
the_head_of_a_real_wav_on_disk_walks_to_its_data_chunk :: proc(t: ^testing.T) {
	// read_head against a real file rather than a buffer: one open for the
	// length and the bytes, so the length belongs to the file the bytes came
	// from.
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
	// The whole fixture is far shorter than the head, so the head is the file.
	testing.expect_value(t, len(head), FFMPEG_WAV_BYTES)

	facts, malformed := read_wav_facts(head, bytes)
	testing.expect_value(t, malformed, Riff_Fault.None)
	testing.expect_value(t, facts.data_offset, 78)
	testing.expect(t, as_asked_for(facts), "the fixture off the disk is not what was asked for")
}

@(test)
a_head_read_from_a_file_that_is_not_there_is_refused :: proc(t: ^testing.T) {
	// A8: the produced audio is written by ffmpeg and read back off a disk, so
	// one that is not there is an operating error and never an assertion.
	cache := scratch_cache(t, "missing")
	defer delete(cache, context.allocator)
	path := fmt.aprintf("%s\\never-written.wav", cache, allocator = context.allocator)
	defer delete(path, context.allocator)

	buffer: [64]u8 = ---
	_, _, err := read_head(path, buffer[:])
	testing.expect_value(t, err.fault, Fault.Audio_Unreadable)
}

// ------------------------------------------------------- the bounded run --

@(test)
a_child_that_exits_inside_its_bound_ran_to_completion :: proc(t: ^testing.T) {
	group, ok := open_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	// EXIT CODE THREE, and it is `.Finished` all the same. ADR-0002 measured
	// that an exit code says nothing here, and run_bounded no longer even
	// collects one -- what settles a run is what the child left on the disk.
	ending, err := run_bounded(&group, CMD, {"/c", "exit 3"}, RUN_BOUND_MS, context.allocator)
	testing.expect_value(t, err.fault, child.Fault.None)
	testing.expect_value(t, ending, Run.Finished)
}

@(test)
a_child_that_outlives_its_bound_is_stopped_rather_than_waited_for :: proc(t: ^testing.T) {
	// `waitfor` on a signal nobody ever sends, with a timeout of its own so the
	// child ends by itself even if this case never gets to it. The name carries
	// the process id because waitfor registers it MACHINE-WIDE, and a second
	// instance asking for a name already registered fails at once -- measured
	// the hard way in `src/child`, where five cases shared one name.
	signal := fmt.aprintf("transcibrAudioNoSignal%d", os.get_pid(), allocator = context.allocator)
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
	// `.Stopped` and not `.Unstoppable`: the child went, so whatever it had open
	// is the caller's to delete now. That distinction is the whole reason this
	// answer is an enumeration rather than a bool.
	testing.expect_value(t, ending, Run.Stopped)
}

@(test)
a_child_that_will_not_start_is_reported_rather_than_asserted :: proc(t: ^testing.T) {
	// A8: an executable path arrives from outside -- a settings field, a
	// discovered tool -- so one that names nothing is an operating error the
	// caller turns into a Recording's failure row.
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

	// And it reaches a user as a line naming the Recording, which is the only
	// handle anybody has on which setting to go and fix.
	message := error_message(
		Error{fault = .Extraction_Not_Started, child = err},
		"C:\\clips\\one.mp4",
		context.allocator,
	)
	defer delete(message, context.allocator)
	testing.expect(t, len(message) > 0, "a refusal rendered as nothing at all")
}
