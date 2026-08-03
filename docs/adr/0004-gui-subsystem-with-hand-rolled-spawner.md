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

## Stopping one child means stopping a tree

This ADR first said stop was `TerminateProcess` → `WaitForSingleObject` → `CloseHandle`. That is not
enough, and the correction is measured rather than reasoned about.

**Win32 has no process tree** is the sentence this ADR already uses about the group, and it is just
as true one level down. A child that starts something of its own leaves a process `TerminateProcess`
cannot reach and no handle enumerates — so the child dies, its own child does not, and the file the
pair had open stays open.

**The measurement.** `cmd /c (waitfor /t 25 NAME) > file`, then `TerminateProcess` on cmd alone:

| observation | result |
|---|---|
| `cmd exited` | True |
| `conhost.exe` still running | True |
| `waitfor.exe` still running | True |
| file came free within 6 s | **False**, 2 runs of 2 |

That is the exact shape of the failure this matters for. ADR-0002 has transcibr move, delete or
re-run against the artifacts of a stopped Recording; against a file something still holds, that is a
sharing violation or a half-written file moved beside the Recording.

So **each child is started into a nested job object of its own**, inside the group, and stop
terminates that job rather than that process. Microsoft describes `TerminateJobObject` as
`TerminateProcess` applied to every member, so the rule above is extended rather than weakened —
what is still never used is `process_terminate`, the cooperative request that reports success
without stopping anything.

The wait is extended the same way. Waiting on the child's process object says nothing about what the
child started, and a job object **signals when its end-of-job time limit is exceeded and never when
its last process leaves** — so there is nothing to wait on and `ActiveProcesses` is polled instead.
Stop answers false when the bound runs out with anything still in the job, and false means something
may still be holding files: the caller is told rather than reassured.

The per-child job deliberately does **not** carry the kill-on-close limit the group carries. Closing
a `Child` gives handles back and ends nothing; what ends a child nobody stopped is the group, which
outlives every child in it.

The bound is a budget for the whole of stop rather than for each wait inside it. Given to both, a
thirty-second bound would mean a Stop press taking a minute to come back, with nothing to show for
the second half of it.

**What this cost to verify.** The file coming free is the consequence a caller cares about, and it
is not a reliable discriminator on its own: terminating `cmd.exe` tears down the console it owned,
and the grandchild on that console starts exiting too. Over 22 runs of a stop reduced to this ADR's
first rule, the file came free immediately in 1 — the case passed with two processes still running.
The job's own process count said 2 in every one of those 22 runs, the passing one included, so that
is what `src/child`'s case reads after stop returns.

## Consequences

More than four things must be hand-declared because `core:sys/windows` does not bind them. This ADR
first named `CreateJobObjectW`, `AssignProcessToJobObject`, `SetInformationJobObject` and
`SetThreadExecutionState`; the count is a floor rather than the list, and stopping a tree adds
`QueryInformationJobObject` and `TerminateJobObject` to it. `src/child/win32.odin` is the list.

- **Child stdout goes to `NUL`, never to a pipe.** The engine prints every cue to stdout during
  inference — measured at 14,468 bytes for 20 minutes of audio, against a default pipe buffer of a
  few KB — so an undrained stdout pipe wedges the child early in the first recording, with the GUI
  frozen and no error. Only stderr is piped, for progress.
- **A job object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`**, children spawned `CREATE_SUSPENDED`
  and assigned before resume. Win32 has no process tree; without this an orphaned engine holds 3+ GB
  of VRAM invisibly after any crash, and the next run puts two engines on one GPU — the exact state
  the one-GPU-worker invariant exists to prevent, and one its assertion cannot see across a process
  boundary.
- **Stop is `TerminateJobObject` → `WaitForSingleObject` → wait for the job to empty →
  `CloseHandle`.** Not `process_terminate`, which is a *cooperative* request the child may ignore
  and which reports success without stopping anything in a console binary — and not
  `TerminateProcess` on the child alone, which is what this ADR said first and which leaves the
  child's own children running. See *Stopping one child means stopping a tree*.
- **We own Windows argument quoting**, unit-tested in the pure core against adversarial paths.

The folder picker needs no COM work: `core:sys/windows` already ships the full `IFileOpenDialog`
surface. Use `FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST`, since `FOS_PICKFOLDERS`
alone admits non-filesystem shell items whose path cannot be resolved.
