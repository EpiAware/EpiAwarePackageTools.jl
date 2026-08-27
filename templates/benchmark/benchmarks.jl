# PACKAGE-OWNED — scaffold writes this once and never overwrites it.
#
# Benchmark suite definition. Build a BenchmarkTools `BenchmarkGroup` named
# `SUITE`; the managed `run.jl` / `compare.jl` consume it. Put AD-gradient
# benchmarks under the `"AD gradients"` group so the comparison comment folds
# them into a compact per-(scenario x backend) matrix. Edit freely.

using BenchmarkTools
using {{PACKAGE}}

const SUITE = BenchmarkGroup()

# Example evaluation benchmark — replace with the package's own:
# SUITE["Evaluation"]["example"] = @benchmarkable sum(rand(100))
{{AD_BENCH_SUITE}}
