# Progress is parsed from the engine's stderr, with a time-based fallback

A batch runs for hours, so the UI needs a real percentage per recording. It comes from parsing the
engine's progress output on stderr, degrading to an estimate derived from audio duration and a
measured realtime factor when no progress lines appear.

The format, verified against the binary: lines of the exact shape

```
whisper_print_progress_callback: progress =   6%
```

on **stderr**, in hardcoded 5% steps, so any recording produces exactly twenty of them. The engine's
"no prints" flag does not suppress them.

This is a deliberate coupling to another program's human-readable output, which is not a contract and
can change between releases without warning. That is why the fallback exists: a format change
degrades the progress bar instead of breaking the run.

## Consequences

**The fallback triggers on elapsed time since the last progress line, never on the absence of
lines.** The engine is silent during model load, so "no progress yet" is normal for the first minute
and is not a stall.

**Never animate the fallback over a process that has stopped producing bytes.** A confidently
advancing estimate over a dead child is worse than a frozen bar, because it hides the failure — see
the stdout deadlock in ADR-0004, where exactly this combination turns a hang into an apparently
healthy run. A per-job watchdog treats no bytes on either stream for N minutes as an operating error.

**Audio duration comes from the engine's own startup banner**, which reports sample count and
seconds for the file it is about to process, or from the container probe (ADR-0009) — not from the
scratch WAV's size. The WAV header is not a fixed 44 bytes: ffmpeg's muxer writes a `LIST`/`INFO`
chunk before the data chunk, unconditionally and even when the source carries no metadata, so both a
fixed-offset parse and a `(size − 44) / byte_rate` duration are wrong by a per-file amount. Walk the
RIFF chunks or do not read the header at all.
