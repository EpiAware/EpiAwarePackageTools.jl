#src MANAGED by EpiAwarePackageTools.scaffold — do not edit by hand.
#src Split out of `ad-backends.jl` (#299): the backend-support/how-to-choose
#src narrative lives there, under Tutorials; this page is the cost report,
#src under the Benchmarks nav, alongside the performance-history page (when
#src the package has one). The page body is re-applied on every update so it
#src stays kit-current; everything package-specific it reports (scenarios,
#src backends, broken/skip declarations) is read at docs-build time from the
#src package-owned `test/ADFixtures` registry, so declare a broken scenario
#src there, never here. If this page cannot execute for this package, park it
#src via `FORCE_STUB_TUTORIALS` in `docs/docs_config.jl` instead of editing it.

md"""
# [AD backend comparison](@id ad-comparison)

What each [AD backend](@ref ad-backends) costs on {{PACKAGE}}.jl's shared
AD scenario set, so a decision between backends can be made from numbers
rather than the general pattern alone.
See the [AD backends](@ref ad-backends) page for which backends are
supported, how to configure them, and how to debug one that misbehaves.

## Packages used
"""

md"""
```@raw html
<details><summary>Show setup code</summary>
```
"""

using {{PACKAGE}}
using ADFixtures
import DifferentiationInterfaceTest as DIT
## DIT 0.11 dropped its Chairmarks dependency; `benchmark_differentiation`
## needs it loaded explicitly to resolve `run_benchmark!`.
using Chairmarks
using DataFramesMeta
using Statistics
using CairoMakie
using AlgebraOfGraphics

CairoMakie.activate!(type = "png", px_per_unit = 2)
set_theme!(theme_latexfonts(); fontsize = 14)

backend_entries = ADFixtures.backends()
scenario_list = ADFixtures.scenarios()

## The registry's optional bookkeeping accessors (see the ADRegistry
## contract): a missing accessor means no broken or skipped scenarios.
function _optional(name, default)
    isdefined(ADFixtures, name) ? getfield(ADFixtures, name)() : default
end
global_broken = Set(String.(_optional(:broken_scenario_names, String[])))
backend_broken = _optional(
    :backend_broken_scenarios, Dict{String, Set{String}}())
backend_skip = _optional(
    :backend_skip_scenarios, Dict{String, Set{String}}());

md"""
```@raw html
</details>
```
"""

md"""
## Benchmark

`DifferentiationInterfaceTest.benchmark_differentiation` runs every
(backend, scenario) pair the registry supports.
Combinations declared broken or skipped in the registry are excluded from
their backend's rows, so they show up as reduced scenario coverage here
and as named entries in the [AD backends](@ref ad-backends) support table,
rather than as timings of gradients that are wrong or crash.
The figures are the prepared per-call cost.
DifferentiationInterface prepares each backend once, recording a tape for
ReverseDiff and compiling a rule for Enzyme and Mooncake, and we time the
reused operator, so that one-off preparation is excluded.
This matches repeated use such as an MCMC run, where preparation is
amortised over many gradient calls.
Each backend's time and allocations are then divided by the ForwardDiff
value on the same scenario, so ForwardDiff sits at 1.0 by construction;
values below 1.0 are faster (or lighter), above 1.0 slower (or heavier).
Timings use short per-measurement budgets so the page stays cheap to
build; treat small differences as indicative rather than exact.
"""

md"""
### Summary

Geometric mean of the relative cost across the scenarios each backend can
handle. `Scenarios` reports coverage, since a partial backend averages
only over the scenarios it differentiates.
"""

md"""
```@raw html
<details><summary>Show benchmark code</summary>
```
"""

bench_parts = map(backend_entries) do entry
    excluded = union(global_broken,
        get(backend_broken, entry.name, Set{String}()),
        get(backend_skip, entry.name, Set{String}()))
    scens = filter(s -> !(s.name in excluded), scenario_list)
    part = DataFrame(DIT.benchmark_differentiation(
        [entry.backend], scens;
        logging = false,
        benchmark_test = false,
        benchmark_seconds = 0.5))
    ## Label rows with the registry's backend name, which distinguishes
    ## configurations (e.g. Enzyme forward vs reverse) that share a package.
    part[!, :backend_label] .= entry.name
    part
end
raw_bench = vcat(bench_parts...)

bench_long = @chain raw_bench begin
    @rsubset :operator == ^(:gradient)
    @rtransform begin
        :backend = :backend_label
        :scenario = :scenario.name
        :time_us = :time * 1e6
        :bytes_kb = :bytes / 1024
    end
    @rsubset isfinite(:time_us) && isfinite(:bytes_kb)
    @select :backend :scenario :time_us :bytes_kb
end;

## The baseline every cost is divided by: ForwardDiff when the registry has
## it (the org standard), otherwise the registry's first backend.
baseline = any(e -> e.name == "ForwardDiff", backend_entries) ?
           "ForwardDiff" : first(backend_entries).name

ref = @chain bench_long begin
    @rsubset :backend == baseline
    @select :scenario :ref_time=:time_us :ref_bytes=:bytes_kb
end

rel = @chain bench_long begin
    leftjoin(ref, on = :scenario)
    @rsubset !ismissing(:ref_time) && !ismissing(:ref_bytes)
    @rtransform begin
        :rel_time = :time_us / :ref_time
        :rel_bytes = :bytes_kb / :ref_bytes
    end
end;

## Geometric mean over positive values; guards against a zero-allocation
## scenario sending `log` to -Inf.
function geomean(x)
    pos = filter(>(0), x)
    isempty(pos) ? NaN : exp(mean(log.(pos)))
end

n_total = length(scenario_list)

summary_table = @chain rel begin
    @by :backend begin
        :rel_time = round(geomean(:rel_time); digits = 2)
        :rel_bytes = round(geomean(:rel_bytes); digits = 2)
        :scenarios = "$(length(:scenario))/$(n_total)"
    end
    @orderby :rel_time
    rename(
        :backend => "Backend",
        :rel_time => "Relative time",
        :rel_bytes => "Relative allocations",
        :scenarios => "Scenarios")
end;

md"""
```@raw html
</details>
```
"""

summary_table

md"""
### Spread across scenarios

Each box summarises a backend's relative cost across the scenario set, on
a log scale so speed-ups and slow-downs are symmetric around the baseline
at 1.0.
"""

md"""
```@raw html
<details><summary>Show plotting code</summary>
```
"""

plot_df = @chain rel begin
    stack([:rel_time, :rel_bytes],
        variable_name = :metric, value_name = :value)
    @rsubset isfinite(:value) && :value > 0
    @rtransform begin
        :metric = :metric == "rel_time" ? "Relative time" :
                  "Relative allocations"
        :family = first(split(:backend))
        :mode = occursin("reverse", lowercase(:backend)) ? "reverse" :
                "forward"
    end
end

## Order the facets time-then-allocations.
metric_order = sorter(["Relative time", "Relative allocations"])

fig_relative = draw(
    data(plot_df) *
    mapping(
        :backend => "",
        :value => "Cost relative to $baseline",
        col = :metric => metric_order) *
    visual(BoxPlot);
    figure = (size = (1200, 500),),
    axis = (yscale = log10, xticklabelrotation = pi / 4),
    facet = (; linkyaxes = :none)
);

md"""
```@raw html
</details>
```
"""

fig_relative

md"""
### Per scenario

The same data with one point per scenario, so individual outliers show
rather than being summarised.
Scenarios on the horizontal axis, relative cost on the vertical axis (log
scale), backends by colour, faceted by metric.
"""

md"""
```@raw html
<details><summary>Show plotting code</summary>
```
"""

fig_scenarios = draw(
    data(plot_df) *
    mapping(
        :scenario => "",
        :value => "Cost relative to $baseline",
        color = :family => "Backend family",
        marker = :mode => "Mode",
        col = :metric => metric_order) *
    visual(Scatter, markersize = 11);
    figure = (size = (1600, 800),),
    axis = (yscale = log10, xticklabelrotation = pi / 4),
    facet = (; linkyaxes = :none)
);

md"""
```@raw html
</details>
```
"""

fig_scenarios

md"""
The full long-format result is available as `raw_bench` if you want GC
fraction, compile fraction, the `value_and_gradient` rows, or absolute
timings.

## Reproducing this page

The numbers above are measured on the docs-build machine, so they reflect
that CPU.
To regenerate locally:

```
task docs
```

or, equivalently:

```
julia --project=docs docs/make.jl
```

## See also

- The [AD backends](@ref ad-backends) page explains what each backend is,
  how to configure it, and how to debug one that misbehaves.
- `test/ADFixtures` is the package-owned registry this page renders from;
  scenarios, backends, and broken/skip declarations all live there.
- The shared harness and the `ADRegistry` contract live in
  [EpiAwarePackageTools.jl](https://github.com/EpiAware/EpiAwarePackageTools.jl).
"""
