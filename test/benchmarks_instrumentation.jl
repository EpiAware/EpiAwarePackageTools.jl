# Code-coverage counters make the code they instrument slower than the code a
# benchmark is meant to describe, so a job that publishes timings runs every
# measuring process uninstrumented. The managed benchmark workflows therefore
# carry no coverage flag, no coverage upload, and none of the julia-actions
# steps that add a coverage flag of their own; the one managed caller that does
# instrument a run publishes no timings.

@testitem "benchmark workflows measure uninstrumented" begin
    using Test
    using EpiAwarePackageTools: _templates_dir

    workflows = joinpath(_templates_dir(), ".github", "workflows")
    template(name) = read(joinpath(workflows, name), String)

    # The managed workflows that run a benchmark suite and publish what it
    # measured: the base-vs-head PR comment and the persistent timeline.
    measuring = ["benchmark.yaml", "benchmark-history.yaml"]

    @testset "$name runs no instrumented step" for name in measuring
        body = template(name)
        @test !occursin("--code-coverage", body)
        @test !occursin(r"Pkg\.test\([^)]*coverage", body)
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

    # `tests.yml`'s `upload_coverage` input makes the test caller the one
    # managed workflow that instruments a full suite run, so it is the caller
    # that must publish no timings. Its own comments name the benchmark
    # environment, so match on the directives rather than the whole file.
    @testset "the coverage-measuring caller runs no benchmark" begin
        body = template("test.yaml")
        @test occursin("upload_coverage: true", body)
        directives = filter(
            line -> !startswith(strip(line), "#"), split(body, "\n")
        )
        @test !any(line -> occursin("benchpkg", line), directives)
        @test !any(line -> occursin("benchmark", line), directives)
    end
end
