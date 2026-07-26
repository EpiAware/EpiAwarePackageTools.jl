## Unreleased

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
