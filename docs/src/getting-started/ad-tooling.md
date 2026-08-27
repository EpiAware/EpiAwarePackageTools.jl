# [AD tooling](@id ad-tooling)

Automatic differentiation is how the models in these packages are fit, so a
gradient that is silently wrong is a serious defect.
The kit ships a harness that checks each package's gradients against a trusted
reference on every supported AD backend, systematically, in CI.
This is the feature that most sets the kit apart from a generic package
template, so this page explains both how it works and why it is built the way it
is.
See [Infrastructure and template sync](@ref infrastructure) for the
managed-versus-package-owned split.

## Why per-backend gradient testing

A Julia model can be differentiated by several AD backends, and they do not all
agree.
A backend can return a wrong gradient on a construct it mishandles while every
other backend is correct, and nothing in an ordinary test suite would notice,
because the model still evaluates and the sampler still runs.
The only reliable check is to compute the gradient of the same log density with
each backend and compare it against a reference the package trusts.

The harness makes that check systematic.
Every backend runs the same scenarios against the same ForwardDiff reference,
each backend runs as its own CI job so a transiently unstable backend only reds
its own status, and a scenario a backend genuinely cannot handle is recorded as
broken rather than quietly dropped.
The result is that a regression in gradient correctness on any single backend is
caught the moment it lands.

## Opting in

Pass `ad = true` to `scaffold` (the default for a numerical package); a tooling
or non-numerical package passes `ad = false` and gets none of this.

```julia
scaffold(pkgdir(MyPackage); ad = true)
```

This writes the AD CI caller, the `test/ad/` harness wiring, the `ADFixtures`
registry skeleton, and the AD test environment.

## The backend matrix

The kit tests seven backends across four AD packages.

| Backend | Package |
|---|---|
| ForwardDiff | ForwardDiff |
| ReverseDiff (tape) | ReverseDiff |
| ReverseDiff (compiled) | ReverseDiff |
| Enzyme forward | Enzyme |
| Enzyme reverse | Enzyme |
| Mooncake forward | Mooncake |
| Mooncake reverse | Mooncake |

ForwardDiff doubles as the reference: each scenario carries a ForwardDiff
gradient, and the remaining backends are checked against it.

## The AD docs page

An `ad = true` package gets one managed AD page, `AD comparison`, under its own
top-level Benchmarks nav group.
It reports what each backend costs on the package's own scenario set, and
carries a short section on choosing between them.

There used to be a second page, an `AD backends` tutorial under Getting started.
It is retired.
Its support table repeated the README's per-backend coverage badge row and the
comparison page's own scenario coverage, and the rest was generic advice about
using AD that belonged to no package in particular.

Package pages across the org link to that page by its Documenter anchor,
`@ref ad-backends`, so the anchor moved to the comparison page's
`Choosing a backend` section rather than disappearing.
A sync deletes the retired source, and warns when a package's own
`docs/docs_config.jl` still registers it, because that file is package-owned and
the sync cannot edit it.

### [Where the page's numbers come from](@id ad-benchmark-numbers)

The page renders the gradient numbers the package's benchmark suite already
measures, or measures them itself when there are none to read.

`benchmark/benchmarks.jl` builds its `"AD gradients"` group from the same
`test/ADFixtures` registry the gradient tests use, keyed
`["AD gradients"][scenario][backend]`.
That is the convention the pull request benchmark comment folds into its AD
matrix, so one suite definition feeds both it and this page.
`benchmark-history.yaml` runs the suite on each push to `main` and deploys the
run to the `benchmarks` branch, with the raw per-revision results under
`history/results/` beside the plots.
`latest.json` there is the file for the revision that run measured.

The docs build reads that file without the package configuring anything.
It resolves the branch with `git`, exactly as the performance-history page
resolves `history/table.md`, so no checkout step is needed.
A package whose run carried no gradient numbers at all is left measuring every
(backend, scenario) pair itself while the docs build runs, which is fine for a
small registry and stops fitting in a CI job for a large one.

Name a different location to read some other run:

```julia
# docs/docs_config.jl
const AD_BENCHMARK_RESULTS = "bench-results"
```

The value is a results file, or a directory of them, in which case `latest.json`
wins and otherwise the most recently written file does.
A git checkout gives every file the same modification time, which is why the run
names its own revision rather than leaving the newest file to be guessed.
A relative path resolves against `docs/`.
The `AD_BENCHMARK_RESULTS` environment variable overrides the const, so CI can
name a checkout without touching the package-owned config:

```
AD_BENCHMARK_RESULTS=bench-results julia --project=docs docs/make.jl
```

Whichever results the page reads, it renders what it finds and never measures:

- Nothing found: the page states that no measurements are available.
- Some backends missing: the page renders those it has and names the rest.
  A gap means the suite does not cover that backend, or names it differently
  from the registry, since both are package-owned and nothing checks that they
  agree.

Costs are relative to ForwardDiff where it has numbers, and otherwise to the
first backend that does.
Each time is the fastest sample of its benchmark, whether the page read it from
a published run or measured it, which is the estimator
`DifferentiationInterfaceTest.benchmark_differentiation` reports.

### One single source of truth

The backend list is defined once in the kit, in `_AD_BACKENDS`, and everything
AD-related is generated from it.
That one list drives the README coverage-flag badge table, the `codecov.yml`
per-backend flags and the coverage gate that waits for every flag to upload, the
starter scenario test items, the AD dependency list in the scaffolded harness,
and the `backends` matrix the CI caller passes to the reusable workflow.

Passing the matrix to the workflow explicitly, rather than trusting the
reusable's own default, is deliberate.
It means the CI matrix that actually runs can never drift from the badges and
coverage flags the same package generates.
Add, remove, or reorder a backend in `_AD_BACKENDS` and every one of those
regenerates consistently on the next sync.

## The registry contract

The harness has no knowledge of any particular package's types.
It talks to a package's fixtures through the [`ADRegistry`](@ref) contract, so
the run logic every package would otherwise copy lives in the kit while the
scenarios stay in the package.

A registry is any object, commonly a package's `ADFixtures` module, that
responds to:

- `scenarios(; with_reference, kwargs...)` returning the gradient scenarios,
  each carrying its function, input, contexts, and ForwardDiff reference.
- `backends()` returning the backends to test as `(; name, backend)` named
  tuples.

Three further accessors are optional and default to empty, so a package with no
broken or skipped scenarios need not define them.

- `broken_scenario_names()` for scenarios broken on every backend.
- `backend_broken_scenarios()` for per-backend broken scenarios.
- `backend_skip_scenarios()` for per-backend scenarios too unstable to run at
  all.

The broken and skip bookkeeping is what lets a known gradient failure be
recorded honestly.
A broken scenario is still run through [`check_broken`](@ref), which asserts it
really does fail, so a scenario marked broken that starts passing again is
flagged rather than left stale.

## What the kit scaffolds

An `ad = true` package gets:

- `test/ad/setup.jl` (managed) wiring the shared harness to the package's
  registry and exposing [`test_working_backend`](@ref) and
  [`test_partial_backend`](@ref) as thin locals.
- `test/ad/scenarios.jl` (package-owned) with one starter `@testitem` per
  backend, tagged so the per-backend CI can select a single backend by tag.
- `test/ad/runtests.jl` (managed) discovering those items with TestItemRunner.
- `test/ADFixtures/` (package-owned) the registry skeleton implementing the
  contract, with a placeholder scenario that runs out of the box.

The AD items live in their own environment and their own CI, kept out of the
main test run, because Enzyme, Mooncake, and the rest are heavy dependencies
that the ordinary tests should not carry.

## Registering scenarios

Replace the placeholder scenario in `test/ADFixtures/src/ADFixtures.jl` with the
package's own differentiable log densities, and add the backends the package
supports to `backends()`.
Group scenarios by category if the package distinguishes them, for example a
marginal likelihood from a latent one, and select the category from the scenario
test items.

Each backend is its own `@testitem` in `test/ad/scenarios.jl`, so a scenario
group is added by writing an item that calls `test_working_backend` for the
backend and category.

```julia
@testitem "ForwardDiff gradients (latent)" tags=[:ad, :forwarddiff] setup=[ADHelpers] begin
    test_working_backend("ForwardDiff"; category = :latent)
end
```

## The CI workflow and status badge

The `ad.yaml` caller drives the per-backend matrix on pushes to `main`, pull
requests, and merge queues.
It skips only clearly AD-irrelevant changes such as prose docs, so anything
touching sources, extensions, tests, or the suite still runs the full matrix.
Each backend uploads coverage under its own flag, and the coverage gate holds
the status until every flag has reported.

The kit ships one aggregate `ad.yaml` rather than six separate per-backend
workflows, so the README carries a single AD status badge for the whole matrix.
The per-backend detail lives in the coverage-flag table below that badge, where
each backend has its own coverage badge.

### Giving a slow backend more time

Each backend job runs under the reusable workflow's own timeout.
A package whose slowest backend approaches that cap can raise it with the
`ad_timeout` input, in minutes.

```julia
using EpiAwarePackageTools
update("."; ad_timeout = 120)
```

The value is written as `timeout_minutes` in the caller's `with:` block and
kept by later syncs that do not re-pass it, so the input only has to be given
once.
Leaving `ad_timeout` unset passes no `timeout_minutes` at all, which is what
every package that fits inside the reusable's default should do.
Raising the cap only stops a job being killed part way; it is worth checking
first whether the leg is genuinely slow or is hanging.

## Running AD tests locally

The scaffolded `Taskfile.yml` wraps the AD runs.

- `task test-ad` runs every backend in the isolated AD environment.
- `TAG=enzyme_reverse task test-ad-backend` runs a single backend by tag,
  exactly as the per-backend CI does.

Running a single backend by tag is the fastest way to reproduce a CI failure
that only one backend hits.

## Making code AD-safe

This page is about *testing* that a package's differentiable code works across
backends.
Making that code differentiable in the first place — stripping an AD tape, or
giving a backend an analytic derivative for a call it cannot handle, such as a
`cdf` through `SpecialFunctions.gamma_inc` — is the job of
[EpiAwareADTools.jl](https://github.com/EpiAware/EpiAwareADTools.jl), the org's
shared home for AD-safe evaluation hooks (`cdf_ad_safe`, `primal`, and the rest)
and AD workarounds.
A package imports it in its own source, and the AD scenarios registered here
then exercise the result.
It is a staging ground rather than a permanent home: each workaround is
documented against the upstream fix meant to replace it, so entries are deleted
as those land.
The kit does not depend on it, and an `ad = true` package takes it on only if it
needs one of those workarounds.
