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

    @testset "build_benchmark_page: renders grouped published history" begin
        dir = mktempdir()
        run(pipeline(`git -C $dir init -q`; stdout = devnull, stderr = devnull))
        run(`git -C $dir config user.email t@t`)
        run(`git -C $dir config user.name t`)
        write(joinpath(dir, "f.txt"), "x")
        run(`git -C $dir add -A`)
        run(pipeline(`git -C $dir commit -qm init`;
            stdout = devnull, stderr = devnull))
        sha = strip(read(`git -C $dir rev-parse HEAD`, String))
        short = sha[1:14]
        cdate = strip(read(
            `git -C $dir show -s --date=short --format=%cd $sha`, String))
        main = strip(read(`git -C $dir rev-parse --abbrev-ref HEAD`, String))
        run(`git -C $dir checkout -q --orphan benchmarks`)
        run(pipeline(`git -C $dir reset -q --hard`;
            stdout = devnull, stderr = devnull))
        hist = joinpath(dir, "history")
        mkpath(hist)
        # A realistic multi-suite table: slash-path row names, a truncated
        # commit-hash column header (matching benchpkgtable output).
        write(joinpath(hist, "table.md"),
            "|   | $short...  |\n" *
            "|:--|:---------:|\n" *
            "| AD gradients/Enzyme forward | 1.0 |\n" *
            "| AD gradients/ForwardDiff | 2.0 |\n" *
            "| Baseline/allocations | 3.0 |\n" *
            "| time_to_load | 4.0 |\n")
        write(joinpath(hist, "plot_Pkg_1.png"), "PNG")
        write(joinpath(hist, "plot_Pkg_2.png"), "PNG")
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
        # Ratio table grouped into per-suite `###` sections (#193).
        @test occursin("### Ratio summary", out)
        @test occursin("### AD gradients", out)
        @test occursin("### Baseline", out)
        # Row labels have the suite prefix stripped.
        @test occursin("| Enzyme forward | 1.0 |", out)
        @test occursin("| ForwardDiff | 2.0 |", out)
        @test occursin("| allocations | 3.0 |", out)
        # The flat slash-path row name is no longer spliced verbatim.
        @test !occursin("AD gradients/Enzyme forward", out)
        # Column relabelled from raw hash to commit date.
        @test occursin(cdate, out)
        @test !occursin("$short...", out)
        # Plots collapsed behind <details>, each still embedded (sorted).
        @test occursin("### Per-benchmark timelines", out)
        @test occursin("<details>", out)
        @test occursin("<summary>", out)
        @test occursin(
            "![plot_Pkg_1.png](https://raw.githubusercontent.com/Org/Pkg.jl/benchmarks/history/plot_Pkg_1.png)",
            out)
        @test !occursin("tree/benchmarks/history", out)  # not the fallback
    end

    @testset "build_benchmark_page: history_suites filters suites" begin
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
        write(joinpath(hist, "table.md"),
            "|   | c1 |\n|:--|:--:|\n" *
            "| AD gradients/ForwardDiff | 2.0 |\n" *
            "| Baseline/allocations | 3.0 |\n")
        run(`git -C $dir add -A`)
        run(pipeline(`git -C $dir commit -qm hist`;
            stdout = devnull, stderr = devnull))
        run(`git -C $dir checkout -q $main`)
        prose = joinpath(dir, "benchmarks.md")
        write(prose, "Narrative.\n")
        dest = joinpath(dir, "src", "benchmarks.md")
        DB.build_benchmark_page(; dest = dest, repo = "Org/Pkg.jl",
            package = "Pkg", prose_file = prose, project_root = dir,
            history_suites = ["AD gradients"])
        out = read(dest, String)
        # Only the named headline suite is rendered.
        @test occursin("### AD gradients", out)
        @test !occursin("### Baseline", out)
        @test !occursin("allocations", out)
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
    if VERSION >= v"1.11"
        # `dep_public` is only public where the `public` keyword parses (>=1.11),
        # so it appears as a documented public binding on the API page only there.
        @test occursin("Pkg160.dep_public", pub)
    end
end

@testitem "re-exports resolve without checkdocs flooding (#175)" begin
    using Test
    using Documenter
    using EpiAwarePackageTools
    const DB = EpiAwarePackageTools.DocsBuild
    # `Logging` is not a declared test dep; its API lives in `Base.CoreLogging`
    # (always loadable), and `TestLogger` comes from `Test`.
    const CL = Base.CoreLogging

    # A dependency that owns docstrings, one of which (`dep_only`) the package
    # never surfaces, and a package re-exporting part of the dep (the
    # ComposedDistributions <- ConvolvedDistributions shape from #175).
    module Dep175
    export owned_reexport
    "owned_reexport docstring"
    owned_reexport
    owned_reexport(x) = x
    "dep_only docstring — documented in the dep, never surfaced by the pkg"
    dep_only
    dep_only(x) = x
    end

    # Re-export a dep-owned binding: its docstring stays in `Dep175`, so
    # resolving the pkg's `@docs` entry for it needs `Dep175` in makedocs'
    # `modules` — the crux of #175. (No `public` keyword here, so the fixture
    # parses on lts (1.10) as a plain module.)
    module Pkg175
    using ..Dep175: owned_reexport
    export owned_reexport
    "native docstring"
    native
    native() = 1
    export native
    end

    # Auto-discovery finds the dep as the owner of the re-exported docstring,
    # and never lists the package itself.
    owners = DB.api_owning_modules(Pkg175)
    @test Dep175 in owners
    @test !(Pkg175 in owners)
    # Same-package submodules are already reachable from `mod`, so they are not
    # reported as external owners. Otherwise a package that re-exports from its
    # own submodule (as the kit does from `DocsBuild`) would needlessly flip its
    # own checkdocs off. The kit re-exports `build_docs` from `DocsBuild`.
    @test isempty(DB.api_owning_modules(EpiAwarePackageTools))

    # Mirror build_docs' module widening + checkdocs scoping so the test guards
    # the exact resolution/completeness behaviour makedocs runs with.
    doc_modules = Module[Pkg175]
    append!(doc_modules, collect(owners))
    checkdocs = length(doc_modules) > 1 ? :none : :all
    @test checkdocs === :none

    # Build the API pages (the @docs blocks listing the re-export) and run a
    # real makedocs pass, collecting its warnings.
    function makedocs_warnings(modules; checkdocs = :all)
        dir = mktempdir()
        src = joinpath(dir, "src")
        DB.build_api_pages(Pkg175, joinpath(src, "lib"))
        write(joinpath(src, "index.md"), "# Home\n\nHome.\n")
        pages = ["Home" => "index.md",
            "Public" => "lib/public.md", "Internals" => "lib/internals.md"]
        logger = Test.TestLogger(; min_level = CL.Debug)
        CL.with_logger(logger) do
            Documenter.makedocs(; root = dir, sitename = "Pkg175",
                modules = modules, pages = pages, remotes = nothing,
                doctest = false, warnonly = true, checkdocs = checkdocs,
                format = Documenter.HTML())
        end
        return [string(r.message) for r in logger.logs
                if r.level >= CL.Warn]
    end

    nodocs(msgs) = count(m -> occursin("no docs found", m), msgs)
    missingdocs(msgs) = count(
        m -> occursin("not included in the manual", m), msgs)

    # Control: the un-widened build reproduces the #175 bug — the re-exported
    # @docs entry raises "no docs found" (a broken @ref in the built HTML).
    narrow = makedocs_warnings(Module[Pkg175])
    @test nodocs(narrow) > 0

    # The fix: widening resolution to the owning modules resolves the re-export
    # (no "no docs found")...
    widened = makedocs_warnings(doc_modules; checkdocs = checkdocs)
    @test nodocs(widened) == 0
    # ...and disabling the (redundant) completeness check keeps the package off
    # the hook for the dependency's own missing docstring (`Dep175.dep_only`).
    @test missingdocs(widened) == 0

    # Guard the scoping decision: widening *without* the checkdocs relaxation
    # would flood the package's log with the dependency's own hygiene — the
    # exact failure the :none scoping prevents.
    widened_checked = makedocs_warnings(doc_modules; checkdocs = :all)
    @test nodocs(widened_checked) == 0
    @test any(m -> occursin("Dep175.dep_only", m), widened_checked)
end

@testitem "benchmark history table reshaping (#193)" begin
    using Test
    using EpiAwarePackageTools
    const DB = EpiAwarePackageTools.DocsBuild

    # A representative `table.md` matching benchpkgtable's real output: an empty
    # first (name) column header, truncated commit-hash column headers, and
    # slash-path leaf-benchmark row names spanning several suites.
    tbl = """
    |                                   | aaaa1111...  | bbbb2222...  |
    |:----------------------------------|:------------:|:------------:|
    | AD gradients/Enzyme forward       | 1.0          | 1.2          |
    | AD gradients/ForwardDiff          | 2.0          | 1.9          |
    | Baseline/allocations              | 3.0          | 3.0          |
    | time_to_load                      | 4.0          | 4.1          |
    """

    @testset "_parse_pipe_table / _history_table_parts" begin
        cols, entries = DB._history_table_parts(tbl)
        # The alignment row is dropped; the two hash columns survive.
        @test cols == ["aaaa1111...", "bbbb2222..."]
        # One entry per leaf benchmark, name => values.
        @test length(entries) == 4
        @test entries[1] == ("AD gradients/Enzyme forward" => ["1.0", "1.2"])
        @test entries[end] == ("time_to_load" => ["4.0", "4.1"])
    end

    @testset "_cap_columns keeps the most recent n" begin
        cols, entries = DB._history_table_parts(tbl)
        capped_cols, capped = DB._cap_columns(cols, entries, 1)
        # Only the newest (rightmost) column is retained.
        @test capped_cols == ["bbbb2222..."]
        @test capped[1] == ("AD gradients/Enzyme forward" => ["1.2"])
        # n >= column count is a no-op.
        @test DB._cap_columns(cols, entries, 5) == (cols, entries)
    end

    @testset "_group_rows_by_suite groups + strips the prefix" begin
        _, entries = DB._history_table_parts(tbl)
        groups = DB._group_rows_by_suite(entries)
        suites = first.(groups)
        # First-seen suite order, one group per first `/`-segment.
        @test suites == ["AD gradients", "Baseline", "time_to_load"]
        adrows = groups[1].second
        # The suite prefix is stripped from each row label.
        @test first.(adrows) == ["Enzyme forward", "ForwardDiff"]
        # A name with no `/` forms its own single-row suite (label == name).
        @test groups[3].second == ["time_to_load" => ["4.0", "4.1"]]
    end

    @testset "_render_ratio_table: grouped, capped, all suites" begin
        io = IOBuffer()
        # `project_root` here is not a git repo, so the hash columns stay as-is
        # (date relabelling is exercised in the git-backed page test).
        DB._render_ratio_table(io, tbl, mktempdir(); last_n = 5,
            suites = String[])
        out = String(take!(io))
        @test occursin("### AD gradients", out)
        @test occursin("### Baseline", out)
        @test occursin("### time_to_load", out)
        @test occursin("| Enzyme forward | 1.0 | 1.2 |", out)
        # The flat slash-path is not spliced verbatim.
        @test !occursin("AD gradients/Enzyme forward", out)
    end

    @testset "_render_ratio_table: history_suites filter" begin
        io = IOBuffer()
        DB._render_ratio_table(io, tbl, mktempdir(); last_n = 5,
            suites = ["AD gradients"])
        out = String(take!(io))
        @test occursin("### AD gradients", out)
        @test !occursin("### Baseline", out)
        @test !occursin("allocations", out)
    end

    @testset "_render_ratio_table: unparseable table spliced verbatim" begin
        io = IOBuffer()
        DB._render_ratio_table(io, "not a table at all", mktempdir())
        @test occursin("not a table at all", String(take!(io)))
    end
end

@testitem "benchmarks branch fetched via explicit refspec (#192)" begin
    using Test
    using EpiAwarePackageTools
    const DB = EpiAwarePackageTools.DocsBuild

    mktempdir() do root
        origin = joinpath(root, "origin.git")
        work = joinpath(root, "work")
        clone = joinpath(root, "clone")
        q = (; stdout = devnull, stderr = devnull)
        run(pipeline(`git init -q --bare $origin`; q...))
        run(pipeline(`git init -q $work`; q...))
        run(`git -C $work config user.email t@t`)
        run(`git -C $work config user.name t`)
        write(joinpath(work, "f"), "x")
        run(`git -C $work add -A`)
        run(pipeline(`git -C $work commit -qm init`; q...))
        run(`git -C $work branch -M main`)
        run(`git -C $work checkout -q --orphan benchmarks`)
        run(pipeline(`git -C $work reset -q --hard`; q...))
        mkpath(joinpath(work, "history"))
        write(joinpath(work, "history", "table.md"),
            "|  | c1 |\n|:-|:-:|\n| a/b | 1 |\n")
        run(`git -C $work add -A`)
        run(pipeline(`git -C $work commit -qm hist`; q...))
        run(`git -C $work checkout -q main`)
        run(`git -C $work remote add origin $origin`)
        run(pipeline(`git -C $work push -q origin main benchmarks`; q...))

        # A single-branch clone tracking only `main` — the CI docs checkout
        # shape. `origin/benchmarks` is absent until an explicit fetch.
        run(pipeline(
            `git clone -q --single-branch --branch main $origin $clone`; q...))
        @test DB._benchmarks_ref(clone; fetch = false) === nothing
        # The refspec fetch creates the `origin/benchmarks` tracking ref so the
        # lookup resolves it. A bare `git fetch origin benchmarks` (the old
        # behaviour) would only populate FETCH_HEAD and still return nothing —
        # the #192 failure that blanked the deployed history page.
        @test DB._benchmarks_ref(clone; fetch = true) == "origin/benchmarks"
        @test !isempty(DB._history_files(clone, "origin/benchmarks"))
    end
end
