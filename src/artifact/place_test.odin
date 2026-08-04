package artifact

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "transcibr:transcript"

@(private)
ENGINE_JSON :: #load("../transcript/fixtures/engine-output.json", string)

@(private)
FIXTURE_MS :: transcript.Millis(253_949)

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
	testing.expect(t, !holds_a_part(t, b.beside), "a published artifact left its temporary behind")
}

@(test)
publishing_over_an_artifact_that_is_already_there_replaces_it :: proc(t: ^testing.T) {
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

@(test)
a_recording_that_came_through_has_all_three_artifacts_beside_it :: proc(t: ^testing.T) {
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

	retained, unread := os.read_entire_file_from_path(placed[.Engine_Output], context.allocator)
	defer delete(retained, context.allocator)
	testing.expect(t, unread == nil, "the retained Engine output could not be read")
	testing.expect_value(t, len(retained), len(ENGINE_JSON))
}

@(test)
the_sidecar_a_completed_recording_leaves_reads_back_as_the_settings_it_was_made_under :: proc(
	t: ^testing.T,
) {
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

@(test)
engine_output_that_will_not_parse_is_quarantined_and_the_recording_re_run :: proc(t: ^testing.T) {
	b := set_out(t, "truncated", ENGINE_JSON[:len(ENGINE_JSON) / 2])
	defer cleared(b)

	placed, err := completed(b)
	defer destroy_names(placed, context.allocator)

	testing.expect_value(t, err.fault, Fault.Output_Quarantined)
	aside := quarantined(b.output, context.allocator)
	defer delete(aside, context.allocator)
	testing.expect(t, os.exists(aside), "output that will not parse was not quarantined")
	testing.expect(t, !os.exists(b.output), "output that will not parse was left where it was")
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
engine_output_that_could_not_be_moved_aside_is_not_reported_as_moved_aside :: proc(t: ^testing.T) {
	b := set_out(t, "unmovable", ENGINE_JSON[:len(ENGINE_JSON) / 2])
	defer cleared(b)

	aside := quarantined(b.output, context.allocator)
	defer delete(aside, context.allocator)
	defer os.remove(aside)
	testing.expect(t, os.make_directory_all(aside) == nil, "could not block the quarantine name")

	placed, err := completed(b)
	defer destroy_names(placed, context.allocator)

	testing.expect_value(t, err.fault, Fault.Output_Not_Quarantined)
	testing.expect(t, os.exists(b.output), "output that could not be moved aside went missing")
	testing.expect(
		t,
		!os.exists(placed[.Sidecar]),
		"a Sidecar vouched for a Recording whose output would not parse",
	)
}

@(test)
a_second_run_over_output_that_will_not_parse_replaces_the_quarantined_file :: proc(t: ^testing.T) {
	b := set_out(t, "twice", ENGINE_JSON[:len(ENGINE_JSON) / 2])
	defer cleared(b)

	for attempt in 0 ..< 2 {
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
	b := set_out(t, "absent")
	defer cleared(b)
	testing.expect(t, os.remove(b.output) == nil, "a case could not take away its own fixture")

	placed, err := completed(b)
	defer destroy_names(placed, context.allocator)

	testing.expect_value(t, err.fault, Fault.Output_Unreadable)
}

@(test)
a_recording_whose_path_names_no_file_is_refused_before_anything_is_read :: proc(t: ^testing.T) {
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
	b := set_out(t, "pre-epoch")
	defer cleared(b)

	dated := made_by()
	dated.source_modified_ns = -10_800_000_000_000

	placed, err := completed(b, dated)
	defer destroy_names(placed, context.allocator)

	testing.expect_value(t, err.fault, Fault.Not_Recordable)
	testing.expect(t, !os.exists(placed[.Transcript]), "a refused Recording got a Transcript")
	testing.expect(
		t,
		!os.exists(placed[.Engine_Output]),
		"a refused Recording had its Engine output retained",
	)
	testing.expect(t, !os.exists(placed[.Sidecar]), "a refused Recording got a Sidecar")
	testing.expect(t, !holds_a_part(t, b.beside), "a refused Recording left a temporary behind")
	testing.expect(
		t,
		os.exists(b.output),
		"the Engine's own output was moved aside for a bad clock",
	)
}

// Exhaustive, so a Fault added without a reason is a build failure here rather
// than borrowed_message's assertion firing inside the runner, which takes the
// whole sweep down instead of naming a case (issue #22).
@(private)
reason_for :: proc(fault: Fault) -> transcript.Parse_Error {
	switch fault {
	case .Output_Quarantined, .Output_Not_Quarantined:
		return {fault = .Malformed_Json, json_name = "C:\\cache\\talk.json"}
	case .Nothing_Transcribed:
		return {fault = .No_Cues, json_name = "C:\\cache\\talk.json"}
	case .None, .Named_No_File, .Not_Recordable, .Output_Unreadable, .Not_Written, .Not_Placed:
		return {}
	}
	return {}
}

@(test)
every_fault_renders_a_line_a_recordings_failure_row_can_carry :: proc(t: ^testing.T) {
	for fault in Fault {
		if fault == .None {
			continue
		}
		message := error_message(
			Error{fault = fault, parse = reason_for(fault)},
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
