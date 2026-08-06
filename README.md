# transcibr

Local transcription tool. Converts video and audio files into text transcripts using Whisper.

> **Status: early implementation.** The specification is in `docs/spec/`. The build and test
> commands work (see [Building from source](#building-from-source)); `transcibr-cli` already
> dispatches `--help`, `--plan`, `--from-json` and `--transcribe` -- a full GPU run over one
> Recording, end to end (`src/cli/main.odin`). There are no releases yet.

## What it does

transcibr turns video and audio files into readable Markdown transcripts, entirely on the local
machine. It is a batch tool: point it at a directory of recordings, get a directory of transcripts,
resumable if interrupted.

**Transcription is offline by definition** — no cloud transcription, no API keys, no account, and no
LLM post-processing stage. Once the engine and a model are on disk, a running batch makes no network
request of any kind; your audio and video never leave your machine. (The two downloads that put them
there are described under [Network access](#network-access), and you start both by hand.) The
transcript is the deliverable, not an input to something else. That constraint is load-bearing: with
nothing downstream to clean up after a bad transcript, quality settings are maxed and correctness
lives in this program.

Transcription itself is delegated to `whisper.cpp` (MIT, GGML `large-v3-turbo`, fp16) and audio
extraction to `ffmpeg`, both driven as **subprocesses** rather than through FFI bindings. The value
transcibr adds over calling those CLIs by hand is the part around them: merging three-second
subtitle fragments into prose paragraphs, stripping Whisper's repetition hallucinations, rendering
coarse timestamp anchors, deciding worker counts from the hardware, and resuming a half-finished
batch.

## Architecture

**A pure core, a thin impure shell.** Every decision that can be a pure function over in-memory
data belongs in the core: cue parsing, paragraph merging, hallucination stripping, Markdown
rendering, and the hardware→settings decision. Everything that touches ffmpeg, the GPU, the
filesystem, or Win32 stays in a shell kept as thin as it can be.

This is not a style preference. The core is where the program's actual value lives *and* the only
part that can be tested properly — you cannot unit-test a speech model. Work is therefore
**test-first**: the core gets real red-green cycles against `core:testing`, the shell gets
integration tests and a committed golden fixture (one real engine JSON output plus its expected
Markdown, re-rendered via a `--from-json` flag so output can be tuned at zero GPU cost).

Two invariants the design turns on, both enforced by assertion and test rather than convention:

- **Exactly one GPU worker.** One GPU is a serial resource; concurrent transcriptions contend for
  the same SMs and VRAM, delivering the same work later with a higher chance of OOM. CPU extraction
  workers run ahead of it through a **bounded** queue (depth 1–2) — unbounded, extraction fills the
  disk at ~115 MB per hour of audio.
- **transcibr owns every artifact.** The engine writes only into a scratch cache; its output is
  validated before being moved into place, and every artifact lands by atomic rename. A record of
  how each transcript was produced is written last and only on success, so changing the model or the
  merge profile re-runs the work instead of silently skipping it. Together these make crash recovery
  a non-feature.

## Scope boundaries

Deliberately excluded:

| Excluded | Reason |
| --- | --- |
| Update checks, telemetry, analytics, crash reporting, licence checks | transcibr has no server and phones home for nothing. The only network requests it makes are the two downloads you start by hand — see [Network access](#network-access). |
| whisper.cpp FFI bindings | Days of work versus one for subprocess, with no throughput gain at batch 1 |
| Greedy decoding (`-bs 1`) | `-bs` is beam size, not batch size, and the engine has no batch-size flag at all. Dropping to greedy sampling makes repetition loops measurably more frequent — the exact defect the hallucination stripper exists to clean up. Beam search stays at the default. |
| Diarization, forced alignment | Python-only tooling, and a large scope addition. Speaker labels are not part of the deliverable; multi-speaker material is handled temporally instead, via merge profiles. |
| SQLite manifest, content-addressed cache | One process, one operator — a small per-recording record plus atomic rename gives the same guarantee |
| Quantized models | VRAM is not scarce on the target machine; quantization only costs accuracy |

## Network access

transcibr makes exactly two kinds of network request, and you start both by hand:

1. Fetching the GPU transcription engine, when you choose to download it.
2. Fetching a speech model, when you choose to download it.

That is the complete list. Before either download starts, transcibr shows the exact URL, the exact
byte size, the SHA-256 it will verify against, and the licence — and waits for you to confirm.
Nothing is fetched by default, at startup, or in the background. If verification fails the file is
deleted rather than used.

**Transcription never touches the network.** Unplug the cable and every transcription still works,
identically.

This is structural, not a promise: all network code lives in one file, `src/net/winhttp.odin`,
called from exactly two places. `grep -ri --include=*.odin -r winhttp src/` is the whole audit —
case-insensitive, because a case-sensitive grep refuses the spelling nobody writes and admits
`WinHttpOpen`, the Win32 headers' own capitalisation — and it is not merely run by hand:
`collect_network_violations` in `tools\policy\check.odin` fails `just check`, and so `just ci` --
the moment the name appears, in any case, in any `.odin` file anywhere under `src\` outside that
one.

## Requirements and installation

Windows 11 with an NVIDIA GPU. The installer includes everything needed to start; the two large
components are fetched afterwards, on your say-so.

| Component | How it arrives | Size |
| --- | --- | --- |
| transcibr | in the installer | small |
| FFmpeg (LGPL v3, unmodified — see [notices](THIRD-PARTY-NOTICES.md)) | in the installer | ~128 MB |
| whisper.cpp GPU engine | you download it after installing | ~650 MB, ~1.15 GB on disk |
| Speech model | you download it after installing | ~1.5 GB |

Already have the engine, a model, or FFmpeg elsewhere on disk? Point transcibr at them in Settings
and skip the downloads entirely.

Building from source additionally needs the Odin compiler and the MSVC toolset, which Odin links
through on Windows.

## Building from source

A [`justfile`](justfile) (casey/just) at the repository root, run by hand or by CI -- `just ci` is
exactly what the workflow runs, so nothing there does anything a developer's own machine cannot do
too. `just install-tools` fetches the two pinned tools a developer's own machine usually already has.

```text
just build         # -> build\transcibr-cli.exe, debug
just release        # -> build\transcibr-cli.exe, -o:speed
just check          # tools\policy: CLAUDE.md's source policies and the package-accounting check
just test           # every package under src\ and tools\policy
just fmt            # every .odin file under src, tools and docs/reference against odinfmt.json, rewritten in place
just ci             # fmt-check, check, build, release, test, test-single, smoke
```

`check` builds and runs `tools\policy`, a small Odin program that reads the repository's own source
with `core:odin/parser` and answers every source rule `just ci` enforces — the line limit, the
comment ban, `@(require_results)`, the `#+vet` tags, the `os.remove_all` ban, network confinement
(see [Network access](#network-access)), and the package-accounting check over both package roots,
`src\` and `tools\`: every package under either root holding tests is named in the `justfile`'s own
`test` recipe, and every package under either root holding none at all is a violation (`src\cli` is
the one exemption, by ADR-0009; `tools\` has no exemption roster at all). It is not part of
transcibr and ships with nothing; ADR-0028 records why the build reads Odin with the compiler's
parser rather than with a text scan of its own, and ADR-0035 records the move off PowerShell onto
`just`.

The command-line binary re-renders a transcript from retained engine output, without touching the
GPU — which is what makes tuning the paragraphing cost seconds instead of hours:

```powershell
.\build\transcibr-cli.exe                          # report the version and exit
.\build\transcibr-cli.exe --from-json out.json --profile conversation `
    --source talk.mp4 --engine "whisper.cpp 1.9.1" --model ggml-large-v3-turbo.bin
```

The transcript goes to standard output. `--source`, `--engine` and `--model` are what its front
matter records about how it was made; the engine's own output cannot settle them — it carries no
engine version and reports every large model as `large` (ADR-0003) — so anything not given is
recorded as `unknown` rather than guessed at. The detected language *is* read out of that output,
because it is the one such fact the engine does report (ADR-0001).

The Odin compiler is pinned to release `dev-2026-07a`. The pin lives in the `justfile` and nowhere
else — `just install-tools` downloads exactly that tag rather than keeping a second copy that can
drift. Every recipe looks for the compiler at `$env:ODIN`, falling back to `C:\Odin\dist\odin.exe`,
so it does not need to be on `PATH`.

The formatter is pinned the same way and resolved the same way — `$env:ODINFMT`, falling back to
`C:\Odin\dist\odinfmt.exe`. It is **not** part of the Odin distribution: `odinfmt` ships in
`ols-x86_64-pc-windows-msvc.zip` on the [ols](https://github.com/DanielGavin/ols) releases, pinned
here to `dev-2026-06`.

Unlike the PowerShell layer issue #152 retired, the `justfile` itself does not verify which build of
either tool it finds — it runs whatever `$env:ODIN` / `$env:ODINFMT` (or the `C:\Odin\dist\` fallback)
resolves to, pinned or not. `just install-tools` is what guarantees the pinned build: run it, or
point the two environment variables at binaries you have pinned by hand, before trusting a local
`just ci` the way CI's own run can be trusted.

The style itself is `odinfmt.json` at the repository root, which is the name odinfmt looks for on
its own — an editor formatting on save and the build cannot disagree about it. A misformatted file
fails `just fmt-check`, not merely a check somebody remembers to run. `fmt` and `fmt-check` each
spell the same three directories — `src`, `tools`, `docs\reference` — but only `fmt-check` iterates
them file by file: `fmt` hands each directory whole to `odinfmt -w`, while `fmt-check` walks each
directory with a `for /r` loop per file, running odinfmt per file without `-w`, comparing its
output against the file on disk byte for byte, and never consulting `git` -- the per-file loop is
what a byte compare needs. It is line-ending-sensitive on purpose:
`core.autocrlf` is on, a Windows checkout holds CRLF, and `newline_style` is pinned to match rather
than left to odinfmt's own default, which is CRLF on Windows and LF everywhere else.

Every build and test recipe passes the full vet set with warnings as errors, and the test recipes
additionally set `ODIN_TEST_FAIL_ON_BAD_MEMORY=true` — it defaults to false, which would let a
procedure that leaks its returned slice pass with a warning (ADR-0010).

Check the repository out under a path containing no space. `odin test` runs its test binary
through a command line it does not quote, so a space is re-parsed as an argument separator and the
compiler exits `-1` with `Unknown argument encountered '<second word>'` — a checkout under
`C:\Users\John Smith\...` fails before a single test runs (ADR-0035's second accepted risk).

**`odin test` collects test procedures from one package only**, and on a package with none it prints
`No tests to run.` and exits 0. `just test` therefore spells one explicit line per package that holds
tests under `src\` and `tools\policy`, rather than naming one and hoping; `tools\policy`'s own
package-accounting check fails `just check` the moment a tested package under either root loses its
line from that list, or a package under either root loses its last test file. To run a single test:

```text
just test-one version banner_names_the_program_and_its_version
```

## License

transcibr is licensed under the [Apache License 2.0](LICENSE).

transcibr bundles unmodified binaries from the FFmpeg project (<https://ffmpeg.org>), used under the
GNU Lesser General Public License version 3. transcibr is not affiliated with, and does not own,
FFmpeg. Licence texts and corresponding source: see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
