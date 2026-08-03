# GUI-subsystem binary, with a hand-rolled process spawner shared by both binaries

transcibr ships as a GUI-subsystem `transcibr.exe` plus a console-subsystem `transcibr-cli.exe`.
Both spawn children through **one** hand-rolled `CreateProcessW` wrapper in the shared shell, not
through `core:os`.

`core:os` cannot do this job: `Process_Desc` has exactly `working_dir`, `command`, `env`, `stderr`,
`stdout`, `stdin` — no creation-flags field — and the spawn path hard-codes the flag word, so
`CREATE_NO_WINDOW` cannot be passed. Without it a GUI-subsystem parent pops a console window per
child: once per ffmpeg and once per engine invocation, for every recording in the batch.

The spawner is shared rather than GUI-only on purpose. A console binary has no console-window
problem and every incentive to let children inherit its console — but if the two binaries take
different subprocess paths, every integration test and every `--dry-run` certifies code the shipped
GUI never executes, and subprocess bugs can only ever appear in production. `CREATE_NO_WINDOW` and
`SW_HIDE` are harmless in a console build.

## Consequences

Four things must be hand-declared because `core:sys/windows` does not bind them: `CreateJobObjectW`,
`AssignProcessToJobObject`, `SetInformationJobObject`, and `SetThreadExecutionState`.

- **Child stdout goes to `NUL`, never to a pipe.** The engine prints every cue to stdout during
  inference — measured at 14,468 bytes for 20 minutes of audio, against a default pipe buffer of a
  few KB — so an undrained stdout pipe wedges the child early in the first recording, with the GUI
  frozen and no error. Only stderr is piped, for progress.
- **A job object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`**, children spawned `CREATE_SUSPENDED`
  and assigned before resume. Win32 has no process tree; without this an orphaned engine holds 3+ GB
  of VRAM invisibly after any crash, and the next run puts two engines on one GPU — the exact state
  the one-GPU-worker invariant exists to prevent, and one its assertion cannot see across a process
  boundary.
- **Stop is `TerminateProcess` → `WaitForSingleObject` → `CloseHandle`.** Not `process_terminate`,
  which is a *cooperative* request the child may ignore and which reports success without stopping
  anything in a console binary.
- **We own Windows argument quoting**, unit-tested in the pure core against adversarial paths.

The folder picker needs no COM work: `core:sys/windows` already ships the full `IFileOpenDialog`
surface. Use `FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST`, since `FOS_PICKFOLDERS`
alone admits non-filesystem shell items whose path cannot be resolved.
