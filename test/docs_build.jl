# Unit tests for the generic docs-build machinery (EpiAwarePackageTools.DocsBuild).
# These exercise the page generators in isolation — the heavy makedocs orchestration
# is covered by each package's own docs build, not re-run here.

@testitem "DocsBuild page generators" begin
    using Test
    using EpiAwarePackageTools
    const DB = EpiAwarePackageTools.DocsBuild

    sample_readme = """
    # Pkg <img src="docs/src/assets/logo.svg" width="150" align="right">

    <!-- badges:start -->
    | **Docs** |
    |:---:|
    | [![x](y)](z) |
    <!-- badges:end -->

    Tagline.

    ```julia
    using Pkg
    ```

    ## Keep me

    Body kept.

    ## Comparison

    | A | B |
    |---|---|
    | 1 | 2 |

    ## Drop me

    gone

    ### sub of drop

    also gone

    ## After

    stays
    """

    @testset "build_index: badges, logo, @example, rewrites" begin
        dir = mktempdir()
        readme = joinpath(dir, "README.md")
        write(readme, sample_readme)
        dest = joinpath(dir, "index.md")
        DB.build_index(; readme = readme, dest = dest, repo = "Org/Pkg.jl",
            execute = true,
            rewrites = ["Tagline." => "REWRITTEN"], strip_sections = String[])
        out = read(dest, String)
        # EditURL meta block points at the README.
        @test occursin(
            "EditURL = \"https://github.com/Org/Pkg.jl/blob/main/README.md\"",
            out)
        # Badges (between the markers) and the markers themselves are gone.
        @test !occursin("badges:start", out)
        @test !occursin("[![x](y)](z)", out)
        # Inline logo image stripped from the title, title text kept.
        @test !occursin("logo.svg", out)
        @test occursin("# Pkg", out)
        # ```julia -> ```@example readme.
        @test occursin("```@example readme", out)
        @test !occursin("```julia", out)
        # Line rewrite applied.
        @test occursin("REWRITTEN", out)
        # With no strip sections, content tables are KEPT.
        @test occursin("| 1 | 2 |", out)
    end

    @testset "build_index: named-section stripping" begin
        dir = mktempdir()
        readme = joinpath(dir, "README.md")
        write(readme, sample_readme)
        dest = joinpath(dir, "index.md")
        DB.build_index(; readme = readme, dest = dest, repo = "Org/Pkg.jl",
            strip_sections = ["Drop me"])
        out = read(dest, String)
        # The named section AND its deeper subsection are removed...
        @test !occursin("## Drop me", out)
        @test !occursin("### sub of drop", out)
        @test !occursin("also gone", out)
        # ...but a same-level heading after it ends the strip and is kept.
        @test occursin("## After", out)
        @test occursin("stays", out)
        # Earlier sections and the comparison table are untouched.
        @test occursin("## Keep me", out)
        @test occursin("| 1 | 2 |", out)
    end

    @testset "build_index: execute=false leaves ```julia" begin
        dir = mktempdir()
        readme = joinpath(dir, "README.md")
        write(readme, sample_readme)
        dest = joinpath(dir, "index.md")
        DB.build_index(; readme = readme, dest = dest, repo = "Org/Pkg.jl",
            execute = false)
        out = read(dest, String)
        @test occursin("```julia", out)
        @test !occursin("@example readme", out)
    end

    @testset "build_release_notes: header + NEWS, else skipped" begin
        dir = mktempdir()
        news = joinpath(dir, "NEWS.md")
        header = joinpath(dir, "header.jl")
        write(news, "## 1.0\n- a change\n")
        write(header, "const RELEASE_NOTES_HEADER = \"# Release notes\\n\\n\"\n")
        dest = joinpath(dir, "release-notes.md")
        @test DB.build_release_notes(;
            news = news, header_file = header, dest = dest) == dest
        out = read(dest, String)
        @test startswith(out, "# Release notes")
        @test occursin("- a change", out)
        # Missing NEWS -> nothing written.
        @test DB.build_release_notes(; news = joinpath(dir, "none.md"),
            header_file = header, dest = joinpath(dir, "x.md")) === nothing
    end

    @testset "build_benchmark_page: tight skeleton + fallback" begin
        dir = mktempdir()
        run(pipeline(`git -C $dir init -q`; stdout = devnull, stderr = devnull))
        prose = joinpath(dir, "benchmarks.md")
        write(prose, "Narrative here.\n\n## Structure\nstuff\n")
        dest = joinpath(dir, "src", "benchmarks.md")
        lc = DB.build_benchmark_page(; dest = dest, repo = "Org/Pkg.jl",
            package = "Pkg", prose_file = prose, project_root = dir)
        out = read(dest, String)
        # Managed skeleton: anchored heading + Performance history only.
        @test occursin("# [Benchmarks](@id benchmarks)", out)
        @test occursin("## Performance history", out)
        # Prose hook spliced verbatim; no managed free-text "Running" section.
        @test occursin("Narrative here.", out)
        @test occursin("## Structure", out)
        @test !occursin("## Running benchmarks", out)
        # No benchmarks branch yet -> graceful fallback link.
        @test occursin("`benchmarks` branch", out)
        @test occursin(
            "https://github.com/Org/Pkg.jl/tree/benchmarks/history", out)
        # Linkcheck-ignore regexes returned for the history URLs.
        @test any(r -> occursin(r, "raw.githubusercontent.com/Org/Pkg.jl/benchmarks"), lc)
    end

    @testset "build_benchmark_page: renders published history" begin
        dir = mktempdir()
        run(pipeline(`git -C $dir init -q`; stdout = devnull, stderr = devnull))
        run(`git -C $dir config user.email t@t`)
        run(`git -C $dir config user.name t`)
        write(joinpath(dir, "f.txt"), "x")
        run(`git -C $dir add -A`)
        run(pipeline(`git -C $dir commit -qm init`;
            stdout = devnull, stderr = devnull))
        main = strip(read(`git -C $dir rev-parse --abbrev-ref HEAD`, String))
        run(`git -C $dir checkout -q --orphan benchmarks`)
        run(pipeline(`git -C $dir reset -q --hard`;
            stdout = devnull, stderr = devnull))
        hist = joinpath(dir, "history")
        mkpath(hist)
        write(joinpath(hist, "table.md"), "| b | r |\n|---|---|\n| a | 1 |\n")
        write(joinpath(hist, "Primary.png"), "PNG")
        write(joinpath(hist, "Interval.png"), "PNG")
        run(`git -C $dir add -A`)
        run(pipeline(`git -C $dir commit -qm hist`;
            stdout = devnull, stderr = devnull))
        run(`git -C $dir checkout -q $main`)
        prose = joinpath(dir, "benchmarks.md")
        write(prose, "Narrative.\n")
        dest = joinpath(dir, "src", "benchmarks.md")
        DB.build_benchmark_page(; dest = dest, repo = "Org/Pkg.jl",
            package = "Pkg", prose_file = prose, project_root = dir)
        out = read(dest, String)
        # Ratio table inlined.
        @test occursin("### Ratio summary", out)
        @test occursin("| a | 1 |", out)
        # Each plot embedded via its raw GitHub URL (sorted).
        @test occursin("### Per-benchmark timelines", out)
        @test occursin(
            "![Interval.png](https://raw.githubusercontent.com/Org/Pkg.jl/benchmarks/history/Interval.png)",
            out)
        @test occursin(
            "![Primary.png](https://raw.githubusercontent.com/Org/Pkg.jl/benchmarks/history/Primary.png)",
            out)
        @test !occursin("tree/benchmarks/history", out)  # not the fallback
    end

    @testset "api_bindings + build_api_pages split public/private" begin
        public, private = DB.api_bindings(EpiAwarePackageTools)
        @test :scaffold in public
        @test !(:scaffold in private)
        # Every documented binding lands in exactly one bucket.
        @test isempty(intersect(public, private))
        dir = mktempdir()
        lib = joinpath(dir, "lib")
        DB.build_api_pages(EpiAwarePackageTools, lib)
        pub = read(joinpath(lib, "public.md"), String)
        @test occursin("# [Public Documentation](@id public-api)", pub)
        @test occursin("```@docs", pub)
        @test occursin("EpiAwarePackageTools.scaffold", pub)
        intr = read(joinpath(lib, "internals.md"), String)
        @test occursin("# Internal Documentation", intr)
        @test !occursin("@id public-api", intr)
    end

    @testset "_documenter loads the real Documenter module" begin
        # Documenter is already a test dependency (for `test_doctest`), so
        # this is cheap and exercises the lazy-load wrapper for real.
        Documenter = DB._documenter()
        @test Documenter isa Module
        @test nameof(Documenter) == :Documenter
    end

    @testset "_write_tutorial_stubs writes each stub, no-ops when empty" begin
        mktempdir() do dir
            tdir = joinpath(dir, "tutorials")
            DB._write_tutorial_stubs(
                tdir, ["a.md" => "# A", "b.md" => "# B"])
            @test isfile(joinpath(tdir, "a.md"))
            @test isfile(joinpath(tdir, "b.md"))
            a = read(joinpath(tdir, "a.md"), String)
            @test occursin("# A", a)
            @test occursin("fast documentation", a)

            # Empty stubs: no directory created, no error.
            empty_dir = joinpath(dir, "untouched")
            DB._write_tutorial_stubs(empty_dir, Pair{String, String}[])
            @test !isdir(empty_dir)
        end
    end

    @testset "_copy_tutorial_data copies data/*-data dirs, skips others" begin
        mktempdir() do dir
            src_root = joinpath(dir, "src")
            build_root = joinpath(dir, "build")
            mkpath(joinpath(src_root, "tutorials", "data"))
            write(joinpath(src_root, "tutorials", "data", "sample.csv"),
                "a,b\n1,2\n")
            mkpath(joinpath(src_root, "tutorials", "other-data"))
            write(joinpath(src_root, "tutorials", "other-data", "x.txt"), "x")
            mkpath(joinpath(src_root, "tutorials", "not-data-dir"))
            write(joinpath(src_root, "tutorials", "not-data-dir", "y.txt"),
                "y")

            DB._copy_tutorial_data(src_root, build_root)

            @test isfile(
                joinpath(build_root, "tutorials", "data", "sample.csv"))
            @test isfile(
                joinpath(build_root, "tutorials", "other-data", "x.txt"))
            @test !isdir(
                joinpath(build_root, "tutorials", "not-data-dir"))
        end
    end
end
