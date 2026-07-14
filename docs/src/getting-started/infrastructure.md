# [Infrastructure and template sync](@id infrastructure)

The kit does two jobs for an adopting package: it writes the standard
infrastructure once (`scaffold`), and it keeps that infrastructure current
afterwards (`scaffold_update`, driven on a schedule).
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
  `scaffold_update` rewrites them from the bundled templates on every sync, so drift is
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

## Overriding a managed file

A package that must keep its own version of a managed file says so in the file.
Put the marker `EPIAWARE_MANAGED_OVERRIDE` in a comment anywhere in it, and
`scaffold_update` preserves the file rather than resyncing it, reporting it
under `preserved` in the manifest.

```yaml
# EPIAWARE_MANAGED_OVERRIDE: this package needs its own test matrix.
```

Remove the marker to hand the file back to the kit. `scaffold` with
`force = true` ignores the marker and lays the managed file down fresh, so a new
package always starts fully managed.

Use this sparingly. An overridden file stops tracking the standard, so kit fixes
no longer reach it, which is the opposite of what the kit is for. Prefer the
supported hooks (the package-owned config values, the marker-delimited regions,
and the `ad`/`benchmarks`/`downgrade_compat` flags) where they cover the need.

What the marker does **not** cover:

- The marker-delimited regions described above, in files that are otherwise
  package-owned: the README badge block, the README standard sections, the
  `.gitignore` managed block, and the `[workspace]` stanza in `Project.toml`.
  Those are refreshed on every sync whether or not the file carries the marker.
  Customise them by editing outside their markers, which is what the markers are
  for. There is no region-level opt-out.
- Retirement. When the kit retires a path, a sync deletes it whether or not it
  carries the marker, because a retired path is infrastructure the kit no longer
  supports at all.
- The two managed JSON files (`docs/package.json` and `.secrets.baseline`). The
  marker has to live in a comment and JSON has no comments, so these cannot be
  overridden this way.

The match is case-sensitive: write `EPIAWARE_MANAGED_OVERRIDE` in capitals. A
mis-cased marker does nothing and the file is resynced as usual.

The AD-harness driver `test/ad/setup.jl` is the original case: a package whose
`ADFixtures` registry predates the current `ADRegistry` contract must keep a
hand-written driver while it migrates. That file also honours its older marker
`EPIAWARE_AD_SETUP_OWNED`; either marker preserves it. It is also the one file
where `scaffold_update` warns before overwriting a version that has diverged
from the kit's and carries no marker, because a clobber there breaks every AD CI
job. No such warning exists for managed files generally: divergence from the
current template is the normal state of an adopter that is simply on an older
kit version, so a general divergence warning would fire on every sync and tell
you nothing. Mark the files you own instead.

## Staying in sync

Two workflows keep an adopting package aligned with the kit.

- The scheduled template-sync workflow
  (`.github/workflows/template-sync.yaml`) re-runs `scaffold_update` against the
  repository on a schedule and on Dependabot updates, then opens or refreshes a
  pull request whenever the committed infrastructure has drifted from the
  current standard.
- Dependabot (`.github/dependabot.yml`) keeps the pinned reusable-workflow and
  action references current, so fixes in the shared workflows reach the
  repository without manual edits.

An improvement made once in the kit therefore propagates to every adopting
package on the next sync.

## Registration safety

The managed `registrability.yaml` caller runs the shared
`EpiAware/.github` registrability workflow whenever a package's `Project.toml`
changes (and on demand, and on `main`).
It runs two read-only checks.

- Registrability asserts that every non-stdlib `[deps]` entry exists in the
  General registry with a version satisfying the package's own `[compat]`.
  A dependency pinned in `[sources]` to a git revision is unregistered, so the
  check fails with a per-dependency message.
  This is the failure that had ConvolvedDistributions 0.2.0 rejected from
  General with nothing in CI to catch it.
- The reverse-dependency scan reports which org packages depend on this one
  and whether their `[compat]` admits the version under test.
  A breaking release legitimately strands a downstream bound, so this is a
  warning by default; set `fail_on_revdep_break: true` on the caller job to
  gate on it.

## How the kit applies this to itself

The kit manages its own repository the same way an adopter's is managed, with
one difference: it is a tooling package, so it scaffolds itself with
`ad = false` (no AD CI or harness).

A `self-drift` CI check runs `scaffold_update("."; ad = false)` and asserts the result
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
scaffold_update(pkgdir(MyPackage))
```

`scaffold_update` rewrites only the managed files and returns a manifest of what was
created, updated, or preserved; package-owned files are left untouched.
