# Unit tests for the published AD benchmark reader: the data path the
# scaffolded AD-comparison docs page renders from, exercised here rather than
# only through a docs build.

@testsnippet ADResultFixtures begin
    using Test
    using EpiAwarePackageTools

    # One leaf of a published benchmark results file: a times vector in
    # nanoseconds and a scalar memory in bytes, the shape AirspeedVelocity
    # writes. Built as JSON text rather than through a serialiser, so the
    # fixture states the on-disk contract the reader is held to.
    leaf(time_ns, bytes) = string(
        """{"times": [""", time_ns, ", ", time_ns, """], "gctimes": [0.0], """,
        """"memory": """, bytes, """, "allocs": 3}"""
    )

    group(pairs) = string(
        """{"data": {""",
        join(("\"" * k * "\": " * v for (k, v) in pairs), ", "),
        "}}"
    )

    # A whole results file: `gradients` maps scenario name to its
    # `backend => leaf` mapping, and `extra` is anything sitting outside the
    # gradient group.
    function write_results(
            path, gradients; extra = Pair{String, String}[],
            ad_group = "AD gradients"
        )
        ad = group([n => group(b) for (n, b) in gradients])
        mkpath(dirname(path))
        write(path, group(vcat([ad_group => ad], collect(extra))))
        return path
    end

    # `touch` cannot set a time, and the loader picks the newest file by
    # modification time, so the tests stamp files rather than sleeping between
    # writes and hoping the filesystem's granularity is fine enough.
    function set_mtime(path, t)
        f = Base.Filesystem.open(path, Base.Filesystem.JL_O_RDWR)
        try
            Base.Filesystem.futime(f, t, t)
        finally
            close(f)
        end
        return path
    end
end

@testitem "AD benchmarks: a complete run" setup = [ADResultFixtures] begin
    using EpiAwarePackageTools: load_ad_benchmarks, ad_benchmark_note

    dir = mktempdir()
    write_results(
        joinpath(dir, "results_Pkg@abc.json"),
        Dict(
            "AR" => Dict(
                "ForwardDiff" => leaf(1000.0, 2048),
                "Mooncake" => leaf(3000.0, 4096)
            ),
            "MA" => Dict("ForwardDiff" => leaf(2000.0, 1024))
        )
    )

    r = load_ad_benchmarks(dir, ["ForwardDiff", "Mooncake"])
    @test r.backends == ["ForwardDiff", "Mooncake"]
    @test isempty(r.missing_backends)
    @test length(r.rows) == 3
    ar = only(filter(x -> x.backend == "Mooncake", r.rows))
    @test ar.scenario == "AR"
    @test ar.time_us ≈ 3.0
    @test ar.bytes_kb ≈ 4.0
    # Rows follow the expected backend order, not the file's key order.
    @test first(r.rows).backend == "ForwardDiff"
    @test ad_benchmark_note(r) == ""
end

@testitem "AD benchmarks: non-gradient benchmarks are ignored" setup = [
    ADResultFixtures,
] begin
    using EpiAwarePackageTools: load_ad_benchmarks

    file = joinpath(mktempdir(), "results.json")
    write_results(
        file, Dict("AR" => Dict("ForwardDiff" => leaf(1000.0, 2048)));
        extra = Dict(
            "Evaluation" => group(Dict("logpdf" => leaf(50.0, 16)))
        )
    )

    r = load_ad_benchmarks(file, ["ForwardDiff"])
    @test [x.scenario for x in r.rows] == ["AR"]
end

@testitem "AD benchmarks: a partial run is reported" setup = [
    ADResultFixtures,
] begin
    using EpiAwarePackageTools: load_ad_benchmarks, ad_benchmark_note

    file = joinpath(mktempdir(), "results.json")
    write_results(
        file, Dict("AR" => Dict("ForwardDiff" => leaf(1000.0, 2048)))
    )

    r = load_ad_benchmarks(file, ["ForwardDiff", "Enzyme reverse", "Mooncake"])
    @test r.backends == ["ForwardDiff"]
    @test r.missing_backends == ["Enzyme reverse", "Mooncake"]
    note = ad_benchmark_note(r)
    @test occursin("Partial measurements", note)
    @test occursin("Enzyme reverse and Mooncake", note)
    @test occursin("they are", note)
end

@testitem "AD benchmarks: nothing to read is not fatal" setup = [
    ADResultFixtures,
] begin
    using EpiAwarePackageTools: load_ad_benchmarks, ad_benchmark_note

    for source in [joinpath(mktempdir(), "gone"), mktempdir()]
        r = load_ad_benchmarks(source, ["ForwardDiff"])
        @test isempty(r.rows)
        @test r.missing_backends == ["ForwardDiff"]
        @test occursin("No measurements for this build", ad_benchmark_note(r))
    end
end

@testitem "AD benchmarks: an unreadable file is not fatal" setup = [
    ADResultFixtures,
] begin
    using EpiAwarePackageTools: load_ad_benchmarks

    file = joinpath(mktempdir(), "results.json")
    write(file, "not json at all")
    r = load_ad_benchmarks(file, ["ForwardDiff"])
    @test isempty(r.rows)
    @test r.missing_backends == ["ForwardDiff"]
end

@testitem "AD benchmarks: unusable leaves are dropped" setup = [
    ADResultFixtures,
] begin
    using EpiAwarePackageTools: load_ad_benchmarks

    file = joinpath(mktempdir(), "results.json")
    write_results(
        file,
        Dict(
            "AR" => Dict(
                "ForwardDiff" => leaf(1000.0, 2048),
                # No memory recorded, so there is no allocation figure to
                # divide by the baseline's.
                "Zygote" => "{\"times\": [1000.0]}",
                # Measured but with no timing samples.
                "Enzyme reverse" => "{\"times\": [], \"memory\": 16}"
            )
        )
    )

    r = load_ad_benchmarks(file, ["ForwardDiff", "Zygote", "Enzyme reverse"])
    @test r.backends == ["ForwardDiff"]
    @test r.missing_backends == ["Zygote", "Enzyme reverse"]
end

@testitem "AD benchmarks: a backend outside the registry is kept" setup = [
    ADResultFixtures,
] begin
    using EpiAwarePackageTools: load_ad_benchmarks

    # A backend renamed in the registry since the run. Its numbers still show,
    # after the expected ones, rather than vanishing without a word.
    file = joinpath(mktempdir(), "results.json")
    write_results(
        file,
        Dict(
            "AR" => Dict(
                "ForwardDiff" => leaf(1000.0, 2048),
                "Enzyme" => leaf(500.0, 1024)
            )
        )
    )

    r = load_ad_benchmarks(file, ["ForwardDiff", "Enzyme reverse"])
    @test r.backends == ["ForwardDiff", "Enzyme"]
    @test r.missing_backends == ["Enzyme reverse"]
    @test last(r.rows).backend == "Enzyme"
end

@testitem "AD benchmarks: a scenario name may contain a slash" setup = [
    ADResultFixtures,
] begin
    using EpiAwarePackageTools: load_ad_benchmarks

    file = joinpath(mktempdir(), "results.json")
    write_results(
        file, Dict("AR/latent" => Dict("ForwardDiff" => leaf(1000.0, 2048)))
    )

    r = load_ad_benchmarks(file, ["ForwardDiff"])
    @test only(r.rows).scenario == "AR/latent"
end

@testitem "AD benchmarks: the newest file in a directory wins" setup = [
    ADResultFixtures,
] begin
    using EpiAwarePackageTools: load_ad_benchmarks

    # A `benchmarks` branch checkout carries one file per revision
    # benchmarked; the page wants the newest, not an average across releases.
    dir = mktempdir()
    old = write_results(
        joinpath(dir, "results_Pkg@v1.json"),
        Dict("AR" => Dict("ForwardDiff" => leaf(9000.0, 2048)))
    )
    new = write_results(
        joinpath(dir, "results_Pkg@v2.json"),
        Dict("AR" => Dict("ForwardDiff" => leaf(1000.0, 2048)))
    )
    set_mtime(old, 1.0e9)
    set_mtime(new, 1.0e9 + 60)

    r = load_ad_benchmarks(dir, ["ForwardDiff"])
    @test only(r.rows).time_us ≈ 1.0
    @test r.source == new
end

@testitem "AD benchmarks: path resolution and opt-in" begin
    using EpiAwarePackageTools.DocsBuild: ad_benchmark_results_path

    saved = get(ENV, "AD_BENCHMARK_RESULTS", nothing)
    try
        delete!(ENV, "AD_BENCHMARK_RESULTS")
        docs = mktempdir()
        # Neither configured nor in the environment: the page measures live.
        @test ad_benchmark_results_path(docs, nothing) === nothing
        @test ad_benchmark_results_path(docs, "") === nothing
        # A relative config resolves against `docs/`; an absolute one stands.
        @test ad_benchmark_results_path(docs, "bench-results") ==
            abspath(joinpath(docs, "bench-results"))
        @test ad_benchmark_results_path(docs, "/tmp/bench") == "/tmp/bench"
        # The environment overrides the config, and an empty value does not.
        ENV["AD_BENCHMARK_RESULTS"] = "/tmp/from-ci"
        @test ad_benchmark_results_path(docs, "bench-results") ==
            "/tmp/from-ci"
        ENV["AD_BENCHMARK_RESULTS"] = ""
        @test ad_benchmark_results_path(docs, nothing) === nothing
    finally
        if saved === nothing
            delete!(ENV, "AD_BENCHMARK_RESULTS")
        else
            ENV["AD_BENCHMARK_RESULTS"] = saved
        end
    end
end
