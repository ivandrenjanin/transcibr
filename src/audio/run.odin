package audio

import "core:fmt"
import "core:mem"
import "core:os"
import "core:time"
import "transcibr:child"
import "transcibr:process"

Tools :: struct {
	ffmpeg:  string,
	ffprobe: string,
}

// The length a piece of audio's own header works out to, in milliseconds, and
// never a duration for anything downstream to use. Distinct so that handing one
// where a duration belongs is a compile error rather than a Sidecar wrong by a
// second, permanently.
Measured_Ms :: distinct i64

Extracted :: struct {
	// Owned by the caller and freed with the allocator that was handed in.
	audio:        string,
	container_ms: i64,
	measured_ms:  Measured_Ms,
}

PROBE_BOUND_MS :: i64(60_000)

// Half an hour against a corpus whose longest Recording is 168 minutes: ffmpeg
// decodes far faster than realtime, and the cost that scales is reading the
// source. What it bounds is a wedge, not slowness.
EXTRACTION_BOUND_MS :: i64(30 * 60 * 1000)

// A quarter of a second, against bounds of sixty seconds and half an hour. At 25
// milliseconds this was eighty kernel calls a second per running child; what it
// must stay well under is the 64 KiB pipe filling at `-loglevel error`.
@(private)
POLL_MS :: u32(250)

// The head and never the file: a Recording's audio is hundreds of megabytes and
// the chunk table ffmpeg writes lands in the first hundred bytes, so this is six
// hundred times what is needed.
@(private)
AUDIO_HEAD_BYTES :: 64 * 1024

// Why `taken_ns` is a wall clock and not a monotonic tick: ADR-0023.
read_source :: proc(source: string, allocator: mem.Allocator) -> (reading: Reading, err: Error) {
	assert(len(source) > 0, "there is no Recording here to read")
	assert(allocator.procedure != nil, "a stat needs an allocator for the path it hands back")

	info, refusal := os.stat(source, allocator)
	if refusal != nil {
		return {}, Error{fault = .Source_Unreadable}
	}
	defer os.file_info_delete(info, allocator)

	return Reading {
		bytes = info.size,
		modified_ns = time.time_to_unix_nano(info.modification_time),
		taken_ns = time.time_to_unix_nano(time.now()),
	}, Error{}
}

settle :: proc(
	source: string,
	planned: Reading,
	gap_ns: i64,
	allocator: mem.Allocator,
) -> (
	err: Error,
) {
	assert(gap_ns > 0, "a gap of no time at all says nothing about anything")
	assert(len(source) > 0, "there is no Recording here to settle")
	assert(allocator.procedure != nil, "a stat needs an allocator for the path it hands back")

	if planned.taken_ns <= 0 {
		return Error{fault = .Planned_Reading_Unusable}
	}

	for attempt in 0 ..< SETTLING_ATTEMPTS {
		now, unreadable := read_source(source, allocator)
		if unreadable.fault != .None {
			return unreadable
		}
		fault, again := settling_fault(
			settling(planned, now, gap_ns),
			SETTLING_ATTEMPTS - attempt - 1,
		)
		if !again {
			return Error{fault = fault}
		}
		time.sleep(time.Duration(remaining_gap_ns(planned, now, gap_ns)))
	}
	unreachable()
}

@(private)
Run :: enum u8 {
	Not_Started = 0,
	Finished,
	Stopped,
	// It may still be running and may still hold its output file open, which is
	// why nothing may delete that file.
	Unstoppable,
}

@(private)
run_bounded :: proc(
	group: ^child.Job_Object,
	executable: string,
	arguments: []string,
	bound_ms: i64,
	allocator: mem.Allocator,
) -> (
	ending: Run,
	err: child.Error,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(bound_ms > 0, "a child given no time at all cannot do anything")
	assert(len(executable) > 0, "there is no executable here to start")
	assert(allocator.procedure != nil, "starting a child needs an allocator for its command line")

	c, refusal := child.start(group, executable, arguments, allocator)
	if refusal.fault != .None {
		return .Not_Started, refusal
	}
	defer child.close(&c)

	started := time.tick_now()
	for {
		if !drain(&c) {
			return stop(&c), child.Error{}
		}
		if child.wait(&c, POLL_MS) {
			return .Finished, child.Error{}
		}
		if i64(time.duration_milliseconds(time.tick_since(started))) > bound_ms {
			return stop(&c), child.Error{}
		}
	}
}

// The pipe is 64 KiB and ffmpeg at `-loglevel error` says almost nothing, but a
// Recording that fails to decode says a line per frame.
@(private)
drain :: proc(c: ^child.Child) -> (readable: bool) {
	assert(c != nil, "there is no child here to read")

	discarded: [4096]u8 = ---
	for {
		read, at_end, reading := child.read_diagnostics(c, discarded[:])
		if reading.fault != .None {
			return false
		}
		if at_end || read == 0 {
			return true
		}
		assert(read <= len(discarded), "the child said more than there was room for")
	}
}

@(private)
stop :: proc(c: ^child.Child) -> Run {
	assert(c != nil, "there is no child here to stop")

	if child.stop(c) {
		return .Stopped
	}
	return .Unstoppable
}

probe :: proc(
	group: ^child.Job_Object,
	tools: Tools,
	source: string,
	answer: string,
	allocator: mem.Allocator,
) -> (
	probed: process.Probe,
	err: Error,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(answer) > 0, "a probe with nowhere to write its answer says nothing")
	assert(len(source) > 0, "there is no Recording here to probe")

	arguments := process.probe_arguments(source, answer, allocator)
	defer delete(arguments, allocator)

	ending, refusal := run_bounded(group, tools.ffprobe, arguments, PROBE_BOUND_MS, allocator)
	switch ending {
	case .Not_Started:
		return {}, Error{fault = .Probe_Not_Started, child = refusal}
	case .Unstoppable:
		return {}, Error{fault = .Probe_Not_Stopped}
	case .Stopped, .Finished:
	}
	defer os.remove(answer)
	if ending == .Stopped {
		return {}, Error{fault = .Probe_Did_Not_Finish}
	}

	said, unreadable := os.read_entire_file(answer, allocator)
	if unreadable != nil {
		return {}, Error{fault = .Probe_Answer_Unreadable}
	}
	defer delete(said, allocator)

	answered, fault := process.read_probe(string(said))
	if fault != .None {
		return {}, Error{fault = .Probe_Unreadable, probe = fault}
	}
	return answered, Error{}
}

@(private)
check_audio :: proc(
	part: string,
	container_ms: i64,
	tolerance: Tolerance,
) -> (
	produced_ms: Measured_Ms,
	err: Error,
) {
	assert(len(part) > 0, "there is no audio here to check")
	assert(container_ms > 0, "a container with no duration was never accepted by the probe")

	buffer: [AUDIO_HEAD_BYTES]u8 = ---
	head, bytes, unreadable := read_head(part, buffer[:])
	if unreadable.fault != .None {
		return 0, unreadable
	}

	facts, malformed := read_wav_facts(head, bytes)
	if malformed != .None {
		return 0, Error{fault = .Audio_Malformed, riff = malformed}
	}
	if !as_asked_for(facts) {
		return 0, Error{fault = .Audio_Not_As_Asked_For}
	}

	measured := audio_ms(facts)
	if !durations_agree(container_ms, measured, tolerance) {
		return 0, Error{fault = .Durations_Disagree, said = container_ms, got = measured}
	}
	return Measured_Ms(measured), Error{}
}

// One open for both the length and the bytes, so the length belongs to the same
// file the bytes came from: a stat taken separately can name a file something
// has replaced in between.
@(private)
read_head :: proc(path: string, into: []u8) -> (head: []u8, bytes: i64, err: Error) {
	assert(len(path) > 0, "there is no audio here to read")
	assert(len(into) > 0, "a head with nowhere to be read into reads nothing")

	handle, refused := os.open(path)
	if refused != nil {
		return nil, 0, Error{fault = .Audio_Unreadable}
	}
	defer os.close(handle)

	length, unmeasurable := os.file_size(handle)
	if unmeasurable != nil {
		return nil, 0, Error{fault = .Audio_Unreadable}
	}

	wanted := into[:min(int(length), len(into))]
	read, unreadable := os.read_at(handle, wanted, 0)
	if unreadable != nil && read == 0 {
		return nil, 0, Error{fault = .Audio_Unreadable}
	}
	assert(read <= len(wanted), "more of the head came back than there was room for it")
	return wanted[:read], length, Error{}
}

// Why the two intermediates carry the process id and `<name>.wav` does not, and
// what the process id does not separate: ADR-0023.
Job :: struct {
	source:  string,
	cache:   string,
	name:    string,
	planned: Reading,
}

// The cache is not checked here: a cache that will not open is not a fact about
// this Recording, it fails every Recording identically, and it is `open_cache`'s
// answer -- which a Batch calls once, before the first extraction.
extract :: proc(
	group: ^child.Job_Object,
	tools: Tools,
	job: Job,
	allocator: mem.Allocator,
	tolerance := DEFAULT_TOLERANCE,
) -> (
	produced: Extracted,
	err: Error,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(job.name) > 0, "a Recording with no artifact stem has nowhere to put its audio")
	assert(allocator.procedure != nil, "an extraction needs an allocator to work in")

	if unsettled := settle(job.source, job.planned, MINIMUM_SETTLING_GAP_NS, allocator);
	   unsettled.fault != .None {
		return {}, unsettled
	}

	answer := fmt.aprintf(
		"%s\\%s.%d.probe",
		job.cache,
		job.name,
		os.get_pid(),
		allocator = allocator,
	)
	defer delete(answer, allocator)
	probed, unprobed := probe(group, tools, job.source, answer, allocator)
	if unprobed.fault != .None {
		return {}, unprobed
	}
	if probed.audio_streams == 0 {
		return {}, Error{fault = .No_Audio_Stream}
	}
	return produce(group, tools, job, probed.duration_ms, tolerance, allocator)
}

@(private)
produce :: proc(
	group: ^child.Job_Object,
	tools: Tools,
	job: Job,
	container_ms: i64,
	tolerance: Tolerance,
	allocator: mem.Allocator,
) -> (
	produced: Extracted,
	err: Error,
) {
	assert(container_ms > 0, "a container with no duration was never accepted by the probe")
	assert(len(job.name) > 0, "a Recording with no artifact stem has nowhere to put its audio")

	audio := fmt.aprintf("%s\\%s.wav", job.cache, job.name, allocator = allocator)
	part := fmt.aprintf("%s.%d.part", audio, os.get_pid(), allocator = allocator)
	defer delete(part, allocator)
	defer if err.fault != .None {
		discard_part(part, err.fault)
		delete(audio, allocator)
	}

	arguments := process.extract_arguments(job.source, part, allocator)
	defer delete(arguments, allocator)
	ending, refusal := run_bounded(group, tools.ffmpeg, arguments, EXTRACTION_BOUND_MS, allocator)
	switch ending {
	case .Not_Started:
		return {}, Error{fault = .Extraction_Not_Started, child = refusal}
	case .Stopped:
		return {}, Error{fault = .Extraction_Did_Not_Finish}
	case .Unstoppable:
		return {}, Error{fault = .Extraction_Not_Stopped}
	case .Finished:
	}

	measured, unusable := check_audio(part, container_ms, tolerance)
	if unusable.fault != .None {
		return {}, unusable
	}
	if os.rename(part, audio) != nil {
		return {}, Error{fault = .Audio_Not_Published}
	}
	return Extracted{audio = audio, container_ms = container_ms, measured_ms = measured}, Error{}
}

// `.Extraction_Not_Stopped` reports a wait that never completed, so ffmpeg may
// still be running and may still hold this file; the sweep takes it on age
// instead. Every other failure leaves a half-written file the next run would
// find and take for finished work.
@(private)
discard_part :: proc(part: string, fault: Fault) {
	assert(len(part) > 0, "there is no half-written audio here to discard")
	assert(fault != .None, "an extraction that came through has no half-written audio")

	if fault == .Extraction_Not_Stopped {
		return
	}
	os.remove(part)
}

// The resolved path is what is checked: a relative cache path is perfectly ASCII
// and resolves under an account name that may not be. A path that is not valid
// UTF-8 answers `.Unusable` rather than `.Path_Not_Ascii`, because
// `get_absolute_path` refuses it before the ASCII check ever sees it.
open_cache :: proc(cache: string, allocator: mem.Allocator) -> Cache_Fault {
	assert(len(cache) > 0, "there is no scratch cache here to open")
	assert(allocator.procedure != nil, "resolving a path needs an allocator to resolve it into")

	resolved, unresolvable := os.get_absolute_path(cache, allocator)
	if unresolvable != nil {
		return .Unusable
	}
	defer delete(resolved, allocator)

	if !ascii_only(resolved) {
		return .Path_Not_Ascii
	}
	if os.make_directory_all(cache) != nil && !os.exists(cache) {
		return .Unusable
	}
	return .None
}

// Best effort by construction: Windows refuses to delete a file another process
// holds open without sharing delete permission, so the file stays, the sweep
// carries on, and what is answered is what actually went.
sweep_cache :: proc(
	cache: string,
	limits: Sweep_Limits,
	allocator: mem.Allocator,
) -> (
	taken: int,
	fault: Cache_Fault,
) {
	assert(len(cache) > 0, "there is no scratch cache here to sweep")
	assert(allocator.procedure != nil, "a listing needs an allocator to be read into")

	if opening := open_cache(cache, allocator); opening != .None {
		return 0, opening
	}
	listing, unreadable := os.read_all_directory_by_path(cache, allocator)
	if unreadable != nil {
		return 0, .Unusable
	}
	defer os.file_info_slice_delete(listing, allocator)

	entries := cache_entries(listing, allocator)
	defer delete(entries, allocator)
	chosen := sweep_choice(entries, limits, allocator)
	defer delete(chosen, allocator)

	for index in chosen {
		if os.remove(entries[index].name) == nil {
			taken += 1
		}
	}
	return taken, .None
}

// Why the listing counts entries `core:os` cannot classify: ADR-0023.
@(private)
cache_entries :: proc(listing: []os.File_Info, allocator: mem.Allocator) -> []Cache_Entry {
	assert(allocator.procedure != nil, "a listing needs an allocator to be turned into entries")

	now := time.time_to_unix_nano(time.now())
	entries := make([dynamic]Cache_Entry, 0, len(listing), allocator)
	for info in listing {
		if info.type != .Regular && info.type != .Undetermined {
			continue
		}
		append(
			&entries,
			Cache_Entry {
				name = info.fullpath,
				bytes = info.size,
				age_ns = now - time.time_to_unix_nano(info.modification_time),
			},
		)
	}
	shrink(&entries)
	return entries[:]
}
