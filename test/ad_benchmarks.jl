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

    # `touch` cannot set a time, and the loader falls back to the newest file
    # by modification time, so the tests stamp files rather than sleeping
    # between writes and hoping the filesystem's granularity is fine enough.
    function set_mtime(path, t)
        f = Base.Filesystem.open(path, Base.Filesystem.JL_O_RDWR)
        try
            Base.Filesystem.futime(f, t, t)
        finally
            close(f)
        end
        return path
    end

    # A repo whose `benchmarks` branch carries a published run, laid out the
    # way `benchmark-history.yaml` deploys it.
    function benchmarks_branch_repo(gradients; extra = Pair{String, String}[])
        root = mktempdir()
        run(pipeline(`git -C $root init -q`; stderr = devnull))
        run(`git -C $root symbolic-ref HEAD refs/heads/benchmarks`)
        write_results(
            joinpath(root, "history", "results", "latest.json"), gradients;
            extra = extra
        )
        run(`git -C $root add -A`)
        run(
            pipeline(
                `git -C $root -c user.email=t@example -c user.name=T
                commit -q -m published`;
                stdout = devnull
            )
        )
        return root
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

    # Both siblings are nested as deeply as a gradient benchmark, so each
    # would split into a (scenario, backend) row on any reading that does not
    # hold them to the gradient group's exact name.
    file = joinpath(mktempdir(), "results.json")
    write_results(
        file, Dict("AR" => Dict("ForwardDiff" => leaf(1000.0, 2048)));
        extra = [
            "Evaluation" => group(
                Dict("density" => group(Dict("logpdf" => leaf(50.0, 16))))
            ),
            "AD gradients extra" => group(
                Dict("AR" => group(Dict("ForwardDiff" => leaf(70.0, 32))))
            ),
        ]
    )

    r = load_ad_benchmarks(file, ["ForwardDiff"])
    @test [(x.scenario, x.time_us) for x in r.rows] == [("AR", 1.0)]
end

@testitem "AD benchmarks: the reported time is the fastest sample" setup = [
    ADResultFixtures,
] begin
    using EpiAwarePackageTools: load_ad_benchmarks

    # The statistic `DifferentiationInterfaceTest.benchmark_differentiation`
    # reports, so the page states one whichever path filled it.
    file = joinpath(mktempdir(), "results.json")
    samples = """{"times": [4000.0, 1000.0, 9000.0], "memory": 2048}"""
    write(
        file,
        group(
            [
                "AD gradients" => group(
                    ["AR" => group(["ForwardDiff" => samples])]
                ),
            ]
        )
    )

    @test only(load_ad_benchmarks(file, ["ForwardDiff"]).rows).time_us ≈ 1.0
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
                # Recorded, but with no sample to take a time from.
                "Enzyme reverse" => "{\"times\": [], \"memory\": 16}"
            )
        )
    )

    r = load_ad_benchmarks(file, ["ForwardDiff", "Zygote", "Enzyme reverse"])
    @test r.backends == ["ForwardDiff"]
    @test r.missing_backends == ["Zygote", "Enzyme reverse"]
    @test only(r.rows).backend == "ForwardDiff"
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

@testitem "AD benchmarks: the run's own file wins in a checkout" setup = [
    ADResultFixtures,
] begin
    using EpiAwarePackageTools: load_ad_benchmarks

    # A git checkout stamps every file with the checkout time, so which file
    # is newest says nothing about which revision is newest. The run names its
    # own revision in `latest.json`, and that is what the page wants.
    dir = mktempdir()
    latest = write_results(
        joinpath(dir, "latest.json"),
        Dict("AR" => Dict("ForwardDiff" => leaf(1000.0, 2048)))
    )
    tag = write_results(
        joinpath(dir, "results_Pkg@v0.1.0.json"),
        Dict("AR" => Dict("ForwardDiff" => leaf(9000.0, 2048)))
    )
    set_mtime(latest, 1.0e9)
    set_mtime(tag, 1.0e9 + 60)

    r = load_ad_benchmarks(dir, ["ForwardDiff"])
    @test r.source == latest
    @test only(r.rows).time_us ≈ 1.0
end

@testitem "AD benchmarks: the branch supplies the numbers" setup = [
    ADResultFixtures,
] begin
    using EpiAwarePackageTools: load_ad_benchmarks
    using EpiAwarePackageTools.DocsBuild: published_ad_benchmark_results

    root = benchmarks_branch_repo(
        Dict("AR" => Dict("ForwardDiff" => leaf(1000.0, 2048)))
    )
    file = published_ad_benchmark_results(root)
    @test file !== nothing
    @test only(load_ad_benchmarks(file, ["ForwardDiff"]).rows).time_us ≈
        1.0
end

@testitem "AD benchmarks: an unpublished branch supplies nothing" setup = [
    ADResultFixtures,
] begin
    using EpiAwarePackageTools.DocsBuild: published_ad_benchmark_results

    # No repo at all, and a repo whose run measured no gradients. The second
    # leaves the page measuring live rather than rendering an empty table.
    @test published_ad_benchmark_results(mktempdir()) === nothing
    evaluation_only = benchmarks_branch_repo(
        Dict{String, Dict{String, String}}();
        extra = ["Evaluation" => group(Dict("logpdf" => leaf(50.0, 16)))]
    )
    @test published_ad_benchmark_results(evaluation_only) === nothing
end

@testitem "AD benchmarks: the exported path is scoped to one render" setup = [
    ADResultFixtures,
] begin
    using EpiAwarePackageTools.DocsBuild: _with_ad_benchmark_results

    root = benchmarks_branch_repo(
        Dict("AR" => Dict("ForwardDiff" => leaf(1000.0, 2048)))
    )
    docs = mktempdir()
    saved = get(ENV, "AD_BENCHMARK_RESULTS", nothing)
    try
        # The page's subprocess needs the variable while the render runs, and
        # a second package built in this process must resolve its own.
        delete!(ENV, "AD_BENCHMARK_RESULTS")
        during = _with_ad_benchmark_results(docs, nothing, root) do
            get(ENV, "AD_BENCHMARK_RESULTS", "")
        end
        @test !isempty(during)
        @test !haskey(ENV, "AD_BENCHMARK_RESULTS")

        # An empty value is a real setting the caller made: it opts out, and
        # it comes back rather than being replaced by the resolved path.
        ENV["AD_BENCHMARK_RESULTS"] = ""
        _with_ad_benchmark_results(docs, nothing, root) do
            nothing
        end
        @test ENV["AD_BENCHMARK_RESULTS"] == ""
    finally
        if saved === nothing
            delete!(ENV, "AD_BENCHMARK_RESULTS")
        else
            ENV["AD_BENCHMARK_RESULTS"] = saved
        end
    end
end

@testitem "AD benchmarks: the build exports a results path" setup = [
    ADResultFixtures,
] begin
    using EpiAwarePackageTools.DocsBuild: _export_ad_benchmark_results

    root = benchmarks_branch_repo(
        Dict("AR" => Dict("ForwardDiff" => leaf(1000.0, 2048)))
    )
    docs = mktempdir()
    saved = get(ENV, "AD_BENCHMARK_RESULTS", nothing)
    try
        # What the package named wins over the branch.
        delete!(ENV, "AD_BENCHMARK_RESULTS")
        @test _export_ad_benchmark_results(docs, "bench-results", root) ==
            abspath(joinpath(docs, "bench-results"))

        # With nothing named, the branch is what the page renders from, and
        # the path reaches the page's subprocess through the environment.
        delete!(ENV, "AD_BENCHMARK_RESULTS")
        path = _export_ad_benchmark_results(docs, nothing, root)
        @test path !== nothing
        @test ENV["AD_BENCHMARK_RESULTS"] == path

        # A package with no published run is left measuring live.
        delete!(ENV, "AD_BENCHMARK_RESULTS")
        @test _export_ad_benchmark_results(docs, nothing, mktempdir()) ===
            nothing
        @test !haskey(ENV, "AD_BENCHMARK_RESULTS")
    finally
        if saved === nothing
            delete!(ENV, "AD_BENCHMARK_RESULTS")
        else
            ENV["AD_BENCHMARK_RESULTS"] = saved
        end
    end
end
