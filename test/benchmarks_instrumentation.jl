# Code-coverage counters make the code they instrument slower than the code a
# benchmark is meant to describe, so a job that publishes timings runs every
# measuring process uninstrumented. The managed benchmark workflows therefore
# carry no coverage flag, no coverage upload, and none of the julia-actions
# steps that add a coverage flag of their own; the managed coverage caller
# measures nothing.

@testitem "benchmark workflows measure uninstrumented" begin
    using Test
    using EpiAwarePackageTools

    workflows = joinpath(
        pkgdir(EpiAwarePackageTools), "templates", ".github", "workflows"
    )
    template(name) = read(joinpath(workflows, name), String)

    # The managed workflows that run a benchmark suite and publish what it
    # measured: the base-vs-head PR comment and the persistent timeline.
    measuring = ["benchmark.yaml", "benchmark-history.yaml"]

    @testset "$name runs no instrumented step" for name in measuring
        body = template(name)
        @test !occursin("--code-coverage", body)
        @test !occursin("Pkg.test(coverage", body)
    end

    @testset "$name uploads no coverage" for name in measuring
        body = template(name)
        @test !occursin("julia-processcoverage", body)
        @test !occursin("codecov", body)
    end

    # `julia-runtest` and `julia-docdeploy` pass a coverage flag to the Julia
    # processes they start, so a measuring workflow reaches for neither even
    # though its own steps spell out no flag.
    @testset "$name starts Julia itself" for name in measuring
        body = template(name)
        @test !occursin("julia-actions/julia-runtest", body)
        @test !occursin("julia-actions/julia-docdeploy", body)
    end

    @testset "the coverage caller runs no benchmark" begin
        body = template("codecoverage.yaml")
        @test !occursin("benchpkg", body)
        @test !occursin("benchmark", body)
    end
end
