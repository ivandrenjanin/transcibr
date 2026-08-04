package audio

import "core:fmt"
import "core:mem"
import "core:os"
import "core:time"
import "transcibr:child"
import "transcibr:process"

// This file drives the two children and the filesystem, and is kept thin enough
// to inspect by reading: every branch in it either calls a decision next door or
// reports what the world said.
//
// ADR-0009 says the pipeline and the subprocess layer will never have UNIT
// tests, and that is about the decisions -- there are none here to unit-test.
// What run_test.odin does instead is what `src/child` already does: start real
// children under real bounds and sweep a real directory. The part that needs
// ffmpeg and ffprobe themselves is verified by hand and recorded in the pull
// request.

// Where the two executables are. Handed in rather than resolved here: which
// ffmpeg a Batch runs is a settings question and one ADR-0013 answers with a
// bundled build, and a shell module that went looking for one would be a second
// place that answer lives.
Tools :: struct {
	ffmpeg:  string,
	ffprobe: string,
}

// The length a piece of audio's OWN HEADER works out to, in milliseconds, and
// never a duration for anything downstream to use.
//
// A DISTINCT TYPE AND NOT A NAME, which is rule T2's remedy pointed at something
// that is not an identifier. The spec is explicit -- "Duration comes from the
// Engine's startup banner or from a container probe, never from the scratch
// audio file's header" -- and this was a plain `i64` renamed to say so, which
// documents the trap without closing it. As a distinct type, handing one to
// something that wants a duration is a COMPILE ERROR, and the cast at the
// storage edge is the one place a reader should slow down.
//
// What makes it dangerous rather than obviously wrong is that it has come
// through durations_agree: it is within a second of right, so a Sidecar written
// from it is wrong by too little for anyone to notice, and wrong permanently.
Measured_Ms :: distinct i64

// What one Recording's extraction produced, and what the job carries forward.
Extracted :: struct {
	// The scratch WAV. OWNED by the caller and freed with `delete` and the
	// allocator that was handed in.
	audio:        string,
	// The container's own duration, and THE ONLY DURATION HERE. It is what
	// "carried with the job" means: the Sidecar records it and the progress
	// estimate keys on it.
	container_ms: i64,
	// What the produced WAV's own header works out to -- the MEASUREMENT the
	// check made. Its TYPE is what keeps a consumer reaching for a duration from
	// reaching this instead; see Measured_Ms above.
	measured_ms:  Measured_Ms,
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
// diagnostic output again.
//
// A QUARTER OF A SECOND, against bounds of sixty seconds and half an hour. At 25
// milliseconds this was eighty kernel calls a second per running child to honour
// a bound to a fiftieth of a percent of itself; a quarter of a second loses
// nothing either bound can measure. What it must stay well under is the pipe
// filling, and the pipe is 64 KiB against a child at `-loglevel error`.
@(private)
POLL_MS :: u32(250)

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
//
// THE SETTLED READING IS NOT RETURNED, and its absence is the decision. It was,
// and the one caller discarded it -- the same defect this file records twenty
// lines down for `run_bounded`'s exit code, in the file that had just recorded
// it. A Reading nobody reads is a second thing that can be wrong about which
// file was looked at.
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

	// A REFUSAL AND NOT AN ASSERTION (A8). This was an assertion, and a Reading
	// carries a wall clock precisely so a Batch can resume across a reboot
	// (ADR-0003) -- so the day one is read back off a disk rather than passed
	// along in memory, a reading with no timestamp on it is external input, and
	// asserting on it crashes the Batch that resume exists for.
	if planned.taken_ns <= 0 {
		return Error{fault = .Planned_Reading_Unusable}
	}

	// SETTLING_ATTEMPTS TIMES AT MOST, and the later looks only where the readings
	// so far were too close together to mean anything. Read-and-decide is one
	// thing, so it is spelled once: every pass compares against the PLANNED
	// reading and never against the last one, because the gap that has to be long
	// enough is the whole of it and comparing the last two would answer "too soon"
	// for ever.
	//
	// WHAT TO MAKE OF EACH LOOK IS NOT DECIDED HERE. That is settling_fault next
	// door, which has cases of its own -- including the one that says a Recording
	// nothing was ever seen to stop writing is a refusal and not a success.
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
	// settling_fault asks for another look only where `attempts_left` is above
	// zero, and the last pass hands it zero. This package's own arithmetic and
	// nothing external (A8), so it is a crash and not a fabricated verdict --
	// which is what a second `.Still_Unsettled` spelled here would be: a line no
	// case can reach, saying what the loop already said.
	unreachable()
}

// How one bounded run of a child ended.
//
// THE EXIT CODE IS NOT IN HERE, and its absence is the decision: ADR-0002
// measured that exit code zero means nothing, so what each caller checks is what
// the child actually produced. It used to be returned, and both callers computed
// it and threw it away -- twenty lines of comment explaining a value nothing
// read, and a fabricated `0` on the path where no child had exited at all.
@(private)
Run :: enum u8 {
	// It never started. `err` says why.
	Not_Started = 0,
	// It exited by itself, inside its bound.
	Finished,
	// It had to be stopped, and it stopped.
	Stopped,
	// It had to be stopped and WOULD NOT. It may still be running, and it may
	// still hold its output file open -- which is why nothing may delete that
	// file (CLAUDE.md's rule on stopping a child).
	Unstoppable,
}

// Runs one child to completion under a wall-clock bound, draining its diagnostic
// output so the pipe cannot fill and wedge it.
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
			// A pipe that cannot be read is not something to wait out. An
			// undrained pipe stops the child dead with no error anywhere
			// (ADR-0004), so a read that fails IS that wedge, arriving early --
			// and polling to the bound turns a failure detectable in
			// milliseconds into half an hour of nothing happening.
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

// Everything the child has said so far, read and thrown away. False means the
// pipe could not be read.
//
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

// Stops a child that has to go, and says whether it went.
//
// The answer was DISCARDED, and it is the one thing the caller has to know:
// CLAUDE.md's rule for stopping a child is "do not touch any file the child had
// open until the wait completes", and `stop` returning false is exactly the
// report that it did not.
@(private)
stop :: proc(c: ^child.Child) -> Run {
	assert(c != nil, "there is no child here to stop")

	if child.stop(c) {
		return .Stopped
	}
	return .Unstoppable
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
	assert(len(source) > 0, "there is no Recording here to probe")

	arguments := process.probe_arguments(source, answer, allocator)
	defer delete(arguments, allocator)

	ending, refusal := run_bounded(group, tools.ffprobe, arguments, PROBE_BOUND_MS, allocator)
	// A SWITCH AND NOT THREE `if`s WITH AN ASSERT AFTER THEM. Both cover the four
	// endings; only one of them makes a FIFTH ending a build failure rather than
	// a crash on the Recording that met it, which is the guard this package's own
	// FAULT tables are built on.
	switch ending {
	case .Not_Started:
		return {}, Error{fault = .Probe_Not_Started, child = refusal}
	case .Unstoppable:
		// The answer file is NOT removed. ffprobe may still be running and may
		// still hold it open, and CLAUDE.md's rule for stopping a child is not
		// to touch a file it had open until the wait completes. The sweep takes
		// it on age instead.
		return {}, Error{fault = .Probe_Not_Stopped}
	case .Stopped, .Finished:
	// The child is gone either way, which is what makes the answer file
	// transcibr's to delete below. Which of the two it was is asked after.
	}
	// Past here the child is gone, and its answer file is transcibr's to delete.
	defer os.remove(answer)
	if ending == .Stopped {
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
// The two decisions in it are next door and are pure: as_asked_for in riff.odin
// compares the format against what the command line asked for, and
// durations_agree in duration.odin measures the audio against the container.
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

	// ON THE STACK, and never allocated. The head is read and finished with
	// inside this procedure, so an allocation for it would be one whose whole
	// life is these twenty lines -- and it was freed at the length that was
	// READ rather than the length that was reserved, which Odin's heap
	// allocator forgives and a size-classed one (ADR-0010) would not.
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
	// The cast at the storage edge, and the one place a measurement becomes
	// something a caller can carry (T2).
	return Measured_Ms(measured), Error{}
}

// The front of a file, and how long the whole file is.
//
// One open for both, so the length belongs to the same file the bytes came from:
// a stat taken separately can name a file something has replaced in between.
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

// One Recording's extraction, as everything it needs to be started.
//
// A record rather than five parameters, so a caller cannot get two paths the
// wrong way round -- and so `name` is visibly the artifact stem (ADR-0008) that
// the audio, the Engine's output and the Sidecar all share, rather than a
// filename someone invents here.
//
// THE TWO INTERMEDIATES ARE NAMED FOR THIS PROCESS AS WELL AS THE RECORDING, and
// the finished audio is not. `<name>.probe` and `<name>.wav.part` are the same
// two names in every transcibr on the machine, and the scratch cache is shared,
// so two windows over one Recording had one worker's `defer os.remove(answer)`
// deleting the other's probe answer and one worker's rename moving the file the
// other's ffmpeg was still writing. Every outcome of that is an operating error
// against one Recording, and it is still two runs colliding over a name neither
// agreed to share. `<name>.wav` stays plain: it is the artifact stem, and two
// workers that both produced it produced the same bytes.
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
// the Batch carries on. THAT IS WHY THE CACHE IS NOT CHECKED HERE: a cache that
// will not open is not a fact about this Recording, it fails every Recording in
// the Batch identically, and it is `open_cache`'s answer in its own vocabulary.
// A Batch calls that once -- `sweep_cache` does -- before the first extraction.
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
	// A switch, for the reason `probe` gives: a fifth ending is a build failure
	// here and was a crash on whichever Recording first met it.
	switch ending {
	case .Not_Started:
		return {}, Error{fault = .Extraction_Not_Started, child = refusal}
	case .Stopped:
		return {}, Error{fault = .Extraction_Did_Not_Finish}
	case .Unstoppable:
		return {}, Error{fault = .Extraction_Not_Stopped}
	case .Finished:
	// Past here ffmpeg is gone, and what it left is transcibr's to read back.
	}

	// The exit code is deliberately not consulted (ADR-0002): what settles it
	// is what is on the disk.
	measured, unusable := check_audio(part, container_ms, tolerance)
	if unusable.fault != .None {
		return {}, unusable
	}
	if os.rename(part, audio) != nil {
		return {}, Error{fault = .Audio_Not_Published}
	}
	return Extracted{audio = audio, container_ms = container_ms, measured_ms = measured}, Error{}
}

// Removes the half-written audio a failed extraction left behind, unless ffmpeg
// would not stop.
//
// THE ONE PLACE THE `.part` IS DELETED, and a procedure rather than a condition
// buried in `produce`'s own `defer` for the reason ADR-0018 gives: it is a
// decision, nothing in run.odin can be reached by a case, and deleting the guard
// outright passed every case in this package.
//
// What the guard is for is CLAUDE.md's rule on stopping a child -- do not touch
// any file the child had open until the wait completes. `.Extraction_Not_Stopped`
// is the report that the wait never completed: ffmpeg may still be running and
// may still hold this file. The sweep takes it on age instead. Every other
// failure leaves a half-written file the next run would find and take for
// finished work.
@(private)
discard_part :: proc(part: string, fault: Fault) {
	assert(len(part) > 0, "there is no half-written audio here to discard")
	assert(fault != .None, "an extraction that came through has no half-written audio")

	if fault == .Extraction_Not_Stopped {
		return
	}
	os.remove(part)
}

// The scratch cache, checked and created. ONCE PER BATCH and never per
// Recording: what it answers is about the whole cache, its answer is the same
// for every Recording in the Batch, and a Batch whose cache will not open has
// nowhere to put any Recording's audio. `extract` does not call it.
//
// THE RESOLVED PATH IS WHAT IS CHECKED, which is ADR-0002's own wording -- it
// asks that `doctor` fail "when the *resolved* cache or model path contains a
// non-ASCII byte" -- and the scenario it names is a non-ASCII Windows account
// name inside %LOCALAPPDATA%. A relative cache path is perfectly ASCII and
// resolves under one, so checking the string as handed in answers about a path
// nothing will ever open.
//
// The ASCII rule comes before the directory is created, because a directory
// happily created under a non-ASCII path is exactly the failure that then shows
// up three stages later as an Engine that produced nothing.
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
		// Both halves (A3): a cache that already exists is the ordinary case
		// and is not a failure, and one that could be created neither now nor
		// before is.
		return .Unusable
	}
	return .None
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
	fault: Cache_Fault,
) {
	assert(len(cache) > 0, "there is no scratch cache here to sweep")
	assert(allocator.procedure != nil, "a listing needs an allocator to be read into")

	if opening := open_cache(cache, allocator); opening != .None {
		return 0, opening
	}
	// `core:os` and not a hand-rolled FindFirstFileW walk, which is a decision
	// with a measured cost: that listing opens a HANDLE per entry to work out
	// each file's type, roughly four kernel calls and two allocations apiece.
	//
	// IT IS NOT WASTE, which is what this said before. The size, the modification
	// time and the directory and reparse-point attributes do all come from the
	// directory entry itself -- but the open is exactly what decides `.Regular`
	// against `.Undetermined`, and cache_entries keeps both and turns on that
	// distinction being made at all. A walk that never opened anything would have
	// to make it some other way.
	//
	// What it costs is bounded anyway. This runs ONCE per Batch, and a
	// thousand-file cache is some tens of milliseconds against a Batch measured in
	// hours -- while the alternative is hand-rolled Win32 in the procedure that
	// deletes files.
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

// A directory listing as the sweep sees it: files only, each with its age.
//
// A file dated in the FUTURE gets a negative age and is therefore younger than
// the floor, so it is never taken. That is the safe answer to a clock skew or a
// file copied off a machine running ahead, and it is what falls out of doing the
// arithmetic in one place rather than clamping it in another.
//
// `.Undetermined` IS COUNTED, and what that admits is wider than this once
// claimed. It said the leftover was "exactly a file nothing could open", and
// `core:os` does not classify that narrowly: `stat_windows.odin` calls an entry
// a `.Symlink` for `IO_REPARSE_TAG_SYMLINK` and `IO_REPARSE_TAG_MOUNT_POINT` and
// for no other tag, so ANY other reparse point on a non-directory falls through
// to `.Undetermined` the moment its handle will not open. Measured on this
// machine: `%LOCALAPPDATA%\Microsoft\WindowsApps` lists 39 entries that way --
// AppExecLinks, size zero, neither symlink nor junction nor directory. The
// realistic one inside a cache is a cloud-files placeholder whose hydration
// fails offline.
//
// Counting them is still the right answer, and it rests on the part that is not
// in doubt: the size and the modification time of an `.Undetermined` entry come
// from the DIRECTORY ENTRY and are exactly as good as a `.Regular` one's. What
// dropping them cost was measured -- their bytes never entered the total, so a
// cache dominated by in-flight `.part` files measured well under its ceiling and
// swept nothing at all, which is the leak the ceiling exists to stop.
//
// What bounds the widening is not this filter. It is the floor and the two
// ceilings in sweep.odin, which an `.Undetermined` entry meets like any other,
// and the fact that sweep_cache is best effort by construction: it may CHOOSE
// such a file, `os.remove` may refuse, and it counts what it actually removed.
@(private)
cache_entries :: proc(listing: []os.File_Info, allocator: mem.Allocator) -> []Cache_Entry {
	assert(allocator.procedure != nil, "a listing needs an allocator to be turned into entries")

	now := time.time_to_unix_nano(time.now())
	entries := make([dynamic]Cache_Entry, 0, len(listing), allocator)
	for info in listing {
		// Directories and symbolic links are left alone. The cache holds files
		// transcibr wrote; anything else in it is somebody else's. `.Undetermined`
		// is kept, and what that is and what it admits is above.
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
	// Shrunk to what was kept, so the slice handed back is the whole of its own
	// allocation: `delete` frees `len` items and this was made at `cap`.
	shrink(&entries)
	return entries[:]
}
