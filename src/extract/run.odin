package extract

import "core:fmt"
import "core:mem"
import "core:os"
import "core:time"
import "transcibr:child"
import "transcibr:process"

// This file drives the two children and the filesystem. It is the whole of what
// ADR-0009 says will never have a unit test, kept thin enough to inspect by
// reading: every branch in it either calls a decision next door or reports what
// the world said.

// Where the two executables are. Handed in rather than resolved here: which
// ffmpeg a Batch runs is a settings question and one ADR-0013 answers with a
// bundled build, and a shell module that went looking for one would be a second
// place that answer lives.
Tools :: struct {
	ffmpeg:  string,
	ffprobe: string,
}

// What one Recording's extraction produced, and what the job carries forward.
Extracted :: struct {
	// The scratch WAV. OWNED by the caller and freed with `delete` and the
	// allocator that was handed in.
	audio:        string,
	// The container's own duration, which is what "carried with the job" means:
	// the Sidecar records it, the progress estimate keys on it, and the check
	// below measured the produced audio against it.
	container_ms: i64,
	audio_ms:     i64,
}

// How long ffprobe is given, in milliseconds. Generous against a Recording on a
// slow network share, and BOUNDED because nothing may block forever (issue #27):
// a probe that never returns is a Batch that never starts.
PROBE_BOUND_MS :: i64(60_000)

// How long one extraction is given, in milliseconds.
//
// Half an hour against a corpus whose longest Recording is 168 minutes. ffmpeg
// decoding to PCM runs far faster than realtime and the cost that actually
// scales is reading the source -- two gigabytes over a hundred-megabit share is
// about three minutes -- so this is roughly an order of magnitude of headroom
// over anything measured. What it bounds is a wedge, not slowness.
EXTRACTION_BOUND_MS :: i64(30 * 60 * 1000)

// How long each poll of a running child waits before it drains the child's
// diagnostic output again. Long enough not to spin, short enough that a bound is
// honoured to a fraction of a second.
@(private)
POLL_MS :: u32(25)

// How much of the produced audio is read back to find its chunks.
//
// The head and never the file: a Recording's audio is hundreds of megabytes, and
// what is needed from it is a chunk table that ffmpeg writes in the first
// hundred bytes. Sixty-four kilobytes is six hundred times that, so a muxer that
// one day writes a much larger `LIST` still walks -- and a head that ran out is
// reported as `.Head_Too_Short` rather than as a malformed file.
@(private)
AUDIO_HEAD_BYTES :: 64 * 1024

// One reading of a Recording, taken now.
//
// `taken_ns` is the WALL CLOCK and not a monotonic tick, which is a decision: a
// Reading is taken when the Batch is planned and compared when the Recording's
// extraction starts, and a Batch resumes across a reboot (ADR-0003) -- a
// monotonic tick from a previous boot compares against nothing. The cost is that
// a clock step between two readings distorts the GAP; it cannot distort the size
// or the modification time, which are what actually prove a file is moving.
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

// Whether a Recording has stopped changing, against the reading taken when the
// Batch planned it.
//
// Waits at most once, and only where the two readings are too close together to
// mean anything -- which for every Recording but the first in a Batch has
// already been true for minutes by the time its extraction starts. See
// settling.odin for what the gap costs and who pays it.
settle :: proc(
	source: string,
	planned: Reading,
	gap_ns: i64,
	allocator: mem.Allocator,
) -> (
	reading: Reading,
	err: Error,
) {
	assert(planned.taken_ns > 0, "a Recording was settled against a reading nobody took")
	assert(gap_ns > 0, "a gap of no time at all says nothing about anything")

	now, unreadable := read_source(source, allocator)
	if unreadable.fault != .None {
		return {}, unreadable
	}
	switch settling(planned, now, gap_ns) {
	case .Still_Being_Written:
		return {}, Error{fault = .Still_Being_Written}
	case .Settled:
		return now, Error{}
	case .Too_Soon_To_Tell:
	// Waited out below.
	}

	// Clamped to the whole gap, never more. `now` and `planned` carry a wall
	// clock, and a clock that stepped backwards between them makes the
	// arithmetic ask for a longer wait than the gap ever was.
	time.sleep(time.Duration(min(gap_ns, gap_ns - (now.taken_ns - planned.taken_ns))))
	again, vanished := read_source(source, allocator)
	if vanished.fault != .None {
		return {}, vanished
	}
	// Against the PLANNED reading and not against `now`: the gap that has to
	// be long enough is the whole of it, and comparing the last two readings
	// would answer "too soon" for ever.
	switch settling(planned, again, gap_ns) {
	case .Still_Being_Written:
		return {}, Error{fault = .Still_Being_Written}
	case .Settled:
		return again, Error{}
	case .Too_Soon_To_Tell:
		return {}, Error{fault = .Still_Unsettled}
	}
	return {}, Error{fault = .Still_Unsettled}
}

// Runs one child to completion under a wall-clock bound, draining its diagnostic
// output so the pipe cannot fill and wedge it.
//
// `finished` false means the bound ran out and the child was stopped. The exit
// code is returned and DELIBERATELY not interpreted here: ADR-0002 measured that
// exit code zero means nothing, so what each caller checks is what the child
// actually produced.
@(private)
run_bounded :: proc(
	group: ^child.Job_Object,
	executable: string,
	arguments: []string,
	bound_ms: i64,
	allocator: mem.Allocator,
) -> (
	code: u32,
	finished: bool,
	err: child.Error,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(bound_ms > 0, "a child given no time at all cannot do anything")

	c, refusal := child.start(group, executable, arguments, allocator)
	if refusal.fault != .None {
		return 0, false, refusal
	}
	defer child.close(&c)

	started := time.tick_now()
	discarded: [4096]u8
	for {
		// Drained and thrown away. The pipe is 64 KiB and ffmpeg at
		// `-loglevel error` says almost nothing, but a Recording that fails to
		// decode says a line per frame -- and an undrained pipe stops the child
		// dead with no error anywhere (ADR-0004).
		for {
			read, at_end, reading := child.read_diagnostics(&c, discarded[:])
			if reading.fault != .None || at_end || read == 0 {
				break
			}
		}
		if child.wait(&c, POLL_MS) {
			break
		}
		if i64(time.duration_milliseconds(time.tick_since(started))) > bound_ms {
			child.stop(&c)
			return 0, false, child.Error{}
		}
	}
	code, _ = child.exit_code(&c)
	return code, true, child.Error{}
}

// Asks ffprobe how long a Recording is and what streams it carries.
//
// The answer goes to a file in the cache and is deleted afterwards: ADR-0004
// sends every child's standard output to the null device, and `-o` is what lets
// one spawner serve a child that has something to say on it.
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

	arguments := process.probe_arguments(source, answer, allocator)
	defer delete(arguments, allocator)

	_, finished, refusal := run_bounded(group, tools.ffprobe, arguments, PROBE_BOUND_MS, allocator)
	defer os.remove(answer)
	if refusal.fault != .None {
		return {}, Error{fault = .Probe_Not_Started, child = refusal}
	}
	if !finished {
		return {}, Error{fault = .Probe_Did_Not_Finish}
	}

	// The exit code is not consulted, which is ADR-0002's rule applied to the
	// other child: what settles it is whether there is a readable answer.
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

// Reads back what ffmpeg produced and checks it is what ffmpeg was asked for.
//
// A4's read side, and the reason `transcibr:process` holds the two numbers as
// constants: the command line asks for them here and this demands them there.
@(private)
check_audio :: proc(
	part: string,
	container_ms: i64,
	tolerance: Tolerance,
	allocator: mem.Allocator,
) -> (
	produced_ms: i64,
	err: Error,
) {
	assert(len(part) > 0, "there is no audio here to check")
	assert(container_ms > 0, "a container with no duration was never accepted by the probe")

	head, bytes, unreadable := read_head(part, allocator)
	if unreadable.fault != .None {
		return 0, unreadable
	}
	defer delete(head, allocator)

	facts, malformed := read_wav_facts(head, bytes)
	if malformed != .None {
		return 0, Error{fault = .Audio_Malformed, riff = malformed}
	}
	if facts.channels != process.AUDIO_CHANNELS ||
	   facts.samples_per_second != process.AUDIO_SAMPLE_RATE {
		return 0, Error{fault = .Audio_Not_As_Asked_For}
	}

	produced_ms = audio_ms(facts)
	if !durations_agree(container_ms, produced_ms, tolerance) {
		return 0, Error{fault = .Durations_Disagree, said = container_ms, got = produced_ms}
	}
	return produced_ms, Error{}
}

// The front of a file, and how long the whole file is.
//
// One open for both, so the length belongs to the same file the bytes came from:
// a stat taken separately can name a file something has replaced in between.
@(private)
read_head :: proc(path: string, allocator: mem.Allocator) -> (head: []u8, bytes: i64, err: Error) {
	handle, refused := os.open(path)
	if refused != nil {
		return nil, 0, Error{fault = .Audio_Unreadable}
	}
	defer os.close(handle)

	length, unmeasurable := os.file_size(handle)
	if unmeasurable != nil {
		return nil, 0, Error{fault = .Audio_Unreadable}
	}

	buffer := make([]u8, min(int(length), AUDIO_HEAD_BYTES), allocator)
	read, unreadable := os.read_at(handle, buffer, 0)
	if unreadable != nil && read == 0 {
		delete(buffer, allocator)
		return nil, 0, Error{fault = .Audio_Unreadable}
	}
	return buffer[:read], length, Error{}
}

// One Recording's extraction, as everything it needs to be started.
//
// A record rather than five parameters, so a caller cannot get two paths the
// wrong way round -- and so `name` is visibly the artifact stem (ADR-0008) that
// the audio, the Engine's output and the Sidecar all share, rather than a
// filename someone invents here.
Job :: struct {
	source:  string,
	// The scratch cache, ASCII-only (ADR-0002).
	cache:   string,
	// The stem every artifact of this Recording is named from.
	name:    string,
	// The reading taken when the Batch planned this Recording. See settle.
	planned: Reading,
}

// Turns one Recording into the mono 16 kHz audio the Engine reads, and answers
// how long the Recording actually is.
//
// Nothing is left behind on any failing path: the audio is written to a `.part`
// and moved into place in one step (the spec's rule for every artifact), and a
// `.part` that failed any check is removed rather than left for the next run to
// find.
//
// A8: every refusal here is an operating error against this one Recording, and
// the Batch carries on.
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

	if opening := open_cache(job.cache); opening.fault != .None {
		return {}, opening
	}
	if _, unsettled := settle(job.source, job.planned, MINIMUM_SETTLING_GAP_NS, allocator);
	   unsettled.fault != .None {
		return {}, unsettled
	}

	answer := fmt.aprintf("%s\\%s.probe", job.cache, job.name, allocator = allocator)
	defer delete(answer, allocator)
	probed, unprobed := probe(group, tools, job.source, answer, allocator)
	if unprobed.fault != .None {
		return {}, unprobed
	}
	// The criterion that names the file, and the one refusal that has to happen
	// before any GPU time is spent rather than after.
	if probed.audio_streams == 0 {
		return {}, Error{fault = .No_Audio_Stream}
	}
	return produce(group, tools, job, probed.duration_ms, tolerance, allocator)
}

// The extraction itself: ffmpeg into a `.part`, read the `.part` back, and only
// then move it into place.
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

	audio := fmt.aprintf("%s\\%s.wav", job.cache, job.name, allocator = allocator)
	part := fmt.aprintf("%s.part", audio, allocator = allocator)
	defer delete(part, allocator)
	defer if err.fault != .None {
		// Nothing half-written is left where the next run could find it and
		// take it for finished work.
		os.remove(part)
		delete(audio, allocator)
	}

	arguments := process.extract_arguments(job.source, part, allocator)
	defer delete(arguments, allocator)
	_, finished, refusal := run_bounded(
		group,
		tools.ffmpeg,
		arguments,
		EXTRACTION_BOUND_MS,
		allocator,
	)
	if refusal.fault != .None {
		return {}, Error{fault = .Extraction_Not_Started, child = refusal}
	}
	if !finished {
		return {}, Error{fault = .Extraction_Did_Not_Finish}
	}

	// The exit code is deliberately not consulted (ADR-0002): what settles it
	// is what is on the disk.
	audio_ms, unusable := check_audio(part, container_ms, tolerance, allocator)
	if unusable.fault != .None {
		return {}, unusable
	}
	if os.rename(part, audio) != nil {
		return {}, Error{fault = .Audio_Not_Published}
	}
	return Extracted{audio = audio, container_ms = container_ms, audio_ms = audio_ms}, Error{}
}

// The scratch cache, checked and created.
//
// The ASCII rule first, because it is ADR-0002's and it is about the whole cache
// rather than about anything in it -- and because a directory happily created
// under a non-ASCII path is exactly the failure that then shows up three stages
// later as an Engine that produced nothing.
@(private)
open_cache :: proc(cache: string) -> Error {
	assert(len(cache) > 0, "there is no scratch cache here to open")

	if !ascii_only(cache) {
		return Error{fault = .Cache_Path_Not_Ascii}
	}
	if os.make_directory_all(cache) != nil && !os.exists(cache) {
		// Both halves (A3): a cache that already exists is the ordinary case
		// and is not a failure, and one that could be created neither now nor
		// before is.
		return Error{fault = .Cache_Unusable}
	}
	return Error{}
}

// Sweeps the scratch cache at Batch start, and answers how many files went.
//
// Best effort by construction. Windows refuses to delete a file another process
// holds open without sharing delete permission, and that refusal is not this
// Batch's verdict to deliver: the file stays, the sweep carries on, and the
// Batch starts. What stops the sweep taking a file a worker is USING is the
// floor in sweep.odin, which does not depend on how that worker opened it.
sweep_cache :: proc(
	cache: string,
	limits: Sweep_Limits,
	allocator: mem.Allocator,
) -> (
	taken: int,
	err: Error,
) {
	assert(allocator.procedure != nil, "a listing needs an allocator to be read into")

	if opening := open_cache(cache); opening.fault != .None {
		return 0, opening
	}
	listing, unreadable := os.read_all_directory_by_path(cache, allocator)
	if unreadable != nil {
		return 0, Error{fault = .Cache_Unusable}
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
	assert(taken <= len(chosen), "the sweep removed more files than it chose")
	return taken, Error{}
}

// A directory listing as the sweep sees it: files only, each with its age.
//
// A file dated in the FUTURE gets a negative age and is therefore younger than
// the floor, so it is never taken. That is the safe answer to a clock skew or a
// file copied off a machine running ahead, and it is what falls out of doing the
// arithmetic in one place rather than clamping it in another.
@(private)
cache_entries :: proc(listing: []os.File_Info, allocator: mem.Allocator) -> []Cache_Entry {
	assert(allocator.procedure != nil, "a listing needs an allocator to be turned into entries")

	now := time.time_to_unix_nano(time.now())
	entries := make([dynamic]Cache_Entry, 0, len(listing), allocator)
	for info in listing {
		// Directories and everything else are left alone. The cache holds
		// files transcibr wrote; anything else in it is somebody else's.
		if info.type != .Regular {
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
	return entries[:]
}
