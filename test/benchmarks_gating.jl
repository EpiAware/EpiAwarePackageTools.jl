# Benchmarks are opt-in: a fresh scaffold writes NO benchmark CI, suite, or docs
# page; `benchmarks = true` writes them all. `update` detects an adopter's state
# from the managed benchmark workflows so a resync PRESERVES an opt-in instead
# of stripping it (the #72 idempotence trap), and bakes the value into the
# scheduled template-sync call.

@testitem "benchmarks opt-in gating + idempotence" begin
    using Test
    using EpiAwarePackageTools
    using EpiAwarePackageTools: _detect_benchmarks

    # A minimal package root so placeholder substitution has values to resolve.
    function _fake_pkg(dir; name = "FakePkg",
            authors = "[\"Ada Lovelace\", \"FakeOrg contributors\"]")
        write(joinpath(dir, "Project.toml"),
            "name = \"$name\"\n" *
            "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
            "authors = $authors\n")
        return dir
    end

    # The files that exist only when benchmarks are enabled.
    const BENCH_FILES = [
        ".github/workflows/benchmark.yaml",
        ".github/workflows/benchmark-history.yaml",
        "benchmark/run.jl",
        "benchmark/compare.jl",
        "benchmark/comment/comment.jl",
        "benchmark/comment/Project.toml",
        "benchmark/Project.toml",
        "benchmark/benchmarks.jl",
        "docs/benchmarks.md"]

    @testset "benchmarks = false writes no benchmark files or page" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; benchmarks = false)
            for f in BENCH_FILES
                @test !isfile(joinpath(dir, f))
            end
            # No dangling nav entry; the docs opt out via BENCHMARK_PAGE.
            pages = read(joinpath(dir, "docs/pages.jl"), String)
            @test !occursin("benchmarks.md", pages)
            cfg = read(joinpath(dir, "docs/docs_config.jl"), String)
            @test occursin("const BENCHMARK_PAGE = false", cfg)
        end
    end

    @testset "benchmarks = true writes the full benchmark surface" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; benchmarks = true)
            for f in BENCH_FILES
                @test isfile(joinpath(dir, f))
            end
            pages = read(joinpath(dir, "docs/pages.jl"), String)
            @test occursin("\"Benchmarks\" => \"benchmarks.md\"", pages)
            cfg = read(joinpath(dir, "docs/docs_config.jl"), String)
            @test occursin("const BENCHMARK_PAGE = true", cfg)
        end
    end

    @testset "default (nothing) opts out on a fresh package" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)  # no `benchmarks` kwarg -> detect -> false (fresh)
            @test !isfile(joinpath(dir, ".github/workflows/benchmark.yaml"))
            @test !isfile(joinpath(dir, "benchmark/benchmarks.jl"))
        end
    end

    @testset "_detect_benchmarks keys on the workflow files" begin
        mktempdir() do dir
            @test _detect_benchmarks(dir) == false
            _fake_pkg(dir)
            scaffold(dir; benchmarks = true)
            @test _detect_benchmarks(dir) == true
        end
    end

    @testset "update preserves an enabled adopter (no kwarg)" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; benchmarks = true)
            # A plain resync (as the scheduled sync's first run would do before
            # its template-sync.yaml carries the baked value) must NOT strip the
            # benchmark infra: detection recovers the enabled state.
            update(dir)
            update(dir)
            @test isfile(joinpath(dir, ".github/workflows/benchmark.yaml"))
            @test isfile(joinpath(dir,
                ".github/workflows/benchmark-history.yaml"))
            @test isfile(joinpath(dir, "benchmark/benchmarks.jl"))
        end
    end

    @testset "update keeps a disabled adopter disabled (no kwarg)" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; benchmarks = false)
            update(dir)
            @test !isfile(joinpath(dir, ".github/workflows/benchmark.yaml"))
            @test !isfile(joinpath(dir, "benchmark/run.jl"))
        end
    end

    @testset "template-sync bakes the benchmarks value" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; benchmarks = true)
            sync = read(joinpath(dir,
                    ".github/workflows/template-sync.yaml"), String)
            @test occursin("benchmarks = true", sync)
        end
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; benchmarks = false)
            sync = read(joinpath(dir,
                    ".github/workflows/template-sync.yaml"), String)
            @test occursin("benchmarks = false", sync)
        end
    end

    @testset "_strip_benchmark_nav drops only the benchmark leaf" begin
        strip = EpiAwarePackageTools.DocsBuild._strip_benchmark_nav
        pages = [
            "Home" => "index.md",
            "API reference" => [
                "Public API" => "lib/public.md",
                "Internal API" => "lib/internals.md"
            ],
            "Benchmarks" => "benchmarks.md"]
        out = strip(pages)
        @test length(out) == 2
        @test !any(e -> e isa Pair && e.second == "benchmarks.md", out)
        # A non-benchmark tree is returned unchanged in shape.
        @test out[1] == ("Home" => "index.md")
    end
end
