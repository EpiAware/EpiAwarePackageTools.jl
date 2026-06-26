using Test
using EpiAwarePackageTools
# Loaded at top level so the `@benchmarkable` macro used in `benchmarks.jl`
# resolves when that file is parsed (macros expand at include time, before the
# testset body runs).
using BenchmarkTools

@testset "EpiAwarePackageTools" begin
    include("quality.jl")
    include("qa.jl")
    include("scaffold.jl")
    include("ad_harness.jl")
    include("benchmarks.jl")
end
