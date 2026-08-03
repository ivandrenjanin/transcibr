# The engine and the models are fetched by explicit user action, not bundled

The whisper.cpp CUDA release (~1.15 GB unpacked) and the speech model (~1.5 GB) are downloaded after
installation, each behind a confirmation dialog that states exactly what is being fetched, from
where, how large it is, the SHA-256 it will be verified against, and under what licence. Nothing is
fetched at startup, in the background, or by default.

Bundling them would mean a ~2.7 GB installer, and would make transcibr a redistributor of both
MIT-licensed software and NVIDIA's proprietary CUDA runtime.

## What downloading avoids

Both licences attach their conditions to *copying and distributing*, not to causing someone else to
download. GitHub's and HuggingFace's servers make the copy, onto the user's disk; the bytes never
touch our infrastructure.

- **MIT** requires its notice "in all copies or substantial portions of the Software". We make no
  copy, so there is no copy for a notice to accompany.
- **The CUDA EULA's** distribution conditions bind a distributor exercising the distribution grant.
  The end user, not us, becomes NVIDIA's licensee — the agreement is self-executing on whoever
  downloads, installs and uses.
- The EULA's clause about not causing the SDK to become subject to an open source licence is **not**
  a hazard here; it targets copyleft reaching *into* the SDK, and the EULA separately and explicitly
  permits using the SDK to build applications released under OSI-approved licences. Apache-2.0
  qualifies. Download for durability and installer size, not out of fear of that clause.

## Disclose anyway

Nothing obliges us to display licence terms for software we do not distribute. We do it because
**the upstream engine archive contains no licence files whatsoever** — not MIT, not NVIDIA's — so we
are the only party positioned to put those terms in front of a user before they accept them by
downloading. Phrase it as disclosure, not as a EULA click-through administered on NVIDIA's behalf;
we are not a party to it. After extraction, write the relevant licence texts into a `LICENSES`
folder beside the binaries.

## Consequences

**Verification is fail-closed.** Expected byte size and SHA-256 are compiled-in constants, one
record per artifact, each hash computed locally before being committed rather than transcribed from
a web page. On mismatch: delete the file, name expected and actual, refuse to proceed. Never "use it
anyway". Do not read the expected hash from a response header — whoever can tamper with the body can
set the header.

**Upstream can move under us.** Every upstream release is mutable: assets can be deleted, or replaced
with different bytes under the same name. Empirically nothing has ever been pruned, but that is a
habit, not a guarantee. Three mitigations, in order of value:

1. **Accept a user-supplied path to an existing install** — engine, model, and ffmpeg. The day an
   asset disappears, users are inconvenienced rather than blocked. This is a settings field and a
   file-exists check, and without it one upstream deletion bricks every installed copy.
2. **An overridable download manifest** — URL, size, hash, display name — compiled in as a default
   but overridable from disk, so a URL change is fixable by publishing a corrected manifest rather
   than a new build.
3. **A periodic upstream canary** in CI, checking asset digests via API without transferring bytes.

Pin the model by repository revision rather than a moving branch. Mirroring is permitted if ever
needed — MIT for the engine, MIT for the weights — but **never mirror the NVIDIA runtime**: doing so
lands NVIDIA's distribution conditions on us, including one requiring the distributable portions to
be accessed only by our application, which is awkward precisely because they would be loaded by a
separate program.
