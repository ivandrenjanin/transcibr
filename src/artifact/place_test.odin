package artifact

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "transcibr:transcript"

// The whole of ADR-0002, against a real scratch cache and a real Recording's
// directory: validate what the Engine produced, move it into place atomically,
// and write the Sidecar last.
//
// THE ENGINE OUTPUT IS THE COMMITTED FIXTURE FROM `transcibr:transcript` and not
// a second copy of one. That file is one real whisper.cpp run, committed exactly
// as the Engine wrote it and held byte for byte by `**/fixtures/** -text`, and
// it is what pins the schema this design bets on (ADR-0001). A copy here would
// be a second piece of evidence that could drift from the first, and the cases
// below would then be checking this package against a file nobody had run the
// Engine to produce.
//
// NO GPU TIME IS SPENT ANYWHERE IN THIS FILE, and none needs to be: what is
// under test is what happens to the bytes the Engine left, and the bytes are on
// disk in the repository. The Engine's own half -- that it really writes them,
// that exit zero with no output is a failure -- is checked over a real child in
// `transcibr:engine`, and the two halves meet in the command-line binary.
@(private)
ENGINE_JSON :: #load("../transcript/fixtures/engine-output.json", string)

// A Recording's length, in the units the parser checks Cues against.
@(private)
FIXTURE_MS :: transcript.Millis(253_949)

// One Recording's Sidecar, filled in the way the shell fills it.
@(private)
made_by :: proc(profile := transcript.DEFAULT_PROFILE) -> Sidecar {
	return Sidecar {
		engine_version = "whisper.cpp v1.9.1",
		model = "C:\\models\\ggml-large-v3.bin",
		model_digest = Digest(ABC_SHA256),
		model_bytes = 3_094_623_691,
		beam = ENGINE_DEFAULT_BEAM,
		merge_profile = transcript.profile_name(profile),
		source_bytes = 402_653_184,
		source_modified_ns = 1_754_136_000_000_000_000,
		container_ms = i64(FIXTURE_MS),
	}
}

// The Render Context the shell hands in, with the language deliberately left for
// `complete` to read out of the Engine's own output (ADR-0001).
@(private)
rendered_as :: proc(
	source: string,
	profile := transcript.DEFAULT_PROFILE,
) -> transcript.Render_Context {
	return transcript.Render_Context {
		now = time.unix(1_754_136_000, 0),
		source_display = source,
		engine_version = "whisper.cpp v1.9.1",
		model = "ggml-large-v3",
		profile = profile,
	}
}

// Whether anything in a directory is a half-written artifact.
@(private)
holds_a_part :: proc(t: ^testing.T, directory: string) -> bool {
	listing, unreadable := os.read_all_directory_by_path(directory, context.allocator)
	if !testing.expect(t, unreadable == nil, "a directory a case just wrote to would not list") {
		return false
	}
	defer os.file_info_slice_delete(listing, context.allocator)

	for info in listing {
		if strings.has_suffix(info.name, ".part") {
			return true
		}
	}
	return false
}

// ------------------------------------------------- one artifact into place --

@(test)
bytes_reach_their_final_name_and_leave_no_temporary_behind :: proc(t: ^testing.T) {
	beside := scratch(t, "publish")
	defer delete(beside, context.allocator)
	defer remove_scratch(beside)

	destination := fmt.aprintf("%s\\talk.md", beside, allocator = context.allocator)
	defer delete(destination, context.allocator)

	err := publish(destination, transmute([]u8)string("# talk\n"), .Transcript, context.allocator)
	testing.expect_value(t, err.fault, Fault.None)

	written, unreadable := os.read_entire_file_from_path(destination, context.allocator)
	defer delete(written, context.allocator)
	testing.expect(t, unreadable == nil, "the artifact is not under the name it was published to")
	testing.expect_value(t, string(written), "# talk\n")
	// The other half (A3), and the one a rename that silently became a copy would
	// fail: the temporary name is gone.
	testing.expect(t, !holds_a_part(t, beside), "a published artifact left its temporary behind")
}

@(test)
publishing_over_an_artifact_that_is_already_there_replaces_it :: proc(t: ^testing.T) {
	// A Recording re-run under changed settings (ADR-0003) publishes over its own
	// artifacts, so a rename that refused an existing name would make every
	// re-run fail after the GPU time had already been spent. `core:os`'s rename
	// passes MOVEFILE_REPLACE_EXISTING, and this is what holds that shut.
	beside := scratch(t, "replace")
	defer delete(beside, context.allocator)
	defer remove_scratch(beside)

	destination := file_in(t, beside, "talk.md", "the transcript from an older run\n")
	defer delete(destination, context.allocator)

	err := publish(
		destination,
		transmute([]u8)string("the new one\n"),
		.Transcript,
		context.allocator,
	)
	testing.expect_value(t, err.fault, Fault.None)

	written, unreadable := os.read_entire_file_from_path(destination, context.allocator)
	defer delete(written, context.allocator)
	testing.expect(t, unreadable == nil, "the artifact went missing while being replaced")
	testing.expect_value(t, string(written), "the new one\n")
}

@(test)
an_artifact_that_cannot_be_moved_into_place_leaves_no_half_written_file :: proc(t: ^testing.T) {
	// A8: the filesystem is outside this program. A destination that cannot be
	// renamed onto -- here a DIRECTORY sitting under the artifact's own name,
	// which is a thing a user can really have -- is an operating error against
	// this Recording, and the half-written file it was going to be must not be
	// left for the next run to find and take for finished work.
	beside := scratch(t, "blocked")
	defer delete(beside, context.allocator)
	defer remove_scratch(beside)

	destination := fmt.aprintf("%s\\talk.md", beside, allocator = context.allocator)
	defer delete(destination, context.allocator)
	defer os.remove(destination)
	testing.expect(t, os.make_directory_all(destination) == nil, "could not block the destination")

	err := publish(destination, transmute([]u8)string("# talk\n"), .Transcript, context.allocator)
	testing.expect_value(t, err.fault, Fault.Not_Placed)
	testing.expect_value(t, err.which, Artifact.Transcript)
	testing.expect(t, !holds_a_part(t, beside), "a failed publish left its temporary behind")
}

// ------------------------------------------------- one Recording, complete --

@(test)
a_recording_that_came_through_has_all_three_artifacts_beside_it :: proc(t: ^testing.T) {
	// ACCEPTANCE, end to end and without a GPU: the Engine's output is validated,
	// the Transcript is rendered from it, and all three land beside the Recording
	// under one stem (ADR-0008) with nothing half-written left anywhere.
	cache := scratch(t, "complete-cache")
	defer delete(cache, context.allocator)
	defer remove_scratch(cache)
	beside := scratch(t, "complete-beside")
	defer delete(beside, context.allocator)
	defer remove_scratch(beside)

	output := file_in(t, cache, "talk.json", ENGINE_JSON)
	defer delete(output, context.allocator)
	source := fmt.aprintf("%s\\talk.mkv", beside, allocator = context.allocator)
	defer delete(source, context.allocator)

	placed, err := complete(
		source,
		output,
		FIXTURE_MS,
		rendered_as(source),
		made_by(),
		context.allocator,
	)
	defer destroy_names(placed, context.allocator)

	if !testing.expectf(t, err.fault == .None, "a good Recording failed: %v", err.fault) {
		return
	}
	testing.expect(t, os.exists(placed.transcript), "no Transcript was placed")
	testing.expect(t, os.exists(placed.engine_output), "the Engine's output was not retained")
	testing.expect(t, os.exists(placed.sidecar), "no Sidecar was written")
	testing.expect(t, !holds_a_part(t, beside), "a completed Recording left a temporary behind")

	// The Transcript really is one: the front matter ADR-0008 has planning look
	// for is there, and so is the language the Engine detected -- which is the one
	// front matter fact the Engine's own output can settle, and the one `complete`
	// reads rather than being handed.
	document, unreadable := os.read_entire_file_from_path(placed.transcript, context.allocator)
	defer delete(document, context.allocator)
	testing.expect(t, unreadable == nil, "the Transcript that was placed could not be read")
	testing.expect(
		t,
		strings.has_prefix(string(document), "---"),
		"a Transcript with no front matter",
	)
	testing.expect(
		t,
		strings.contains(string(document), "language: \"en\""),
		"the language the Engine detected did not reach the front matter",
	)

	// The retained Engine output is the Engine's own bytes and not a re-rendering
	// of them: ADR-0003's cheap re-render path reads this file, and a lossy copy
	// would make that path produce a different Transcript from the original run.
	retained, unread := os.read_entire_file_from_path(placed.engine_output, context.allocator)
	defer delete(retained, context.allocator)
	testing.expect(t, unread == nil, "the retained Engine output could not be read")
	testing.expect_value(t, len(retained), len(ENGINE_JSON))
}

@(test)
the_sidecar_a_completed_recording_leaves_reads_back_as_the_settings_it_was_made_under :: proc(
	t: ^testing.T,
) {
	// What the Sidecar is FOR (ADR-0003), through the whole path rather than in
	// memory: the record written by `complete` is read off the disk and compared,
	// and a Recording re-run under another Merge Profile is not the same
	// Recording.
	cache := scratch(t, "sidecar-cache")
	defer delete(cache, context.allocator)
	defer remove_scratch(cache)
	beside := scratch(t, "sidecar-beside")
	defer delete(beside, context.allocator)
	defer remove_scratch(beside)

	output := file_in(t, cache, "talk.json", ENGINE_JSON)
	defer delete(output, context.allocator)
	source := fmt.aprintf("%s\\talk.mkv", beside, allocator = context.allocator)
	defer delete(source, context.allocator)

	placed, err := complete(
		source,
		output,
		FIXTURE_MS,
		rendered_as(source),
		made_by(),
		context.allocator,
	)
	defer destroy_names(placed, context.allocator)
	if !testing.expectf(t, err.fault == .None, "a good Recording failed: %v", err.fault) {
		return
	}

	written, unreadable := os.read_entire_file_from_path(placed.sidecar, context.allocator)
	defer delete(written, context.allocator)
	testing.expect(t, unreadable == nil, "the Sidecar that was written could not be read")

	recorded, readable := read_sidecar(string(written), context.allocator)
	defer destroy_sidecar(recorded, context.allocator)
	testing.expect(t, readable, "the Sidecar this program wrote could not be read back")
	testing.expect_value(t, changed(recorded, made_by()), Change.None)
	testing.expect_value(t, changed(recorded, made_by(.Conversation)), Change.Merge_Profile)
}

@(test)
the_sidecar_is_the_last_thing_written_so_its_presence_means_finished :: proc(t: ^testing.T) {
	// THE PROMISE THE WHOLE PACKAGE RESTS ON. Planning treats a Recording as done
	// only when its Sidecar says the settings match (ADR-0003), so a Sidecar
	// written before the artifacts it vouches for would report a Recording
	// complete whose Transcript never landed -- permanently, because the next run
	// would skip it.
	//
	// A directory under the Transcript's own name is what makes the placement
	// fail after the Engine's output has already been retained, which is exactly
	// the half-finished state the ordering has to survive.
	cache := scratch(t, "order-cache")
	defer delete(cache, context.allocator)
	defer remove_scratch(cache)
	beside := scratch(t, "order-beside")
	defer delete(beside, context.allocator)
	defer remove_scratch(beside)

	output := file_in(t, cache, "talk.json", ENGINE_JSON)
	defer delete(output, context.allocator)
	source := fmt.aprintf("%s\\talk.mkv", beside, allocator = context.allocator)
	defer delete(source, context.allocator)

	blocked := fmt.aprintf("%s\\talk.md", beside, allocator = context.allocator)
	defer delete(blocked, context.allocator)
	defer os.remove(blocked)
	testing.expect(t, os.make_directory_all(blocked) == nil, "could not block the Transcript")

	placed, err := complete(
		source,
		output,
		FIXTURE_MS,
		rendered_as(source),
		made_by(),
		context.allocator,
	)
	defer destroy_names(placed, context.allocator)

	testing.expect_value(t, err.fault, Fault.Not_Placed)
	testing.expect_value(t, err.which, Artifact.Transcript)
	testing.expect(t, !os.exists(placed.sidecar), "a Recording that failed still looks finished")
	testing.expect(t, !holds_a_part(t, beside), "a failed Recording left a temporary behind")
}

// ------------------------------------- what the Engine left that is not usable --

@(test)
engine_output_that_will_not_parse_is_quarantined_and_the_recording_re_run :: proc(t: ^testing.T) {
	// ADR-0002's headline consequence: "a validated JSON that fails to parse is
	// treated as ABSENT -- quarantine it to `.json.bad` and re-run the full
	// pipeline, rather than reporting a permanent failure". The file this leaves
	// behind is what stops the next run finding a truncated `.json` in the cache
	// and taking it for finished work -- which is the poisoning that made resume
	// fail in exactly the case it exists for.
	cache := scratch(t, "truncated-cache")
	defer delete(cache, context.allocator)
	defer remove_scratch(cache)
	beside := scratch(t, "truncated-beside")
	defer delete(beside, context.allocator)
	defer remove_scratch(beside)

	// Cut in half, which is what a Stop press or a full disk leaves: the Engine
	// opens its output with a truncating stream, under its FINAL name.
	output := file_in(t, cache, "talk.json", ENGINE_JSON[:len(ENGINE_JSON) / 2])
	defer delete(output, context.allocator)
	source := fmt.aprintf("%s\\talk.mkv", beside, allocator = context.allocator)
	defer delete(source, context.allocator)

	placed, err := complete(
		source,
		output,
		FIXTURE_MS,
		rendered_as(source),
		made_by(),
		context.allocator,
	)
	defer destroy_names(placed, context.allocator)

	testing.expect_value(t, err.fault, Fault.Output_Quarantined)
	// Moved aside rather than left where the next run would find it, and not
	// deleted either: a file a user can be pointed at is the difference between a
	// bug report and a shrug.
	aside := quarantined(output, context.allocator)
	defer delete(aside, context.allocator)
	testing.expect(t, os.exists(aside), "output that will not parse was not quarantined")
	testing.expect(t, !os.exists(output), "output that will not parse was left where it was")
	// And NOTHING was placed. A Transcript beside a Recording whose Cues could
	// not be read is worse than none at all.
	testing.expect(
		t,
		!os.exists(placed.transcript),
		"a Transcript was placed from output nobody could read",
	)
	testing.expect(t, !os.exists(placed.sidecar), "a Sidecar vouched for a Recording that failed")
}

@(test)
a_second_run_over_output_that_will_not_parse_replaces_the_quarantined_file :: proc(t: ^testing.T) {
	// The negative space of the case above (A3). A Recording re-run and failing
	// the same way twice must not fail on the QUARANTINE instead -- a rename onto
	// an existing `.json.bad` that refused would turn a re-runnable Recording into
	// a permanent failure on the second attempt, which is the exact shape
	// ADR-0002 exists to prevent.
	cache := scratch(t, "twice-cache")
	defer delete(cache, context.allocator)
	defer remove_scratch(cache)
	beside := scratch(t, "twice-beside")
	defer delete(beside, context.allocator)
	defer remove_scratch(beside)

	source := fmt.aprintf("%s\\talk.mkv", beside, allocator = context.allocator)
	defer delete(source, context.allocator)

	for attempt in 0 ..< 2 {
		output := file_in(t, cache, "talk.json", ENGINE_JSON[:len(ENGINE_JSON) / 2])
		defer delete(output, context.allocator)

		placed, err := complete(
			source,
			output,
			FIXTURE_MS,
			rendered_as(source),
			made_by(),
			context.allocator,
		)
		defer destroy_names(placed, context.allocator)
		testing.expectf(
			t,
			err.fault == .Output_Quarantined,
			"attempt %d answered %v",
			attempt,
			err.fault,
		)
	}
}

@(test)
engine_output_that_parsed_and_said_nothing_fails_the_recording :: proc(t: ^testing.T) {
	// The other disposition, and the one that is NOT re-run: "exit 0 but no or
	// empty output is a hard per-Recording failure" (ADR-0002). The Engine
	// transcribed a Recording of silence, of music or of a dead audio track, and
	// re-running it transcribes nothing again -- so quarantining this would spend
	// the GPU time for ever.
	cache := scratch(t, "silent-cache")
	defer delete(cache, context.allocator)
	defer remove_scratch(cache)
	beside := scratch(t, "silent-beside")
	defer delete(beside, context.allocator)
	defer remove_scratch(beside)

	output := file_in(
		t,
		cache,
		"talk.json",
		`{"transcription":[{"offsets":{"from":0,"to":253949},"text":"   "}]}`,
	)
	defer delete(output, context.allocator)
	source := fmt.aprintf("%s\\talk.mkv", beside, allocator = context.allocator)
	defer delete(source, context.allocator)

	placed, err := complete(
		source,
		output,
		FIXTURE_MS,
		rendered_as(source),
		made_by(),
		context.allocator,
	)
	defer destroy_names(placed, context.allocator)

	testing.expect_value(t, err.fault, Fault.Nothing_Transcribed)
	aside := quarantined(output, context.allocator)
	defer delete(aside, context.allocator)
	testing.expect(
		t,
		!os.exists(aside),
		"a Recording that will never transcribe was set up to re-run",
	)
	testing.expect(
		t,
		os.exists(output),
		"the Engine's own output was moved for a fault that is not its shape",
	)
}

@(test)
engine_output_that_is_not_there_at_all_is_reported_rather_than_asserted :: proc(t: ^testing.T) {
	// A8: what the Engine left is outside this program, and by the time this runs
	// the cache sweep of another transcibr may have taken it.
	cache := scratch(t, "absent-cache")
	defer delete(cache, context.allocator)
	defer remove_scratch(cache)
	beside := scratch(t, "absent-beside")
	defer delete(beside, context.allocator)
	defer remove_scratch(beside)

	output := fmt.aprintf("%s\\talk.json", cache, allocator = context.allocator)
	defer delete(output, context.allocator)
	source := fmt.aprintf("%s\\talk.mkv", beside, allocator = context.allocator)
	defer delete(source, context.allocator)

	placed, err := complete(
		source,
		output,
		FIXTURE_MS,
		rendered_as(source),
		made_by(),
		context.allocator,
	)
	defer destroy_names(placed, context.allocator)

	testing.expect_value(t, err.fault, Fault.Output_Unreadable)
}

@(test)
a_recording_whose_path_names_no_file_is_refused_before_anything_is_read :: proc(t: ^testing.T) {
	cache := scratch(t, "nameless-cache")
	defer delete(cache, context.allocator)
	defer remove_scratch(cache)

	output := file_in(t, cache, "talk.json", ENGINE_JSON)
	defer delete(output, context.allocator)

	placed, err := complete(
		"C:\\clips\\",
		output,
		FIXTURE_MS,
		rendered_as("C:\\clips\\"),
		made_by(),
		context.allocator,
	)
	defer destroy_names(placed, context.allocator)

	testing.expect_value(t, err.fault, Fault.Named_No_File)
}

@(test)
a_recording_the_filesystem_dates_before_1970_is_refused_with_nothing_published :: proc(
	t: ^testing.T,
) {
	// A8, on the one field of a Sidecar that is not this program's own
	// arithmetic. `source_modified_ns` is `os.stat`'s answer about somebody
	// else's file, and a moment before 1970 is negative -- a recorder whose clock
	// never started and defaulted to "1970-01-01 00:00" local time anywhere east
	// of Greenwich, a file restored from an archive that kept its original time,
	// a virtual filesystem answering FILETIME 0 for 1601.
	//
	// This CRASHED THE PROCESS, and it crashed it late: the Sidecar is written
	// last, so the assertion in write_number fired with the retained Engine
	// output and the Transcript already published -- a Recording that looks
	// two-thirds finished, no Sidecar, and under a Batch the whole run dead with
	// it. Refused here, nothing is published at all and the Batch carries on.
	cache := scratch(t, "pre-epoch-cache")
	defer delete(cache, context.allocator)
	defer remove_scratch(cache)
	beside := scratch(t, "pre-epoch-beside")
	defer delete(beside, context.allocator)
	defer remove_scratch(beside)

	output := file_in(t, cache, "talk.json", ENGINE_JSON)
	defer delete(output, context.allocator)
	source := fmt.aprintf("%s\\talk.mkv", beside, allocator = context.allocator)
	defer delete(source, context.allocator)

	dated := made_by()
	// 1969-12-31 21:00 UTC.
	dated.source_modified_ns = -10_800_000_000_000

	placed, err := complete(
		source,
		output,
		FIXTURE_MS,
		rendered_as(source),
		dated,
		context.allocator,
	)
	defer destroy_names(placed, context.allocator)

	testing.expect_value(t, err.fault, Fault.Not_Recordable)
	// NOTHING, and that is the whole of it (A3). The two artifacts that used to
	// be on the disk by the time this failed are the reason the refusal is where
	// it is rather than where the record is written.
	testing.expect(t, !os.exists(placed.transcript), "a refused Recording got a Transcript")
	testing.expect(
		t,
		!os.exists(placed.engine_output),
		"a refused Recording had its Engine output retained",
	)
	testing.expect(t, !os.exists(placed.sidecar), "a refused Recording got a Sidecar")
	testing.expect(t, !holds_a_part(t, beside), "a refused Recording left a temporary behind")
	// And what the Engine left is where it was: this is not the shape of failure
	// a quarantine answers, and moving it aside would set up a re-run that spends
	// the GPU time again to reach the same refusal.
	testing.expect(t, os.exists(output), "the Engine's own output was moved aside for a bad clock")
}

@(test)
every_fault_renders_a_line_a_recordings_failure_row_can_carry :: proc(t: ^testing.T) {
	// The guard an exhaustive switch cannot give on its own: an arm that is
	// present and says nothing compiles, and is found by the renderer's own
	// assertion in front of a user, on a Recording that is already failing.
	for fault in Fault {
		if fault == .None {
			continue
		}
		// The two faults that borrow their reason from the parser are handed a
		// real one, because this checks the renderer rather than what happens when
		// this package loses a report between the failure and the row.
		reason := transcript.Parse_Error{}
		if fault == .Output_Quarantined || fault == .Nothing_Transcribed {
			reason = transcript.Parse_Error {
				fault     = .Malformed_Json if fault == .Output_Quarantined else .No_Cues,
				json_name = "C:\\cache\\talk.json",
			}
		}
		message := error_message(
			Error{fault = fault, parse = reason},
			"C:\\recordings\\talk.mkv",
			context.allocator,
		)
		defer delete(message, context.allocator)

		testing.expectf(t, len(message) > 0, "%v rendered as nothing at all", fault)
		testing.expectf(
			t,
			strings.contains(message, "talk.mkv"),
			"%v does not name the Recording it is about",
			fault,
		)
	}
}
