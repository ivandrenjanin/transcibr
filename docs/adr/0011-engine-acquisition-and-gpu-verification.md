# The engine is a pinned prebuilt CUDA release, resolved as a directory, and verified to reach the GPU

We use the published Windows cuBLAS build of the engine rather than compiling from source: no cmake
dependency, no long first build, and a build failure cannot block the project before a single
transcript exists. The exact release tag and asset filename are pinned in the setup documentation —
the asset name encodes the CUDA version and changes between releases.

**Acquisition never happens during transcription.** The engine and model are fetched once, by
explicit user action, before any batch runs — see ADR-0014 for the distribution model and ADR-0015
for how the download is implemented. A running batch makes no network request of any kind.

## The engine is a directory, not an executable

The release unpacks to an executable plus roughly twenty DLLs, and the CUDA backend is one of them.
It is built with runtime backend discovery: `ggml-cuda.dll` is located at load time from the
executable's directory, the working directory, or an environment variable — and **a candidate that
fails to load is skipped, not reported.**

So the obvious deployment — copy `whisper-cli.exe` somewhere on `PATH` — produces an engine that
starts cleanly, prints nothing unusual, and transcribes on the CPU. Measured GPU throughput is about
17× realtime; the CPU path is more than an order of magnitude slower, turning a four-and-a-half hour
batch into days. Nothing about the output distinguishes it. The same silent degradation follows a
driver too old for the bundled CUDA runtime, or a GPU in a reset state.

The engine setting therefore resolves a **directory**, and `doctor` asserts that the CUDA DLL sits
beside the executable rather than merely that the executable exists.

## Consequences

`doctor` verifies by hash, not by presence, and actually spawns the engine rather than stat-ing it —
checking that a GPU exists proves nothing about whether the engine reached it.

Verification continues at runtime, because a healthy `doctor` result does not survive a driver
update: the first completed recording's `systeminfo` field is checked for CUDA, and a first-recording
realtime factor an order of magnitude below the measured baseline aborts the batch rather than
letting it run overnight on the wrong device.

The model is selectable per batch with the smaller, faster model as the default. Note that the engine
reports **every** large model as the bare string `"large"`, so a transcript's model identity comes
from our own record (ADR-0003) and never from the engine's output.
