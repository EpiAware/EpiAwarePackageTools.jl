# [Infrastructure and template sync](@id infrastructure)

`{{PACKAGE}}` adopts shared configuration and test infrastructure from
[EpiAwarePackageTools](https://github.com/EpiAware/EpiAwarePackageTools.jl)
(the kit).
The kit owns the standard CI workflows, the documentation build, the quality
and AD test harnesses, and the developer config.
This page explains how that infrastructure is set up and how it stays current.

## Managed and package-owned files

Files fall into two classes.

- Managed files are the standard infrastructure (CI callers, the docs build,
  formatter and pre-commit config, coverage config).
  The kit rewrites them on every sync, so drift is removed automatically.
  Each managed file carries a `MANAGED by EpiAwarePackageTools.scaffold`
  header; do not edit them by hand.
- Package-owned files are written once and never overwritten (unit tests, the
  QA config values, the navigation tree, the README body, `LICENSE`).
  These are yours to edit.

## Staying in sync

Two pieces keep `{{PACKAGE}}` aligned with the kit.

- A scheduled template-sync workflow (`.github/workflows/template-sync.yaml`)
  re-runs the kit's `scaffold_update` against this repository, then opens or refreshes a
  pull request when the committed infrastructure has drifted from the current
  standard.
- Dependabot (`.github/dependabot.yml`) keeps the pinned reusable-workflow and
  action references current, so security and bug fixes in the shared
  workflows reach this repository without manual edits.

Together they mean an improvement made once in the kit propagates to every
adopting package.

## Adopting or updating by hand

You can also run the kit directly from a Julia session:

```julia
using EpiAwarePackageTools

# Re-apply the managed standard files and report drift.
scaffold_update("path/to/{{PACKAGE}}.jl")
```

`scaffold_update` rewrites only the managed files and reports which were changed;
package-owned files are left untouched.
See the [EpiAwarePackageTools documentation](https://github.com/EpiAware/EpiAwarePackageTools.jl)
for the full set of options.
