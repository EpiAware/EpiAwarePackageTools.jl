## Unreleased

**New**: every benchmark page now lives under its own `docs/src/benchmarks/`
folder with a top-level "Benchmarks" nav group — a sibling of "Getting
started"/"API reference"/"Extensions", never nested inside Tutorials
(#299/#305, the shape EpiAwareADTools#28 asked for: "Benchmarks:
Performance over time, AD comparison").

The AD backend-comparison benchmark moves off the `ad-backends` tutorial
page onto its own `ad-comparison` page under `docs/src/benchmarks/`
(`ad = true`).
The benchmark table and plots read as a cost report, not a how-to guide, so
EpiAwareADTools#28 asked for the split; `ad-backends` stays under Tutorials,
keeps the backend-support table, Enzyme configuration, and debugging
sections, and now cross-links to `ad-comparison` for the numbers instead of
carrying them.
The performance-history page (`benchmarks = true`) moves from
`docs/src/benchmarks.md` to `docs/src/benchmarks/over-time.md`, labelled
"Performance over time" in the nav.
`docs/src/benchmarks/` has its own Literate pipeline
(`HEAVY_BENCHMARKS`/`BENCHMARK_STUBS` in `docs_config.jl`, mirroring
`HEAVY_TUTORIALS`/`TUTORIAL_STUBS`), so the AD-comparison report renders
independently of the Tutorials directory.

`docs/pages.jl` and `docs/docs_config.jl` are both package-owned and
write-once, so `update` cannot make either change to an adopter's files
automatically.
An existing adopter needs edits after their first sync on this kit version.
An `ad = true` adopter's `docs/docs_config.jl`: add `"ad-comparison.jl"` to
a new `HEAVY_BENCHMARKS` const, and `"ad-comparison.md" => "# [AD backend
comparison](@id ad-comparison)"` to a new `BENCHMARK_STUBS` const (both
default to empty when absent, so a build does not error — it just never
renders that page).
Any adopter with `benchmarks = true` or `ad = true` (i.e. anyone with a
"Benchmarks" nav entry at all): in `docs/pages.jl`, replace the existing
`"Benchmarks"` entry with
`"Benchmarks" => ["Performance over time" => "benchmarks/over-time.md",
"AD comparison" => "benchmarks/ad-comparison.md"]`, dropping whichever line
does not apply — the old flat `"Benchmarks" => "benchmarks.md"` entry now
points at a path the build no longer writes.
Until the `pages.jl` edit lands, a rendered page (built once
`HEAVY_BENCHMARKS`/`BENCHMARK_PAGE` is in place) is still reachable by
direct URL or `@ref` — `ad-backends` still cross-links to it — it just
won't appear in the sidebar. Until the `docs_config.jl` edit lands, the
build now drops any `pages.jl` entry whose page it did not actually
render, so an adopter who only fixes `pages.jl` never ships a dangling nav
link either — the entry is simply absent until both edits land, not
present-but-broken.
`update` now warns when either edit is still outstanding, so the gap
surfaces at sync time rather than only in this note.

A package that declares `[extensions]` now gets an "Extensions" group in its
docs nav, one entry per extension, each pointing at a seeded page under
`docs/src/extensions/` (#319).
The extensions are read from the package's own `Project.toml` rather than
gated by a kwarg: an extension is a fact about the package, unlike the
benchmark and AD opt-ins.
The pages are package-owned and write-once, so authored scope prose survives
every sync, and each ships its public-API `@autodocs` block inert, as a code
sample inside an outer fence — an extension module exists only once its
weakdeps load, so a live block would red the docs build of a package whose
docs environment does not carry them yet.
An HTML comment would not do: Documenter parses with the `Markdown` stdlib,
which has no CommonMark HTML-block handling, so a fence inside `<!-- -->` is
still live to it (the quirk behind #301/#304).
A page that the write-once nav in `docs/pages.jl` does not list is reported as
a warning naming the entry to add, rather than left unreachable.
A build drops any Extensions entry whose page is missing, so a package that
was scaffolded before this, or that removed an extension, never publishes a
dangling link.
`docs/pages.jl` is package-owned and written once, so an already-scaffolded
package adds the group by hand, as it does today when it flips
`benchmarks = true`.
A new managed workflow, `.github/workflows/release-nudge.yaml`, is
scaffolded into every adopting package (thin caller of a new
EpiAware/.github reusable, `release-nudge.yml`).
It runs weekly and on demand, compares `Project.toml`'s version and the
commits on `main` against the latest release/tag (and, best-effort, the
version registered in the Julia General registry), and opens or
refreshes a single labelled issue telling a maintainer what to do — bump
via `/version`, update `NEWS.md`, then `/register` — whenever there are
unreleased changes, closing it once everything is released.
The issue is never edited in place: a stale one (state changed, or
simply sat open too long) is closed with a "superseded" comment and
replaced.
The generated issue body can never contain a literal `@`, so neither a
contributor's handle nor the registry bot's own handle can ever render
as an accidental mention or trigger.

The managed `.github/dependabot.yml` now runs both ecosystems daily rather
than weekly (#312).
Both were already grouped by a wildcard pattern (#249), so each run refreshes
the one open grouped PR per ecosystem instead of opening more: a shorter
interval buys faster reusable-workflow and dependency updates at the same open
PR count.
The cost is CI, not review load: each refresh is a new commit and so a new
check run, where a weekly interval let a week's bumps share one.
A package that would rather trade update latency for runner time can set the
`julia` ecosystem — the expensive half, since a refresh reruns the full test
matrix — back to `weekly` in its own copy; the grouping is what matters.
Adopters pick this up on their next `update`.

**Breaking**: `scaffold_update` is renamed back to `update`, and is now
`public`, not `export`ed (#294).
A bare `using EpiAwarePackageTools` no longer brings it into scope — call
it as `EpiAwarePackageTools.update(...)` or
`using EpiAwarePackageTools: update`.

This function used to be a bare `update` until #173 found that an
`export`ed generic verb collides with a package's own same-named export:
`using EpiAwarePackageTools; using ComposedDistributions` left `update`
unbound in `Main`, breaking Documenter `@ref` resolution across every
kit-adopting package that also ships its own `update`. #178 fixed it at
the time with a hard rename to `scaffold_update`.
`public` closes that collision a different way: a `public`-not-`export`ed
name is never brought into scope by a bare `using`, so it cannot fight
another package's export regardless of what either package calls its own
verb — that makes the short, generic name safe again, so #294 renames it
back.

`scaffold_update` is kept `public` too, as a transitional alias
(`const scaffold_update = update`) — an already-qualified caller
(`EpiAwarePackageTools.scaffold_update(...)`, or an explicit
`using EpiAwarePackageTools: scaffold_update`) keeps working unchanged.
The alias is removed in a future cleanup once adopters have moved onto
`update`.

Every template-sync/self-drift caller shipped by the kit now calls
`update`; an adopter on an older scaffolded
`.github/workflows/template-sync.yaml` (calling `scaffold_update(...)`
unqualified after a bare `using EpiAwarePackageTools`) needs a one-line
fix — qualify the call — before their first sync on this kit version, or
the sync run itself fails.

`build_index`'s HTML-comment strip now recognises the two remaining CommonMark code forms it previously missed: a 4-space indented code block and an inline single-backtick code span. A `<!-- -->` shown as literal example text inside either now survives verbatim on the generated docs index, closing the gap #301/PR#304 deliberately left open (#306).

`build_docs` no longer flags a package's own module docstring as "not included in the manual" under `checkdocs = :all` (the default for a package with no re-exports): it is now rendered as its own `@docs` block prepended to `lib/public.md`, ahead of Contents/Index, so it both satisfies the completeness scan and is actually readable on the built site (#313).

The managed `Taskfile.yml` `coverage` task now instruments the actual test run. It previously passed `--code-coverage=user` to the outer `julia` process while `Pkg.test()` spawns its own child for the real run — the child was never instrumented, so every `task coverage` produced an `lcov.info` with no real per-file numbers. The recipe now passes `Pkg.test(coverage=true, ...)` directly, and the post-processing step's `Pkg.add("Coverage")` moved to a shared `@coverage` environment so it no longer dirties adopters' tracked `test/Project.toml` (#315).

The managed `Quality: formatting` testitem now runs through the package's isolated, exactly-pinned `test/formatter/` environment (the same isolation `test_linting` already used for JET), instead of resolving JuliaFormatter from the shared test environment where its version floats with the CI Julia in the matrix. Packages get this automatically once `qa_config.jl` gains a `formatter_env` key on their next `scaffold`; adopters whose package-owned `qa_config.jl` predates the key keep today's in-process check via a `hasproperty` guard that warns when it engages, matching the existing `QA_CONFIG.readme` fallback idiom (#188, #321).

`update` now seeds a missing `CITATION.cff` (write-once, like `scaffold`) instead of only ever rendering the managed "How to cite" README section that points at it. A package that adopted the template before citation seeding existed used to carry a permanently dangling `CITATION.cff` link that no `update` could ever fix — a hard docs-linkcheck 404 the moment its README reached a linkchecked build (#322).
