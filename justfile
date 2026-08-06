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

# Rewrite every .odin file under src, tools and docs/reference as
# odinfmt.json says -- the same repository-wide scope `check` walks (minus
# the build/vendor directories tools/policy also excludes), so the one
# committed .odin file outside src and tools does not go unformatted
# (round 2 review finding 2).
fmt:
	{{ odinfmt }} -w -path:src -config:odinfmt.json
	{{ odinfmt }} -w -path:tools -config:odinfmt.json
	{{ odinfmt }} -w -path:docs/reference -config:odinfmt.json

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
	for /r docs\reference %f in (*.odin) do @({{ odinfmt }} -path:"%f" -config:odinfmt.json > build\fmt-check.tmp & fc /b "%f" build\fmt-check.tmp >nul || (echo NOT FORMATTED: %f & del /q build\fmt-check.tmp & exit /b 1))
	del /q build\fmt-check.tmp

# One explicit line per package: the 12 src/ packages that hold tests, plus
# tools/policy, which reads Odin and is tested in Odin (ADR-0028). `cli` is
# the one src/ package with none, by ADR-0009 -- an entry point thin enough
# to read, with no logic of its own worth testing.
test:
	if not exist build\odin-test mkdir build\odin-test
	{{ odin }} test src/artifact {{ collection }} -out:build/odin-test/artifact.exe {{ memory }} {{ vet }}
	{{ odin }} test src/audio {{ collection }} -out:build/odin-test/audio.exe {{ memory }} {{ vet }}
	{{ odin }} test src/child {{ collection }} -out:build/odin-test/child.exe {{ memory }} {{ vet }}
	{{ odin }} test src/crashlog {{ collection }} -out:build/odin-test/crashlog.exe {{ memory }} {{ vet }}
	{{ odin }} test src/doctor {{ collection }} -out:build/odin-test/doctor.exe {{ memory }} {{ vet }}
	{{ odin }} test src/engine {{ collection }} -out:build/odin-test/engine.exe {{ memory }} {{ vet }}
	{{ odin }} test src/pipeline {{ collection }} -out:build/odin-test/pipeline.exe {{ memory }} {{ vet }}
	{{ odin }} test src/planning {{ collection }} -out:build/odin-test/planning.exe {{ memory }} {{ vet }}
	{{ odin }} test src/process {{ collection }} -out:build/odin-test/process.exe {{ memory }} {{ vet }}
	{{ odin }} test src/testkit {{ collection }} -out:build/odin-test/testkit.exe {{ memory }} {{ vet }}
	{{ odin }} test src/transcript {{ collection }} -out:build/odin-test/transcript.exe {{ memory }} {{ vet }}
	{{ odin }} test src/version {{ collection }} -out:build/odin-test/version.exe {{ memory }} {{ vet }}
	{{ odin }} test tools/policy {{ collection }} -out:build/odin-test/policy.exe {{ memory }} {{ vet }}

# One test, focused: `just test-one version banner_names_the_program_and_its_version`.
# `policy` resolves to tools/policy; every other name resolves to src/<pkg>.
test-one pkg name:
	if not exist build\odin-test mkdir build\odin-test
	{{ odin }} test {{ if pkg == "policy" { "tools/policy" } else { "src/" + pkg } }} {{ collection }} -out:build/odin-test/focus.exe -define:ODIN_TEST_NAMES={{ pkg }}.{{ name }} {{ memory }} {{ vet }}

# The #97-class detector (issue #104): src/child under ODIN_TEST_THREADS=1,
# the one setting that surfaces a defect the default 12-thread sweep cannot.
test-single:
	if not exist build\odin-test mkdir build\odin-test
	{{ odin }} test src/child {{ collection }} -out:build/odin-test/child-single.exe -define:ODIN_TEST_THREADS=1 {{ memory }} {{ vet }}

# Run the built CLI and assert its banner reaches STDOUT -- the check that
# caught a real stream-swap in the #119 review. Only stdout is captured, so a
# banner printed to stderr instead leaves the file empty and findstr fails.
smoke: build
	build\transcibr-cli.exe > build\smoke.out
	findstr /b /r /c:"transcibr-cli [0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*" build\smoke.out >nul

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
# full test sweep, the single-threaded detector, the release build, and the
# smoke test last. `build` and `release` both write to the same
# `build/transcibr-cli.exe` path, and each of the two consumers below needs a
# specific one on disk when it runs: `test`'s crashlog crash-drill tests
# (`src/crashlog/crashlog_crash_test.odin`) need the `-debug` binary with a
# PDB present for `assertion_hook`'s stack symbolization (issue #76 review
# round 1), and `smoke` is the only recipe that runs the CLI as the shipping
# artifact, so it needs the `-o:speed` release binary actually built and
# executed rather than left untested (issue #76 review round 2). `build`
# before `test`, `release` before `smoke`, is the one ordering that gives
# both consumers the binary they need.
ci: fmt-check check build test test-single release smoke
