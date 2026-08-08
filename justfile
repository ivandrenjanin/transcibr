# Every command this repository's build, test and formatting rules boil down
# to, replacing the six scripts\*.ps1 files issue #152 retired. The vet set
# and the collection flag are the one spelling every recipe below shares;
# CLAUDE.md rule S1 points here rather than repeating them.
#
# No PowerShell anywhere: `install-tools` uses curl.exe and tar.exe, both
# shipped with Windows since 1803, and every other recipe is a bare `odin` or
# `odinfmt` invocation cmd.exe can run as-is.
set windows-shell := ["cmd.exe", "/c"]

odin := env_var_or_default("ODIN", 'C:\Odin\dist\odin.exe')
odinfmt := env_var_or_default("ODINFMT", 'C:\Odin\dist\odinfmt.exe')
vet := "-vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do"
collection := "-collection:transcibr=src"
memory := "-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true"

odin_release := "dev-2026-07a"
odinfmt_release := "dev-2026-06"

# List every recipe.
default:
	@{{ just_executable() }} --list

# Debug build of the CLI, with symbols.
build:
	if not exist build mkdir build
	{{ odin }} build src/cli {{ collection }} -out:build/transcibr-cli.exe -subsystem:console -debug {{ vet }}

# Release build of the CLI, optimised for speed.
release:
	if not exist build mkdir build
	{{ odin }} build src/cli {{ collection }} -out:build/transcibr-cli.exe -subsystem:console -o:speed {{ vet }}

# All existing source policies: CLAUDE.md section 0, rule F1, rule F2, rule
# M2, the issue #97/#105 os.remove_all(...) ban, and the package-accounting
# check issue #152 added -- over both package roots, src/ and tools/: every
# package under either root holding a *_test.odin file must be named in the
# test recipe below, and every package under either root holding none at all
# is a violation (src/cli is the one exemption, by ADR-0009; tools/ has no
# exemption roster at all).
check:
	if not exist build mkdir build
	{{ odin }} run tools/policy {{ collection }} -out:build/transcibr-policy.exe {{ vet }}

# Rewrite every .odin file under src and tools as odinfmt.json says -- the
# same repository-wide scope `check` walks (minus the build/vendor
# directories tools/policy also excludes). docs/reference is no longer named
# here: this PR deleted its only file (absorbed into src/net/winhttp.odin,
# closing #55), so the directory does not exist in a fresh checkout and
# odinfmt exits nonzero over a missing path (fix round 1 finding 1).
fmt:
	{{ odinfmt }} -w -path:src -config:odinfmt.json
	{{ odinfmt }} -w -path:tools -config:odinfmt.json

# The same check, refused if odinfmt would change anything -- compared file
# by file against odinfmt's own un-written output, never against `git diff`,
# so a developer's own uncommitted-but-already-formatted edits elsewhere in
# the tree never trip this (round 2 review finding 1: `git diff` judges git
# state, not byte-formatting, and CI/the ticket-loop always run this on a
# dirty tree). Same scope as `fmt` above.
fmt-check:
	if not exist build mkdir build
	for /r src %f in (*.odin) do @({{ odinfmt }} -path:"%f" -config:odinfmt.json > build\fmt-check.tmp & fc /b "%f" build\fmt-check.tmp >nul || (echo NOT FORMATTED: %f & del /q build\fmt-check.tmp & exit /b 1))
	for /r tools %f in (*.odin) do @({{ odinfmt }} -path:"%f" -config:odinfmt.json > build\fmt-check.tmp & fc /b "%f" build\fmt-check.tmp >nul || (echo NOT FORMATTED: %f & del /q build\fmt-check.tmp & exit /b 1))
	del /q build\fmt-check.tmp

# Builds tools/policy's own test-harness binary, `policy-cli.exe`, which
# `exit_code_test.odin` spawns as a child process to pin the VIOLATION_ERROR
# exit mapping. Kept as its OWN recipe rather than a line inside `test:`'s
# body (fix round 1 finding 1): `missing_from_test_recipe` in
# tools/policy/packages.odin treats the `tools/policy` token as
# present the moment it occurs anywhere in the `test:` recipe's own body, so
# a second occurrence there -- this build line, alongside the real
# `odin test tools/policy` line -- let the package-accounting check see
# `tools/policy` as present even with the real test line deleted. `test:`
# invokes this recipe by name below rather than inlining the `odin build`
# line, so the token appears in `test:`'s body exactly once, on the line
# that actually runs the tests.
policy-cli-exe:
	if not exist build\odin-test mkdir build\odin-test
	{{ odin }} build tools/policy {{ collection }} -out:build/odin-test/policy-cli.exe {{ vet }}

# One explicit line per package: the 12 src/ packages that hold tests, plus
# tools/policy, which reads Odin and is tested in Odin (ADR-0028). `cli` is
# the one src/ package with none, by ADR-0009 -- an entry point thin enough
# to read, with no logic of its own worth testing.
#
# `src/crashlog`'s crash-drill tests spawn a debug build of transcibr-cli as a
# child process and need a real PDB for `assertion_hook`'s stack symbolization
# (issue #76 review round 1). Sharing `build/transcibr-cli.exe` with `build`
# and `release` made `test` pass or fail depending on which of those last ran
# (issue #76 review round 3) -- a `just ci` ending on `release` left a
# non-debug binary at that path, so `test` run again afterward failed a
# symbolization assertion the first `just ci` pass never saw. The drill gets
# its own binary at its own path instead, built here and never touched by
# `build` or `release`.
test:
	if not exist build\odin-test mkdir build\odin-test
	{{ odin }} build src/cli {{ collection }} -out:build/odin-test/transcibr-cli-drill.exe -subsystem:console -debug {{ vet }}
	{{ odin }} test src/artifact {{ collection }} -out:build/odin-test/artifact.exe {{ memory }} {{ vet }}
	{{ odin }} test src/audio {{ collection }} -out:build/odin-test/audio.exe {{ memory }} {{ vet }}
	{{ odin }} test src/child {{ collection }} -out:build/odin-test/child.exe {{ memory }} {{ vet }}
	{{ odin }} test src/cliargs {{ collection }} -out:build/odin-test/cliargs.exe {{ memory }} {{ vet }}
	{{ odin }} test src/crashlog {{ collection }} -out:build/odin-test/crashlog.exe {{ memory }} {{ vet }}
	{{ odin }} test src/doctor {{ collection }} -out:build/odin-test/doctor.exe {{ memory }} {{ vet }}
	{{ odin }} test src/engine {{ collection }} -out:build/odin-test/engine.exe {{ memory }} {{ vet }}
	{{ odin }} test src/net {{ collection }} -out:build/odin-test/net.exe {{ memory }} {{ vet }}
	{{ odin }} test src/pipeline {{ collection }} -out:build/odin-test/pipeline.exe {{ memory }} {{ vet }}
	{{ odin }} test src/planning {{ collection }} -out:build/odin-test/planning.exe {{ memory }} {{ vet }}
	{{ odin }} test src/process {{ collection }} -out:build/odin-test/process.exe {{ memory }} {{ vet }}
	{{ odin }} test src/testkit {{ collection }} -out:build/odin-test/testkit.exe {{ memory }} {{ vet }}
	{{ odin }} test src/transcript {{ collection }} -out:build/odin-test/transcript.exe {{ memory }} {{ vet }}
	{{ odin }} test src/version {{ collection }} -out:build/odin-test/version.exe {{ memory }} {{ vet }}
	{{ just_executable() }} policy-cli-exe
	{{ odin }} test tools/policy {{ collection }} -out:build/odin-test/policy.exe {{ memory }} {{ vet }}

# One test, focused: `just test-one version banner_names_the_program_and_its_version`.
# `policy` resolves to tools/policy; every other name resolves to src/<pkg>.
#
# odin test exits 0 with "No tests to run." (core/testing/runner.odin) when
# ODIN_TEST_NAMES matches no @(test) procedure -- a bogus name reports green
# having run nothing (issue #154). tools/policy's package-accounting check
# does not cover this: it proves the test recipe names every tested package,
# not that one focused run inside a package actually found its target, so
# the guard has to sit where the runner's own words land -- here, not there.
# Output is NOT live: it is redirected into build\odin-test\focus.out and only
# `type`-d back to the console after the odin test process has already exited.
# A run that hangs (the #22 runner hang CLAUDE.md's Odin notes document) or is
# interrupted with Ctrl+C prints nothing at all while it is running and shows
# nothing after the interrupt either -- the `type` replay only runs on the
# success/failure branches below, never on an interrupted invocation, so
# whatever bytes had already landed in focus.out stay on disk, unread on the
# console, until someone opens the file by hand. The odin test exit code
# itself is left untouched for a real pass or a real test failure, and only
# the exit-0-but-nothing-collected case is escalated.
#
# Deliberately grepped for "No tests to run.", not the ticket's suggested
# "Finished 0 tests" -- the zero-collected path in core/testing/runner.odin
# returns before the "Finished %i test%s" line is ever reached, so that
# string does not exist at this pin.
#
# Pinned by `test-one-selftest` below (issue #175), which `ci` now runs: a
# future Odin release that rewords "No tests to run." fails that recipe
# loudly, rather than letting this guard degrade silently back to exit 0. The
# findstr pattern remains a literal, case-sensitive match on one line of text
# owned by the Odin toolchain, not by this repository -- `test-one-selftest`
# pins the wording, not the ownership.
#
# What `test-one-selftest` does NOT pin is the rest of this same staleness
# family, each recorded here as its own still-accepted risk: a stale
# `build\odin-test\transcibr-cli-drill.exe` reports the crashlog crash-drill
# tests green after an edit to record.odin that was never rebuilt (#176-A
# review deposit on issue #175); a stale `build\odin-test\policy-cli.exe`
# reports the policy exit-code tests green the same way (#184 review deposit
# on issue #175). `just test` rebuilds both binaries as its own first lines,
# so `just ci` is honest about those two; only a bare `just test-one` after an
# edit, without a preceding `just test`, meets either of them.
#
# A third, unrelated member of the same family is NOT covered by anything in
# `just ci`: a `#+build`-tagged `*_test.odin` file reports 0 tests collected
# as a pass through `odin test` itself -- the exact line `just test` runs for
# that package -- rather than the hollow-file violation issue #174 closed for
# the untagged case (#174 review deposit on issue #175). Rebuilding binaries
# does not touch this risk; it is a source-level build tag, and no recipe in
# `ci` reads for it. `just test-one` on that package's real test name DOES
# catch it -- the bogus-name guard above fires "0 tests collected" -- so this
# residual is met by `just ci` and missed by a bare `just test-one`, the
# inverse of the other two.
test-one pkg name:
	if not exist build\odin-test mkdir build\odin-test
	{{ odin }} test {{ if pkg == "policy" { "tools/policy" } else { "src/" + pkg } }} {{ collection }} -out:build/odin-test/focus.exe -define:ODIN_TEST_NAMES={{ pkg }}.{{ name }} {{ memory }} {{ vet }} > build\odin-test\focus.out 2>&1 && (type build\odin-test\focus.out & findstr /b /c:"No tests to run." build\odin-test\focus.out >nul && (echo TEST-ONE: "{{ pkg }}.{{ name }}" matched no test procedure -- 0 tests collected & exit /b 1) || exit /b 0) || (type build\odin-test\focus.out & exit /b 1)

# Proves `test-one`'s bogus-name guard both ways, by exit code (issue #175,
# the #160/#154 exit-semantics discipline): a bogus name must exit nonzero
# carrying the guard's own "TEST-ONE: " message, and a real, currently
# existing test name must exit 0 through that same recipe. `pkg` is fixed to
# `policy`, the one name CLAUDE.md's notes say `test-one` resolves
# identically everywhere, including CI's environment.
#
# The real name is never hardcoded into this recipe. CLAUDE.md warns that
# every `just test-one` example named in this repository's own docs is "a
# claim worth re-running, not a pinned fact" now that issue #152 retired the
# layer that used to pin one -- a hardcoded name here would be this exact
# ticket's defect, one level up. Instead the name is derived fresh, each run,
# from tools\policy\discover_test.odin: grepped for the `proc(t: ^testing.T)`
# signature `core:testing` requires of every `@(test)` procedure, taking the
# first match. That file carries no `#+build` tag (the #174 review deposit's
# hollow-file shape), so what this recipe finds is always a real, collectible
# test.
test-one-selftest:
	if not exist build\odin-test mkdir build\odin-test
	if exist build\odin-test\selftest-name.txt del /q build\odin-test\selftest-name.txt
	(for /f "tokens=1" %W in ('findstr /c:":: proc(t: ^testing.T)" tools\policy\discover_test.odin') do (> build\odin-test\selftest-name.txt echo %W & exit /b 0)) & if not exist build\odin-test\selftest-name.txt (echo TEST-ONE-SELFTEST: could not derive a real test name from tools\policy\discover_test.odin & exit /b 1)
	{{ just_executable() }} test-one policy test-one-selftest-bogus-name-does-not-exist-175 > build\odin-test\selftest-bogus.out 2>&1 & if not errorlevel 1 (echo TEST-ONE-SELFTEST: "policy.test-one-selftest-bogus-name-does-not-exist-175" exited 0 -- the bogus-name guard is disarmed & type build\odin-test\selftest-bogus.out & exit /b 1) & exit /b 0
	findstr /b /c:"TEST-ONE: " build\odin-test\selftest-bogus.out >nul || (echo TEST-ONE-SELFTEST: the bogus-name case failed but not with the guard's own message & type build\odin-test\selftest-bogus.out & exit /b 1)
	for /f "usebackq delims=" %N in ("build\odin-test\selftest-name.txt") do ({{ just_executable() }} test-one policy %N > build\odin-test\selftest-real.out 2>&1 & if errorlevel 1 (echo TEST-ONE-SELFTEST: the real name "%N", derived live from tools\policy\discover_test.odin, no longer resolves through test-one & type build\odin-test\selftest-real.out & exit /b 1))

# The #97-class detector (issue #104): src/child under ODIN_TEST_THREADS=1,
# the one setting that surfaces a defect the default 12-thread sweep cannot.
test-single:
	if not exist build\odin-test mkdir build\odin-test
	{{ odin }} test src/child {{ collection }} -out:build/odin-test/child-single.exe -define:ODIN_TEST_THREADS=1 {{ memory }} {{ vet }}

# Run the built CLI and assert its banner reaches STDOUT -- the check that
# caught a real stream-swap in the #119 review. Only stdout is captured, so a
# banner printed to stderr instead leaves the file empty and findstr fails.
# `build\` is supposed to hold only real build products (issue #165), so
# smoke.out is deleted on both exit paths. The CLI run and the findstr check
# are chained with `&&`, not `&`, so a nonzero exit from the CLI itself
# short-circuits straight to the failure branch instead of being swallowed
# by an unconditional `&` and overridden by findstr's later verdict
# (issue #231 fix round 1).
smoke: build
	(build\transcibr-cli.exe > build\smoke.out && findstr /b /r /c:"transcibr-cli [0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*" build\smoke.out >nul) && (del build\smoke.out & exit /b 0) || (del build\smoke.out & exit /b 1)

# The pinned toolchain, absorbed from scripts\install-pinned-tool.ps1: a
# tagged Odin release and the odinfmt build inside ols's release zip, both by
# curl.exe and tar.exe rather than a PowerShell web request. This INSTALLS
# the pinned release; it does not VERIFY what it downloaded -- no version or
# hash check runs (ADR-0035's "What did not move" section). Writes
# ODIN and ODINFMT to %GITHUB_ENV% when it is set, so every later step in the
# same job picks up the extracted paths without a second lookup.
install-tools:
	if not exist .tools mkdir .tools
	curl.exe -fsSL -o .tools/odin.zip "https://github.com/odin-lang/Odin/releases/download/{{ odin_release }}/odin-windows-amd64-{{ odin_release }}.zip"
	tar.exe -xf .tools/odin.zip -C .tools
	curl.exe -fsSL -o .tools/odinfmt.zip "https://github.com/DanielGavin/ols/releases/download/{{ odinfmt_release }}/ols-x86_64-pc-windows-msvc.zip"
	tar.exe -xf .tools/odinfmt.zip -C .tools
	for /f "delims=" %f in ('dir /s /b .tools\odin.exe') do @echo ODIN=%f & if defined GITHUB_ENV echo ODIN=%f>>"%GITHUB_ENV%"
	for /f "delims=" %f in ('dir /s /b .tools\odinfmt-*.exe') do @echo ODINFMT=%f & if defined GITHUB_ENV echo ODINFMT=%f>>"%GITHUB_ENV%"

# Everything CI runs, in the order a developer would want to know about a
# failure: formatting first, source policy second, then the debug build, the
# full test sweep, the single-threaded detector, the test-one selftest, the
# release build, and the smoke test last. `build` and `release` both write to
# the same `build/transcibr-cli.exe` path, and `smoke` is the only recipe
# that runs the CLI as the shipping artifact, so `release` runs immediately
# before it to put the `-o:speed` binary actually built and executed rather
# than left untested (issue #76 review round 2). `test` no longer shares that
# path or its ordering constraint: it builds its own debug binary for the
# crashlog crash-drill tests at `build/odin-test/transcibr-cli-drill.exe`, as
# its own first line (issue #76 review round 3), so `test` and `test-single`
# can run in any order relative to `build`/`release` without one leaving the
# other a binary it cannot use. `test-one-selftest` runs after both -- it
# invokes `test-one` itself, which only needs the toolchain and the source
# tree, so it carries no build-ordering constraint of its own (issue #175).
ci: fmt-check check build test test-single test-one-selftest release smoke
