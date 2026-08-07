# All network access is hand-declared WinHTTP, confined to a single file

Downloads go through `src/net/winhttp.odin`, which hand-declares the WinHTTP entry points it needs
and is **the only file in the codebase that touches the network**. It is called from exactly two
places, both behind a confirmation dialog (ADR-0014).

Odin offers nothing usable here, verified against the pinned compiler: there is no `core:http`,
`core:net` is Berkeley sockets with no TLS anywhere, and `core:sys/windows` binds no WinHTTP at all —
the only occurrences of the name in the package are error-code comments. So the entry points are
declared by hand, exactly as ADR-0004 already does for the process spawner and job object.

**`vendor:curl` exists, works, and is rejected.** Using it would link a C library into transcibr —
precisely the FFI relationship the architecture avoids for both ffmpeg and the engine — and would
add a TLS backend decision, CVE tracking, and a redistribution obligation. WinHTTP is present on
every Windows machine and uses the system TLS stack, so transcibr ships no crypto library, no CA
bundle, and no OpenSSL DLLs. `core:crypto` provides streaming SHA-256; never load a 1.5 GB file into
memory to hash it.

**In-process, not a separate helper.** A second executable is a second thing to sign, a second thing
for antivirus to score, and turns progress and cancellation into an IPC protocol instead of a byte
counter and a flag. The WinHTTP path is a few hundred lines and a working prototype already
type-checks under the project's full vet set — there is no complexity being avoided by splitting it
out. Issue #14 absorbed that prototype directly into `src/net/winhttp.odin`; the reference file
itself is gone (closes #55).

## Consequences

**Never persist a redirected URL for resume.** Both upstreams redirect cross-host to presigned CDN
URLs that expire in roughly an hour. A user who pauses a 1.5 GB download overnight and resumes from a
stored CDN URL gets a 403. Persist only the canonical URL, bytes received, and expected hash;
re-request the canonical URL on resume and let WinHTTP mint a fresh redirect. Treat a mid-transfer
403 as "signature expired, re-resolve", not as permanent failure. This is the single most likely bug
in the whole downloader.

**Assert the resume actually resumed.** Send `Range: bytes=<size>-` and require a 206 response. A
server that ignores the range and returns 200 will otherwise have its full body appended to the
existing partial file, silently producing a corrupt artifact that only the hash check catches.

**Leave redirect policy at its default** — it follows cross-host redirects while refusing
HTTPS-to-HTTP downgrade, and the `Range` header set before sending survives the redirect. Manual
redirect chasing is dead code.

**A 401 is never a credential prompt.** The upstream repositories are public and no token is ever
required or shipped; a 401 means the repository is unavailable, and the UI must say so rather than
asking the user to log in.

**The single-file rule is the point.** It makes the README's network guarantee auditable by
`grep -ri --include=*.odin -r winhttp src/` rather than by trusting a promise. `Assert-OdinNetworkConfinement` in
`scripts\common.ps1` is that CI check, landed in issue #58: it fails `build.ps1` if the name `winhttp`
appears, in any case, anywhere under `src\` outside `src/net/winhttp.odin` itself — the one **file**,
not merely a directory that happens to hold only it today — so a second file added beside it that
also spells the name still fails the build.

**What it does not catch: a second file that touches the network without spelling the name.** The
gate matches a literal substring, not a call graph. Reproduced directly (issue #58, round 2 of
review): with `src/net/winhttp.odin` wrapping `WinHttpOpen` in an exported `open`, a second file
`src/net/download.odin` holding nothing but `fetch :: proc() { _ = open() }` — calling the wrapper,
never spelling `winhttp` itself — passes `build.ps1` clean. Once `src/net` is a package, a sibling
calls in unqualified and an importer writes `import "transcibr:net"`; neither spells the name either.
The gate confines where the literal name may appear, not where a call into the wrapper may originate.

## Addendum (2026-08-06, #152)

`Assert-OdinNetworkConfinement` moved mechanism-intact into `tools\policy\check.odin`'s
`collect_network_violations` (`NETWORK_CODE_FILE = src/net/winhttp.odin`), failing `just check` on
the same literal-substring match issue #58 landed — reading Odin source with the compiler's parser
elsewhere in `tools\policy` (ADR-0028) changes nothing about this one check, which still answers a
substring and needs no grammar. The wrapper-calling residual recorded above — a second file that
calls into `open` without spelling `winhttp` itself passes the gate — applies unchanged to the new
gate; nothing about the #152 migration narrows or widens what this check can see.
