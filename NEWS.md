## Unreleased

A package that declares `[extensions]` now gets an "Extensions" group in its
docs nav, one entry per extension, each pointing at a seeded page under
`docs/src/extensions/` (#319).
The extensions are read from the package's own `Project.toml` rather than
gated by a kwarg: an extension is a fact about the package, unlike the
benchmark and AD opt-ins.
The pages are package-owned and write-once, so authored scope prose survives
every sync, and each ships its public-API `@autodocs` block commented out —
an extension module exists only once its weakdeps load, so a live block would
red the docs build of a package whose docs environment does not carry them
yet.
A build drops any Extensions entry whose page is missing, so a package that
was scaffolded before this, or that removed an extension, never publishes a
dangling link.
`docs/pages.jl` is package-owned and written once, so an already-scaffolded
package adds the group by hand, as it does today when it flips
`benchmarks = true`.

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
