package planning

import "core:strings"
import "core:testing"
import "transcibr:artifact"

// Criterion one: every Recording found is printed with a decision AND a reason.
// Walked rather than spot-checked, so a Reason added without a sentence is red
// here rather than blank in front of a user.
@(test)
every_reason_renders_a_line_carrying_a_decision_and_a_recording :: proc(t: ^testing.T) {
	for reason in Reason {
		says := reason_says(reason)
		if !testing.expectf(t, len(says) > 0, "%v has no sentence at all", reason) {
			continue
		}

		line := plan_line(
			Entry {
				found = Found{source = "C:\\clips\\one talk.mp4"},
				outcome = Outcome{decision = .Transcribe, reason = reason},
			},
			context.allocator,
		)
		defer delete(line, context.allocator)

		testing.expectf(
			t,
			strings.contains(line, says),
			"%v rendered <%s>, which does not carry its own sentence",
			reason,
			line,
		)
		testing.expectf(
			t,
			strings.contains(line, "one talk.mp4"),
			"%v rendered <%s>, which does not name the Recording",
			reason,
			line,
		)
		testing.expectf(
			t,
			strings.contains(line, decision_says(.Transcribe)),
			"%v rendered <%s>, which does not say what will be done",
			reason,
			line,
		)
	}
}

@(test)
every_decision_says_what_it_will_do :: proc(t: ^testing.T) {
	for decision in Decision {
		testing.expectf(t, len(decision_says(decision)) > 0, "%v says nothing at all", decision)
	}
}

// `core:fmt` pads an INTEGER's width with zeros, and `src/cli` printed
// `transcribing 000%` before that came out of it (CLAUDE.md, Odin notes).
// `fmt_string` writes spaces directly for `%s` and does not go near
// `fmt_write_padding`, which is why a width verb is safe here -- measured, and
// this is what holds it, since the package that got caught cannot hold it
// itself (ADR-0009).
@(test)
the_column_a_decision_stands_in_is_padded_with_spaces_and_never_zeros :: proc(t: ^testing.T) {
	for decision in Decision {
		line := plan_line(
			Entry {
				found = Found{source = "C:\\clips\\talk.mp4"},
				outcome = Outcome{decision = decision, reason = .Nothing_Recorded},
			},
			context.allocator,
		)
		defer delete(line, context.allocator)

		does := decision_says(decision)
		testing.expectf(
			t,
			strings.has_prefix(line, does),
			"%v does not open its own row: <%s>",
			decision,
			line,
		)
		testing.expectf(
			t,
			line[len(does)] == ' ' || line[len(does)] == '"',
			"%v is padded with something a reader will misread: <%s>",
			decision,
			line,
		)
	}
}

// A Recording re-done for its settings names WHICH setting: "it will be done
// again" with no cause is the report ADR-0003 exists to make impossible.
@(test)
a_recording_re_done_for_its_settings_names_the_setting_that_changed :: proc(t: ^testing.T) {
	line := plan_line(
		Entry {
			found = Found{source = "C:\\clips\\talk.mp4"},
			outcome = Outcome{decision = .Transcribe, reason = .Settings_Changed, change = .Model},
		},
		context.allocator,
	)
	defer delete(line, context.allocator)

	testing.expectf(
		t,
		strings.contains(line, "Model"),
		"a Recording re-done for its Model does not say so: <%s>",
		line,
	)
}

@(test)
every_note_a_walk_leaves_renders_against_the_path_that_caused_it :: proc(t: ^testing.T) {
	for what in Note {
		says := note_says(what)
		if !testing.expectf(t, len(says) > 0, "%v has no sentence at all", what) {
			continue
		}

		line := note_line(Walk_Note{note = what, path = "D:\\archive\\shut"}, context.allocator)
		defer delete(line, context.allocator)

		testing.expectf(
			t,
			strings.contains(line, says),
			"%v rendered <%s>, which does not carry its own sentence",
			what,
			line,
		)
		testing.expectf(
			t,
			strings.contains(line, "shut"),
			"%v rendered <%s>, which does not name the directory",
			what,
			line,
		)
	}
}

// ADR-0008 asks for the offending PAIR, so both paths and the artifact they
// share have to be in the line.
@(test)
a_failed_plan_names_both_recordings_and_the_artifact_they_would_share :: proc(t: ^testing.T) {
	inventory := []Found {
		recording_at("C:\\clips\\interview.mp4"),
		recording_at("C:\\clips\\interview.m4a"),
	}
	plan, ok := plan_batch(inventory, settings(), context.allocator)
	defer destroy_plan(plan, context.allocator)
	if !testing.expect(t, !ok, "two Recordings racing one output path were planned anyway") {
		return
	}

	line := collision_line(plan, context.allocator)
	defer delete(line, context.allocator)

	for named in ([?]string{"interview.mp4", "interview.m4a", "interview.md"}) {
		testing.expectf(
			t,
			strings.contains(line, named),
			"a refused Batch does not name %q: <%s>",
			named,
			line,
		)
	}
}

// The comparison folds case; the REPORT must not. A user told their Batch will
// write `c:\users\...` when the directory is spelled `C:\Users\...` has been
// handed this package's comparison key instead of a path.
@(test)
a_failed_plan_names_the_artifact_as_it_would_be_written_and_not_folded :: proc(t: ^testing.T) {
	inventory := []Found {
		recording_at("C:\\Clips\\Interview.mp4"),
		recording_at("C:\\Clips\\Interview.m4a"),
	}
	plan, ok := plan_batch(inventory, settings(), context.allocator)
	defer destroy_plan(plan, context.allocator)
	if !testing.expect(t, !ok, "two Recordings racing one output path were planned anyway") {
		return
	}

	collision, named := plan.collision.?
	testing.expect(t, named, "a plan failed for a collision it did not name")
	testing.expect_value(t, collision.name, "C:\\Clips\\Interview.md")
}

// Nothing prints a collision line for a Batch that has none.
@(test)
a_plan_that_came_through_has_no_collision_line_to_print :: proc(t: ^testing.T) {
	plan, ok := plan_batch(
		[]Found{recording_at("C:\\clips\\talk.mp4")},
		settings(),
		context.allocator,
	)
	defer destroy_plan(plan, context.allocator)

	testing.expect(t, ok, "a Batch with one Recording in it failed the plan")
	line := collision_line(plan, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, len(line), 0)
}

@(test)
a_change_this_package_reports_is_the_one_artifact_answered :: proc(t: ^testing.T) {
	found := a_recording()
	found.transcript = .Transcibrs
	recorded := matching_sidecar(found)
	recorded.beam = 9
	found.recorded = recorded

	outcome := decide(found, settings())
	testing.expect_value(t, outcome.change, artifact.Change.Beam)
}
