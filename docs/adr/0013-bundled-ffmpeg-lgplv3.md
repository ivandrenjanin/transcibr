# FFmpeg is bundled unmodified, under LGPL v3, from a pinned dated build

transcibr ships FFmpeg inside its installer: `ffmpeg.exe`, `ffprobe.exe` and the seven `libav*`
DLLs from BtbN's `win64-lgpl-shared` build, redistributed byte-for-byte, installed into
`%LOCALAPPDATA%\transcibr\third-party\ffmpeg\` — physically separate from transcibr's own program
files. `ffplay.exe` is omitted. About 128 MB.

It is bundled rather than downloaded because it is the one dependency needed before transcibr can do
anything at all, and because at 128 MB it is a fraction of the engine and model that are fetched
later. Audio-only use does not require any GPL component — and note the stronger fact: **there is no
GPL component in an lgpl build at all**, so even full video decoding would be licence-clean. Do not
lean on "we only decode audio" as the argument; it is true but it is not what carries it.

## The build must be pinned to a dated autobuild, never `latest`

BtbN's `latest` tag is republished daily and is mutable. Its filename records no FFmpeg commit, two
same-day downloads are not byte-identical, and a pinned hash would fail every day. Worse, without a
commit you cannot say what source corresponds to the binaries — which is the one obligation we do
take on.

Pin an **end-of-month** `autobuild-YYYY-MM-DD-HH-MM` tag, whose asset name carries the revision
(`ffmpeg-N-<rev>-g<commit>-win64-lgpl-shared.zip`). Month-end tags are retained for roughly two
years; mid-month tags are pruned within a fortnight. Verify the published `checksums.sha256` in the
release pipeline and fail the build on mismatch.

## This build is LGPL **v3**, not 2.1

FFmpeg's own code is LGPL-2.1-or-later, but BtbN's lgpl variant is configured `--enable-version3`
and unconditionally links gmp (LGPLv3), alongside Apache-2.0 dependencies that FFmpeg's own
`LICENSE.md` describes as incompatible with LGPL v2.1 but not with version 3. The `LICENSE.txt`
inside the zip is `COPYING.LGPLv3`.

**ffmpeg.org's suggested notice string names version 2.1 and is wrong for this build.** Every notice
must say version 3.

## What binds us, and what does not

**Not a Combined Work.** LGPLv3 §4's entire apparatus — prominent notices, object code for
relinking, relink recipes, Installation Information — applies to a work "produced by combining or
linking an Application with the Library". transcibr spawns `ffmpeg.exe` with a command line and reads
back a file; the FSF's test places command-line subprocess invocation on the separate-programs side.
So: no LGPL exception in transcibr's own LICENSE, no published object files, no relink recipe, and
Apache-2.0 is unaffected.

**We convey object code, so GPLv3 §4 and §6 apply.** Keep all notices intact, ship both licence
texts (LGPLv3 is meaningless standalone — it incorporates GPLv3 by reference), and make the
Corresponding Source available. §6(b) and §6(c) written-offer routes are tied to physical products;
we ship a download, so **§6(d) is the only available route** — equivalent access, same place, no
charge. A "contact me for sources" file is not compliance.

Each release therefore carries about 20 MB of source assets: FFmpeg at the pinned commit, and the
`FFmpeg-Builds` scripts archive — the latter matters because the DLLs statically absorb roughly
thirty libraries and each build script pins an exact version, which discharges the "scripts to
control those activities" half of the Corresponding Source definition in one file. Source must stay
available for as long as the release it belongs to remains downloadable.

## Consequences

- **No installer EULA click-through.** LGPL conditions everything on terms that do not restrict
  modification or reverse engineering for debugging; stock Windows EULA templates carry a
  no-reverse-engineering clause, which over a package containing FFmpeg is a direct conflict.
  Apache-2.0 plus third-party notices is sufficient and is the norm.
- **The Independent JPEG Group credit is a named, hard obligation** on executable-only distribution
  and lands on us rather than upstream. It appears in `THIRD-PARTY-NOTICES.md`.
- Do not strip, repack, re-sign, compress or rename the binaries. Keeping them byte-identical to a
  published SHA-256 makes "unmodified" checkable in ten seconds.
