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

`build_index`'s HTML-comment strip now recognises the two remaining CommonMark code forms it previously missed: a 4-space indented code block and an inline single-backtick code span. A `<!-- -->` shown as literal example text inside either now survives verbatim on the generated docs index, closing the gap #301/PR#304 deliberately left open (#306).

`build_docs` no longer flags a package's own module docstring as "not included in the manual" under `checkdocs = :all` (the default for a package with no re-exports): it is now rendered as its own `@docs` block prepended to `lib/public.md`, ahead of Contents/Index, so it both satisfies the completeness scan and is actually readable on the built site (#313).

The managed `Taskfile.yml` `coverage` task now instruments the actual test run. It previously passed `--code-coverage=user` to the outer `julia` process while `Pkg.test()` spawns its own child for the real run — the child was never instrumented, so every `task coverage` produced an `lcov.info` with no real per-file numbers. The recipe now passes `Pkg.test(coverage=true, ...)` directly, and the post-processing step's `Pkg.add("Coverage")` moved to a shared `@coverage` environment so it no longer dirties adopters' tracked `test/Project.toml` (#315).

The managed `Quality: formatting` testitem now runs through the package's isolated, exactly-pinned `test/formatter/` environment (the same isolation `test_linting` already used for JET), instead of resolving JuliaFormatter from the shared test environment where its version floats with the CI Julia in the matrix. Packages get this automatically once `qa_config.jl` gains a `formatter_env` key on their next `scaffold`; adopters whose package-owned `qa_config.jl` predates the key keep today's in-process check via a `hasproperty` guard that warns when it engages, matching the existing `QA_CONFIG.readme` fallback idiom (#188, #321).

`update` now seeds a missing `CITATION.cff` (write-once, like `scaffold`) instead of only ever rendering the managed "How to cite" README section that points at it. A package that adopted the template before citation seeding existed used to carry a permanently dangling `CITATION.cff` link that no `update` could ever fix — a hard docs-linkcheck 404 the moment its README reached a linkchecked build (#322).
