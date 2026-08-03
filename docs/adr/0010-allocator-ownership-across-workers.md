# Nothing crossing a thread boundary comes from `context.temp_allocator`

Every value handed from one worker to another — paths, command lines, job records, parsed cues —
is allocated from an explicitly-passed allocator. Each recording owns an arena, created when its job
starts and destroyed by whichever stage finishes it. `context.temp_allocator` is used only for
values that die inside the procedure that created them.

`context.temp_allocator` is **thread-local**, and each thread gets its own arena. Worse, the string
helpers in `core:sys/windows` — `utf8_to_wstring`, `utf8_to_utf16`, `wstring_to_utf8`,
`utf16_to_utf8` — all *default* their allocator parameter to it. So the natural way to convert a path
for a Win32 call produces memory owned by the calling worker's arena.

The failure this prevents: an extract worker builds a path with the default allocator and sends the
job down the channel; that worker loops and calls `free_all`; the GPU worker on the other side still
holds the pointer. Best case an unintelligible failure. Worst case the freed bytes are reused by the
next iteration's path, and **one recording's transcript is written from another recording's audio**,
atomically renamed into place, and made permanent by the completion record.

Neither the assertions nor the golden fixture can catch this. The assertions all pass — the data is
well-formed, merely the wrong recording's. The fixture tests the pure core, which never crosses a
thread. It is exactly the class of defect the safety discipline is meant to prevent and cannot.

## Consequences

The allocator contract is stated before any shell code is written, not retrofitted. Every
string-conversion call site passes its allocator explicitly, including the `core:sys/windows` helpers
whose defaults make omission the path of least resistance — so review treats a defaulted allocator on
anything that outlives its procedure as a defect, like any other style rule.

Set `-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true` when running tests. `ODIN_TEST_TRACK_MEMORY` defaults
true but `FAIL_ON_BAD_MEMORY` defaults false, so a core procedure that leaks its returned slice is
reported and still passes.
