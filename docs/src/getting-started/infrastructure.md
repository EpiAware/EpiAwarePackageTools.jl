# [Infrastructure and template sync](@id infrastructure)

The kit does two jobs for an adopting package: it writes the standard
infrastructure once (`scaffold`), and it keeps that infrastructure current
afterwards (`update`, driven on a schedule).
This page explains the sync machinery and how the kit applies it to itself on
its own repository.
For what that infrastructure actually contains, see the reference pages on the
[test infrastructure](@ref test-infrastructure), [benchmarking](@ref
benchmarking), and [AD tooling](@ref ad-tooling).

## Managed and package-owned files

Every file the kit writes is one of two kinds.

- Managed files are the standard infrastructure: the CI caller workflows, the
  documentation build (`docs/make.jl` and the VitePress theme, config, and
  components), the formatter and pre-commit config, and the coverage config.
  `update` rewrites them from the bundled templates on every sync, so drift is
  removed automatically.
  Each managed file carries a `MANAGED by EpiAwarePackageTools.scaffold`
  header; do not edit them by hand.
- Package-owned files are written once and never overwritten: the package's
  unit tests, its QA config values, the navigation tree (`docs/pages.jl`), the
  README body, `LICENSE`, `CITATION.cff` (your citation metadata), and the docs
  source pages such as this one.
  These are yours to edit.

The README badge block, the README standard sections (Contributing, How to
cite, Code of conduct), and the `.gitignore` standard rules are a hybrid: they
are managed between markers, so their wording and the ignore rules stay current
while anything you add outside the markers is preserved. The managed "How to
cite" section points at the package-owned `CITATION.cff`, so GitHub renders a
"Cite this repository" widget and the citation content stays yours to edit.

## Staying in sync

Two workflows keep an adopting package aligned with the kit.

- The scheduled template-sync workflow
  (`.github/workflows/template-sync.yaml`) re-runs `update` against the
  repository on a schedule and on Dependabot updates, then opens or refreshes a
  pull request whenever the committed infrastructure has drifted from the
  current standard.
- Dependabot (`.github/dependabot.yml`) keeps the pinned reusable-workflow and
  action references current, so fixes in the shared workflows reach the
  repository without manual edits.

An improvement made once in the kit therefore propagates to every adopting
package on the next sync.

## How the kit applies this to itself

The kit manages its own repository the same way an adopter's is managed, with
one difference: it is a tooling package, so it scaffolds itself with
`ad = false` (no AD CI or harness).

A `self-drift` CI check runs `update("."; ad = false)` and asserts the result
is zero drift, proving the committed infrastructure matches what the templates
currently produce.
Because the kit is its own first adopter, this documentation site and its
generated pages are the live example described in the
[getting-started note](@ref getting-started): what you see here is exactly what
the scaffold writes.

## Running a sync by hand

You can drive the same sync from a Julia session:

```julia
using EpiAwarePackageTools

# Re-apply the managed standard files and report drift.
update(pkgdir(MyPackage))
```

`update` rewrites only the managed files and returns a manifest of what was
created, updated, or preserved; package-owned files are left untouched.
