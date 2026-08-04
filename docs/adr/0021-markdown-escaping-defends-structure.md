# Markdown escaping defends structure and spends fidelity, measured against two renderers

A paragraph of transcribed speech is arbitrary text, and a Markdown reader treats several of its
characters as structure. The escaper that stops that is two short constants. `INLINE_SPECIALS` is
`` \ ` * _ [ ] < | `` and is applied to every byte of a paragraph; `BLOCK_STARTERS` is `#>-+=~` and
is applied only to the byte a reader sees first, together with one rule for a run of digits followed
by `.` or `)` — because "1999. That was the year" is an ordered list numbered from 1999 to every
Markdown reader there is, and the year itself leaves the page.

Three things a Markdown reader can read as structure are deliberately **not** on those lists: `&`,
`~~`, and the characters inside a bare URL. Each omission was measured, each costs something on the
page, and **none of the three corrupts the document's structure under either renderer tested**. What
they cost is fidelity on one line of one transcript. This ADR records the measurements because they
are the evidence a decision to fix any of the three would start from, and because the source
comments that carried them are being removed.

## What was measured, and against what

Every row below came out of the built binary and was then rendered by **commonmark.js 0.31.2** and
**marked 18.0.7** — the latter being GFM with its extensions on by default. Two renderers: one
strict, one carrying the extension set most viewers ship. Nothing here is a reading of a
specification. A claim about renderer behaviour that is not in the tables below was not measured.

The escaper's positive behaviour is pinned by the suite — `ORDINARY_PROSE`, `INLINE_ESCAPE_CASES`,
`BLOCK_START_CASES` and `FLATTENED_START_CASES` in `src/transcript/render_test.odin` assert the
exact bytes the renderer writes. **The three omissions are pinned by nothing**, because pinning them
needs a Markdown renderer and this repository has none. The closest thing is the row `"C# and F# are
languages, R&D is a department, and 3+4=7."` in `ORDINARY_PROSE`, which pins that the escaper leaves
that ampersand alone and says nothing whatever about what a renderer then does with it. Neither
golden fixture transcript contains an `&`, a `~~` or a `http`, so the fixture does not reach these
cases either.

## `&` is not escaped

An ampersand that opens a valid HTML5 entity name is resolved by every renderer there is, and the
speech carrying it changes on the page:

| speech | what the reader gets |
|---|---|
| `&copy; 2026` | `© 2026` |
| `spaced&nbsp;out` | a non-breaking space where the entity stood |
| `&lt;b&gt;` | `<b>` |
| `&amp;` | `&` |

An ampersand that opens something which is *not* a valid entity name is left as text by both.
`&notit;` is not an entity name, and neither renderer resolves it — measured, commonmark.js writes
`&amp;notit;` and marked writes `&notit;`. What divides the two renderers is the **route and not the
outcome**: commonmark.js resolves a valid entity itself and writes the character, while marked hands
the entity on for the browser to resolve. `&not;` is the row that shows it — `<p>¬</p>` from one and
`<p>&not;</p>` from the other, the same `¬` on the page either way.

Escaping `&` instead would put a backslash in front of the ampersand in every "R&D", "AT&T", "Q&A",
"H&M" and "Fish & chips" a transcript holds. Every one of those was measured too, and every one of
them reaches the reader verbatim today, because an ampersand is structure only where a valid entity
*name* follows it.

**What is measured here is what each spelling does on the page. What is assumed is how often each
spelling arrives.** The trade is taken because the harmful spelling is one a speech model does not
produce: `&copy;` is not a sound, it is punctuation somebody typed, and a transcript is transcribed
speech. No count was taken of either class in real engine output, and this ADR does not claim one.

## `~~` is not in the inline set

GFM reads a pair of tildes as strikethrough. "He said ~~never mind~~ and moved on." reaches a GFM
reader with the four tildes gone and the words between them struck through, while CommonMark writes
every byte of it verbatim. **No word is lost — only the tildes — and a tilde is not a sound.**

Escaping it would put a backslash in front of the `~` in every "~20 minutes" an engine ever wrote.
That is the same trade as `&`, on the same reasoning and with the same unmeasured half. A tilde that
*opens* a paragraph is escaped, because `~` is in `BLOCK_STARTERS`; what is left alone is a tilde
anywhere else in the line, which is where the measured example sits.

## A bare URL under GFM is the hard one

This is the only trade of the three where **the escaper's own backslashes reach the reader**. GFM
autolinks a bare `http://`, `https://` or `www.` run, and it consumes that run's raw text *before*
backslash escapes resolve inside it — so a backslash written to protect an underscore becomes a
character of the link:

| speech | what a GFM reader sees |
|---|---|
| `https://en.wikipedia.org/wiki/Foo_bar` | `https://en.wikipedia.org/wiki/Foo\_bar` |
| `https://github.com/some_org/some_repo` | `.../some\_org/some\_repo` |
| `www.example.com/a_b_c` | `www.example.com/a\_b\_c` |
| `http://x.example/a[1]` | `http://x.example/a\[1\]` |

The `href` is corrupted with it, carrying `%5C` where each backslash landed, so **the link goes
somewhere other than the place that was said**. CommonMark renders every one of those correctly,
which is why it took a second look to find.

The trigger is narrow and worth stating exactly: an **autolinked** bare URL carrying `_`, `*`, `[`
or `]`. Ordinary speech holding the same characters is verbatim under both renderers —
`with_underscores`, `first_last@example.com`, `my_report_final.docx` and
`C:\Users\bob_smith\notes.txt` were each measured, and each arrives exactly as it was said.

## Why the URL case is not fixed

Neither available fix is cheap, and one of them is a regression.

**Leaving URL runs unescaped trades this corruption for a worse one.**
`http://x.example/a*b*c` italicises under CommonMark the moment the backslashes come off. That moves
a fidelity loss which today lands only under GFM into the renderer the deliverable is currently
right under, which is the wrong direction.

**Doing it properly means implementing GFM's autolink boundary rules** — trailing punctuation,
balanced parentheses, where the run ends — inside an escaper whose whole virtue is being short
enough to check by eye. The escaper is two constants and three procedures precisely so that a
reviewer can hold all of it at once; a boundary-rule implementation is a second Markdown parser
living inside the renderer.

Assumed rather than measured: that engine output carries URL-shaped tokens often enough for this to
matter. The engine does emit them off technical talks, but no count was taken and neither golden
fixture holds one.

## Two smaller facts the code depends on

`\` is **first** in `INLINE_SPECIALS` because it has to be. Escaped last, every backslash written by
the escapes after it would be escaped again.

`>` is **not** in `INLINE_SPECIALS`. It opens a blockquote only at the start of a line, while the
closing half of a tag somebody read out is far commoner in speech than a line beginning with one, so
it is handled at the line start instead — where it can actually do harm. `<` is escaped inline, so
"Type <b>bold</b> to start." reaches the document as `Type \<b>bold\</b> to start.`, which is
enough: the tag cannot open.

## The accepted cost

**A transcript can reach a reader with a valid entity spelling resolved into a character, with a
pair of tildes gone and the words between them struck through, and with a link whose visible text
and whose `href` both differ from what was said.** Those are real defects in the deliverable, and
they are paid rather than fixed.

Two of the three are visible on the page — struck-through words and stray backslashes are the kind
of wrongness a reader notices and mistrusts. The corrupted `href` is the one that is not: a link
that looks right and goes somewhere else is a silent failure, and it is the sharpest edge of this
decision.

The cost is bounded by the retained engine JSON. ADR-0002 and ADR-0003 keep it beside the recording,
so a change to the escaper is a re-render of the batch and no GPU pass — a transcript produced under
today's escaper does not have to be re-transcribed to get tomorrow's.

What the escaper is protecting in exchange is worth naming, because it is not symmetric with any of
this. `---` opening a line is a thematic break, and `---` under prose is a setext heading that
swallows the line above — the shape a reader would mistake for a second front matter block, in a
document whose front matter is what ADR-0008 has planning read to decide whether an existing `.md`
is transcibr's own output or somebody's notes. Structure failures delete or re-label speech;
these three cost characters on one line. Rendering stays pure and fixture-covered (ADR-0009), but no
fixture covers a renderer, so this ADR is the only record of the three cases.

## What would reopen this

**`&` and `~~`:** engine output starting to carry entity spellings or tilde pairs — a subtitle track
read back through the engine, say. The tables above are what a fix would be measured against, and
the first thing a fix owes is the count neither of them has.

**The bare URL:** a transcript ever having to be right under GFM as well as under CommonMark. That
is the line, and it is a decision about which renderers the deliverable is promised to rather than a
bug report.

**All three together:** any renderer, or any later version of these two, under which one of the
omissions costs structure rather than fidelity. The claim carrying this whole decision is that
structure survives, and it is measured at exactly two renderers at two pinned versions.
