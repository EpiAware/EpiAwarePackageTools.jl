using Test
using EpiAwareTestUtils
# Loaded at top level so the `@benchmarkable` macro used in `benchmarks.jl`
# resolves when that file is parsed (macros expand at include time, before the
# testset body runs).
using BenchmarkTools

@testset "EpiAwareTestUtils" begin
    include("quality.jl")
    include("ad_harness.jl")
    include("benchmarks.jl")
end
