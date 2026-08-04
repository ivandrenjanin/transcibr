// Package artifact owns everything transcibr leaves on a disk for a person to
// find: it validates what the Engine produced before trusting a byte of it,
// moves every artifact into place atomically, and writes the Sidecar last.
//
// THE SPEC'S SHELL MODULE *artifact storage*, one package for one module, which
// is ADR-0017 applied rather than narrowed -- and named for its subject the way
// `transcibr:engine` is named for the invocation rather than for the Engine.
//
// IT IS ADR-0002 MADE INTO CODE, and that decision is the whole specification
// for this package. Four measured facts about the Engine drive every line of it:
// it writes its output with a truncating stream under a name it chooses, so a
// Stop press or a full disk leaves a truncated file under its FINAL name; resume
// branching on that file's existence classifies the truncation as finished work
// and never retries the GPU time; argv reaches it in the system ANSI code page,
// so a path carrying a byte outside ASCII fails to open with no output at all;
// and its exit code is zero even when it read no audio. So nothing the Engine
// writes is a completed artifact in place, and this package is what makes one.
//
// Impure, and honestly so: it reads what the Engine left, writes bytes, renames
// files and hashes a Model off the disk. Every DECISION it needs is pure and has
// a suite -- what an artifact is called (naming.odin), what a Sidecar says and
// when a Sidecar has gone stale (sidecar.odin) -- because ADR-0009 says a layer
// with a filesystem inside it cannot be checked, and ADR-0018 records that a
// decision turning up in the impure file belongs in one of the pure ones.
//
// Nothing outside this program may crash it (A8). The Engine's output, the
// Recording's own path, a Sidecar read back off a disk, a Model file and every
// answer the filesystem gives are all from outside, so each is refused through a
// return value and reported against the Recording that caused it. The Batch
// carries on (ADR-0002).
package artifact
