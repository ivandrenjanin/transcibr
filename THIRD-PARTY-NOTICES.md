# Third-party notices

transcibr is licensed under the [Apache License 2.0](LICENSE). It bundles one third-party component
and relies on others that it does not distribute.

---

## Bundled: FFmpeg

transcibr bundles unmodified binaries from the FFmpeg project (<https://ffmpeg.org>), used under the
**GNU Lesser General Public License version 3**. transcibr is not affiliated with, and does not own,
FFmpeg.

The binaries are the `win64-lgpl-shared` build published by
[BtbN/FFmpeg-Builds](https://github.com/BtbN/FFmpeg-Builds), redistributed byte-for-byte. `ffplay.exe`
is omitted. No file has been modified.

Licence texts ship alongside the binaries in `third-party/ffmpeg/`:

- `LICENSE.txt` — GNU Lesser General Public License version 3, as published in the upstream archive
- `COPYING.GPLv3` — GNU General Public License version 3, which the LGPL v3 incorporates by reference

Build provenance and the corresponding source location are recorded in
`third-party/ffmpeg/README-FFMPEG.md`. **Corresponding source is attached to every transcibr release**
that contains these binaries, as `ffmpeg-source-<commit>.tar.gz` (FFmpeg at the exact commit built)
and `ffmpeg-builds-<sha>.tar.gz` (the build scripts, dependency list and version pins).

The bundled FFmpeg binaries statically incorporate additional third-party libraries. Their
identities, exact versions and upstream sources are recorded in `variants/` and `scripts.d/` of the
accompanying `FFmpeg-Builds` source archive, and their licence texts accompany those sources.

This software includes code from the Independent JPEG Group's software (via FFmpeg's libavcodec:
`jfdctfst.c`, `jfdctint_template.c`, `jrevdct.c`). These files are unmodified.

---

## Not distributed: fetched by the user after installation

transcibr distributes no part of the following. They are downloaded from their upstream publishers,
onto your machine, only when you explicitly choose to download them. The copy is made by the
upstream servers; it does not pass through the transcibr project.

| Component | Licence | Upstream |
| --- | --- | --- |
| whisper.cpp | MIT — © The ggml authors | <https://github.com/ggml-org/whisper.cpp> |
| Whisper model weights | MIT — © 2022 OpenAI | <https://github.com/openai/whisper> |
| NVIDIA CUDA runtime libraries | NVIDIA CUDA Toolkit EULA | <https://docs.nvidia.com/cuda/> |
| SDL2 (inside the engine archive) | zlib licence — © 1997–2023 Sam Lantinga | <https://www.libsdl.org/> |

The NVIDIA CUDA runtime libraries are **proprietary software**. They arrive inside the whisper.cpp
release archive, and by downloading them you accept the NVIDIA CUDA Toolkit EULA directly with
NVIDIA. transcibr is not a party to that agreement.

The upstream engine archive ships no licence files of its own. transcibr shows the applicable
licences before any download begins and writes copies into a `LICENSES` folder beside the extracted
files, so the terms are available on disk afterwards.
