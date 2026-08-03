package transcript

import "core:mem"
import "core:slice"
import "core:strings"
import "core:testing"

// ---------------------------------------------------------------------------
// The two Merge Profiles against the two populations ADR-0007 measured.
//
// The objection this answers is a serious one, and the ADR records it: the
// Engine emits Cues delimited by timestamp tokens in consecutive pairs, so the
// end of one Cue is by construction the start of the next, and inter-Cue gaps
// might carry almost no information. If that were true both profiles would
// collapse into one rule and the whole feature would be theatre.
//
// It is false, and the two content types are measurably different populations
// rather than a distinction invented in advance. The continuous recording is
// bimodal -- 45.8% touching Cues, with 19% of gaps over two and a half seconds
// while the speaker pauses -- and the interactive one is a dense continuous
// distribution of short turns with almost no touching Cues. That is why the
// fixtures below are gap TABLES rather than round numbers: a profile comparison
// run against invented gaps proves only that two different thresholds are two
// different thresholds.
// ---------------------------------------------------------------------------

// The gap distribution ADR-0007 measured for one kind of material, as shares and
// percentiles rather than as a histogram. Held beside the table it describes so
// that a table edited by hand is checked against what it is supposed to be, in
// checked code rather than in a comment (CLAUDE.md A6).
@(private)
Gap_Distribution :: struct {
	touching:  f64,
	over_800:  f64,
	over_2500: f64,
	p50:       Millis,
	p75:       Millis,
	p90:       Millis,
}

// One kind of material: its measured gaps, how long its Cues run, and how often
// they end a sentence.
@(private)
Material :: struct {
	name:                    string,
	gaps:                    []Millis,
	// ADR-0007's Cue duration p50 for this material, used for every Cue. The
	// merger reads durations only through the gap between neighbours, so
	// spreading them would vary nothing this measures.
	duration_ms:             Millis,
	// One Cue in every `unfinished_every` ends without a sentence-ending mark,
	// which is how the measured sentence-final share is reproduced: one in five
	// for continuous speech (80.5% measured), one in forty for interactive
	// (99.8% measured).
	unfinished_every:        int,
	finished:                []string,
	unfinished:              []string,
	measured:                Gap_Distribution,
	// What each profile makes of it. Observed and then pinned, so paragraphing
	// cannot drift without a test saying so -- the relation between them is
	// asserted separately, and that one comes from the ADR rather than from a
	// run of this code.
	monologue_paragraphs:    int,
	conversation_paragraphs: int,
}

// 45.8% of these are touching, and a fifth of them are pauses over two and a
// half seconds long. Written in a plausible spoken order rather than sorted:
// runs of touching Cues with the occasional long pause through them, which is
// what "bimodal" looks like laid out in time. The percentiles are read off a
// sorted copy in the test, so the order here changes nothing it checks.
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

// The other population: short turns, almost nothing touching, and the mass
// sitting in a dense band either side of half a second.
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

// Not rodata: every row names the tables above, which are variables rather than
// constants, and rodata takes only constant initialisation.
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

// Lays one material's gaps out into Cues, saying something over each of them.
@(private)
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

// The share of gaps at or above a threshold.
@(private)
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

// The value at a percentile of a SORTED set of gaps.
@(private)
percentile :: proc(sorted: []Millis, pct: int) -> Millis {
	assert(len(sorted) > 0, "no gaps to take a percentile of")
	assert(pct > 0, "the zeroth percentile is the minimum, which is not what this is for")
	assert(pct < 100, "the hundredth percentile is the maximum, which is not what this is for")

	at := min(len(sorted) * pct / 100, len(sorted) - 1)
	return sorted[at]
}

// Whether a share is close enough to a measured one. Three points: the fixtures
// are forty gaps apiece against measurements taken over 154 and 415, so a share
// can only land on a multiple of two and a half points.
@(private)
NEAR_ENOUGH :: 0.03

// The fixtures against the table they claim to reproduce. A profile comparison
// run over invented gaps proves only that two different thresholds are two
// different thresholds, so what makes the comparison below mean anything is
// this: the gaps it runs on are the ones that were measured.
@(test)
the_gap_fixtures_reproduce_what_adr_0007_measured :: proc(t: ^testing.T) {
	for m in MATERIALS {
		sorted := slice.clone(m.gaps, context.allocator)
		defer delete(sorted, context.allocator)
		slice.sort(sorted)

		// Gaps are whole milliseconds, so "at or below zero" is everything that
		// is not "at or above one".
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

// The acceptance criterion: both profiles against realistic gap distributions,
// producing visibly different paragraphing.
//
// The margins are the interesting part, and they are the bimodality showing
// through. On continuous speech the aggressive profile finds a third again as
// many Paragraphs -- 12 against 9 -- because there is barely any gap mass
// between 800 ms and 2500 ms for its lower thresholds to reach. On interactive
// speech it finds nearly three times as many -- 23 against 8 -- because that
// band is exactly where the interactive distribution puts most of its mass. A
// single threshold cannot serve both, which is the whole of ADR-0007.
//
// The counts here are observations. The RELATION between them is not, and it has
// a case of its own below.
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

// ADR-0007's actual claim, which is not "the two profiles differ" but "the two
// content types are measurably different POPULATIONS rather than a distinction
// invented in advance". If that were wrong, the profiles would pull the two
// materials apart by the same margin and the second profile would be a knob
// rather than a decision.
//
// This is the one expectation in this file that does not come from having run
// the code. It comes from the shape of the two distributions.
@(test)
the_profiles_diverge_further_on_interactive_material :: proc(t: ^testing.T) {
	// MATERIALS is ordered as ADR-0007's table is: continuous first, interactive
	// second. Stated rather than assumed, because everything below indexes it.
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

// ---------------------------------------------------------------------------
// The profiles by NAME, which is what a person picks and what a Transcript
// records having been merged under.
//
// A Merge Profile is "a named set of thresholds" (CONTEXT.md), and until now the
// name existed only in prose: the thresholds were two constants and the word
// `monologue` lived in the spec. A front matter block recording the profile, and
// a command line accepting one, both need the name to be a value.
// ---------------------------------------------------------------------------

@(test)
every_merge_profile_is_named_and_names_itself_back :: proc(t: ^testing.T) {
	// Every member, so a profile added without a row in PROFILES fails here
	// rather than rendering a Transcript that records an empty profile.
	for profile in Merge_Profile {
		name := profile_name(profile)
		testing.expectf(t, len(name) > 0, "%v carries no name", profile)

		back, known := profile_named(name)
		testing.expectf(t, known, "%v is called %q, which is a name nothing knows", profile, name)
		testing.expectf(t, back == profile, "%q came back as %v, want %v", name, back, profile)
	}
}

// The negative space of that (CLAUDE.md A3). Without it, a lookup that answered
// `.Monologue` to everything satisfies every line above.
@(test)
a_name_no_merge_profile_carries_is_refused :: proc(t: ^testing.T) {
	// A name off by a letter, a name in the wrong case, and nothing at all. The
	// middle one is the interesting row: a lookup folding case would accept a
	// spelling the front matter never writes, and re-rendering would then record
	// a profile under two names.
	unknown := []string{"murmur", "Monologue", ""}
	for name, i in unknown {
		profile, known := profile_named(name)
		testing.expectf(t, !known, "case %d: %q was accepted as %v", i, name, profile)
	}
}

// The thresholds behind each name, against the constants ADR-0007 tuned. Read
// through the profile rather than beside it: a table row pointing at the wrong
// constant is a Transcript merged one way and recording the other.
@(test)
each_merge_profile_carries_the_thresholds_adr_0007_tuned :: proc(t: ^testing.T) {
	testing.expect_value(t, profile_params(.Monologue), MONOLOGUE)
	testing.expect_value(t, profile_params(.Conversation), CONVERSATION)
}

// What a usage line offers a caller, read out of the table rather than spelled
// again in another package.
//
// `monologue|conversation` was hand-written into the command line's USAGE, which
// is a copy of PROFILES living where no compiler compares the two: a third
// profile would be unmentioned, and a renamed one would be offered under a
// spelling profile_named refuses.
@(test)
the_profiles_a_caller_may_pick_are_the_profiles_that_exist :: proc(t: ^testing.T) {
	offered := profile_names(context.allocator)
	defer delete(offered, context.allocator)

	listed := strings.split(offered, "|", context.allocator)
	defer delete(listed, context.allocator)

	// Every profile, in the order the enumeration declares them, and nothing
	// else. Walked over the enumeration on one side and the list on the other, so
	// a profile missing from either is a failure rather than a shorter loop.
	at := 0
	for profile in Merge_Profile {
		if !testing.expectf(t, at < len(listed), "%v is not offered in %q", profile, offered) {
			break
		}
		testing.expectf(
			t,
			listed[at] == profile_name(profile),
			"%q is offered where %v was expected",
			listed[at],
			profile,
		)
		at += 1
	}
	testing.expectf(t, at == len(listed), "%q offers something no profile answers to", offered)

	// And every name in it is one the lookup actually accepts, which is the whole
	// promise a usage line makes (CLAUDE.md A4).
	for name in listed {
		_, known := profile_named(name)
		testing.expectf(t, known, "%q is offered and refused", name)
	}
}

// The profile a caller who chose none is merged under, named once so the two
// binaries cannot disagree about it.
//
// Spec story 44 asks that a re-render produce the Transcript the original run
// would have. The command line spelled its default as a bare enum member, where
// the window ADR-0004 promises could quietly spell a different one -- and the
// two would then paragraph the same Recording differently while both recording
// what they did.
@(test)
the_default_merge_profile_is_one_the_lookup_knows :: proc(t: ^testing.T) {
	name := profile_name(DEFAULT_PROFILE)
	testing.expect(t, len(name) > 0, "the default profile carries no name")

	back, known := profile_named(name)
	testing.expectf(t, known, "the default profile is called %q, which nothing knows", name)
	testing.expect_value(t, back, DEFAULT_PROFILE)
}

// Two profiles under one name would resolve to whichever the lookup reached
// first, so a Batch asking for the second gets the first's thresholds and the
// front matter records the name both of them answer to. Nothing in the type
// stops it, and the round trip above cannot see it: the duplicate's own name
// still comes back as a profile, just not as that one.
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

// And the cap, on the profiles that actually ship rather than on a threshold a
// case pinned for itself.
//
// Walked over the ENUMERATION and never over a list of constants written out
// beside it. A third profile added to Merge_Profile would be silently exempt
// from the only case checking the cap on shipped thresholds, while this case's
// name went on claiming it covered every one of them.
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
