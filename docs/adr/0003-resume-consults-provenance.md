# Resume consults recorded provenance, not file existence

Each completed recording gets a small sidecar written last and only on success, carrying the engine
version, model path and hash, beam size, merge profile, prompt, source size and mtime, and container
duration. `plan_jobs` classifies a recording as done only when the artifact exists *and* the
recorded settings match the current ones.

Presence-only resume looks simpler and is wrong. The model is user-selectable per batch: a user who
transcribes a batch on `large-v3-turbo`, judges the accuracy insufficient, selects `large-v3`
and re-runs gets **every recording skipped in under a second**, with every transcript on disk still the
turbo one and the UI reporting success. The same holds for switching merge profile.

Front matter inside the transcript is not a substitute. The re-render path cannot reproduce it: the
engine's JSON carries no engine version, no audio duration, and reports every large model as the
bare string `"large"` — so re-rendering would stamp the *currently installed* engine version onto
cues decoded by a different one. Wrong provenance is worse than absent provenance.

## Consequences

This is deliberately not the SQLite manifest rejected in the scope table — it is one small file per
recording, written by the same validate-then-move discipline as ADR-0002, and a missing or
unparseable sidecar simply means "unknown, re-do it". It is also what makes the cheap re-render path
honest: with the settings recorded, changing only the merge profile re-renders from the retained
JSON without touching the GPU.
