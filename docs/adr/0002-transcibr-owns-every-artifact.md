# transcibr owns every artifact; the engine writes only into a scratch cache

The engine is directed at an ASCII-only cache directory with `-of <cache>\<job_id>`. transcibr then
validates the JSON it produced — parses, cue count greater than zero, monotonic offsets — and only
then moves it beside the recording. Nothing the engine writes is ever treated as a completed
artifact in place.

The obvious design is to let the engine write `<recording>.json` next to the source and treat that
file's existence as "transcription done". It cannot work, for four independent reasons, all verified:

1. **Not atomic.** The engine opens its output with a truncating stream and appends `.json` to
   whatever prefix it is given, so it cannot even be pointed at a `.part` name. A Stop press, a
   crash, or a full disk leaves a truncated file under its final name.
2. **Permanently poisoned.** Resume branching on existence classifies that truncated file as
   "transcribed, needs rendering", fails to parse, and takes the identical branch on every
   subsequent run. The GPU work is never retried and recovery needs the user to delete a file the UI
   never mentions — the headline promise failing in exactly the case resume exists for.
3. **Non-ASCII paths are mangled.** `whisper-cli` is `int main(int argc, char**argv)` under MSVC, so
   argv arrives in the system ANSI code page. A filename containing non-ASCII characters, or merely
   a non-ASCII Windows
   account name inside `%LOCALAPPDATA%`, fails to open and no output appears. ffmpeg does *not* have
   this bug — it re-reads `GetCommandLineW()` — so testing the extraction step looks clean while
   only the transcription step fails.
4. **Exit code 0 means nothing.** A failed audio read is a `continue` that falls through to
   `return 0`, so a truncated WAV yields success, one stderr line, and no output file.

## Consequences

A validated JSON that fails to parse is treated as *absent*: quarantine it to `.json.bad` and re-run
the full pipeline, rather than reporting a permanent failure. "Exit 0 but no or empty output" is a
hard per-recording failure. Never pass more than one input file per invocation. `doctor` fails
loudly when the resolved cache or model path contains a non-ASCII byte — the ASCII property must be
chosen, not sanitised, since 8.3 short-name generation can be disabled per volume.
