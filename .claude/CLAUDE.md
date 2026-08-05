<!-- CODEGRAPH_START -->
## CodeGraph

In repositories indexed by CodeGraph (a `.codegraph/` directory exists at the repo root), reach for it BEFORE grep/find or reading files when you need to understand or locate code:

- **MCP tool** (when available): `codegraph_explore` answers most code questions in one call — the relevant symbols' verbatim source plus the call paths between them, including dynamic-dispatch hops grep can't follow. Name a file or symbol in the query to read its current line-numbered source. If it's listed but deferred, load it by name via tool search.
- **Shell** (always works): `codegraph explore "<symbol names or question>"` prints the same output.

If there is no `.codegraph/` directory, skip CodeGraph entirely — indexing is the user's decision.
<!-- CODEGRAPH_END -->

## CodeGraph does not index this repository yet

The block above is generated and says to reach for CodeGraph before grep. **Do not, here.** It degrades on
the *absence* of a `.codegraph/` directory, and this repository has one — so the advice reads as live when
it is not.

CodeGraph has no Odin support. Upstream PR
[colbymchenry/codegraph#1000](https://github.com/colbymchenry/codegraph/pull/1000) adds it and has not landed.
Measured here: `codegraph status` reports **1 file, 0 nodes, 0 edges, language `yaml`** — it indexes this
repository's YAML and none of its 80 `.odin` files.

Use grep and the compiler. When that PR lands and an index over `src/` actually exists, delete this section.
