#+vet explicit-allocators
package pipeline

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:testing"
import "transcibr:artifact"
import "transcibr:audio"
import "transcibr:child"
import "transcibr:engine"
import "transcibr:planning"
import "transcibr:process"
import "transcibr:testkit"
import "transcibr:transcript"

// Freed by the caller with `delete` and the same allocator, exactly like a
// real `identify_model` answer -- `Sidecar` does not own the strings a caller
// builds it out of (see artifact.Sidecar's own doc comment), so `made.model_-`
// `digest` below stays valid only as long as this does.
@(private)
@(require_results)
a_digest :: proc(fill: u8) -> artifact.Digest {
	one := [1]u8{fill}
	return artifact.Digest(
		strings.repeat(string(one[:]), artifact.DIGEST_CHARS, context.allocator),
	)
}

// The landmine ADR-0027 names at `current_of` (src/planning/plan.odin): a
// worker that reused a RECORDED Sidecar to write a fresh one after a real
// transcribe would stamp the previous Engine's version onto cues the
// currently installed one decoded. `recording_sidecar` cannot do that even by
// accident -- its signature carries no recorded Sidecar at all, only what
// this Batch named and what this run measured -- and this pins the answer
// rather than the signature.
@(test)
recording_sidecar_never_carries_a_stale_recorded_engine_version :: proc(t: ^testing.T) {
	digest := a_digest('a')
	defer delete(string(digest), context.allocator)
	job := Recording_Job {
		source = "C:\\clips\\talk.mp4",
		tools = Tools{engine = engine.Tools{engine = "C:\\tools\\whisper-cli.exe"}},
		engine_version = "whisper.cpp 1.9.9",
		model = artifact.Model{path = "C:\\models\\large.bin", digest = digest, bytes = 500},
		prompt = "names and jargon",
		profile = transcript.Merge_Profile.Conversation,
	}
	extracted := Recording_Extracted {
		planned = audio.Reading{bytes = 12_345, modified_ns = 67_890},
		extracted = audio.Extracted{container_ms = 30_000},
	}

	made := recording_sidecar(job, extracted)

	testing.expect_value(t, made.engine_version, "whisper.cpp 1.9.9")
	testing.expect_value(t, made.engine, "C:\\tools\\whisper-cli.exe")
	testing.expect_value(t, made.model, "C:\\models\\large.bin")
	testing.expect_value(t, made.merge_profile, "conversation")
	testing.expect_value(t, made.prompt, "names and jargon")
	testing.expect_value(t, made.source_bytes, i64(12_345))
	testing.expect_value(t, made.source_modified_ns, i64(67_890))
	testing.expect_value(t, made.container_ms, i64(30_000))
}

// The same proof from the other side: two Jobs built for the identical
// Recording but naming different Engines produce Sidecars that disagree on
// exactly that field -- there is no shared, cached "current" value a second
// call could leak from the first.
@(test)
recording_sidecar_reflects_whichever_engine_its_own_job_named :: proc(t: ^testing.T) {
	extracted := Recording_Extracted {
		planned = audio.Reading{bytes = 1, modified_ns = 1},
		extracted = audio.Extracted{container_ms = 1_000},
	}
	digest := a_digest('b')
	defer delete(string(digest), context.allocator)
	model := artifact.Model {
		path   = "m.bin",
		digest = digest,
		bytes  = 1,
	}

	first := recording_sidecar(
		Recording_Job {
			tools = Tools{engine = engine.Tools{engine = "engine-one.exe"}},
			engine_version = "engine-one",
			model = model,
			profile = transcript.DEFAULT_PROFILE,
		},
		extracted,
	)
	second := recording_sidecar(
		Recording_Job {
			tools = Tools{engine = engine.Tools{engine = "engine-two.exe"}},
			engine_version = "engine-two",
			model = model,
			profile = transcript.DEFAULT_PROFILE,
		},
		extracted,
	)

	testing.expect_value(t, first.engine_version, "engine-one")
	testing.expect_value(t, second.engine_version, "engine-two")
}

// A pre-1970 modification time is an operating error the filesystem can
// genuinely hand back (`os.stat` really does date real files before 1970,
// src/artifact/sidecar.odin:164), not a programmer bug -- A8 asks that it be
// refused through `artifact.recordable`/`complete`'s error return, downstream
// of this call, and never asserted here. This pins that `recording_sidecar`
// itself stays a pass-through for the field and does not crash on it.
@(test)
recording_sidecar_passes_a_pre_1970_modification_time_through_without_crashing :: proc(
	t: ^testing.T,
) {
	digest := a_digest('d')
	defer delete(string(digest), context.allocator)
	extracted := Recording_Extracted {
		planned = audio.Reading{bytes = 1, modified_ns = -1},
		extracted = audio.Extracted{container_ms = 1_000},
	}

	made := recording_sidecar(
		Recording_Job {
			tools = Tools{engine = engine.Tools{engine = "whisper-cli.exe"}},
			engine_version = "whisper.cpp 1.9.9",
			model = artifact.Model{path = "m.bin", digest = digest, bytes = 1},
			profile = transcript.DEFAULT_PROFILE,
		},
		extracted,
	)

	testing.expect_value(t, made.source_modified_ns, i64(-1))
}

// The three outcomes `sort_entry` settles without ever building a Recording
// Job: nothing here should reach the GPU-serialising pipeline at all, which
// this proves by checking that `jobs` stays empty rather than by mocking
// run_batch.
@(test)
sort_entry_counts_skip_and_refuse_without_building_a_job :: proc(t: ^testing.T) {
	o := Batch_Options {
		profile = transcript.DEFAULT_PROFILE,
	}
	summary: Summary
	jobs := make([dynamic]Recording_Job, 0, 2, context.allocator)
	defer delete(jobs)

	skipped := planning.Entry {
		found = planning.Found{source = "C:\\clips\\done.mp4"},
		outcome = planning.Outcome{decision = .Skip, reason = .Up_To_Date},
	}
	refused := planning.Entry {
		found = planning.Found{source = "C:\\clips\\bad"},
		outcome = planning.Outcome{decision = .Refuse, reason = .Names_No_File},
	}

	sort_entry(&summary, skipped, o, context.allocator, &jobs)
	sort_entry(&summary, refused, o, context.allocator, &jobs)

	testing.expect_value(t, summary.skipped, 1)
	testing.expect_value(t, summary.refused, 1)
	testing.expect_value(t, summary.transcribed, 0)
	testing.expect_value(t, len(jobs), 0)
}

// The one entry sort_entry hands to the pipeline: a Job that carries the
// Recording forward and an arena of its own, freed by whichever Stage
// finishes it -- never freed here, because a Job that has not yet reached a
// Stage still owns it.
@(test)
sort_entry_builds_exactly_one_job_for_a_transcribe_decision :: proc(t: ^testing.T) {
	digest := a_digest('c')
	defer delete(string(digest), context.allocator)
	o := Batch_Options {
		model = artifact.Model{path = "m.bin", digest = digest, bytes = 1},
		tools = Tools{engine = engine.Tools{engine = "whisper-cli.exe"}},
		profile = transcript.DEFAULT_PROFILE,
	}
	summary: Summary
	jobs := make([dynamic]Recording_Job, 0, 1, context.allocator)
	defer delete(jobs)

	entry := planning.Entry {
		found = planning.Found{source = "C:\\clips\\talk.mp4"},
		outcome = planning.Outcome{decision = .Transcribe, reason = .Nothing_Recorded},
	}
	sort_entry(&summary, entry, o, context.allocator, &jobs)
	defer abandon_recording_job(jobs[0])

	if !testing.expect_value(t, len(jobs), 1) {
		return
	}
	testing.expect_value(t, jobs[0].source, "C:\\clips\\talk.mp4")
	testing.expect_value(t, jobs[0].name, "talk")
	testing.expect(t, jobs[0].arena != nil, "a Job built for the pipeline carries no arena")
}

// A round-4 adversarial review measured `Recording_Job.engine_exe` as a
// second, independently-set copy of the Engine path alongside `tools.engine.-`
// `engine` (the one `engine.transcribe` actually spawns): mutating the
// recorded copy alone at `recording_job_of` left the whole suite green,
// because nothing tied the two together. `new_recording_job` now takes only
// one Engine path -- `tools.engine.engine` -- and `recording_sidecar` reads
// it from there, so there is no second field left for a caller to set
// differently from what gets spawned. This pins that through the real
// constructor rather than through a hand-built `Recording_Job` literal, which
// would not have exercised the missing field at all.
@(test)
recording_job_of_records_the_same_engine_path_it_will_spawn :: proc(t: ^testing.T) {
	digest := a_digest('e')
	defer delete(string(digest), context.allocator)
	job := new_recording_job(
		"C:\\clips\\talk.mp4",
		"talk",
		nil,
		Tools{engine = engine.Tools{engine = "C:\\tools\\whisper-cli.exe"}},
		"C:\\cache",
		artifact.Model{path = "C:\\models\\large.bin", digest = digest, bytes = 500},
		"",
		"whisper.cpp 1.9.9",
		transcript.DEFAULT_PROFILE,
		engine.Report{},
		Health_Watch{},
	)
	defer abandon_recording_job(job)

	extracted := Recording_Extracted {
		planned = audio.Reading{bytes = 1, modified_ns = 1},
		extracted = audio.Extracted{container_ms = 1_000},
	}
	made := recording_sidecar(job, extracted)

	testing.expect_value(t, made.engine, job.tools.engine.engine)
	testing.expect_value(t, made.engine, "C:\\tools\\whisper-cli.exe")
}

// Shared by `health_check_job` (one job, its own fresh watch) and the round-4
// regression below (two jobs, one shared watch) -- factored apart so a test
// that needs the SAME `Health_Watch` to outlive more than one Recording does
// not have to reach into a helper built only for the single-job case.
@(private)
@(require_results)
health_checked_job :: proc(
	t: ^testing.T,
	tag: string,
	output_json: string,
	watch: Health_Watch,
	container_ms := i64(60_000),
	duration_ms := i64(3_000),
	elapsed_ms := i64(3_000),
) -> (
	job: Recording_Job,
) {
	dir := testkit.made_scratch_cache(t, "Pipeline", tag, context.allocator)
	defer delete(dir, context.allocator)
	defer testkit.remove_cache(dir, context.allocator)

	output := fmt.aprintf("%s\\engine-output.json", dir, allocator = context.allocator)
	handle, unopenable := os.open(output, {.Write, .Create, .Trunc})
	testing.expect(t, unopenable == nil, "the case could not write its own fixture")
	_, unwritable := os.write(handle, transmute([]u8)output_json)
	testing.expect(t, unwritable == nil, "the case could not write its own fixture")
	os.close(handle)

	job = new_recording_job(
		"C:\\clips\\talk.mp4",
		"talk",
		nil,
		Tools{engine = engine.Tools{engine = "whisper-cli.exe"}},
		dir,
		artifact.Model{},
		"",
		"whisper.cpp 1.9.9",
		transcript.DEFAULT_PROFILE,
		engine.Report{},
		watch,
	)
	defer abandon_recording_job(job)
	defer delete(output, context.allocator)

	checked_first_recording_health(
		job,
		container_ms,
		engine.Transcribed{output = output, duration_ms = duration_ms, elapsed_ms = elapsed_ms},
	)
	return
}

@(private)
@(require_results)
health_check_job :: proc(
	t: ^testing.T,
	tag: string,
	output_json: string,
	container_ms := i64(60_000),
	duration_ms := i64(3_000),
	elapsed_ms := i64(3_000),
) -> (
	job: Recording_Job,
	checked, abort, unhealthy: bool,
) {
	job = health_checked_job(
		t,
		tag,
		output_json,
		Health_Watch{checked = &checked, abort = &abort, unhealthy = &unhealthy},
		container_ms,
		duration_ms,
		elapsed_ms,
	)
	return
}

@(test)
a_healthy_first_recording_is_checked_once_and_never_aborts_the_batch :: proc(t: ^testing.T) {
	_, checked, abort, unhealthy := health_check_job(
		t,
		"healthy",
		`{"systeminfo": "WHISPER : CUDA : ARCHS = 500,610,700"}`,
	)
	testing.expect_value(t, checked, true)
	testing.expect_value(t, abort, false)
	testing.expect_value(t, unhealthy, false)
}

// The finding this pins: `abort` alone is the identical pointer a Ctrl+C
// press sets, and `pipeline.batch_succeeded` reads a cancelled Batch as a
// success -- correct for an operator's own Ctrl+C, wrong for a Batch stopped
// because the GPU is not being used. `unhealthy` is the SEPARATE signal the
// CLI reads to answer a nonzero exit code specifically for this case, without
// changing what Ctrl+C itself still means.
@(test)
an_unhealthy_first_recording_sets_both_the_shared_abort_flag_and_its_own_unhealthy_flag :: proc(
	t: ^testing.T,
) {
	_, checked, abort, unhealthy := health_check_job(
		t,
		"unhealthy",
		`{"systeminfo": "WHISPER : no gpu backend at all"}`,
	)
	testing.expect_value(t, checked, true)
	testing.expect_value(t, abort, true)
	testing.expect_value(t, unhealthy, true)
}

@(test)
review_engine_output_with_no_systeminfo_field_must_not_abort_the_batch :: proc(t: ^testing.T) {
	_, checked, abort, unhealthy := health_check_job(
		t,
		"nosysteminfo",
		`{"result": {"language": "en"}}`,
	)
	testing.expect_value(t, checked, true)
	testing.expect_value(t, abort, false)
	testing.expect_value(t, unhealthy, false)
}

@(test)
review_unparseable_engine_output_must_not_abort_the_batch :: proc(t: ^testing.T) {
	_, checked, abort, unhealthy := health_check_job(t, "unparseable", `not json at all`)
	testing.expect_value(t, checked, true)
	testing.expect_value(t, abort, false)
	testing.expect_value(t, unhealthy, false)
}

// The round-4 finding: a first Recording under `MIN_HEALTH_CHECK_CONTAINER_-`
// `MS` used to burn the Batch's one health check on a Recording the speed
// half declined to judge, leaving the CUDA-name half's own `.None` (which is
// duration-independent and DOES apply here) indistinguishable from "checked
// and healthy". A short first Recording must leave the gate open so the
// next, longer one still gets judged.
@(test)
review_a_short_first_recording_leaves_the_check_open_for_the_next_one :: proc(t: ^testing.T) {
	checked, abort, unhealthy: bool
	watch := Health_Watch {
		checked   = &checked,
		abort     = &abort,
		unhealthy = &unhealthy,
	}

	_ = health_checked_job(
		t,
		"shortfirst",
		`{"systeminfo": "WHISPER : CUDA : ARCHS = 500,610,700"}`,
		watch,
		container_ms = 2_000,
		duration_ms = 2_000,
		elapsed_ms = 1_400,
	)
	testing.expect_value(t, checked, false)
	testing.expect_value(t, abort, false)

	_ = health_checked_job(
		t,
		"shortfirstsecond",
		`{"systeminfo": "WHISPER : no gpu backend at all"}`,
		watch,
		container_ms = 60_000,
		duration_ms = 60_000,
		elapsed_ms = 60_000,
	)
	testing.expect_value(t, checked, true)
	testing.expect_value(t, abort, true)
	testing.expect_value(t, unhealthy, true)
}

// The exact shape a healthy `--batch` reaches on real hardware: the Engine's
// own reported audio duration equals the Recording's container length on
// every healthy run (both name the same audio), so a factor computed against
// `duration_ms` is always ~1.0x and always aborts. `elapsed_ms` here is the
// wall clock a fast GPU run actually takes for a 10-second clip -- the
// quantity the factor must be computed against instead.
@(test)
review_a_real_engine_duration_reading_must_not_abort_a_healthy_batch :: proc(t: ^testing.T) {
	_, checked, abort, unhealthy := health_check_job(
		t,
		"realengine",
		`{"systeminfo": "WHISPER : CUDA : ARCHS = 500,610,700"}`,
		container_ms = 10_000,
		duration_ms = 10_000,
		elapsed_ms = 600,
	)
	testing.expect_value(t, checked, true)
	testing.expect_value(t, abort, false)
	testing.expect_value(t, unhealthy, false)
}

// Issue #211's real-child half. A stand-in Engine that walks its own
// arguments for `-of` rather than being handed the path, spelled the same
// way `engine_test.odin`'s own `stand_in` is -- that copy is `@(private)` to
// package engine and cannot be imported back here. `directory` is a place
// OUTSIDE the Recording's own cache (round-1 adversarial review): the two
// tests below count the cache's own entries afterward, and a stand-in
// written inside the cache would sit in that count as an entry the sweep
// was never supposed to touch either way.
@(private)
@(require_results)
refusal_stand_in :: proc(t: ^testing.T, directory: string, tag: string, body: string) -> string {
	assert(len(body) > 0, "a stand-in Engine that does nothing at all says nothing")

	path := fmt.aprintf("%s\\stand-in-%s.cmd", directory, tag, allocator = context.allocator)
	script := fmt.aprintf(
		"@echo off\r\nsetlocal\r\nset \"PREFIX=\"\r\n:next\r\nif \"%%~1\"==\"\" goto ready\r\nif /i \"%%~1\"==\"-of\" set \"PREFIX=%%~2\"\r\nshift\r\ngoto next\r\n:ready\r\n%s\r\n",
		body,
		allocator = context.allocator,
	)
	defer delete(script, context.allocator)

	testing.expect(
		t,
		os.write_entire_file(path, transmute([]u8)script) == nil,
		"could not write the stand-in Engine",
	)
	return path
}

@(private)
@(require_results)
opened_group :: proc(t: ^testing.T) -> (group: child.Job_Object, ok: bool) {
	opened, err := child.job_object_open()
	if !testing.expectf(t, err.fault == .None, "no job object: %v", err.fault) {
		return {}, false
	}
	return opened, true
}

// A round-1 adversarial review found the two tests below asserting only the
// absence of one exact path -- a mutation that renamed the Engine's output
// (`<name>-x.json` instead of `<name>.json`) left the real, renamed partial
// sitting in the cache and both tests stayed green, because the exact path
// they checked for never existed either way. Listing the whole cache and
// counting its entries catches that: a renamed leftover is a real entry the
// exact-path check could never see. The caller frees the returned names and
// the slice itself.
//
// A round-2 adversarial review found the entry-set check still vacuous in the
// OTHER direction: an Engine that never wrote into the cache at all (a broken
// `-of` arg walk, or a broken `-of` flag name in `engine_arguments` itself)
// leaves the cache holding only the sentinel either way, so the check passes
// identically whether the sweep removed a real file or removed nothing. The
// witness helper below closes that: it names an extra file the stand-in
// writes at its own resolved prefix, alongside the Engine output proper, so
// the cache holding the witness after the run is a positive proof the child
// really resolved that prefix INSIDE the cache and wrote there -- not just
// that the Engine output is absent.
@(private)
@(require_results)
cache_entry_names :: proc(t: ^testing.T, cache: string, allocator: mem.Allocator) -> []string {
	assert(len(cache) > 0, "there is no cache here to list")

	listing, unreadable := os.read_all_directory_by_path(cache, allocator)
	testing.expectf(t, unreadable == nil, "could not list %s: %v", cache, unreadable)
	names := make([]string, len(listing), allocator)
	for info, i in listing {
		names[i] = strings.clone(info.name, allocator)
	}
	os.file_info_slice_delete(listing, allocator)
	return names
}

// Whether `want` appears anywhere in `names` -- factored out of
// `sweep_leaves_only_the_sentinel_audio` below purely to keep that procedure
// under CLAUDE.md rule F1's 70-line limit once the witness check grew it.
// Shared by `sweep_leaves_only_the_witness`'s sentinel and neighbor writes --
// factored out purely to keep that procedure under CLAUDE.md rule F1's
// 70-line limit once the neighbor probe grew it.
@(private)
must_write_probe :: proc(t: ^testing.T, path: string, label: string) {
	assert(len(path) > 0, "a probe write reached with no path")
	testing.expectf(t, os.write_entire_file(path, []u8{0}) == nil, "could not write the %s", label)
}

@(private)
@(require_results)
names_contain :: proc(names: []string, want: string) -> bool {
	for name in names {
		if name == want {
			return true
		}
	}
	return false
}

// Issue #251's own proof, layered onto #211's: a Recording whose Engine run
// finishes and refuses it (a real, non-empty output written, then a nonzero
// exit -- the #186 review's shape) must leave zero NEW entries in the
// scratch cache AND its own extracted `.wav` gone once `transcribe_and_place`
// has settled it. Four things a bare "the exact output path is gone" check
// cannot see (round-1 adversarial review, mutations 5 and 2; round-2
// adversarial review, mutations F and G; round-1-of-#254's-fix-round
// adversarial review): a renamed leftover (the sweep built the wrong path
// and removed nothing real), an overreaching sweep (the sweep removed a file
// it had no business touching), a sweep that swept nothing because the
// Engine never wrote into the cache at all (a broken `-of` arg walk in the
// stand-in itself, or a broken `-of` flag name in `engine_arguments`) -- the
// last of which the first two rounds' entry-set check could not see either,
// because an Engine that writes nothing leaves the cache holding only the
// sentinel exactly the way a correct sweep does -- and an overreaching wav
// sweep specifically (the #254 fix-round finding: a directory-walk removing
// every `.wav` in the cache passed the whole suite because the only wav in
// the cache WAS the sweep's own target). `sentinel` stands in for the
// extracted `.wav` `audio.extract` would have already written at this exact
// prefix by the time a real Batch reaches transcription -- issue #251
// measured it outliving the refusal it belongs to, so it must now be gone
// alongside the Engine's own output. `neighbor` stands in for a SECOND
// Recording's extracted wav sharing this same cache -- it must survive, and
// is the positive proof the sweep is an exact-path `os.remove` and not a
// directory walk. `body` also writes a witness file at its own resolved
// prefix, a name neither sweep ever touches -- the witness surviving in the
// cache is the positive proof that the Engine really resolved that prefix
// INSIDE the cache and wrote there, closing the third gap above. The
// stand-in Engine itself is written OUTSIDE the cache so the entry count in
// the cache means only what the sweeps -- and the witness and neighbor
// writes -- did to it. Shared by both tests below so each stays under
// CLAUDE.md rule F1's 70-line limit; `tag` keeps their scratch caches apart
// and `body` is each one's own stand-in shape.
@(private)
sweep_leaves_only_the_witness :: proc(t: ^testing.T, tag: string, body: string) {
	group, ok := opened_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	cache := testkit.made_scratch_cache(t, "Pipeline", tag, context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	tools_tag := fmt.aprintf("%s-tools", tag, allocator = context.allocator)
	defer delete(tools_tag, context.allocator)
	tools_dir := testkit.made_scratch_cache(t, "Pipeline", tools_tag, context.allocator)
	defer delete(tools_dir, context.allocator)
	defer testkit.remove_cache(tools_dir, context.allocator)

	sentinel := fmt.aprintf("%s\\%s.wav", cache, tag, allocator = context.allocator)
	defer delete(sentinel, context.allocator)
	must_write_probe(t, sentinel, "sentinel audio file")

	neighbor := fmt.aprintf("%s\\%s-neighbor.wav", cache, tag, allocator = context.allocator)
	defer delete(neighbor, context.allocator)
	must_write_probe(t, neighbor, "neighbor audio file")

	executable := refusal_stand_in(t, tools_dir, tag, body)
	defer delete(executable, context.allocator)

	job := new_recording_job(
		"C:\\clips\\talk.mp4",
		tag,
		&group,
		Tools{engine = engine.Tools{engine = executable}},
		cache,
		artifact.Model{path = "C:\\nowhere\\model.bin"},
		"",
		"whisper.cpp 1.9.9",
		transcript.DEFAULT_PROFILE,
		engine.Report{},
		Health_Watch{},
	)
	extracted := Recording_Extracted {
		job = job,
		extracted = audio.Extracted{audio = sentinel, container_ms = 2_000},
	}

	placed := transcribe_and_place(extracted)

	testing.expect_value(t, placed, false)

	names := cache_entry_names(t, cache, context.allocator)
	defer {
		for name in names {
			delete(name, context.allocator)
		}
		delete(names, context.allocator)
	}
	testing.expectf(
		t,
		len(names) == 2 &&
		names_contain(names, fmt.tprintf("%s.witness", tag)) &&
		names_contain(names, fmt.tprintf("%s-neighbor.wav", tag)),
		"the cache held %v after %s, wanted only the Engine's witness and the neighbor's wav -- either the wav swept too or the sweep overreached onto the neighbor",
		names,
		tag,
	)
}

@(test)
a_refused_recording_leaves_no_engine_output_or_wav_behind_in_the_scratch_cache :: proc(
	t: ^testing.T,
) {
	sweep_leaves_only_the_witness(
		t,
		"refused-sweep",
		">\"%PREFIX%.json\" echo {}\r\n>\"%PREFIX%.witness\" echo x\r\nexit /b 3",
	)
}

// The `.Output_Empty` precedent the ticket names converging to the same
// shape: the Engine exits 0 but writes an empty file, `landed_bounded`
// reports `.Output_Empty`, and the empty file -- and now the wav -- must be
// swept exactly like a `.Refused` run's are -- proved the same entry-set way
// as the test above. The witness write after the empty output is what pins
// WHICH fault landed here: if the resolved prefix were wrong (round-2
// mutation G/F), the witness would never reach the cache, and neither would
// the real `.json` written on the same line before it -- so a witness
// surviving in the cache is proof the output existed at the expected path
// for `landed_bounded` to find and read as empty, the shape `.No_Output` (a
// missing file) cannot produce.
@(test)
an_output_empty_recording_leaves_no_engine_output_or_wav_behind_in_the_scratch_cache :: proc(
	t: ^testing.T,
) {
	sweep_leaves_only_the_witness(
		t,
		"empty-sweep",
		"type nul > \"%PREFIX%.json\"\r\n>\"%PREFIX%.witness\" echo x",
	)
}

// Issue #211's fault-walk mirror of src/audio/run_test.odin's own
// `the_one_failure_that_leaves_a_part_behind_is_an_ffmpeg_that_would_not_stop`
// -- every `engine.Fault` member walked through `discard_engine_output`
// directly, no child spawn needed. A round-1 adversarial review deleted the
// `.Not_Stopped` guard outright and the full `src/pipeline` suite stayed
// green; this table walk is what pins that one member's own behavior rather
// than leaving it "asserted by prose only" the way the review found it.
@(test)
every_engine_fault_but_not_stopped_sweeps_its_own_engine_output :: proc(t: ^testing.T) {
	cache := testkit.made_scratch_cache(t, "Pipeline", "fault-walk", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	job := Recording_Job {
		cache     = cache,
		name      = "fault-walk",
		allocator = context.allocator,
	}
	prefix := fmt.aprintf("%s\\%s", job.cache, job.name, allocator = context.allocator)
	defer delete(prefix, context.allocator)
	output := process.engine_output_path(prefix, context.allocator)
	defer delete(output, context.allocator)

	for fault in engine.Fault {
		if fault == .None {
			continue
		}
		testing.expectf(
			t,
			os.write_entire_file(output, []u8{0}) == nil,
			"could not write %s",
			output,
		)
		discard_engine_output(job, fault)
		testing.expectf(
			t,
			os.exists(output) == (fault == .Not_Stopped),
			"%v left the Engine output in the wrong state",
			fault,
		)
		os.remove(output)
	}
}

// Issue #251's own fault-walk mirror, one level narrower than
// `every_engine_fault_but_not_stopped_sweeps_its_own_engine_output` above:
// `discard_recording_wav` keeps the wav on `.Did_Not_Finish` as well as
// `.Not_Stopped` -- a stop is not a refusal (this proc's own doc comment
// records why) -- so the kept set here is two members wide where the
// Engine-output sweep's is one. A round-1-style deletion of either guard
// would still pass every OTHER test in this file; this table is what pins
// both members' own behavior rather than leaving it asserted by prose only.
@(test)
every_engine_fault_but_not_stopped_or_did_not_finish_sweeps_its_own_recording_wav :: proc(
	t: ^testing.T,
) {
	cache := testkit.made_scratch_cache(t, "Pipeline", "wav-fault-walk", context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	wav := fmt.aprintf("%s\\wav-fault-walk.wav", cache, allocator = context.allocator)
	defer delete(wav, context.allocator)

	for fault in engine.Fault {
		if fault == .None {
			continue
		}
		kept := fault == .Not_Stopped || fault == .Did_Not_Finish
		testing.expectf(t, os.write_entire_file(wav, []u8{0}) == nil, "could not write %s", wav)
		discard_recording_wav(wav, fault)
		testing.expectf(
			t,
			os.exists(wav) == kept,
			"%v left the extracted wav in the wrong state",
			fault,
		)
		os.remove(wav)
	}
}

// Issue #251's success-side pin, the other direction of the ticket's own
// acceptance criteria: an Engine run that comes through clean must leave its
// Recording's extracted wav untouched, byte for byte. Reuses
// `sweep_leaves_only_the_witness`'s own stand-in and sentinel technique
// (`refusal_stand_in`, a real child spawned through the same `Job_Object`)
// rather than calling `discard_recording_wav` directly, because the fact
// this pins is upstream of that proc entirely -- that `transcribe_and_place`
// never REACHES the sweep call at all when `unfinished.fault == .None`. #252
// records that `transcribe_and_place`'s own success path -- what
// `placed_and_reported` does with a real Engine output afterward -- carries
// no test coverage yet; this test does not close that gap; it stops at
// proving the wav survives regardless of what `placed_and_reported` goes on
// to do with the placement itself, which is #252's fixture to build.
@(test)
a_successful_recording_leaves_its_extracted_wav_byte_identical :: proc(t: ^testing.T) {
	group, ok := opened_group(t)
	defer child.job_object_close(&group)
	if !ok {
		return
	}

	tag := "success-survives"
	cache := testkit.made_scratch_cache(t, "Pipeline", tag, context.allocator)
	defer delete(cache, context.allocator)
	defer testkit.remove_cache(cache, context.allocator)

	tools_tag := fmt.aprintf("%s-tools", tag, allocator = context.allocator)
	defer delete(tools_tag, context.allocator)
	tools_dir := testkit.made_scratch_cache(t, "Pipeline", tools_tag, context.allocator)
	defer delete(tools_dir, context.allocator)
	defer testkit.remove_cache(tools_dir, context.allocator)

	sentinel := fmt.aprintf("%s\\%s.wav", cache, tag, allocator = context.allocator)
	defer delete(sentinel, context.allocator)
	original := []u8{1, 2, 3, 4, 5}
	testing.expect(
		t,
		os.write_entire_file(sentinel, original) == nil,
		"could not write the sentinel audio file",
	)

	executable := refusal_stand_in(t, tools_dir, tag, ">\"%PREFIX%.json\" echo {}")
	defer delete(executable, context.allocator)

	digest := a_digest('s')
	defer delete(string(digest), context.allocator)
	job := new_recording_job(
		"C:\\clips\\talk.mp4",
		tag,
		&group,
		Tools{engine = engine.Tools{engine = executable}},
		cache,
		artifact.Model{path = "C:\\nowhere\\model.bin", digest = digest, bytes = 1},
		"",
		"whisper.cpp 1.9.9",
		transcript.DEFAULT_PROFILE,
		engine.Report{},
		Health_Watch{},
	)
	extracted := Recording_Extracted {
		job = job,
		extracted = audio.Extracted{audio = sentinel, container_ms = 2_000},
	}

	_ = transcribe_and_place(extracted)

	after, unreadable := os.read_entire_file_from_path(sentinel, context.allocator)
	testing.expectf(
		t,
		unreadable == nil,
		"the sentinel audio did not survive at all: %v",
		unreadable,
	)
	defer delete(after, context.allocator)
	testing.expect_value(t, string(after), string(original))
}
