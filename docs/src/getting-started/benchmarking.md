# [Benchmarking](@id benchmarking)

Benchmarking is opt-in.
A package that ships a real performance suite enables it, and everything else
skips the benchmark CI, the suite skeleton, and the benchmark docs page.
This page describes what the kit sets up when benchmarks are enabled, how the
two benchmark workflows differ, and how to add scenarios.
See [Infrastructure and template sync](@ref infrastructure) for the
managed-versus-package-owned split.

## Opting in

Pass `benchmarks = true` to `scaffold` (or `scaffold_update`).

```julia
scaffold(pkgdir(MyPackage); benchmarks = true)
```

This writes the benchmark CI callers, the `benchmark/` suite skeleton, and the
package-owned benchmark docs prose hook.
Without the flag none of these are written, so a package that does not track
performance carries no benchmark machinery at all.

## The `benchmark/` suite

`scaffold` lays down a `benchmark/` directory.

- `benchmark/benchmarks.jl` (package-owned) defines the suite.
  It builds a BenchmarkTools `BenchmarkGroup` named `SUITE`, which the runners
  consume.
- `benchmark/run.jl` (managed) runs this checkout's suite and saves the results
  to JSON through the shared benchmark harness.
- `benchmark/compare.jl` (managed) builds the base-versus-head comparison
  comment.
- `benchmark/Project.toml` (package-owned) is the benchmark environment.

You write the measurements in `benchmarks.jl` and leave the runners alone.
Group evaluation benchmarks under their own keys, and put AD-gradient
benchmarks under an `"AD gradients"` group so the comparison comment folds them
into a compact per-scenario-by-backend matrix.

```julia
const SUITE = BenchmarkGroup()
SUITE["Evaluation"]["logpdf"] = @benchmarkable logpdf(d, x)
SUITE["AD gradients"]["logpdf"]["ForwardDiff"] = @benchmarkable gradient(...)
```

Run the suite locally with `julia --project=benchmark benchmark/run.jl`.

## Two workflows, disjoint triggers

The kit ships two benchmark workflows that never run on the same event.

### PR comparison

`benchmark.yaml` runs on pull requests that touch `src`, `ext`, `benchmark`, or
the AD fixtures, and posts a single comparison comment.
It benchmarks each revision in its own job, so the base branch runs the base
branch's sources and fixtures while the pull request runs its own.
That separation is what lets the AD-gradient benchmarks be compared across an
API change, where staging one set of fixtures against both revisions could not.
It also keeps a single runner from loading two heavy AD stacks at once.

The comparison job builds the comment through
`EpiAwarePackageTools.Benchmarks.compare_comment`, which produces a bucketed
summary plus collapsed detail tables split into evaluation and AD-gradient
sections.
The comment carries a marker so a re-run updates the existing comment rather
than posting a new one.

### Performance history

`benchmark-history.yaml` runs on pushes to `main` and on tags, and accumulates
a timeline rather than posting a comment.
It benchmarks the last few tagged releases plus the pushed commit with
AirspeedVelocity, renders a per-benchmark plot and a ratio table, and deploys
them to a dedicated `benchmarks` branch under `history/`.

The history deploy is deliberately separate from the documentation deploy.
Documenter force-pushes the `gh-pages` branch on every docs build, so writing
the timeline there would clobber it;
a dedicated branch keeps the two independent.

The rendered timeline is spliced into the documentation site's benchmark page.
That page combines a managed skeleton, your package-owned prose in
`docs/benchmarks.md`, and the rendered performance history, so the narrative you
write sits above the accumulated timeline.

### Unregistered `[sources]` dependencies

Both benchmark workflows install the package as a *dependency*, and Pkg honours
only the active project's `[sources]` section.
A package that pins a dependency there by git url and revision because that
dependency is not yet registered (an EpiAware package in its pre-registration
window, say) would therefore fail to resolve it, with `has no known versions!`.
AirspeedVelocity's `benchpkg` hits the same wall in the temp project it builds
per revision, which is why the existing staging trick for *path* sources cannot
help: this is registry-level absence, not a relative path.

Both workflows head this off with a step that calls
`EpiAwarePackageTools.Benchmarks.bootstrap_sources_registry`.
It reads the package's `[sources]`, clones each unregistered git pin at its
revision, and registers it into a throwaway `LocalRegistry` in the runner's
depot.
Registries, unlike sources, are depot-level, so the dependency then resolves by
name in every environment on that runner, including benchpkg's temp projects.
Nothing is pushed anywhere and the registry dies with the runner.

The step is a no-op for a package whose `[sources]` are all path pins or
already-registered names: nothing is cloned and no registry is created.
It needs no configuration, and it retires itself as dependencies reach the
General registry.

## Adding scenarios

Add benchmarks by extending `SUITE` in `benchmark/benchmarks.jl`.
New evaluation measurements go under an evaluation group;
new gradient measurements go under the `"AD gradients"` group so they fold into
the comparison matrix.
Because the comparison workflow benchmarks each revision from its own checkout,
a new scenario is measured on both sides of a pull request automatically once it
is on the pull request branch.
Describe what the suite covers and how to read the timeline in
`docs/benchmarks.md`, which is spliced verbatim into the generated benchmark
page.
