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
        # No emitted table carries an empty leading header cell (`|   |`):
        # DocumenterVitepress's inventory writer turns one into an anchored
        # header with an empty anchor id and aborts the deploy build (#204).
        # The reshaped tables lead with `| Benchmark |`/`| Suite |`.
        @test !occursin(r"(?m)^[ \t]*\|[ \t]*\|", out)
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

    @testset "_parse_metric_value: leading number from a table.md cell" begin
        @test DB._parse_metric_value("1.0") == 1.0
        @test DB._parse_metric_value("0.112 ± 0.0006 ms") == 0.112
        @test DB._parse_metric_value("3 ns") == 3.0
        @test DB._parse_metric_value("—") === nothing
        @test DB._parse_metric_value("") === nothing
        @test DB._parse_metric_value("not a number") === nothing
    end

    @testset "_suite_column_medians: per-column median, skips bad cells" begin
        subrows = ["a" => ["1.0", "3.0"], "b" => ["3.0", "not a number"]]
        medians = DB._suite_column_medians(subrows, 2)
        @test medians[1] == 2.0   # median(1.0, 3.0)
        @test medians[2] == 3.0   # only "3.0" parses in column 2
        # A column where nothing parses is `missing`, not zero or NaN.
        subrows2 = ["a" => ["x", "y"]]
        @test all(ismissing, DB._suite_column_medians(subrows2, 2))
    end

    @testset "_suite_column_medians: mismatched-width row skipped" begin
        # `_cap_columns` leaves a malformed row's ORIGINAL (uncapped) cells
        # untouched (#193): a well-formed row here has exactly `ncol = 2`
        # values (already capped to the newest 2 columns), but a malformed
        # row still carries all 5 of its original, oldest-first values.
        # Reading `cellvals[j]` positionally against `1:ncol` would silently
        # pair the malformed row's stale oldest values with the newest
        # columns; it must be skipped instead.
        subrows = [
            "ok" => ["40.0", "50.0"],   # well-formed, capped
            "malformed" => ["1.0", "2.0", "3.0", "4.0", "5.0"]  # uncapped
        ]
        medians = DB._suite_column_medians(subrows, 2)
        # Only the well-formed row contributes; the malformed row's stale
        # `"1.0"`/`"2.0"` never leak into the (newest) capped columns.
        @test medians == [40.0, 50.0]
    end

    @testset "_suite_ratio_series: normalised to the first finite value" begin
        @test DB._suite_ratio_series([2.0, 4.0, 1.0]) == [1.0, 2.0, 0.5]
        # Leading `missing` columns are skipped when picking the baseline.
        series = DB._suite_ratio_series(
            Union{Float64, Missing}[missing, 2.0, 4.0])
        @test ismissing(series[1])
        @test series[2] == 1.0
        @test series[3] == 2.0
        # No finite value at all -> every entry stays `missing`.
        @test all(ismissing,
            DB._suite_ratio_series(Vector{Union{Float64, Missing}}(missing, 3)))
    end

    @testset "_suite_ratio_series: zero baseline never divides by zero" begin
        # A leading `0.0` (a legitimate value, e.g. "0 bytes allocated") must
        # not become the denominator: `0/0` and `x/0` would produce
        # `NaN`/`Inf`, breaking "1.0 at the oldest revision" and silently
        # defeating the finite-value checks downstream.
        series = DB._suite_ratio_series([0.0, 2.0, 4.0])
        @test all(isfinite, skipmissing(series))
        @test series[2] == 1.0   # 2.0 is the real baseline
        @test series[3] == 2.0
        # All-zero series: no non-zero baseline exists -> all `missing`.
        @test all(ismissing, DB._suite_ratio_series([0.0, 0.0, 0.0]))
    end

    @testset "_suite_trend_status: arrow + regression flag" begin
        # A clear regression: doubled since the oldest shown revision.
        ratio, trend, status = DB._suite_trend_status([1.0, 2.0])
        @test ratio == 2.0
        @test trend == "↗"
        @test status == "⚠ reg"
        # A clear improvement: halved.
        ratio, trend, status = DB._suite_trend_status([1.0, 0.5])
        @test ratio == 0.5
        @test trend == "↘"
        @test status == "ok"
        # Within the flat threshold (2%) counts as unchanged, and below the
        # regression threshold is "ok" even though it did tick up.
        ratio, trend, status = DB._suite_trend_status([1.0, 1.01])
        @test trend == "→"
        @test status == "ok"
        # A custom (stricter) regression threshold.
        _, _, status = DB._suite_trend_status([1.0, 1.06];
            regression_threshold = 1.05)
        @test status == "⚠ reg"
        # Fewer than two finite points -> no signal.
        ratio, trend, status = DB._suite_trend_status(
            Vector{Union{Float64, Missing}}([1.0, missing]))
        @test ismissing(ratio)
        @test trend == "→"
        @test status == "n/a"
        # Exactly at the regression threshold flags (>=, not >).
        _, _, status = DB._suite_trend_status([1.0, 1.1];
            regression_threshold = 1.1)
        @test status == "⚠ reg"
        # A non-finite entry (defence in depth alongside the zero-baseline
        # guard in `_suite_ratio_series`) never reaches the threshold
        # comparisons: it is excluded like `missing`, not compared as `NaN`
        # (which would silently evaluate every `>=`/`<=` to `false`).
        ratio, trend, status = DB._suite_trend_status([1.0, NaN, 2.0])
        @test ratio == 2.0
        @test trend == "↗"
        ratio, trend, _ = DB._suite_trend_status([1.0, NaN])
        @test ismissing(ratio)
        @test trend == "→"
    end

    @testset "_write_benchmark_summary: markdown table + legend" begin
        io = IOBuffer()
        rows = [
            (suite = "AD gradients", ratio = 2.0, trend = "↗",
                status = "⚠ reg"),
            (suite = "Baseline",
                ratio = missing, trend = "→", status = "n/a")
        ]
        DB._write_benchmark_summary(io, rows)
        out = String(take!(io))
        @test occursin("## Benchmark summary (overall)", out)
        @test occursin("| AD gradients | 2.0 | ↗ | ⚠ reg |", out)
        @test occursin("| Baseline | n/a | → | n/a |", out)
        # Empty input still writes the heading + a graceful message.
        io2 = IOBuffer()
        DB._write_benchmark_summary(io2, [])
        @test occursin("## Benchmark summary (overall)", String(take!(io2)))
        # `_fmt_ratio` never prints a literal "NaN"/"Inf" -- both degrade to
        # "n/a" like a `missing` ratio, defence in depth alongside the
        # zero-baseline guard in `_suite_ratio_series`.
        @test DB._fmt_ratio(NaN) == "n/a"
        @test DB._fmt_ratio(Inf) == "n/a"
        @test DB._fmt_ratio(2.0) == "2.0"
    end

    @testset "build_benchmark_page: overall summary table + trend plot" begin
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
        # Two revisions: "AD gradients" doubles (regression), "Baseline"
        # halves (improvement), "time_to_load" stays flat.
        write(joinpath(hist, "table.md"),
            "|   | aaaa1111...  | bbbb2222...  |\n" *
            "|:--|:-----------:|:-----------:|\n" *
            "| AD gradients/Enzyme forward | 1.0 | 2.0 |\n" *
            "| AD gradients/ForwardDiff | 1.0 | 2.2 |\n" *
            "| Baseline/allocations | 4.0 | 2.0 |\n" *
            "| time_to_load | 5.0 | 5.05 |\n")
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
        # The overall summary leads the page, above the collapsed detail.
        summary_pos = findfirst("## Benchmark summary (overall)", out)
        detail_pos = findfirst("<summary>Per-suite detail</summary>", out)
        @test summary_pos !== nothing
        @test detail_pos !== nothing
        @test first(summary_pos) < first(detail_pos)
        @test occursin("| AD gradients | 2.1 | ↗ | ⚠ reg |", out)
        @test occursin("| Baseline | 0.5 | ↘ | ok |", out)
        @test occursin("| time_to_load | 1.01 | → | ok |", out)
        # The existing #196 detail (per-suite tables + collapsed plots) still
        # renders, now inside the outer `<details>`.
        @test occursin("### Ratio summary", out)
        @test occursin("### AD gradients", out)
        # The combined trend plot was generated and embedded.
        png = joinpath(dirname(dest), "overall_trend.png")
        @test isfile(png)
        @test filesize(png) > 0
        @test occursin("![Overall benchmark trend](overall_trend.png)", out)
    end

    @testset "_write_overall_trend_plot: render failure degrades to false" begin
        # Plots loads fine (plenty of comparable data), but the destination
        # is unwritable: `blocker` exists as a regular file, so `mkpath` on
        # a path nested under it throws inside the render `try`. This must
        # hit the render-failure `@warn` branch (not the "Plots missing"
        # `@info` branch) and return `false` without propagating.
        series_by_suite = [("A", [1.0, 2.0]), ("B", [1.0, 0.9])]
        col_labels = ["2024-01-01", "2024-01-02"]
        blocker = joinpath(mktempdir(), "blocker")
        write(blocker, "not a directory")
        bad_dest = joinpath(blocker, "sub", "overall_trend.png")
        @test DB._write_overall_trend_plot(
            bad_dest, col_labels, series_by_suite) == false
        @test !isfile(bad_dest)
    end

    @testset "build_benchmark_page: single revision skips the trend plot" begin
        # Mirrors the existing "renders grouped published history" fixture
        # (one column) -- fewer than two comparable points means nothing to
        # plot, so no `Plots` dependency is touched and no PNG is written.
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
            "|   | c1 |\n|:--|:--:|\n| Baseline/allocations | 3.0 |\n")
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
        @test occursin("## Benchmark summary (overall)", out)
        @test occursin("| Baseline | n/a | → | n/a |", out)
        @test !isfile(joinpath(dirname(dest), "overall_trend.png"))
        @test !occursin("Overall benchmark trend", out)
    end

    @testset "_write_benchmark_notes: user prose + auto-detected rows" begin
        io = IOBuffer()
        DB._write_benchmark_notes(io, "`slow_path` is skipped: see #123.")
        out = String(take!(io))
        @test occursin("### Skipped & broken benchmarks", out)
        @test occursin("`slow_path` is skipped", out)
        # Auto-detected rows are appended, quoted, comma-joined.
        io2 = IOBuffer()
        DB._write_benchmark_notes(io2, "", ["Baseline/flaky", "time_to_load"])
        out2 = String(take!(io2))
        @test occursin("### Skipped & broken benchmarks", out2)
        @test occursin("`Baseline/flaky`", out2)
        @test occursin("`time_to_load`", out2)
        # Neither prose nor an auto-detection -> nothing rendered at all.
        io3 = IOBuffer()
        DB._write_benchmark_notes(io3, "")
        @test isempty(String(take!(io3)))
        io4 = IOBuffer()
        DB._write_benchmark_notes(io4, "   ")  # blank/whitespace-only prose
        @test isempty(String(take!(io4)))
    end

    @testset "_unparsed_benchmarks: leaf rows with no parseable data" begin
        groups = [
            "AD gradients" => [
                "Enzyme forward" => ["1.0", "2.0"],   # parses fine
                "broken" => ["—", "—"]                # never parses
            ],
            "time_to_load" => [
                "time_to_load" => ["—", "—"]
            ]
        ]
        out = DB._unparsed_benchmarks(groups)
        @test "AD gradients/broken" in out
        @test "time_to_load" in out  # no `/` -> label alone, no suite prefix
        @test "AD gradients/Enzyme forward" ∉ out
    end

    @testset "build_benchmark_page: notes block + auto-detected skip" begin
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
        # One benchmark never parses across either shown revision (a
        # realistic "errored in CI" signature) alongside normal data.
        write(joinpath(hist, "table.md"),
            "|   | c1 | c2 |\n|:--|:--:|:--:|\n" *
            "| Baseline/allocations | 1.0 | 1.0 |\n" *
            "| Baseline/broken | — | — |\n")
        run(`git -C $dir add -A`)
        run(pipeline(`git -C $dir commit -qm hist`;
            stdout = devnull, stderr = devnull))
        run(`git -C $dir checkout -q $main`)
        prose = joinpath(dir, "benchmarks.md")
        write(prose, "Narrative.\n")
        notes = joinpath(dir, "benchmarks_notes.md")
        write(notes,
            "<!-- guidance -->\n\n`weird_scenario` intentionally excluded.\n")
        dest = joinpath(dir, "src", "benchmarks.md")
        DB.build_benchmark_page(; dest = dest, repo = "Org/Pkg.jl",
            package = "Pkg", prose_file = prose, project_root = dir,
            notes_file = notes)
        out = read(dest, String)
        @test occursin("### Skipped & broken benchmarks", out)
        @test occursin("`weird_scenario` intentionally excluded.", out)
        @test !occursin("<!-- guidance -->", out)
        # The auto-detected no-data benchmark is appended alongside the
        # hand-written note.
        @test occursin("`Baseline/broken`", out)
        # A missing notes_file degrades gracefully: no section, no error.
        dest2 = joinpath(dir, "src2", "benchmarks.md")
        DB.build_benchmark_page(; dest = dest2, repo = "Org/Pkg.jl",
            package = "Pkg", prose_file = prose, project_root = dir,
            notes_file = joinpath(dir, "no_such_file.md"))
        out2 = read(dest2, String)
        @test occursin("`Baseline/broken`", out2)  # auto-detection still runs
        @test !occursin("intentionally excluded", out2)
    end

    @testset "_label_empty_leading_header labels a blank first header cell" begin
        # benchpkgtable's leaf-name column has a blank header; label it so a
        # verbatim splice cannot produce an empty anchor id (#204).
        md = "|   | c1 | c2 |\n|:--|:--:|:--:|\n| a/b | 1.0 | 2.0 |\n"
        out = DB._label_empty_leading_header(md)
        @test occursin("| Benchmark | c1 | c2 |", out)
        @test !occursin(r"(?m)^[ \t]*\|[ \t]*\|", out)
        # Only the header (first blank-leading row) is relabelled; the
        # alignment and data rows are untouched.
        @test occursin("|:--|:--:|:--:|", out)
        @test occursin("| a/b | 1.0 | 2.0 |", out)
        @test count("Benchmark", out) == 1
        # A table already carrying a label is left unchanged.
        labelled = "| Suite | c1 |\n|:--|:--:|\n"
        @test DB._label_empty_leading_header(labelled) == labelled
    end

    @testset "build_benchmark_page: verbatim fallback has no empty anchor" begin
        # A published table.md that parses to a header but no data rows takes
        # the verbatim-splice fallback; the spliced table must still carry no
        # empty leading header cell (#204).
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
        # Header + alignment only: no parseable data rows, so the reshaper
        # falls back to splicing the table verbatim.
        write(joinpath(hist, "table.md"), "|   | c1 | c2 |\n|:--|:--:|:--:|\n")
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
        @test occursin("| Benchmark | c1 | c2 |", out)
        @test !occursin(r"(?m)^[ \t]*\|[ \t]*\|", out)
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

@testitem "api_remotes maps owning modules to source remotes (#190)" begin
    using Test
    using Documenter
    using EpiAwarePackageTools
    const DB = EpiAwarePackageTools.DocsBuild

    @testset "_github_org_repo parses the GitHub URL forms" begin
        @test DB._github_org_repo(
            "https://github.com/EpiAware/ConvolvedDistributions.jl.git") ==
              ("EpiAware", "ConvolvedDistributions.jl")
        @test DB._github_org_repo(
            "https://github.com/EpiAware/ConvolvedDistributions.jl") ==
              ("EpiAware", "ConvolvedDistributions.jl")
        @test DB._github_org_repo(
            "git@github.com:EpiAware/ConvolvedDistributions.jl.git") ==
              ("EpiAware", "ConvolvedDistributions.jl")
        # Non-GitHub hosts have no GitHub remote to derive.
        @test DB._github_org_repo(
            "https://gitlab.com/x/Y.jl.git") === nothing
        @test DB._github_org_repo("") === nothing
    end

    @testset "_remote_spec picks the revision, else the version tag" begin
        url = "https://github.com/EpiAware/ConvolvedDistributions.jl.git"
        # A git-tracked dependency links against the tracked revision.
        @test DB._remote_spec(url, "main", v"0.1.0") ==
              ("EpiAware", "ConvolvedDistributions.jl", "main")
        # With no revision, the installed version's tag names a tagged tree.
        @test DB._remote_spec(url, nothing, v"0.1.0") ==
              ("EpiAware", "ConvolvedDistributions.jl", "v0.1.0")
        # Nothing derivable without a URL, a ref, or a GitHub host.
        @test DB._remote_spec(url, nothing, nothing) === nothing
        @test DB._remote_spec(nothing, "main", v"0.1.0") === nothing
        @test DB._remote_spec("https://gitlab.com/x/Y.jl", "main", v"0.1.0") ===
              nothing
    end

    @testset "api_remotes: extra_remotes escape hatch" begin
        dir = mktempdir()
        # An "Org/Repo.jl" string is expanded into a GitHub remote...
        remotes = DB.api_remotes(Module[]; extra_remotes = Dict(
            dir => "Org/Repo.jl"))
        remote, ref = remotes[realpath(dir)]
        @test remote == Documenter.Remotes.GitHub("Org", "Repo.jl")
        @test ref == "main"
        # ...and an explicit Documenter remote/ref pair passes straight through.
        explicit = (Documenter.Remotes.GitHub("Org", "Other.jl"), "v1.2.3")
        remotes = DB.api_remotes(Module[]; extra_remotes = Dict(
            dir => explicit))
        @test remotes[realpath(dir)] == explicit
    end

    @testset "api_remotes: skips modules with no derivable remote" begin
        # The kit is `develop`ed in its own test environment: its source tree is
        # a git checkout Documenter resolves by itself, so no remote is added.
        @test isempty(DB.api_remotes([EpiAwarePackageTools]))
        # A module with no package directory (Base) is skipped, not an error.
        @test isempty(DB.api_remotes([Base]))
    end
end

@testitem "empty-anchor inventory guard (#232)" begin
    using Test

    # DocumenterVitepress' writer pushes an inventory entry for every anchored
    # header, and `DocInventories.InventoryItem` rejects an empty `name`, so a
    # header with an empty anchor id (e.g. from a third-party docstring
    # rendered through the widened `modules` list) aborts the whole docs
    # build. The kit installs a warn-and-skip guard before `makedocs`.
    #
    # The guard mutates process-global state (DocumenterVitepress' method
    # table), and the "unguarded writer aborts" assertion below only holds
    # while nothing else in the process has patched it. So the whole scenario
    # runs in a fresh subprocess, which reports its observations as `key=value`
    # lines that the assertions here read back; no test-item ordering can
    # perturb it, and nothing leaks into the rest of the suite.
    script = """
    using Test
    using EpiAwarePackageTools
    DB = EpiAwarePackageTools.DocsBuild
    Documenter = DB._documenter()
    DocumenterVitepress = DB._vitepress()

    println("version=", pkgversion(DocumenterVitepress))
    println("aborts=", DB._empty_anchor_aborts(Documenter, DocumenterVitepress))
    println("patched=", DB._guard_empty_anchors())

    # An empty anchor id now warns (naming the page and the heading) and skips
    # the inventory entry instead of throwing.
    logs, (out, items) = Test.collect_test_logs() do
        DB._anchor_probe_render(Documenter, DocumenterVitepress;
            id = "", heading = "Culprit heading")
    end
    warns = filter(l -> l.level == Base.CoreLogging.Warn, logs)
    println("empty_items=", length(items))
    println("empty_out=", occursin("Culprit heading", out))
    println("empty_warns=", length(warns))
    if length(warns) == 1
        kw = Dict(warns[1].kwargs)
        println("warn_msg=", warns[1].message)
        println("warn_page=", kw[:page])
        println("warn_heading=", kw[:heading])
    end

    # A non-empty anchor id still produces its inventory entry, with no
    # warning.
    logs, (out, items) = Test.collect_test_logs() do
        DB._anchor_probe_render(Documenter, DocumenterVitepress;
            id = "real-anchor", heading = "Real heading")
    end
    println("real_items=", length(items))
    println("real_name=", isempty(items) ? "" : items[1].name)
    println("real_out=", occursin("{#real-anchor}", out))
    println("real_warns=",
        length(filter(l -> l.level == Base.CoreLogging.Warn, logs)))

    # Idempotent + self-retiring: with the writer no longer aborting (here
    # because the guard is in place; upstream, once
    # LuxDL/DocumenterVitepress.jl#375 lands) the kit does not patch again.
    println("aborts_after=",
        DB._empty_anchor_aborts(Documenter, DocumenterVitepress))
    println("patched_again=", DB._guard_empty_anchors())
    """
    file = joinpath(mktempdir(), "guard232.jl")
    write(file, script)
    output = read(`$(Base.julia_cmd()) --project=$(Base.active_project()) \
        --startup-file=no $file`, String)
    obs = Dict{String, String}()
    for line in eachsplit(output, '\n')
        occursin('=', line) || continue
        key, value = split(line, '='; limit = 2)
        obs[strip(key)] = strip(value)
    end

    if obs["aborts"] == "false"
        # Upstream fixed (or the writer changed): the shim is dead weight and
        # should be deleted, but that is a maintenance task, not a red suite on
        # an unrelated PR — so record it loudly and assert only that the kit
        # stops monkey-patching.
        @info "DocumenterVitepress $(obs["version"]) no longer aborts on an " *
              "empty anchor id: delete the DocsBuild empty-anchor shim (#232)"
        @test obs["patched"] == "false"
    else
        # The guard installs, and the warning names the culprit.
        @test obs["patched"] == "true"
        @test obs["empty_items"] == "0"
        @test obs["empty_out"] == "true"
        @test obs["empty_warns"] == "1"
        @test occursin("empty anchor id", obs["warn_msg"])
        @test occursin("probe.md", obs["warn_page"])
        @test occursin("Culprit heading", obs["warn_heading"])

        # A non-empty anchor id is untouched.
        @test obs["real_items"] == "1"
        @test obs["real_name"] == "real-anchor"
        @test obs["real_out"] == "true"
        @test obs["real_warns"] == "0"

        # Idempotent, and no second patch once the writer no longer aborts.
        @test obs["aborts_after"] == "false"
        @test obs["patched_again"] == "false"
    end
end

@testitem "empty-anchor guard refuses to patch (#232)" begin
    using Test
    using EpiAwarePackageTools

    # The two branches on which the guard declines to touch the writer. Neither
    # patches anything, so unlike the guard's happy path (above) these need no
    # subprocess isolation: `_vitepress_patchable` is a pure predicate of the
    # version, and the probe below is driven with a stand-in module, leaving the
    # real DocumenterVitepress method table untouched.
    DB = EpiAwarePackageTools.DocsBuild

    # Too new to patch: the shim's body is a copy of
    # `_VITEPRESS_LAST_KNOWN_BROKEN`'s method, so overwriting a newer writer
    # would silently revert unseen upstream changes to it. Refuse, loudly.
    broken = DB._VITEPRESS_LAST_KNOWN_BROKEN
    @test DB._vitepress_patchable(broken)
    @test DB._vitepress_patchable(VersionNumber(broken.major, broken.minor,
        broken.patch - 1))
    newer = VersionNumber(broken.major, broken.minor, broken.patch + 1)
    msg = (:warn, r"newer than the version this shim copies")
    @test_logs msg @test !DB._vitepress_patchable(newer)
    @test_logs msg @test !DB._vitepress_patchable(v"1.0.0")

    # Unknown version: `pkgversion` returns `nothing` for a module carrying no
    # version, and an unknown version is the same question as a too-new one —
    # we cannot show the installed writer is the one we copied, so we decline.
    @test_logs (:warn, r"[Cc]ould not determine the installed") begin
        @test !DB._vitepress_patchable(nothing)
    end

    # Upstream API drift: the probe fails in a way that is not the known
    # `InventoryItem` abort, so the kit does not claim the writer is broken and
    # does not overwrite a method it no longer understands. Driven with a
    # stand-in for DocumenterVitepress whose `render` fails some other way, so
    # the real writer is neither probed nor patched here.
    @eval module DriftedVitepress
    render(args...; kwargs...) = error("upstream renamed the writer")
    end
    Documenter = DB._documenter()
    @test_logs (:warn, r"probe failed unexpectedly") begin
        @test !DB._empty_anchor_aborts(Documenter, DriftedVitepress)
    end
end
