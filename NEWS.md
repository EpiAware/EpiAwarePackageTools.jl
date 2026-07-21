## Unreleased

**New**: the AD backend-comparison benchmark moves off the `ad-backends`
tutorial page onto its own `ad-comparison` page, filed under the Benchmarks
nav rather than Tutorials (#299).
The benchmark table and plots read as a cost report, not a how-to guide, so
EpiAwareADTools#28 asked for the split.
`ad-backends` keeps the backend-support table, Enzyme configuration, and
debugging sections, and now cross-links to `ad-comparison` for the numbers
instead of carrying them.

`docs/pages.jl` is package-owned and write-once, so `update` cannot add the
new nav entry to an adopter's file automatically.
An existing `ad = true` adopter needs to add one line to the end of the
`pages` array in their `docs/pages.jl`, after their first sync on this kit
version: `"Benchmarks" => "getting-started/tutorials/ad-comparison.md"` if
they don't also have `benchmarks = true`, or the nested form
(`"Benchmarks" => ["Performance history" => "benchmarks.md", "AD comparison"
=> "getting-started/tutorials/ad-comparison.md"]`) if they do.
Until that edit lands, the new page still builds and is still cross-linked
from `ad-backends` — `@ref` resolution doesn't depend on the nav listing —
it just won't appear in the sidebar.

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
