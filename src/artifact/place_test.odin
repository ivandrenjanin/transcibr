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

// One Recording's Sidecar, built THE WAY THE SHELL BUILDS IT and not the way a
// suite would.
//
// `sidecar_of` and not a struct literal, which is the point: this used to be a
// literal here and another literal in `src/cli`, and ADR-0009 requires that
// package to collect no tests -- so the record under test agreed with the record
// the program writes by authorship alone. Both now go through one call that
// cannot leave a field out.
@(private)
made_by :: proc(profile := transcript.DEFAULT_PROFILE) -> Sidecar {
	return sidecar_of(
		engine_version = "whisper.cpp v1.9.1",
		model = Model {
			path = "C:\\models\\ggml-large-v3.bin",
			digest = Digest(ABC_SHA256),
			bytes = 3_094_623_691,
		},
		beam = ENGINE_DEFAULT_BEAM,
		merge_profile = transcript.profile_name(profile),
		prompt = "",
		source_bytes = 402_653_184,
		source_modified_ns = 1_754_136_000_000_000_000,
		container_ms = i64(FIXTURE_MS),
	)
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

// One Recording set out the way every case below wants it: a scratch cache with
// the Engine's output in it, a separate directory for the Recording to live
// beside, and the three names its artifacts would be published under.
//
// TWO DIRECTORIES AND NOT ONE, because that is the arrangement the
// cross-volume question is really about. DECLARED ONCE, because the seven lines
// that built them were repeated in ten cases and the nine-line `complete` call
// in eight -- around a hundred and forty of this file's lines saying one thing,
// and eight chances for one case to differ from the others by accident rather
// than on purpose.
@(private)
Bench :: struct {
	cache:  string,
	beside: string,
	source: string,
	output: string,
	names:  Names,
}

@(private)
set_out :: proc(t: ^testing.T, tag: string, left := ENGINE_JSON) -> (b: Bench) {
	for directory, at in ([?]^string{&b.cache, &b.beside}) {
		named := fmt.aprintf("%s-%s", tag, "cache" if at == 0 else "beside")
		defer delete(named, context.allocator)
		directory^ = scratch(t, named)
	}
	b.output = file_in(t, b.cache, "talk.json", left)
	b.source = fmt.aprintf("%s\\talk.mkv", b.beside, allocator = context.allocator)

	namable: bool
	b.names, namable = names_of(b.source, context.allocator)
	testing.expect(t, namable, "a case could not name the artifacts of its own Recording")
	return b
}

// Everything set_out made, freed and removed. Every case defers this.
@(private)
cleared :: proc(b: Bench) {
	destroy_names(b.names, context.allocator)
	remove_scratch(b.cache)
	remove_scratch(b.beside)
	delete(b.cache, context.allocator)
	delete(b.beside, context.allocator)
	delete(b.source, context.allocator)
	delete(b.output, context.allocator)
}

// One Recording put through `complete` the way the shell puts it through.
@(private)
completed :: proc(b: Bench, made := Sidecar{}) -> (Names, Error) {
	settings := made if len(made.model_digest) > 0 else made_by()
	return complete(
		b.source,
		b.output,
		FIXTURE_MS,
		rendered_as(b.source),
		settings,
		context.allocator,
	)
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
	b := set_out(t, "publish")
	defer cleared(b)

	err := publish(b.names, .Transcript, transmute([]u8)string("# talk\n"), context.allocator)
	testing.expect_value(t, err.fault, Fault.None)

	written, unreadable := os.read_entire_file_from_path(b.names[.Transcript], context.allocator)
	defer delete(written, context.allocator)
	testing.expect(t, unreadable == nil, "the artifact is not under the name it was published to")
	testing.expect_value(t, string(written), "# talk\n")
	// The other half (A3), and the one a rename that silently became a copy would
	// fail: the temporary name is gone.
	testing.expect(t, !holds_a_part(t, b.beside), "a published artifact left its temporary behind")
}

@(test)
publishing_over_an_artifact_that_is_already_there_replaces_it :: proc(t: ^testing.T) {
	// A Recording re-run under changed settings (ADR-0003) publishes over its own
	// artifacts, so a rename that refused an existing name would make every
	// re-run fail after the GPU time had already been spent. `core:os`'s rename
	// passes MOVEFILE_REPLACE_EXISTING, and this is what holds that shut.
	b := set_out(t, "replace")
	defer cleared(b)

	older := file_in(t, b.beside, "talk.md", "the transcript from an older run\n")
	defer delete(older, context.allocator)
	testing.expect_value(t, older, b.names[.Transcript])

	err := publish(b.names, .Transcript, transmute([]u8)string("the new one\n"), context.allocator)
	testing.expect_value(t, err.fault, Fault.None)

	written, unreadable := os.read_entire_file_from_path(older, context.allocator)
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
	b := set_out(t, "blocked")
	defer cleared(b)

	blocked := b.names[.Transcript]
	defer os.remove(blocked)
	testing.expect(t, os.make_directory_all(blocked) == nil, "could not block the destination")

	err := publish(b.names, .Transcript, transmute([]u8)string("# talk\n"), context.allocator)
	testing.expect_value(t, err.fault, Fault.Not_Placed)
	testing.expect_value(t, err.which, Artifact.Transcript)
	testing.expect(t, !holds_a_part(t, b.beside), "a failed publish left its temporary behind")
}

// ------------------------------------------------- one Recording, complete --

@(test)
a_recording_that_came_through_has_all_three_artifacts_beside_it :: proc(t: ^testing.T) {
	// ACCEPTANCE, end to end and without a GPU: the Engine's output is validated,
	// the Transcript is rendered from it, and all three land beside the Recording
	// under one stem (ADR-0008) with nothing half-written left anywhere.
	b := set_out(t, "complete")
	defer cleared(b)

	placed, err := completed(b)
	defer destroy_names(placed, context.allocator)

	if !testing.expectf(t, err.fault == .None, "a good Recording failed: %v", err.fault) {
		return
	}
	testing.expect(t, os.exists(placed[.Transcript]), "no Transcript was placed")
	testing.expect(t, os.exists(placed[.Engine_Output]), "the Engine's output was not retained")
	testing.expect(t, os.exists(placed[.Sidecar]), "no Sidecar was written")
	testing.expect(t, !holds_a_part(t, b.beside), "a completed Recording left a temporary behind")

	// The Transcript really is one: the front matter ADR-0008 has planning look
	// for is there, and so is the language the Engine detected -- which is the one
	// front matter fact the Engine's own output can settle, and the one `complete`
	// reads rather than being handed.
	document, unreadable := os.read_entire_file_from_path(placed[.Transcript], context.allocator)
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
	retained, unread := os.read_entire_file_from_path(placed[.Engine_Output], context.allocator)
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
	b := set_out(t, "sidecar")
	defer cleared(b)

	placed, err := completed(b)
	defer destroy_names(placed, context.allocator)
	if !testing.expectf(t, err.fault == .None, "a good Recording failed: %v", err.fault) {
		return
	}

	written, unreadable := os.read_entire_file_from_path(placed[.Sidecar], context.allocator)
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
	b := set_out(t, "order")
	defer cleared(b)

	blocked := b.names[.Transcript]
	defer os.remove(blocked)
	testing.expect(t, os.make_directory_all(blocked) == nil, "could not block the Transcript")

	placed, err := completed(b)
	defer destroy_names(placed, context.allocator)

	testing.expect_value(t, err.fault, Fault.Not_Placed)
	testing.expect_value(t, err.which, Artifact.Transcript)
	testing.expect(t, !os.exists(placed[.Sidecar]), "a Recording that failed still looks finished")
	testing.expect(t, !holds_a_part(t, b.beside), "a failed Recording left a temporary behind")
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
	//
	// Cut in half, which is what a Stop press or a full disk leaves: the Engine
	// opens its output with a truncating stream, under its FINAL name.
	b := set_out(t, "truncated", ENGINE_JSON[:len(ENGINE_JSON) / 2])
	defer cleared(b)

	placed, err := completed(b)
	defer destroy_names(placed, context.allocator)

	testing.expect_value(t, err.fault, Fault.Output_Quarantined)
	// Moved aside rather than left where the next run would find it, and not
	// deleted either: a file a user can be pointed at is the difference between a
	// bug report and a shrug.
	aside := quarantined(b.output, context.allocator)
	defer delete(aside, context.allocator)
	testing.expect(t, os.exists(aside), "output that will not parse was not quarantined")
	testing.expect(t, !os.exists(b.output), "output that will not parse was left where it was")
	// And NOTHING was placed. A Transcript beside a Recording whose Cues could
	// not be read is worse than none at all.
	testing.expect(
		t,
		!os.exists(placed[.Transcript]),
		"a Transcript was placed from output nobody could read",
	)
	testing.expect(
		t,
		!os.exists(placed[.Sidecar]),
		"a Sidecar vouched for a Recording that failed",
	)
}

@(test)
a_second_run_over_output_that_will_not_parse_replaces_the_quarantined_file :: proc(t: ^testing.T) {
	// The negative space of the case above (A3). A Recording re-run and failing
	// the same way twice must not fail on the QUARANTINE instead -- a rename onto
	// an existing `.json.bad` that refused would turn a re-runnable Recording into
	// a permanent failure on the second attempt, which is the exact shape
	// ADR-0002 exists to prevent.
	b := set_out(t, "twice", ENGINE_JSON[:len(ENGINE_JSON) / 2])
	defer cleared(b)

	for attempt in 0 ..< 2 {
		// Written again each time round, because the attempt before it moved the
		// file aside -- which is the whole thing being checked.
		rewritten := file_in(t, b.cache, "talk.json", ENGINE_JSON[:len(ENGINE_JSON) / 2])
		defer delete(rewritten, context.allocator)

		placed, err := completed(b)
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
	b := set_out(
		t,
		"silent",
		`{"transcription":[{"offsets":{"from":0,"to":253949},"text":"   "}]}`,
	)
	defer cleared(b)

	placed, err := completed(b)
	defer destroy_names(placed, context.allocator)

	testing.expect_value(t, err.fault, Fault.Nothing_Transcribed)
	aside := quarantined(b.output, context.allocator)
	defer delete(aside, context.allocator)
	testing.expect(
		t,
		!os.exists(aside),
		"a Recording that will never transcribe was set up to re-run",
	)
	testing.expect(
		t,
		os.exists(b.output),
		"the Engine's own output was moved for a fault that is not its shape",
	)
}

@(test)
engine_output_that_is_not_there_at_all_is_reported_rather_than_asserted :: proc(t: ^testing.T) {
	// A8: what the Engine left is outside this program, and by the time this runs
	// the cache sweep of another transcibr may have taken it.
	b := set_out(t, "absent")
	defer cleared(b)
	testing.expect(t, os.remove(b.output) == nil, "a case could not take away its own fixture")

	placed, err := completed(b)
	defer destroy_names(placed, context.allocator)

	testing.expect_value(t, err.fault, Fault.Output_Unreadable)
}

@(test)
a_recording_whose_path_names_no_file_is_refused_before_anything_is_read :: proc(t: ^testing.T) {
	// The one case that does not use the bench's own Recording, because what it
	// is about is a path that names none.
	b := set_out(t, "nameless")
	defer cleared(b)

	placed, err := complete(
		"C:\\clips\\",
		b.output,
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
	b := set_out(t, "pre-epoch")
	defer cleared(b)

	dated := made_by()
	// 1969-12-31 21:00 UTC.
	dated.source_modified_ns = -10_800_000_000_000

	placed, err := completed(b, dated)
	defer destroy_names(placed, context.allocator)

	testing.expect_value(t, err.fault, Fault.Not_Recordable)
	// NOTHING, and that is the whole of it (A3). The two artifacts that used to
	// be on the disk by the time this failed are the reason the refusal is where
	// it is rather than where the record is written.
	testing.expect(t, !os.exists(placed[.Transcript]), "a refused Recording got a Transcript")
	testing.expect(
		t,
		!os.exists(placed[.Engine_Output]),
		"a refused Recording had its Engine output retained",
	)
	testing.expect(t, !os.exists(placed[.Sidecar]), "a refused Recording got a Sidecar")
	testing.expect(t, !holds_a_part(t, b.beside), "a refused Recording left a temporary behind")
	// And what the Engine left is where it was: this is not the shape of failure
	// a quarantine answers, and moving it aside would set up a re-run that spends
	// the GPU time again to reach the same refusal.
	testing.expect(
		t,
		os.exists(b.output),
		"the Engine's own output was moved aside for a bad clock",
	)
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
