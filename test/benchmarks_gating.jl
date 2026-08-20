# Benchmarks are opt-in: a fresh scaffold writes no benchmark CI, suite, or docs
# page; `benchmarks = true` writes them all. `update` detects an adopter's state
# from the managed benchmark workflows so a resync preserves an opt-in instead
# of stripping it (the #72 idempotence trap), and bakes the value into the
# scheduled template-sync call.

@testitem "benchmarks opt-in gating + idempotence" begin
    using Test
    using EpiAwarePackageTools
    using EpiAwarePackageTools: _detect_benchmarks, update

    # A minimal package root so placeholder substitution has values to resolve.
    function _fake_pkg(
            dir; name = "FakePkg",
            authors = "[\"Ada Lovelace\", \"FakeOrg contributors\"]"
        )
        write(
            joinpath(dir, "Project.toml"),
            "name = \"$name\"\n" *
                "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                "authors = $authors\n"
        )
        return dir
    end

    # The files that exist only when benchmarks are enabled.
    const BENCH_FILES = [
        ".github/workflows/benchmark.yaml",
        ".github/workflows/benchmark-history.yaml",
        "benchmark/run.jl",
        "benchmark/compare.jl",
        "benchmark/Project.toml",
        "benchmark/benchmarks.jl",
        "docs/benchmarks.md",
    ]

    @testset "benchmarks = false writes no benchmark files or page" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; benchmarks = false)
            for f in BENCH_FILES
                @test !isfile(joinpath(dir, f))
            end
            # No performance-history nav entry; the docs opt out via
            # BENCHMARK_PAGE. A "Benchmarks" entry may still exist pointing at
            # the AD-comparison page instead (`ad = true` is the scaffold
            # default, #299/#305) -- that is not this test's concern. Scope
            # to the substituted `pages` array itself, not the header
            # comment above it (which mentions both labels in prose).
            pages = read(joinpath(dir, "docs/pages.jl"), String)
            arr = pages[findfirst("pages = [", pages)[1]:end]
            @test !occursin("benchmarks/over-time.md", arr)
            @test !occursin("\"Performance over time\"", arr)
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
            # `ad = true` is the scaffold default, so the Benchmarks group
            # nests the performance-over-time page alongside AD comparison
            # (#299/#305) rather than pointing at "benchmarks.md" alone.
            pages = read(joinpath(dir, "docs/pages.jl"), String)
            @test occursin(
                "\"Performance over time\" => \"benchmarks/over-time.md\"",
                pages
            )
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
            # its template-sync.yaml carries the baked value) must not strip the
            # benchmark infra: detection recovers the enabled state.
            update(dir)
            update(dir)
            @test isfile(joinpath(dir, ".github/workflows/benchmark.yaml"))
            @test isfile(
                joinpath(
                    dir,
                    ".github/workflows/benchmark-history.yaml"
                )
            )
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
            sync = read(
                joinpath(
                    dir,
                    ".github/workflows/template-sync.yaml"
                ), String
            )
            @test occursin("benchmarks = true", sync)
        end
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; benchmarks = false)
            sync = read(
                joinpath(
                    dir,
                    ".github/workflows/template-sync.yaml"
                ), String
            )
            @test occursin("benchmarks = false", sync)
        end
    end

    @testset "_strip_benchmark_nav drops a leaf whose page is missing" begin
        strip = EpiAwarePackageTools.DocsBuild._strip_benchmark_nav
        mktempdir() do dir
            src = mkpath(joinpath(dir, "src"))
            mkpath(joinpath(src, "lib"))
            write(joinpath(src, "lib", "public.md"), "x")
            write(joinpath(src, "lib", "internals.md"), "x")
            # No `benchmarks/over-time.md` on disk -- the leaf is dangling.
            pages = [
                "Home" => "index.md",
                "API reference" => [
                    "Public API" => "lib/public.md",
                    "Internal API" => "lib/internals.md",
                ],
                "Benchmarks" => "benchmarks/over-time.md",
            ]
            out = strip(pages, src)
            @test length(out) == 2
            @test !any(
                e -> e isa Pair && e.second == "benchmarks/over-time.md", out
            )
            # A non-benchmark tree is returned unchanged in shape.
            @test out[1] == ("Home" => "index.md")
        end
    end

    @testset "_strip_benchmark_nav keeps entries whose pages exist (#305)" begin
        strip = EpiAwarePackageTools.DocsBuild._strip_benchmark_nav
        mktempdir() do dir
            src = mkpath(joinpath(dir, "src"))
            bdir = mkpath(joinpath(src, "benchmarks"))
            write(joinpath(bdir, "over-time.md"), "x")
            write(joinpath(bdir, "ad-comparison.md"), "x")
            pages = [
                "Home" => "index.md",
                "Benchmarks" => [
                    "Performance over time" => "benchmarks/over-time.md",
                    "AD comparison" => "benchmarks/ad-comparison.md",
                ],
            ]
            out = strip(pages, src)
            @test length(out) == 2
            @test out[2] == (
                "Benchmarks" => [
                    "Performance over time" => "benchmarks/over-time.md",
                    "AD comparison" => "benchmarks/ad-comparison.md",
                ]
            )
        end
    end

    @testset "_strip_benchmark_nav drops an emptied group (#305)" begin
        strip = EpiAwarePackageTools.DocsBuild._strip_benchmark_nav
        mktempdir() do dir
            src = mkpath(joinpath(dir, "src"))
            # `over-time.md` never written under this src_dir.
            pages = [
                "Home" => "index.md",
                "Benchmarks" => [
                    "Performance over time" => "benchmarks/over-time.md",
                ],
            ]
            out = strip(pages, src)
            @test length(out) == 1
            @test out[1] == ("Home" => "index.md")
        end
    end

    @testset "_strip_benchmark_nav drops a pre-#305 benchmarks.md leaf" begin
        # An adopter who synced #305 but has not yet edited their
        # package-owned `pages.jl` still names the performance-history page
        # `benchmarks.md`, which the build now writes as
        # `benchmarks/over-time.md`. Documenter hard-errors on a nav entry
        # with no page ("'benchmarks.md' is not an existing page!"), so
        # leaving that leaf would break their docs build outright rather
        # than costing them a sidebar entry.
        strip = EpiAwarePackageTools.DocsBuild._strip_benchmark_nav
        mktempdir() do dir
            src = mkpath(joinpath(dir, "src"))
            bdir = mkpath(joinpath(src, "benchmarks"))
            write(joinpath(bdir, "over-time.md"), "x")
            # The flat pre-#305 shape.
            flat = strip(
                ["Home" => "index.md", "Benchmarks" => "benchmarks.md"], src
            )
            @test flat == ["Home" => "index.md"]
            # And the same stale target inside a group, alongside a sibling
            # whose page does exist.
            grouped = strip(
                [
                    "Home" => "index.md",
                    "Benchmarks" => [
                        "Performance over time" => "benchmarks.md",
                        "AD comparison" => "benchmarks/over-time.md",
                    ],
                ], src
            )
            @test grouped[2] == (
                "Benchmarks" =>
                    ["AD comparison" => "benchmarks/over-time.md"]
            )
        end
        # A package that genuinely still writes `src/benchmarks.md` keeps it:
        # the judgement is the page on disk, never the path's shape.
        mktempdir() do dir
            src = mkpath(joinpath(dir, "src"))
            write(joinpath(src, "benchmarks.md"), "x")
            pages = ["Home" => "index.md", "Benchmarks" => "benchmarks.md"]
            @test strip(pages, src) == pages
        end
    end

    @testset "_strip_benchmark_nav self-heals a mixed remediation (#305)" begin
        # Mixed remediation: an `ad = true` adopter added the "AD
        # comparison" nav entry per `_benchmarks_nav_gap`'s warning, but
        # never added `ad-comparison.jl` to `HEAVY_BENCHMARKS` in
        # `docs/docs_config.jl`, so the page itself is never rendered. The
        # nav must not carry a dangling entry regardless of which of the
        # two independent `update` warnings was acted on.
        strip = EpiAwarePackageTools.DocsBuild._strip_benchmark_nav
        mktempdir() do dir
            src = mkpath(joinpath(dir, "src"))
            bdir = mkpath(joinpath(src, "benchmarks"))
            write(joinpath(bdir, "over-time.md"), "x")
            # ad-comparison.md deliberately absent.
            pages = [
                "Home" => "index.md",
                "Benchmarks" => [
                    "Performance over time" => "benchmarks/over-time.md",
                    "AD comparison" => "benchmarks/ad-comparison.md",
                ],
            ]
            out = strip(pages, src)
            @test out[2] == (
                "Benchmarks" =>
                    ["Performance over time" => "benchmarks/over-time.md"]
            )
        end
        # And the reverse: `docs_config.jl` was fixed (the page renders)
        # but `pages.jl` was never given the nav entry at all -- nothing to
        # strip, the entry simply never existed in `pages`, which is
        # already exercised by the "keeps a sibling" case above.
    end

    @testset "benchmark-history parked triggers survive sync (#153)" begin
        using EpiAwarePackageTools: _detect_benchmark_history_parked
        hist = ".github/workflows/benchmark-history.yaml"
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; benchmarks = true)
            wf = joinpath(dir, hist)
            # A fresh scaffold ships the full push/tags/dispatch triggers.
            @test !_detect_benchmark_history_parked(dir)
            txt = read(wf, String)
            @test occursin("push:", txt)
            @test occursin("tags: ['v*']", txt)

            # Park the workflow (as an unregistered adopter does): drop the
            # push/tags triggers, keeping only workflow_dispatch.
            parked = replace(
                txt,
                r"on:\n.*?\n  workflow_dispatch:"s => "on:\n  workflow_dispatch:"
            )
            write(wf, parked)
            @test _detect_benchmark_history_parked(dir)

            # A bare resync must preserve the parked state, not re-enable the
            # permanently-failing push/tag history run.
            update(dir)
            synced = read(wf, String)
            @test _detect_benchmark_history_parked(dir)
            @test !occursin(r"(?m)^  push:", synced)
            @test occursin("workflow_dispatch:", synced)
            @test occursin("parked until this package is registered", synced)

            # Self-heal: once the package removes the park (restores push), the
            # next sync keeps the full triggers.
            write(wf, txt)
            update(dir)
            @test !_detect_benchmark_history_parked(dir)
            @test occursin(r"(?m)^  push:", read(wf, String))
        end
    end
end

# The benchmark suite is what produces the gradient numbers the AD-comparison
# docs page renders, so an AD package is scaffolded with that group already
# measuring rather than with a commented example of one.
@testitem "the seeded benchmark suite measures AD gradients" begin
    using Test
    using Pkg
    using EpiAwarePackageTools

    function _fake_pkg(dir)
        write(
            joinpath(dir, "Project.toml"),
            "name = \"Wombat\"\n" *
                "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                "authors = [\"Ada Lovelace\"]\n"
        )
        return dir
    end

    _parses(txt) = !any(
        e -> e isa Expr && e.head in (:error, :incomplete),
        Meta.parseall(txt).args
    )

    @testset "an AD package gets a live gradient group" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; ad = true, benchmarks = true)
            suite = read(joinpath(dir, "benchmark", "benchmarks.jl"), String)
            # Assigned, not shown as a comment: the group the page reads and
            # the pull request comment folds into its matrix.
            @test occursin("SUITE[\"AD gradients\"] = grad", suite)
            @test occursin("DI.prepare_gradient(", suite)
            @test occursin("for entry in ADFixtures.backends()", suite)
            @test !occursin("{{", suite)
            @test _parses(suite)

            # ...and the environment it measures in resolves those names.
            proj = joinpath(dir, "benchmark", "Project.toml")
            deps = Pkg.TOML.parsefile(proj)
            @test haskey(deps["deps"], "ADFixtures")
            @test haskey(deps["deps"], "DifferentiationInterface")
            @test deps["sources"]["ADFixtures"]["path"] ==
                "../test/ADFixtures"
            @test haskey(deps["compat"], "DifferentiationInterface")
            @test !occursin("{{", read(proj, String))
            @test endswith(read(proj, String), "\n")
        end
    end

    @testset "a non-AD package gets neither" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; ad = false, benchmarks = true)
            suite = read(joinpath(dir, "benchmark", "benchmarks.jl"), String)
            @test !occursin("ADFixtures", suite)
            @test !occursin(r"(?m)^SUITE\[\"AD gradients\"\]", suite)
            @test _parses(suite)
            proj = joinpath(dir, "benchmark", "Project.toml")
            env = Pkg.TOML.parsefile(proj)
            @test !haskey(env["deps"], "ADFixtures")
            @test !haskey(env["deps"], "DifferentiationInterface")
            @test !haskey(env["sources"], "ADFixtures")
            @test endswith(read(proj, String), "\n")
        end
    end
end

# What lands on the `benchmarks` branch, and from which events. Only pushes to
# `main`, tags and a manual dispatch write it, and each deploy replaces the
# published folder, so nothing pull-request-scoped accumulates there and no
# reaping workflow is needed. A trigger added here would change that.
@testitem "only non-PR events publish to the benchmarks branch" begin
    using Test
    using EpiAwarePackageTools

    mktempdir() do dir
        write(
            joinpath(dir, "Project.toml"),
            "name = \"Wombat\"\n" *
                "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                "authors = [\"Ada Lovelace\"]\n"
        )
        scaffold(dir; benchmarks = true)
        wf = joinpath(dir, ".github", "workflows")

        history = read(joinpath(wf, "benchmark-history.yaml"), String)
        stop = findfirst("permissions:", history)[1] - 1
        triggers = history[findfirst("on:", history)[1]:stop]
        @test !occursin("pull_request", triggers)
        @test occursin("branches: [main]", triggers)
        # Each deploy replaces the published folder rather than adding to it.
        @test occursin("clean: true", history)
        # Concurrent writers queue rather than clobber one another.
        @test occursin("group: benchmark-history-deploy", history)
        @test occursin("cancel-in-progress: false", history)
        # The revision this run measured, named so a checkout can find it.
        @test occursin("public/results/latest.json", history)

        # The pull request workflow keeps its results as job artifacts and
        # posts a comment; it deploys nothing anywhere.
        comparison = read(joinpath(wf, "benchmark.yaml"), String)
        @test occursin("pull_request:", comparison)
        @test occursin("actions/upload-artifact", comparison)
        @test !occursin("github-pages-deploy-action", comparison)
        @test !occursin("branch: benchmarks", comparison)
    end
end
