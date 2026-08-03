# transcibr

Local transcription tool. Converts video and audio files into text transcripts using Whisper.

> **Status: early implementation.** The specification is in `docs/spec/`. The build and test
> commands work (see [Building from source](#building-from-source)); `transcibr-cli` currently
> reports its version and nothing else. There are no releases yet.

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
called from exactly two places. `grep -r winhttp src/` is the whole audit, and CI fails the build if
the name appears anywhere else.

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

Two commands, and CI runs the same two on every push.

```powershell
.\scripts\build.ps1     # -> build\transcibr-cli.exe
.\scripts\test.ps1      # every package under src\
```

The Odin compiler is pinned to release `dev-2026-07a`. The scripts look for it in `$env:ODIN`, then
on `PATH`, then at `C:\Odin\dist\odin.exe`, so it does not need to be on `PATH`.

Both commands pass the full vet set with warnings as errors, and the test command additionally sets
`ODIN_TEST_FAIL_ON_BAD_MEMORY=true` — it defaults to false, which would let a procedure that leaks
its returned slice pass with a warning (ADR-0010).

**`odin test` collects test procedures from one package only**, and on a package with none it prints
`No tests to run.` and exits 0. `test.ps1` therefore discovers every package under `src\` rather than
naming one, counts the tests the runner reports finishing, and fails when that total is zero — a run
that executes nothing is a failure, not a pass. To run a single test, call the compiler directly:

```powershell
C:\Odin\dist\odin.exe test src\version -collection:transcibr=src `
    -vet -vet-tabs -strict-style -vet-style -warnings-as-errors -disallow-do `
    -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true `
    -define:ODIN_TEST_NAMES=version.banner_names_the_program_and_its_version
```

## License

transcibr is licensed under the [Apache License 2.0](LICENSE).

transcibr bundles unmodified binaries from the FFmpeg project (<https://ffmpeg.org>), used under the
GNU Lesser General Public License version 3. transcibr is not affiliated with, and does not own,
FFmpeg. Licence texts and corresponding source: see [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).
