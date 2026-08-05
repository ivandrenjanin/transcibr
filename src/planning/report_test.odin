#+vet explicit-allocators
package planning

import "core:fmt"
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

// PR #64's fourth review, finding 2: `.Transcript_Unreadable` reaches three
// live cases that never wait out a bound at all -- `os.open` refusing a
// locked Transcript instantly, `os.open` refusing a path a directory
// occupies instead of a file, and (before that same review) `os.read_at`
// answering EOF on a 0-byte Transcript. A sentence that claims a bound
// elapsed and was abandoned is a confident wrong diagnosis for every one of
// them; this pins the sentence generic enough to stay true regardless of
// which of the three actually reached it.
@(test)
transcript_unreadable_does_not_claim_a_bound_that_may_never_have_elapsed :: proc(t: ^testing.T) {
	says := reason_says(.Transcript_Unreadable)
	testing.expectf(
		t,
		!strings.contains(says, "bound"),
		"%q claims a bound elapsed, which is not true of every case that reaches it",
		says,
	)
	testing.expectf(
		t,
		!strings.contains(says, "abandoned"),
		"%q claims this walk gave up waiting, which is not true of every case that reaches it",
		says,
	)
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
		strings.contains(line, "the Model"),
		"a Recording re-done for its Model does not say so: <%s>",
		line,
	)
}

// The walking counterpart to `a_recording_re_done_for_its_settings_names_the_setting_that_changed`:
// every member of `artifact.Change`, not only `.Model`, renders as words a user
// reads rather than the raw enum spelling `%v` would have produced.
@(test)
every_change_plan_line_renders_reads_as_words_and_never_as_its_identifier :: proc(t: ^testing.T) {
	for change in artifact.Change {
		line := plan_line(
			Entry {
				found = Found{source = "C:\\clips\\talk.mp4"},
				outcome = Outcome {
					decision = .Transcribe,
					reason = .Settings_Changed,
					change = change,
				},
			},
			context.allocator,
		)
		defer delete(line, context.allocator)

		testing.expectf(
			t,
			!strings.contains(line, "_"),
			"%v rendered <%s>, which still carries an underscore",
			change,
			line,
		)

		raw := fmt.tprintf("(%v)", change)
		testing.expectf(
			t,
			!strings.contains(line, raw),
			"%v rendered its own identifier verbatim: <%s>",
			change,
			line,
		)

		if change != .None {
			testing.expectf(
				t,
				strings.contains(line, change_says(change)),
				"%v rendered <%s>, which does not carry its own words",
				change,
				line,
			)
		}
	}
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
	plan, ok := plan_batch(Inventory{found = inventory}, settings(), context.allocator)
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
	plan, ok := plan_batch(Inventory{found = inventory}, settings(), context.allocator)
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
		Inventory{found = []Found{recording_at("C:\\clips\\talk.mp4")}},
		settings(),
		context.allocator,
	)
	defer destroy_plan(plan, context.allocator)

	testing.expect(t, ok, "a Batch with one Recording in it failed the plan")
	for line in ([?]string {
			collision_line(plan, context.allocator),
			incomplete_line(Inventory{}, context.allocator),
		}) {
		defer delete(line, context.allocator)
		testing.expectf(t, len(line) == 0, "a Batch that came through said <%s> anyway", line)
	}
}

// A Batch must not run over a tree the walk did not finish, and the plan itself
// is what refuses it: handed the Recordings alone, this could only ever have
// been the caller's discipline -- and the only caller that asks is the package
// nothing can turn red (ADR-0009).
@(test)
a_walk_that_did_not_see_the_whole_tree_fails_the_plan_it_feeds :: proc(t: ^testing.T) {
	Case :: struct {
		says:      string,
		inventory: Inventory,
		ok:        bool,
	}

	whole := []Found{recording_at("C:\\clips\\talk.mp4")}
	for c in ([?]Case {
			{"a walk that saw the whole tree", Inventory{found = whole}, true},
			{
				"a walk that was stopped part way",
				Inventory{found = whole, cancelled = true},
				false,
			},
			{
				"a walk that could not list a directory",
				Inventory {
					found = whole,
					notes = []Walk_Note {
						{note = .Directory_Unreadable, path = "D:\\archive\\shut"},
					},
				},
				false,
			},
			{
				"a walk that declined a reparse point it was told to decline",
				Inventory {
					found = whole,
					notes = []Walk_Note{{note = .Reparse_Point_Not_Followed, path = "D:\\link"}},
				},
				true,
			},
		}) {
		plan, ok := plan_batch(c.inventory, settings(), context.allocator)
		defer destroy_plan(plan, context.allocator)

		testing.expectf(t, ok == c.ok, "%s was %v, which is not what it means", c.says, ok)
		testing.expect_value(t, len(plan.entries), 1)
	}
}

// The note is rendered through its own sentence and never as `%v`: a cancelled
// walk read "did not see the whole tree (Root_Unreadable)" over a root it had
// read perfectly well, and no reader of that line could tell those apart.
@(test)
a_partial_walk_says_which_directory_left_it_short_and_a_stopped_one_names_none :: proc(
	t: ^testing.T,
) {
	unread := incomplete_line(
		Inventory{notes = []Walk_Note{{note = .Directory_Unreadable, path = "D:\\archive\\shut"}}},
		context.allocator,
	)
	defer delete(unread, context.allocator)

	for named in ([?]string{"shut", note_says(.Directory_Unreadable)}) {
		testing.expectf(
			t,
			strings.contains(unread, named),
			"<%s> does not carry %q",
			unread,
			named,
		)
	}

	stopped := incomplete_line(Inventory{cancelled = true}, context.allocator)
	defer delete(stopped, context.allocator)

	testing.expect_value(t, stopped, STOPPED_PART_WAY)
	for note in Note {
		says := note_says(note)
		testing.expectf(
			t,
			!strings.contains(stopped, says),
			"a walk that was stopped blamed %v: <%s>",
			note,
			stopped,
		)
	}
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
