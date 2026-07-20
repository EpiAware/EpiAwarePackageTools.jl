#src MANAGED by EpiAwarePackageTools.scaffold — do not edit by hand.
#src Generalised from CensoredDistributions.jl's AD-backends page (the org
#src model page). The page body is re-applied on every update so it
#src stays kit-current; everything package-specific it reports (scenarios,
#src backends, broken/skip declarations) is read at docs-build time from the
#src package-owned `test/ADFixtures` registry, so declare a broken scenario
#src there, never here. If this page cannot execute for this package, park it
#src via `FORCE_STUB_TUTORIALS` in `docs/docs_config.jl` instead of editing it.
#src The backend-comparison benchmark used to live on this page; it is now
#src `ad-comparison.jl`, under the Benchmarks nav rather than Tutorials (#299)
#src — this page keeps the how-to-choose narrative and links there for numbers.

md"""
# [Automatic differentiation backends](@id ad-backends)

{{PACKAGE}}.jl composes with Julia's automatic differentiation (AD)
ecosystem, so its differentiable quantities can be used in gradient-based
inference, for example inside a [Turing.jl](https://turinglang.org) model.
This page reports which backends work and how to configure the ones that
need it. Advice on choosing a backend and on debugging follows; the
[AD comparison](@ref ad-comparison) page benchmarks what each backend
costs on the package's shared AD scenario set.

## Backend support

The AD gradient suite runs as one CI workflow with a job per backend, so a
transiently unstable backend only reds its own job.
The badge below is the latest run of that matrix on `main`, tested on
Julia 1 (the latest stable release).

[![AD](https://github.com/{{REPO}}/actions/workflows/ad.yaml/badge.svg?branch=main)](https://github.com/{{REPO}}/actions/workflows/ad.yaml)

The table below is each backend's code coverage from the gradient suite
(Codecov flag `ad-<backend>`), reporting which package lines that backend
exercises.

{{AD_COV_TABLE}}

A green matrix means each backend differentiates the scenarios we test for
it, which does not by itself mean full coverage.
The next table reports that coverage per backend, rendered directly from
the package's AD-fixture registry (the `ADFixtures` path package at
`test/ADFixtures`), the same registry the gradient tests and the
[AD comparison](@ref ad-comparison) page consume.
A scenario is declared broken or skipped on a backend through the
registry's optional `broken_scenario_names`, `backend_broken_scenarios`,
and `backend_skip_scenarios` accessors, so what this table shows cannot
drift from what the tests actually mark broken.
"""

md"""
```@raw html
<details><summary>Show table code</summary>
```
"""

using EpiAwarePackageTools
using ADFixtures
import Markdown

support_table = Markdown.parse(ad_backend_support_table(ADFixtures));

md"""
```@raw html
</details>
```
"""

support_table

md"""
### Configuring Enzyme

When the registry enables Enzyme, the standard configuration defers
per-value activity decisions to runtime:

```julia
using ADTypes, Enzyme
AutoEnzyme(mode = Enzyme.set_runtime_activity(Enzyme.Reverse))
```

See the [Enzyme FAQ](https://enzymead.github.io/Enzyme.jl/stable/faq/) for
what `set_runtime_activity` does.
Scenario data is passed as a `Constant` DifferentiationInterface context
rather than captured in a closure, which keeps the differentiated function
free of active fields.
Runtime activity is not free: on paths that do not need it, it can make
Enzyme several times slower, so where the registry applies one Enzyme
configuration to every scenario the [AD comparison](@ref ad-comparison)
page's rows for it are conservative.
Running through DifferentiationInterface, by contrast, adds no measurable
overhead.

The scenario set is package-owned.
It is defined with
[DifferentiationInterfaceTest.jl](https://juliadiff.org/DifferentiationInterface.jl/DifferentiationInterfaceTest/stable/)
in the `ADFixtures` path package at `test/ADFixtures`, and shared with the
gradient tests (`test/ad/runtests.jl`), so this page, the tests, and the
per-backend CI all exercise the same set.

## Choosing a backend

Which backend is fastest depends on how many parameters you differentiate
with respect to — the [AD comparison](@ref ad-comparison) page benchmarks
this package's own scenarios, but the pattern there is general:

- Forward mode (ForwardDiff, Enzyme forward, Mooncake forward) costs one
  pass per parameter, so it wins when the parameter count is small.
  Fitting a single distribution has a handful of parameters, which is why
  ForwardDiff usually leads the low-dimensional rows; among the forward
  backends it is typically the fastest on small smooth log densities.
- Reverse mode (ReverseDiff, Enzyme reverse, Mooncake reverse) costs one
  pass per output regardless of the parameter count, so it pays off once
  this package's quantities sit inside a larger model with many latent
  parameters.
  In high-dimensional scenarios Enzyme reverse and Mooncake reverse tend
  to run several times faster than ForwardDiff, while ReverseDiff's tape
  overhead can leave it slower even there.

Turing's
[AD guidance](https://turinglang.org/docs/usage/automatic-differentiation/)
puts the crossover around 20 parameters: forward mode below, reverse mode
above.
ForwardDiff is the simplest fast default for the small-parameter case and
needs no configuration.
For a higher-dimensional model, switch to a reverse-mode backend.
In a Turing model you set this through the sampler's `adtype`, for example
`sample(model, NUTS(; adtype = AutoMooncake()), 1000)`, and the surest
choice is to benchmark the backends on your own model.

## Debugging

ForwardDiff fails with ordinary Julia `MethodError`s that point at the
offending call, so it is the easiest backend to debug; start there when a
gradient misbehaves.
Enzyme and Mooncake report errors at the compiled-IR level, which are
harder to trace.

[DifferentiationInterface](https://github.com/JuliaDiff/DifferentiationInterface.jl)
and
[DifferentiationInterfaceTest](https://juliadiff.org/DifferentiationInterface.jl/DifferentiationInterfaceTest/stable/)
make this tractable.
DI gives one `gradient` call that swaps backends without touching the
model, so you can compare a suspect backend against the ForwardDiff value
on the same input (which is what the gradient tests do).
DIT runs a single function across several backends at once and flags the
ones that disagree with the reference.
Work bottom-up: differentiate one small piece first (a single `logpdf`,
then one of this package's own quantities), confirm it, and build up to
the full model, so the construct a backend chokes on is easy to isolate.
When a genuinely broken combination is confirmed, declare it in the
`ADFixtures` registry (`backend_broken_scenarios`, or
`backend_skip_scenarios` when it cannot run at all): the gradient tests
then record it as `@test_broken` and this page reports it in the support
table, instead of the suite going red.

When the construct a backend chokes on is a distribution evaluation it
cannot differentiate — a `cdf` through `SpecialFunctions.gamma_inc`, say,
or a call whose AD tape needs stripping —
[EpiAwareADTools](https://github.com/EpiAware/EpiAwareADTools.jl) hosts
AD-safe replacements a package imports in its own source: the `cdf_ad_safe`
family of evaluation hooks and the `primal`/`primal_distribution` tape
strips.
It is the org's staging ground for such workarounds, each documented
against the upstream fix that will one day replace it, so reach for it
before declaring a scenario broken.

## Reproducing this page

To regenerate locally:

```
task docs
```

or, equivalently:

```
julia --project=docs docs/make.jl
```

## See also

- The [AD comparison](@ref ad-comparison) page benchmarks every backend's
  relative cost on this package's own AD scenario set.
- `test/ad/` holds the gradient tests as tagged `@testitem`s, validated
  against a ForwardDiff reference with
  `DifferentiationInterfaceTest.test_differentiation`. Pass a backend tag
  (e.g. `TAG=enzyme_reverse task test-ad-backend`) to run a single
  backend, as the per-backend CI does.
- `test/ADFixtures` is the package-owned registry this page renders from;
  scenarios, backends, and broken/skip declarations all live there.
- The shared harness and the `ADRegistry` contract live in
  [EpiAwarePackageTools.jl](https://github.com/EpiAware/EpiAwarePackageTools.jl).
- [EpiAwareADTools.jl](https://github.com/EpiAware/EpiAwareADTools.jl) is the
  org's home for AD-safe evaluation hooks (`cdf_ad_safe`, `primal`, ...) and
  other AD workarounds a package's own source can import when a backend needs
  help with a construct it cannot otherwise differentiate.
"""
