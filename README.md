# EpiAwarePackageTools.jl

<!-- badges:start -->
| | |
|---|---|
| Docs | [![Stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://epiawarepackagetools.epiaware.org/stable/) [![Dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://epiawarepackagetools.epiaware.org/dev/) |
| CI | [![Test](https://github.com/EpiAware/EpiAwarePackageTools.jl/actions/workflows/test.yaml/badge.svg?branch=main)](https://github.com/EpiAware/EpiAwarePackageTools.jl/actions/workflows/test.yaml) [![codecov](https://codecov.io/gh/EpiAware/EpiAwarePackageTools.jl/graph/badge.svg)](https://codecov.io/gh/EpiAware/EpiAwarePackageTools.jl) |
| Quality | [![SciML Code Style](https://img.shields.io/static/v1?label=code%20style&message=SciML&color=9558b2&labelColor=389826)](https://github.com/SciML/SciMLStyle) [![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/Aqua.jl) [![JET](https://img.shields.io/badge/%E2%9C%88%EF%B8%8F%20tested%20with%20-%20JET.jl%20-%20red)](https://github.com/aviatesk/JET.jl) |
| License | [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT) |

<!-- Once registered, add a version badge, e.g.:
[![EpiAwarePackageTools](https://juliahub.com/docs/General/EpiAwarePackageTools/stable/version.svg)](https://juliahub.com/ui/Packages/General/EpiAwarePackageTools) -->
<!-- badges:end -->

Shared, package-agnostic test utilities for [EpiAware](https://github.com/EpiAware) Julia packages.

The package collects the test scaffolding that EpiAware packages would
otherwise each copy: standard quality checks over a target module, and an
AD-gradient harness that checks a package's AD backends against a ForwardDiff
reference. Package-specific fixtures (the actual distributions, models, or
interface checklists) stay in each package; this package only supplies the
reusable run logic.

## What is here

The kit has four parts.

| Part | Helpers |
|---|---|
| Package-quality helpers | `test_aqua`, `test_explicit_imports`, `test_jet`, `test_docstring_format`, `test_ext_ambiguities`, `test_doctest`, `test_formatting`, `test_linting` |
| AD-gradient harness | `ADRegistry`, `check_broken`, `test_working_backend`, `test_partial_backend` |
| Benchmark reporting | `EpiAwarePackageTools.Benchmarks` submodule (`run_suite`, `asv_comment`, `compare_comment`, ...) |
| Scaffold + sync | `scaffold`, `update`, plus the `templates/` directory |

A package adopts the kit by depending on EpiAwarePackageTools in its test
environment and calling `scaffold(pkgdir(MyPackage))` once. That writes the
whole shipped tooling: the root dev config, the CI caller workflows +
dependabot, and the QA / AD / benchmark test infrastructure that calls the
helpers below. The package then fills in the package-owned skeletons (its
`qa_config.jl`, AD scenarios, and `benchmarks.jl`) and adds its own unit tests.
`update(pkgdir(MyPackage))` re-applies only the managed standard files to keep
a package in sync (the entry point a scheduled template-sync uses).

### Package-quality helpers

Run the standard checks over a target module:

```julia
using EpiAwarePackageTools

test_aqua(MyPackage)
test_explicit_imports(MyPackage; ignore = (:SomeInternal,))
test_jet(MyPackage; env = joinpath(@__DIR__, "jet"))
test_docstring_format(MyPackage; crossref_ignore = (:pdf, :cdf))
test_doctest(MyPackage)
test_formatting(MyPackage)
test_linting(MyPackage; env = joinpath(@__DIR__, "jet"))
```

`test_aqua`, `test_explicit_imports`, and `test_docstring_format` run
in-process. `test_jet`/`test_linting` run JET in an isolated environment (pass
`env` as a project directory holding JET plus the package) to keep JET's
dependency pins from clashing with the rest of the test environment, or
in-process when `env` is omitted. `test_doctest` and `test_formatting` need
Documenter and JuliaFormatter in the calling environment.

Per-package specifics are caller-supplied, not baked in: the
`test_explicit_imports` `ignore` list, the `test_docstring_format`
`crossref_ignore` list, and the extension names / surface `prefixes` for
`test_ext_ambiguities`.

`test_ext_ambiguities` covers an ambiguity Aqua cannot see (Aqua runs with no
extensions loaded). Load the trigger package, then assert the extension adds no
ambiguity on the package's own surface:

```julia
import SomeTrigger
test_ext_ambiguities(MyPackage, :MyPackageSomeTriggerExt;
    prefixes = ("MyPackage", "SomeTrigger"))
# quarantine a known, issue-tracked ambiguity without silencing it:
test_ext_ambiguities(MyPackage, :MyPackageOtherExt; broken = true)
```

### Scaffold + sync

`scaffold` writes the whole shipped tooling — config, CI, and test
infrastructure — into a package so it adopts the standard in one call.
`update` re-applies just the managed standard files later. `generate` does the
same for a brand-new package, writing its `Project.toml` and source module
first.

```julia
using EpiAwarePackageTools

scaffold(pkgdir(MyPackage))            # adopt into an existing package
update(pkgdir(MyPackage))             # sync: re-apply managed files, report drift
generate("path/to/NewPkg", "NewPkg")  # create a fresh package, then scaffold it
```

**AD is opt-in.** `scaffold`/`generate`/`update` take an `ad::Bool` keyword
(default `true`). A numerical package keeps `ad = true` and gets the AD CI
caller (`.github/workflows/ad.yaml`), the AD test harness (`test/ad/`,
`test/ADFixtures/`), per-backend `ad-*` codecov flags, and the `test-ad` Taskfile
targets. A tooling/non-numerical package passes `ad = false` to scaffold NONE of
that AD infrastructure — the files that vary by AD content (`Taskfile.yml`,
`codecov.yml`, `test/Project.toml`) are written in their no-AD variants. The kit
itself is a tooling package, so it manages its OWN repo with `ad = false` and a
`self-drift` CI check proves `update("."; ad = false)` yields zero drift.

```julia
scaffold(pkgdir(MyTooling); ad = false)   # no AD CI/harness/flags
```

**Standard README badges** are managed too. The README body stays package-owned,
but a block between `<!-- badges:start -->` / `<!-- badges:end -->` markers holds
the standard badge set (docs stable + dev, Test CI, codecov, SciML style, Aqua,
JET, License — plus per-backend AD CI and coverage badges when `ad = true`),
parameterised from `{{REPO}}` / `{{PACKAGE}}` so no owner or repo is hardcoded.
`scaffold`/`generate` write the markers and initial badges; `update` injects the
block when the markers are absent and re-renders it from the current placeholders
when present. Nothing outside the markers is touched, so a package gets and keeps
the standard badges automatically.

Each template is **managed** (standard infra, overwritten on `update` to remove
drift) or **package-owned** (a starting skeleton written once and never
overwritten). `{{PACKAGE}}` placeholders are filled from the target
`Project.toml` `name`.

Managed (overwritten on `scaffold`/`update`):

- Root dev config: `Taskfile.yml` (test, lint, format, docs, benchmark, and —
  when `ad = true` — AD targets), `.pre-commit-config.yaml` (JuliaFormatter +
  detect-secrets + file hygiene), `.JuliaFormatter.toml` (SciML),
  `.gitattributes` (normalise line endings to LF so the formatter check is
  stable on Windows runners), `.secrets.baseline` (the detect-secrets baseline
  the pre-commit config references), and `codecov.yml` (the `unit` flag, plus
  per-backend `ad-*` flags when `ad = true`).
- CI: `.github/workflows/*` thin callers that invoke the
  [EpiAware/.github](https://github.com/EpiAware/.github) reusables (tests,
  downgrade-compat, docs, doc-preview-cleanup, format/pre-commit, coverage,
  opt-in downstream/reverse-deps, TagBot) and `.github/dependabot.yml`. The
  per-backend AD matrix caller (`ad.yaml`) is added only when `ad = true`.
- Test infra: `test/package/quality.jl` (the QA testset that calls the helpers),
  `test/jet/runtests.jl` + `test/jet/Project.toml`, `test/formatter/runtests.jl`
  + `test/formatter/Project.toml`, and `benchmark/run.jl` / `benchmark/compare.jl`
  (the benchmark wiring using `Benchmarks`). When `ad = true`, the AD-harness
  wiring (`test/ad/setup.jl`, `test/ad/runtests.jl`) is managed too.

Package-owned (written once, never overwritten — `force = true` overrides):

- `test/runtests.jl` — the main test entry (pulls in the QA testset alongside
  the package's own unit tests).
- `test/Project.toml` — the test environment (seeded with the QA deps, plus the
  AD harness deps when `ad = true`).
- `test/package/qa_config.jl` — the QA config **values** the managed testset
  reads (the package's `ignore` lists, extension names, broken-quarantines).
- `LICENSE` — the `license`-selected licence text (an SPDX id, one of `MIT`,
  `Apache-2.0`; default `MIT`), written once with the holder/year filled.
  `update` never rewrites it, so a deliberately changed licence is not reverted.
- When `ad = true`: `test/ad/scenarios.jl` + `test/ad/Project.toml`, and an
  `ADFixtures` registry skeleton (`test/ADFixtures/`) implementing the
  `ADRegistry` contract.
- `benchmark/benchmarks.jl` — the package's `SUITE`.

A package's own unit tests, AD scenarios, registry, and config values therefore
stay package-owned; only the standard infra is managed. Both functions resolve
placeholders (`{{PACKAGE}}`, `{{AUTHORS}}`, `{{HOLDER}}`, `{{ORG}}`, `{{REPO}}`,
`{{REVIEWER}}`, `{{YEAR}}`, `{{UUID}}`) from the target `Project.toml` and
overridable keywords — no person, org, or repo name is hardcoded in any
template. Both return a `(created, updated, preserved)` manifest making clear
which files were newly written, rewritten, or left in place.

The reusable-workflow pins follow CensoredDistributions (a SHA pin for the
EpiAware/.github reusables, `@main` for the opt-in `downstream` workflow);
dependabot keeps each adopting repo's pins current.

### AD-gradient harness

Drive an AD-backend correctness suite against a ForwardDiff reference. The
package supplies an AD-fixture registry satisfying the `ADRegistry` contract
(scenarios with references, a backend list, and broken/skip bookkeeping); the
harness runs the working scenarios and marks the rest broken:

```julia
using EpiAwarePackageTools

test_working_backend(MyPackageADFixtures, "ReverseDiff")
test_partial_backend(MyPackageADFixtures, "Enzyme forward")
```

See the `ADRegistry` docstring for the full contract.

## Installation

The package is not yet registered in the General registry. Until it is, depend
on it from a test environment via a `[sources]` git pin:

```toml
[sources]
EpiAwarePackageTools = {url = "https://github.com/EpiAware/EpiAwarePackageTools.jl", rev = "main"}
```

## Contributing

This package follows [ColPrac](https://github.com/SciML/ColPrac) and the
[SciML style](https://github.com/SciML/SciMLStyle).
