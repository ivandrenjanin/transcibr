#+vet explicit-allocators
package transcript

import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"

@(private)
Gap_Distribution :: struct {
	touching:  f64,
	over_800:  f64,
	over_2500: f64,
	p50:       Millis,
	p75:       Millis,
	p90:       Millis,
}

@(private)
Material :: struct {
	name:                    string,
	gaps:                    []Millis,
	duration_ms:             Millis,
	unfinished_every:        int,
	finished:                []string,
	unfinished:              []string,
	measured:                Gap_Distribution,
	monologue_paragraphs:    int,
	conversation_paragraphs: int,
}

@(private, rodata)
CONTINUOUS_GAPS := []Millis {
	0,
	0,
	80,
	0,
	0,
	160,
	0,
	800,
	0,
	0,
	40,
	0,
	2_500,
	0,
	120,
	0,
	240,
	0,
	8_240,
	0,
	0,
	300,
	1_020,
	0,
	80,
	0,
	3_100,
	200,
	0,
	440,
	21_000,
	360,
	0,
	520,
	4_600,
	640,
	6_200,
	10_500,
	13_000,
	0,
}

@(private, rodata)
INTERACTIVE_GAPS := []Millis {
	520,
	380,
	900,
	460,
	1_020,
	420,
	320,
	640,
	480,
	2_600,
	500,
	560,
	350,
	820,
	440,
	240,
	1_300,
	490,
	700,
	0,
	600,
	470,
	1_800,
	400,
	280,
	860,
	520,
	3_400,
	450,
	200,
	960,
	540,
	140,
	5_200,
	2_100,
	510,
	1_140,
	2_340,
	0,
	1_500,
}

@(private, rodata)
CONTINUOUS_FINISHED := []string {
	" The thing about a long recording is that nobody ever edits it.",
	" You end up with an hour of speech and no way into it at all.",
	" So the merger has to decide where a reader is allowed to breathe.",
	" It reads the silence, and it reads the full stops, and that is all.",
	" Anything cleverer than that would need a model of its own to run.",
}

@(private, rodata)
CONTINUOUS_UNFINISHED := []string {
	" and the reason all of that matters is fairly simple once you see it,",
	" which is something you only really notice after a while of reading,",
	" because the engine cuts a fragment wherever it happens to land,",
}

@(private, rodata)
INTERACTIVE_FINISHED := []string {
	" Yes, exactly.",
	" No, not really.",
	" Did you try it?",
	" I think so.",
	" That makes sense.",
	" Go on, then.",
	" Right.",
	" Hold on a second.",
}

@(private, rodata)
INTERACTIVE_UNFINISHED := []string{" and then I said to them,"}

// Measured; see ADR-0007.
// Not rodata: every row names the tables above, which are variables.
@(private)
MATERIALS := []Material {
	{
		name = "continuous single-speaker",
		gaps = CONTINUOUS_GAPS,
		duration_ms = 3_840,
		unfinished_every = 5,
		finished = CONTINUOUS_FINISHED,
		unfinished = CONTINUOUS_UNFINISHED,
		measured = {
			touching = 0.458,
			over_800 = 0.255,
			over_2500 = 0.190,
			p50 = 80,
			p75 = 800,
			p90 = 8_240,
		},
		monologue_paragraphs = 9,
		conversation_paragraphs = 12,
	},
	{
		name = "interactive, short exchanges",
		gaps = INTERACTIVE_GAPS,
		duration_ms = 1_220,
		unfinished_every = 40,
		finished = INTERACTIVE_FINISHED,
		unfinished = INTERACTIVE_UNFINISHED,
		measured = {
			touching = 0.058,
			over_800 = 0.353,
			over_2500 = 0.092,
			p50 = 520,
			p75 = 1_020,
			p90 = 2_340,
		},
		monologue_paragraphs = 8,
		conversation_paragraphs = 23,
	},
}

@(private)
@(require_results)
material_cues :: proc(m: Material, allocator: mem.Allocator) -> []Cue {
	assert(len(m.gaps) > 0, "material with no gaps in it describes no cue set")
	assert(
		m.unfinished_every > 0,
		"material where every cue is unfinished carries no sentence signal",
	)
	assert(len(m.finished) > 0, "material with nothing said in it")
	assert(len(m.unfinished) > 0, "material with nothing left unfinished in it")

	shape := make([]Shaped_Cue, len(m.gaps), allocator)
	defer delete(shape, allocator)

	for gap, i in m.gaps {
		said := m.finished[i % len(m.finished)]
		if (i + 1) % m.unfinished_every == 0 {
			said = m.unfinished[i % len(m.unfinished)]
		}
		shape[i] = Shaped_Cue {
			gap_ms      = gap,
			duration_ms = m.duration_ms,
			text        = said,
		}
	}
	return shaped_cues(shape, allocator)
}

@(private)
@(require_results)
share_at_least :: proc(gaps: []Millis, at_least: Millis) -> f64 {
	assert(len(gaps) > 0, "no gaps to take a share of")

	counted := 0
	for gap in gaps {
		if gap >= at_least {
			counted += 1
		}
	}
	assert(counted <= len(gaps), "counted more gaps than there were")
	return f64(counted) / f64(len(gaps))
}

@(private)
@(require_results)
percentile :: proc(sorted: []Millis, pct: int) -> Millis {
	assert(len(sorted) > 0, "no gaps to take a percentile of")
	assert(pct > 0, "the zeroth percentile is the minimum, which is not what this is for")
	assert(pct < 100, "the hundredth percentile is the maximum, which is not what this is for")

	at := min(len(sorted) * pct / 100, len(sorted) - 1)
	return sorted[at]
}

// Forty gaps apiece against measurements taken over 154 and 415, so a share can
// only land on a multiple of two and a half points.
@(private)
NEAR_ENOUGH :: 0.03

@(test)
the_gap_fixtures_reproduce_what_adr_0007_measured :: proc(t: ^testing.T) {
	for m in MATERIALS {
		sorted := slice.clone(m.gaps, context.allocator)
		defer delete(sorted, context.allocator)
		slice.sort(sorted)

		touching := 1 - share_at_least(sorted, 1)
		testing.expectf(
			t,
			abs(touching - m.measured.touching) <= NEAR_ENOUGH,
			"%s: %.3f of gaps touching, measured %.3f",
			m.name,
			touching,
			m.measured.touching,
		)

		over_800 := share_at_least(sorted, 800)
		testing.expectf(
			t,
			abs(over_800 - m.measured.over_800) <= NEAR_ENOUGH,
			"%s: %.3f of gaps at or over 800 ms, measured %.3f",
			m.name,
			over_800,
			m.measured.over_800,
		)

		over_2500 := share_at_least(sorted, 2_500)
		testing.expectf(
			t,
			abs(over_2500 - m.measured.over_2500) <= NEAR_ENOUGH,
			"%s: %.3f of gaps at or over 2500 ms, measured %.3f",
			m.name,
			over_2500,
			m.measured.over_2500,
		)

		testing.expectf(t, percentile(sorted, 50) == m.measured.p50, "%s: p50 is wrong", m.name)
		testing.expectf(t, percentile(sorted, 75) == m.measured.p75, "%s: p75 is wrong", m.name)
		testing.expectf(t, percentile(sorted, 90) == m.measured.p90, "%s: p90 is wrong", m.name)
	}
}

@(test)
the_two_merge_profiles_paragraph_measured_material_differently :: proc(t: ^testing.T) {
	for m in MATERIALS {
		cues := material_cues(m, context.allocator)
		defer delete(cues, context.allocator)

		generous := merge_paragraphs(cues, MONOLOGUE, context.allocator)
		defer destroy_paragraphs(generous, context.allocator)
		aggressive := merge_paragraphs(cues, CONVERSATION, context.allocator)
		defer destroy_paragraphs(aggressive, context.allocator)

		testing.expectf(
			t,
			len(aggressive) > len(generous),
			"%s: monologue made %d paragraphs and conversation made %d, which is no difference a reader would see",
			m.name,
			len(generous),
			len(aggressive),
		)
		testing.expectf(
			t,
			len(generous) == m.monologue_paragraphs,
			"%s: monologue made %d paragraphs, pinned at %d",
			m.name,
			len(generous),
			m.monologue_paragraphs,
		)
		testing.expectf(
			t,
			len(aggressive) == m.conversation_paragraphs,
			"%s: conversation made %d paragraphs, pinned at %d",
			m.name,
			len(aggressive),
			m.conversation_paragraphs,
		)
	}
}

@(test)
the_profiles_diverge_further_on_interactive_material :: proc(t: ^testing.T) {
	if !testing.expect_value(t, len(MATERIALS), 2) {
		return
	}
	testing.expect_value(t, MATERIALS[0].name, "continuous single-speaker")
	testing.expect_value(t, MATERIALS[1].name, "interactive, short exchanges")

	spread := [2]f64{}
	for m, i in MATERIALS {
		cues := material_cues(m, context.allocator)
		defer delete(cues, context.allocator)

		generous := merge_paragraphs(cues, MONOLOGUE, context.allocator)
		defer destroy_paragraphs(generous, context.allocator)
		aggressive := merge_paragraphs(cues, CONVERSATION, context.allocator)
		defer destroy_paragraphs(aggressive, context.allocator)

		testing.expectf(
			t,
			len(generous) > 0,
			"%s: the generous profile made no paragraphs at all",
			m.name,
		)
		spread[i] = f64(len(aggressive)) / f64(len(generous))
	}

	testing.expectf(
		t,
		spread[1] >= 2,
		"the aggressive profile barely moved interactive material: %.2f times as many paragraphs",
		spread[1],
	)
	testing.expectf(
		t,
		spread[1] > spread[0],
		"both materials came apart by the same margin (%.2f and %.2f), so one threshold would serve both",
		spread[0],
		spread[1],
	)
}

// Reads PROFILES[profile].name directly, exactly as src/audio/fault_test.odin
// reads its own table directly: a row written present and empty is not caught
// by the enumerated array, so nothing but a test that looks at the row itself
// catches it (see CLAUDE.md, Odin notes: enumerated arrays and switches).
// Kept separate from every_merge_profile_is_named_and_names_itself_back below:
// that test's own call to profile_named walks every Merge_Profile internally
// (through profile_row again) to find the name it is given back, so it cannot
// be made to skip a bad row the way a `continue` skips a renderer call.
@(test)
every_merge_profile_has_a_name_in_profiles :: proc(t: ^testing.T) {
	for profile in Merge_Profile {
		testing.expectf(
			t,
			len(PROFILES[profile].name) > 0,
			"%v has an empty row in PROFILES",
			profile,
		)
	}
}

@(test)
every_merge_profile_is_named_and_names_itself_back :: proc(t: ^testing.T) {
	for profile in Merge_Profile {
		name := profile_name(profile)
		testing.expectf(t, len(name) > 0, "%v carries no name", profile)

		back, known := profile_named(name)
		testing.expectf(t, known, "%v is called %q, which is a name nothing knows", profile, name)
		testing.expectf(t, back == profile, "%q came back as %v, want %v", name, back, profile)
	}
}

@(test)
a_name_no_merge_profile_carries_is_refused :: proc(t: ^testing.T) {
	unknown := []string{"murmur", "Monologue", ""}
	for name, i in unknown {
		profile, known := profile_named(name)
		testing.expectf(t, !known, "case %d: %q was accepted as %v", i, name, profile)
	}
}

@(test)
each_merge_profile_carries_the_thresholds_adr_0007_tuned :: proc(t: ^testing.T) {
	testing.expect_value(t, profile_params(.Monologue), MONOLOGUE)
	testing.expect_value(t, profile_params(.Conversation), CONVERSATION)
}

@(test)
the_profiles_a_caller_may_pick_are_the_profiles_that_exist :: proc(t: ^testing.T) {
	names: [len(Merge_Profile)]string
	at := 0
	for profile in Merge_Profile {
		names[at] = profile_name(profile)
		at += 1
	}

	offered := strings.join(names[:], "|", context.allocator)
	defer delete(offered, context.allocator)

	testing.expect_value(t, PROFILE_CHOICE, offered)
}

@(test)
the_default_merge_profile_merges_as_generously_as_any :: proc(t: ^testing.T) {
	fallback := profile_params(DEFAULT_PROFILE)
	for profile in Merge_Profile {
		p := profile_params(profile)
		testing.expectf(
			t,
			fallback.max_gap_ms >= p.max_gap_ms,
			"the default breaks on %v ms of silence where %v waits for %v ms",
			fallback.max_gap_ms,
			profile,
			p.max_gap_ms,
		)
		testing.expectf(
			t,
			fallback.hard_gap_ms >= p.hard_gap_ms,
			"the default breaks whatever was said at %v ms where %v waits for %v ms",
			fallback.hard_gap_ms,
			profile,
			p.hard_gap_ms,
		)
	}
}

@(test)
no_two_merge_profiles_answer_to_one_name :: proc(t: ^testing.T) {
	for profile in Merge_Profile {
		named, _ := profile_named(profile_name(profile))
		testing.expectf(
			t,
			named == profile,
			"%v and %v are both called %q",
			named,
			profile,
			profile_name(profile),
		)
	}
}

@(test)
no_shipped_profile_exceeds_its_own_character_cap :: proc(t: ^testing.T) {
	for m in MATERIALS {
		cues := material_cues(m, context.allocator)
		defer delete(cues, context.allocator)

		for profile in Merge_Profile {
			p := profile_params(profile)
			paragraphs := merge_paragraphs(cues, p, context.allocator)
			defer destroy_paragraphs(paragraphs, context.allocator)

			for paragraph, i in paragraphs {
				held := strings.rune_count(paragraph.text)
				testing.expectf(
					t,
					held <= p.max_para_chars,
					"%s, %s: paragraph %d holds %d characters against a cap of %d",
					m.name,
					profile_name(profile),
					i + 1,
					held,
					p.max_para_chars,
				)
			}
		}
	}
}
