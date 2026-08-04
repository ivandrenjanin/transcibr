package planning

import "core:strings"
import "core:testing"

@(private)
@(require_results)
recording_at :: proc(source: string) -> Found {
	found := a_recording()
	found.source = source
	return found
}

@(private)
@(require_results)
planned :: proc(sources: []string) -> (plan: Plan, ok: bool) {
	found := make([]Found, len(sources), context.allocator)
	defer delete(found, context.allocator)
	for source, at in sources {
		found[at] = recording_at(source)
	}
	return plan_batch(Inventory{found = found}, settings(), context.allocator)
}

// ADR-0008: a video and its extracted audio side by side is the mainstream
// case, and both name the same Transcript.
@(test)
two_recordings_that_would_write_one_artifact_fail_the_plan_naming_the_pair :: proc(t: ^testing.T) {
	plan, ok := planned(
		[]string{"C:\\clips\\keynote.mp4", "C:\\clips\\interview.mp4", "C:\\clips\\interview.m4a"},
	)
	defer destroy_plan(plan, context.allocator)

	testing.expect(t, !ok, "two Recordings racing one output path were planned anyway")

	collision, named := plan.collision.?
	if !testing.expect(t, named, "a plan failed for a collision it did not name") {
		return
	}
	testing.expect_value(t, collision.left, 1)
	testing.expect_value(t, collision.right, 2)
	testing.expectf(
		t,
		strings.has_suffix(collision.name, "interview.md"),
		"the pair was reported against %q, which is not the artifact they share",
		collision.name,
	)
}

// NTFS is case-insensitive by default, so two names differing only in case are
// one file and the second Recording would overwrite the first's Transcript.
@(test)
two_recordings_whose_names_differ_only_in_case_still_fail_the_plan :: proc(t: ^testing.T) {
	plan, ok := planned([]string{"C:\\clips\\INTERVIEW.mp4", "C:\\clips\\interview.m4a"})
	defer destroy_plan(plan, context.allocator)

	testing.expect(t, !ok, "two Recordings one filesystem cannot tell apart were planned anyway")
	_, named := plan.collision.?
	testing.expect(t, named, "a plan failed for a collision it did not name")
}

// Artifacts are written beside their Recording, so one stem under two
// directories is two Transcripts and not a collision.
@(test)
one_stem_under_two_directories_is_two_artifacts_and_plans_cleanly :: proc(t: ^testing.T) {
	plan, ok := planned([]string{"C:\\clips\\june\\talk.mp4", "C:\\clips\\july\\talk.mp4"})
	defer destroy_plan(plan, context.allocator)

	testing.expect(t, ok, "two Recordings in different directories were called a collision")
	testing.expect_value(t, len(plan.entries), 2)
}

@(test)
every_recording_found_reaches_the_plan_with_a_decision_of_its_own :: proc(t: ^testing.T) {
	plan, ok := planned(
		[]string{"C:\\clips\\one.mp4", "C:\\clips\\two.mkv", "C:\\clips\\three.m4a"},
	)
	defer destroy_plan(plan, context.allocator)

	testing.expect(t, ok, "a Batch with no collision in it failed the plan")
	testing.expect_value(t, len(plan.entries), 3)
	for entry in plan.entries {
		testing.expectf(
			t,
			entry.outcome.decision == .Transcribe,
			"%q was %v rather than transcribed",
			entry.found.source,
			entry.outcome.decision,
		)
	}
}

// A path that names no file makes no artifact name at all, so it cannot collide
// with anything -- and it must still reach the plan as its own refusal.
@(test)
a_path_that_names_no_file_is_refused_rather_than_dropped_from_the_plan :: proc(t: ^testing.T) {
	plan, ok := planned([]string{"C:\\clips\\", "C:\\clips\\talk.mp4"})
	defer destroy_plan(plan, context.allocator)

	testing.expect(t, ok, "a path naming no file was reported as a collision")
	testing.expect_value(t, len(plan.entries), 2)
	testing.expect_value(t, plan.entries[0].outcome.reason, Reason.Names_No_File)
}
