# Exercise the generic benchmark-reporting harness over small synthetic
# inputs. The point is to check the reporting logic (flattening, ratio
# formatting, comment structure) without running any real benchmarks, so the
# inputs are hand-built result dicts and a tiny BenchmarkGroup.

@testset "Benchmarks" begin
    using EpiAwarePackageTools.Benchmarks
    using EpiAwarePackageTools.Benchmarks: flatten_asv, asv_comment,
                                        compare_comment, run_suite, fmt_time, fmt_ratio
    using BenchmarkTools
    import JSON3

    @testset "fmt_time scales by magnitude" begin
        @test fmt_time(NaN) == "—"
        @test endswith(fmt_time(500.0), "ns")
        @test endswith(fmt_time(5.0e3), "μs")
        @test endswith(fmt_time(5.0e6), "ms")
        @test endswith(fmt_time(5.0e9), "s")
    end

    @testset "fmt_ratio rounds and handles NaN" begin
        @test fmt_ratio(NaN) == "—"
        @test fmt_ratio(1.23456) == "1.235"
    end

    @testset "flatten_asv reads a results file" begin
        # An AirspeedVelocity-shaped nested group: inner groups carry "data",
        # leaves carry a "times" vector in nanoseconds.
        group = Dict("data" => Dict(
            "core" => Dict("data" => Dict(
                "op" => Dict("times" => [10.0, 30.0, 20.0]))),
            "AD gradients" => Dict("data" => Dict(
                "scenarioA" => Dict("data" => Dict(
                "ForwardDiff" => Dict("times" => [100.0, 200.0])))))))
        dir = mktempdir()
        path = joinpath(dir, "results_MyPkg@abcdef123456.json")
        open(path, "w") do io
            JSON3.write(io, group)
        end

        # Full SHA on the call side, truncated rev in the filename: must match.
        flat = flatten_asv(dir, "MyPkg", "abcdef123456789")
        @test flat["core/op"] == 20.0                       # median of 3
        @test flat["AD gradients/scenarioA/ForwardDiff"] == 150.0  # median 2
    end

    @testset "asv_comment builds the three sections" begin
        base = Dict(
            "core/op" => 100.0,
            "AD gradients/scenarioA/ForwardDiff" => 100.0)
        head = Dict(
            "core/op" => 150.0,                              # 1.5x slower
            "AD gradients/scenarioA/ForwardDiff" => 80.0)    # faster
        md = asv_comment(base, head)
        @test occursin("## Benchmark results", md)
        @test occursin("Most changed", md)
        @test occursin("AD gradients (PR / base", md)
        @test occursin("scenarioA", md)
        @test occursin("ForwardDiff", md)
        @test occursin("<details>", md)
        # `core/op` moved 1.5x: it is the headline "most changed" row.
        @test occursin("core/op", md)
    end

    @testset "asv_comment ad_prefix = \"\" skips the AD matrix" begin
        base = Dict("core/op" => 100.0)
        head = Dict("core/op" => 110.0)
        md = asv_comment(base, head; ad_prefix = "")
        @test !occursin("AD gradients (PR / base", md)
        @test occursin("core/op", md)
    end

    @testset "asv_comment dir wrapper round-trips through JSON" begin
        function write_results(dir, rev, op_time)
            group = Dict("data" => Dict(
                "core" => Dict("data" => Dict(
                "op" => Dict("times" => [op_time])))))
            open(joinpath(dir, "results_MyPkg@$rev.json"), "w") do io
                JSON3.write(io, group)
            end
        end
        dir = mktempdir()
        write_results(dir, "basebase", 100.0)
        write_results(dir, "headhead", 200.0)
        md = asv_comment(dir, "MyPkg", "basebase", "headhead")
        @test occursin("core/op", md)
        @test occursin("Most changed", md)
    end

    @testset "compare_comment over two saved BenchmarkTools files" begin
        # Build two tiny suites that differ in timing only via the saved
        # trials; saving and reloading exercises the BenchmarkTools path.
        function save_group(path; op_evals)
            suite = BenchmarkTools.BenchmarkGroup()
            suite["core"]["op"] = @benchmarkable sum($(rand(op_evals)))
            tuned = BenchmarkTools.run(suite; samples = 5, seconds = 1)
            BenchmarkTools.save(path, tuned)
        end
        dir = mktempdir()
        base_f = joinpath(dir, "base.json")
        pr_f = joinpath(dir, "pr.json")
        save_group(base_f; op_evals = 10)
        save_group(pr_f; op_evals = 10)
        md = compare_comment(pr_f, base_f;
            backend_order = ["ForwardDiff"])
        @test occursin("Benchmark comparison vs base", md)
        @test occursin("<!-- benchmark-comparison -->", md)
        @test occursin("Evaluation", md)
        @test occursin("core / op", md)
        @test occursin("<details>", md)
    end

    @testset "run_suite runs and optionally saves" begin
        suite = BenchmarkTools.BenchmarkGroup()
        suite["op"] = @benchmarkable sum($(rand(10)))
        dir = mktempdir()
        out = joinpath(dir, "out.json")
        results = run_suite(suite; out_file = out, seconds = 1,
            verbose = false)
        @test results isa BenchmarkTools.BenchmarkGroup
        @test isfile(out)
        # The saved file reloads as a comparable group.
        reloaded = BenchmarkTools.load(out)[1]
        @test haskey(reloaded, "op")
    end
end
