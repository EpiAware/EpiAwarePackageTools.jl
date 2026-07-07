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
        # With no strip sections, content tables are kept.
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
        # The named section and its deeper subsection are removed...
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

    @testset "build_benchmark_page: strips the seed's leading comment" begin
        dir = mktempdir()
        run(pipeline(`git -C $dir init -q`; stdout = devnull, stderr = devnull))
        prose = joinpath(dir, "benchmarks.md")
        # The scaffolded seed opens with an HTML authoring-guidance comment.
        write(prose,
            "<!-- PACKAGE-OWNED — your benchmark narrative.\n" *
            "spans multiple lines. -->\n\nReal narrative.\n")
        dest = joinpath(dir, "src", "benchmarks.md")
        DB.build_benchmark_page(; dest = dest, repo = "Org/Pkg.jl",
            package = "Pkg", prose_file = prose, project_root = dir)
        out = read(dest, String)
        # The leading comment is gone; the real narrative survives (#145).
        @test !occursin("<!--", out)
        @test !occursin("PACKAGE-OWNED", out)
        @test occursin("Real narrative.", out)
        # The heading still leads the page (comment did not push it down).
        @test startswith(out, "# [Benchmarks](@id benchmarks)")
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

    @testset "_check_index_not_truncated fails on a short copy (#91)" begin
        mktempdir() do dir
            src = joinpath(dir, "index.md")
            write(src,
                join(
                    ("# Title", "", "one", "two", "three", "four",
                        "five", "six", "seven", "eight", "nine", "ten"),
                    "\n"))
            built_dir = joinpath(dir, "build", ".documenter")
            mkpath(built_dir)
            # A suspiciously short copy (the #91 failure mode) errors loudly
            # instead of silently shipping a half-built home page.
            write(joinpath(built_dir, "index.md"), "# Title\n\none\ntwo\n")
            @test_throws ErrorException DB._check_index_not_truncated(
                src, built_dir)

            # A complete (here: identical) copy is fine.
            cp(src, joinpath(built_dir, "index.md"); force = true)
            @test DB._check_index_not_truncated(src, built_dir) === nothing

            # Documenter's real pipeline only ever ADDS lines (docstring /
            # cross-reference expansion), which must never be flagged.
            write(joinpath(built_dir, "index.md"),
                read(src, String) * "\nexpanded content\nmore\n")
            @test DB._check_index_not_truncated(src, built_dir) === nothing
        end
    end

    @testset "_check_index_not_truncated no-ops when nothing to check" begin
        mktempdir() do dir
            # No source index.md yet.
            @test DB._check_index_not_truncated(
                joinpath(dir, "index.md"), joinpath(dir, "build")) === nothing

            # Source exists but the built copy is absent (e.g. a caller that
            # skips the Documenter build entirely).
            src = joinpath(dir, "index.md")
            write(src, "# Title\n")
            @test DB._check_index_not_truncated(
                src, joinpath(dir, "nobuild")) === nothing
        end
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

    @testset "_render_tutorials: skip_notebooks stubs only heavy" begin
        # Calls the exact `build_docs` tutorial step (`_render_tutorials`)
        # directly, rather than the full makedocs pipeline: under
        # `skip_notebooks`, light tutorials still run through
        # `_process_tutorials` (executed in-process by Literate), and only
        # heavy tutorials fall back to `_write_tutorial_stubs`.
        mktempdir() do dir
            docs_dir = joinpath(dir, "docs")
            tutorials_dir = joinpath(docs_dir, "src", "tutorials")
            mkpath(tutorials_dir)
            write(joinpath(tutorials_dir, "light.jl"),
                """
                # # A light tutorial

                x = 1 + 1
                """)

            light = ["light.jl"]
            heavy = ["heavy.jl"]
            stubs = Pair{String, String}[
                "light.md" => "# A light tutorial",
                "heavy.md" => "# A heavy tutorial"
            ]

            DB._render_tutorials(docs_dir, tutorials_dir, true, light, heavy,
                stubs)

            light_out = read(joinpath(tutorials_dir, "light.md"), String)
            heavy_out = read(joinpath(tutorials_dir, "heavy.md"), String)

            # Light tutorial went through Literate: real content, not a stub.
            @test occursin("x = 1 + 1", light_out)
            @test occursin("```@example", light_out)
            @test !occursin("fast documentation", light_out)

            # Heavy tutorial is the bare heading stub, never Literate-run.
            @test occursin("# A heavy tutorial", heavy_out)
            @test occursin("fast documentation", heavy_out)
            @test !occursin("x = 1 + 1", heavy_out)
        end
    end

    @testset "_render_tutorials: !skip_notebooks delegates through" begin
        # With skip_notebooks=false, no stubbing/filtering happens at all —
        # `_render_tutorials` is a thin pass-through to `_process_tutorials`.
        # `heavy` is empty here so the (separately tested) subprocess runner
        # path is not exercised by this call.
        mktempdir() do dir
            docs_dir = joinpath(dir, "docs")
            tutorials_dir = joinpath(docs_dir, "src", "tutorials")
            mkpath(tutorials_dir)
            write(joinpath(tutorials_dir, "light.jl"),
                """
                # # A light tutorial

                x = 1 + 1
                """)

            DB._render_tutorials(docs_dir, tutorials_dir, false,
                ["light.jl"], String[], Pair{String, String}[])

            light_out = read(joinpath(tutorials_dir, "light.md"), String)
            @test occursin("x = 1 + 1", light_out)
            @test !occursin("fast documentation", light_out)
        end
    end

    @testset "_render_tutorials: force_stub stubs named heavy tutorials" begin
        # `force_stub` stubs the named heavy tutorials independent of
        # `skip_notebooks` — here under `!skip_notebooks`, where every other
        # heavy tutorial would otherwise execute for real. `heavy` is
        # entirely force-stubbed in this call, so no subprocess is spawned
        # (a heavy tutorial NOT force-stubbed still executes via
        # `_process_tutorials`'s subprocess path — not re-exercised here, per
        # the kit's stated test philosophy: that pipeline is
        # integration-tested by each package's own docs build).
        mktempdir() do dir
            docs_dir = joinpath(dir, "docs")
            tutorials_dir = joinpath(docs_dir, "src", "tutorials")
            mkpath(tutorials_dir)
            write(joinpath(tutorials_dir, "light.jl"),
                """
                # # A light tutorial

                x = 1 + 1
                """)

            stubs = Pair{String, String}[
                "light.md" => "# A light tutorial",
                "heavy.md" => "# A heavy tutorial"
            ]

            DB._render_tutorials(docs_dir, tutorials_dir, false, ["light.jl"],
                ["heavy.jl"], stubs; force_stub = ["heavy.jl"])

            light_out = read(joinpath(tutorials_dir, "light.md"), String)
            heavy_out = read(joinpath(tutorials_dir, "heavy.md"), String)

            # Light still renders for real; force-stubbed heavy never runs.
            @test occursin("x = 1 + 1", light_out)
            @test occursin("# A heavy tutorial", heavy_out)
            @test occursin("fast documentation", heavy_out)
        end
    end

    @testset "_tutorial_md_name(s) map .jl sources to Literate .md output" begin
        @test DB._tutorial_md_name("ad-backends.jl") == "ad-backends.md"
        @test DB._tutorial_md_name("composer-toolkit.jl") ==
              "composer-toolkit.md"
        @test DB._tutorial_md_names(["a.jl", "b.jl"]) ==
              Set(["a.md", "b.md"])
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

@testitem "api_bindings covers re-exports + public-only (#160)" begin
    using Test
    using EpiAwarePackageTools
    const DB = EpiAwarePackageTools.DocsBuild

    # A dependency owning the docstrings, and a package that re-exports part
    # of that surface and declares its own public-but-unexported binding —
    # the shape that produced broken @refs (EpiAware/ComposedDistributions#72).
    module Dep
    export owned_reexport
    "owned_reexport docstring"
    owned_reexport
    owned_reexport(x) = x
    "dep_public docstring"
    dep_public
    dep_public(x) = x
    end

    # `public` is a Julia >=1.11 parse feature, so build the fixture module from
    # a string (parsed only at eval time) and drop the `public` lines on older
    # Julia — otherwise the whole testitem is a parse error on lts (1.10). The
    # re-export / native / internal cases run on every version; the public-only
    # binding is asserted only where `public` parses.
    _pub(name) = VERSION >= v"1.11" ? "public $name" : ""
    Base.include_string(@__MODULE__, """
    module Pkg160
    using ..Dep: owned_reexport, dep_public
    export owned_reexport            # re-export a dep-owned binding
    $(_pub("dep_public"))            # surface a dep-owned binding as public (>=1.11)
    "native docstring"
    native
    native() = 1
    export native
    "guts docstring"
    guts
    guts() = 2                       # documented, unexported -> internal
    undoc_public() = 3               # public but carries no docstring
    $(_pub("undoc_public"))          # -> must be dropped from @docs (>=1.11)
    end
    """)

    pubs, privs = DB.api_bindings(Pkg160)
    # Re-exported and native bindings now appear in the public API (were missed).
    @test :owned_reexport in pubs
    @test :native in pubs
    # Documented-but-unexported bindings stay internal.
    @test :guts in privs
    # A public name with no resolvable docstring is dropped (keeps @docs safe).
    @test !(:undoc_public in pubs)
    @test !(:undoc_public in privs)
    @test isempty(intersect(pubs, privs))
    if VERSION >= v"1.11"
        # A public-but-unexported dep-owned binding surfaces only where `public`
        # parses (>=1.11).
        @test :dep_public in pubs
    end

    # The rendered @docs block lists the re-exported binding, so its @ref
    # resolves instead of producing a broken link.
    dir = mktempdir()
    lib = joinpath(dir, "lib")
    DB.build_api_pages(Pkg160, lib)
    pub = read(joinpath(lib, "public.md"), String)
    @test occursin("Pkg160.owned_reexport", pub)
    @test occursin("Pkg160.dep_public", pub)
end
