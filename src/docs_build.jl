# Generic documentation-build machinery.
#
# This is the package-agnostic core of the EpiAware docs standard: the build
# steps that every package's `docs/make.jl` would otherwise copy inline. The
# managed `make.jl` template is a thin caller — it wires the package-owned
# `pages.jl` + `docs_config.jl` into [`build_docs`](@ref) and nothing else, so
# the logic lives here (versioned + tested) rather than in each repo.
#
# The steps reproduce CensoredDistributions.jl's bespoke build generically:
#
#   - the Literate.jl tutorial pipeline (light tutorials rendered in-process,
#     heavy tutorials each executed in a fresh subprocess); on `skip_notebooks`
#     the light tutorials still render in-process (they are cheap) and only
#     the heavy tutorials fall back to fast-build heading stubs,
#   - `src/index.md` generated from the package README (badge block stripped,
#     optional package-named sections stripped, ```julia blocks turned into
#     `@example readme`, link rewrites applied),
#   - `src/release-notes.md` generated from a project-root `NEWS.md` + the
#     package-owned header,
#   - `src/benchmarks.md`: a tight managed skeleton (page heading + the
#     package-owned prose hook + a data-driven performance-history section that
#     renders the published timeline) — no package-specific free text,
#   - the API reference pages (`lib/public.md`, `lib/internals.md`) from the
#     module's documented bindings (one `@docs` entry per binding), and
#   - the render + deploy with `DocumenterVitepress` (adding DocumenterCitations
#     when a `src/refs.bib` exists).
#
# Documenter / DocumenterVitepress / DocumenterCitations / Literate are loaded
# at call time via `Base.require` (as the Benchmarks harness loads JSON3 /
# BenchmarkTools) so they stay out of the kit's own dependencies; a caller only
# needs them in its `docs` environment. Calls into the loaded modules go through
# `invokelatest` because their methods live in a newer world age.

"""
    EpiAwarePackageTools.DocsBuild

Generic documentation-build machinery shared across EpiAware packages.

[`build_docs`](@ref) runs the whole standard build for a package module; the
managed `docs/make.jl` is a thin caller that forwards the package-owned
`pages.jl` + `docs_config.jl` values. The individual steps
([`build_index`](@ref), [`build_release_notes`](@ref),
[`build_benchmark_page`](@ref), [`build_api_pages`](@ref)) are public so they
can be unit-tested and reused in isolation.
"""
module DocsBuild

import ..EpiAwarePackageTools: _require_pkg
import Statistics

export build_docs, build_index, build_release_notes, build_benchmark_page,
       build_api_pages, api_bindings, api_owning_modules

# ---- lazy dependency loading ----------------------------------------------

# Resolve the heavy docs dependencies at call time so they are not hard
# dependencies of EpiAwarePackageTools; a package only needs them in its `docs`
# environment. `_require_pkg` (defined once in the parent module, #58) is
# shared with every other lazy-load site in the kit.
function _documenter()
    _require_pkg("e30172f5-a6a5-5a46-863b-614d45cd2de4", "Documenter")
end
function _vitepress()
    _require_pkg("4710194d-e776-4893-9690-8d956a29c365", "DocumenterVitepress")
end
function _citations()
    _require_pkg("daee34ce-89f3-4625-b898-19384cb65244", "DocumenterCitations")
end
function _literate()
    _require_pkg("98b081ad-f1c9-55d3-8b20-4c87d4299306", "Literate")
end
# `Plots` (GR backend) draws the overall trend plot (#202); only needed once
# a package opts into `BENCHMARK_PAGE = true`, so it stays lazy like every
# other docs dependency here.
function _plots()
    _require_pkg("91a5bcdd-55d7-5caf-9e0b-520d859cae80", "Plots")
end

# ---- README -> index.md ---------------------------------------------------

"""
    build_index(; readme, dest, repo, execute=true,
                rewrites=Pair{String,String}[], strip_sections=String[])

Generate `dest` (the docs home page) from the package `readme`.

The managed badge block (between the `<!-- badges:start -->` /
`<!-- badges:end -->` markers) and an inline logo `<img>` in the title are
removed. ```julia fences become runnable `@example readme` blocks when
`execute` is `true`. Each `from => to` in `rewrites` is applied line by line
(e.g. an absolute docs URL rewritten to an in-site `@ref`). Any heading whose
title is listed in `strip_sections` is dropped together with its body (up to
the next heading of the same or a higher level) — this is the package-owned
hook for omitting a named README section from the home page; the managed build
hardcodes no such section.
"""
function build_index(; readme::AbstractString, dest::AbstractString,
        repo::AbstractString, execute::Bool = true,
        rewrites = Pair{String, String}[],
        strip_sections = String[])
    mkpath(dirname(dest))
    open(dest, "w") do io
        println(io, "```@meta")
        println(io, "EditURL = \"https://github.com/$repo/blob/main/README.md\"")
        println(io, "```")
        println(io)
        in_badges = false
        strip_level = 0
        for line in eachline(readme)
            if occursin("<!-- badges:start -->", line)
                in_badges = true
                continue
            elseif occursin("<!-- badges:end -->", line)
                in_badges = false
                continue
            end
            in_badges && continue
            # Named-section stripping (package-config driven). A heading at a
            # level <= the section being stripped ends the stripped span; that
            # heading is then itself considered as a possible new strip start.
            m = match(r"^(#+)\s+(.*?)\s*$", line)
            if m !== nothing
                level = length(m.captures[1])
                if strip_level > 0 && level <= strip_level
                    strip_level = 0
                end
                if strip_level == 0 && strip(m.captures[2]) in strip_sections
                    strip_level = level
                    continue
                end
            end
            strip_level > 0 && continue
            if execute && startswith(line, "```julia")
                println(io, "```@example readme")
            elseif occursin("docs/src/assets/logo.svg", line)
                println(io, replace(line,
                    r"\s*<img[^>]*docs/src/assets/logo\.svg[^>]*>" => ""))
            else
                for (from, to) in rewrites
                    line = replace(line, from => to)
                end
                println(io, line)
            end
        end
    end
    println("Generated index.md from README.md")
    return dest
end

# ---- release-notes.md -----------------------------------------------------

"""
    build_release_notes(; news, header_file, dest)

Generate `dest` from a project-root `news` file prefixed with the package-owned
release-notes header defined in `header_file` (which must set
`RELEASE_NOTES_HEADER`). Both are optional: if either is missing nothing is
written and `nothing` is returned.
"""
function build_release_notes(; news::AbstractString, header_file::AbstractString,
        dest::AbstractString)
    if isfile(news) && isfile(header_file)
        # Evaluate the header file in a throwaway module and take the value it
        # returns (its trailing `const RELEASE_NOTES_HEADER = "..."`). Using the
        # include return value rather than reading the binding back avoids the
        # stricter global-binding world-age rules in Julia >= 1.12.
        header = Base.include(Module(:ReleaseNotesHeader), header_file)
        open(dest, "w") do io
            print(io, header)
            for line in eachline(news)
                println(io, line)
            end
        end
        println("Generated release-notes.md from header + NEWS.md")
        return dest
    else
        println("No NEWS.md / release-notes header found; skipping release notes")
        return nothing
    end
end

# ---- benchmark history page -----------------------------------------------

"""
    _embed_benchmark_history(io, repo, project_root; fetch = true,
                             history_suites = String[], history_commits = 5,
                             history_regression_threshold = 1.1,
                             overall_plot_dest = nothing, notes = "")

Render the published benchmark timeline into `io`.

The history is published by `benchmark-history.yaml` to the repo's
`benchmarks` branch under `history/` (per-benchmark PNG plots + a
`table.md` ratio summary). GitHub Pages serves only the gh-pages docs
site, so the history is shown here by enumerating the branch at build
time (a best-effort `git fetch`) and rendering an overall summary plus the
detail. When the branch does not exist yet (no release has published a
timeline) it degrades to a link to the branch.

The raw `table.md` is a single flat table with one row per leaf benchmark
(a `Suite/.../Leaf` slash-path) and one column per benchmarked revision
(labelled by commit hash) — unreadable spliced verbatim at realistic suite
sizes (200+ rows, #193). It is reshaped into two layers
([`_render_benchmark_overview`](@ref)): a `## Benchmark summary (overall)`
table (one row per suite: its median ratio against the oldest shown
revision, a trend arrow and a regression flag) plus a combined trend plot,
and — collapsed behind a `<details>` below it — the existing per-suite
`###` ratio tables and per-benchmark plot wall. Both layers cap to the last
`history_commits` revisions (columns relabelled with commit dates instead
of raw hashes) and `history_suites` (when non-empty) restricts either to
the named headline suites. `overall_plot_dest`, when given, is where the
combined trend plot PNG is written (skipped when `nothing`, e.g. from a
caller that only wants the tabular content).
"""
function _embed_benchmark_history(io, repo::AbstractString,
        project_root::AbstractString; fetch::Bool = true,
        history_suites = String[], history_commits::Integer = 5,
        history_regression_threshold::Real = 1.1,
        overall_plot_dest::Union{Nothing, AbstractString} = nothing,
        notes::AbstractString = "")
    ref = _benchmarks_ref(project_root; fetch = fetch)
    if ref !== nothing
        files = _history_files(project_root, ref)
        pngs = sort!(filter(f -> endswith(f, ".png"), files))
        has_table = "history/table.md" in files
        if has_table || !isempty(pngs)
            if has_table
                tbl = read(`git -C $project_root show $ref:history/table.md`,
                    String)
                _render_benchmark_overview(io, tbl, project_root, pngs, repo;
                    last_n = history_commits, suites = history_suites,
                    regression_threshold = history_regression_threshold,
                    plot_dest = overall_plot_dest, notes = notes)
            elseif !isempty(pngs)
                _write_benchmark_notes(io, notes)
                _embed_history_plots(io, repo, pngs)
            end
            return true
        end
    end
    _write_benchmark_notes(io, notes)
    println(io,
        "The performance timeline (per-benchmark plots and a ratio table) is")
    println(io,
        "published to the [`benchmarks` branch]" *
        "(https://github.com/$repo/tree/benchmarks/history) on each push to")
    println(io, "`main` and each tagged release.")
    return false
end

# The resolvable git ref for the `benchmarks` branch, or `nothing`. A
# best-effort fetch first so a docs-build checkout (which by default fetches
# only the built ref) can still see it. The fetch uses an explicit refspec
# (`+refs/heads/benchmarks:refs/remotes/origin/benchmarks`) rather than a bare
# `git fetch origin benchmarks`: the latter lands only in `FETCH_HEAD` and
# never creates the `origin/benchmarks` tracking ref the lookup below checks,
# so on a single-branch/shallow CI checkout the branch was fetched yet stayed
# invisible and the page silently rendered empty (#192). Failures (offline, or
# no `benchmarks` branch yet) are expected and non-fatal, but now log a
# one-line reason instead of degrading silently.
function _benchmarks_ref(project_root::AbstractString; fetch::Bool = true)
    if fetch
        try
            run(pipeline(`git -C $project_root fetch --no-tags origin
                    +refs/heads/benchmarks:refs/remotes/origin/benchmarks`;
                stdout = devnull, stderr = devnull))
        catch err
            @info "benchmark history: could not fetch the `benchmarks` " *
                  "branch (offline, or it does not exist yet); the page " *
                  "will use any locally present ref or the fallback link" exception = err
        end
    end
    for ref in ("origin/benchmarks", "benchmarks")
        try
            run(pipeline(`git -C $project_root rev-parse --verify --quiet $ref`;
                stdout = devnull, stderr = devnull))
            return ref
        catch
        end
    end
    @info "benchmark history: no `benchmarks` ref resolvable after fetch; " *
          "rendering the fallback link (publish a timeline via " *
          "benchmark-history.yaml to populate this page)"
    return nothing
end

function _history_files(project_root::AbstractString, ref::AbstractString)
    try
        out = read(
            `git -C $project_root ls-tree -r --name-only $ref -- history`,
            String)
        return filter(!isempty, split(out, '\n'))
    catch
        return String[]
    end
end

# ---- benchmark history: table reshaping (#193) -----------------------------

# Parse a GitHub-flavoured pipe table into a vector of cell-rows (the leading
# and trailing empty cells from the `|...|` delimiters dropped). Non-table
# lines are ignored, so surrounding prose in `table.md` is skipped.
function _parse_pipe_table(md::AbstractString)
    rows = Vector{String}[]
    for raw in split(md, '\n')
        ln = strip(raw)
        startswith(ln, "|") || continue
        cells = map(strip, split(ln, '|'))
        length(cells) >= 2 || continue
        push!(rows, String.(cells[2:(end - 1)]))
    end
    return rows
end

# Whether every cell is a markdown alignment marker (`---`, `:---`, `:---:`),
# i.e. the header separator row.
_is_alignment_row(cells) = !isempty(cells) && all(c -> occursin(r"^:?-+:?$", c), cells)

# Split a parsed `table.md` into its revision-column labels and its data rows
# (`name => values`). The header's first cell is the empty benchmark-name
# column, so the revision labels are the remaining header cells.
function _history_table_parts(md::AbstractString)
    all_rows = _parse_pipe_table(md)
    isempty(all_rows) && return (String[], Pair{String, Vector{String}}[])
    header = all_rows[1]
    col_labels = length(header) > 1 ? header[2:end] : String[]
    entries = Pair{String, Vector{String}}[]
    for r in all_rows[2:end]
        (isempty(r) || _is_alignment_row(r)) && continue
        push!(entries, r[1] => (length(r) > 1 ? r[2:end] : String[]))
    end
    return (col_labels, entries)
end

# Keep only the last `n` revision columns (the most recent points on the
# timeline). Rows whose width does not match the header are left untouched so a
# malformed row never throws.
function _cap_columns(col_labels, entries, n::Integer)
    ncol = length(col_labels)
    (n <= 0 || n >= ncol) && return (col_labels, entries)
    keep = (ncol - n + 1):ncol
    capped = map(entries) do (name, vals)
        length(vals) == ncol ? (name => vals[keep]) : (name => vals)
    end
    return (col_labels[keep], capped)
end

# The short commit date for `label` (a benchpkgtable column header), or `label`
# unchanged. Column headers are truncated commit hashes (a trailing `...`) for
# SHA revs and plain names for tag revs; only the former resolve to a date.
function _commit_date(project_root::AbstractString, label::AbstractString)
    ref = rstrip(replace(strip(label), "..." => "", "…" => ""))
    (isempty(ref) || !occursin(r"^[0-9a-fA-F]{7,40}$", ref)) && return label
    try
        d = strip(read(pipeline(`git -C $project_root show -s
                --date=short --format=%cd $ref`; stderr = devnull), String))
        return isempty(d) ? label : d
    catch
        return label
    end
end

# Relabel each revision column with its commit date where resolvable.
function _relabel_history_columns(col_labels, project_root)
    [_commit_date(project_root, l) for l in col_labels]
end

# Group `name => values` rows by the first `/`-segment of each name, preserving
# first-seen order; the segment is stripped from the per-row label. A name with
# no `/` (e.g. `time_to_load`) forms its own single-row suite.
function _group_rows_by_suite(entries)
    groups = Pair{String, Vector{Pair{String, Vector{String}}}}[]
    index = Dict{String, Int}()
    for (name, vals) in entries
        slash = findfirst('/', name)
        if slash === nothing
            suite, label = name, name
        else
            suite = name[1:prevind(name, slash)]
            label = name[nextind(name, slash):end]
        end
        if !haskey(index, suite)
            push!(groups, suite => Pair{String, Vector{String}}[])
            index[suite] = length(groups)
        end
        push!(groups[index[suite]].second, label => vals)
    end
    return groups
end

# Parse, cap, relabel and group `table.md` into per-suite rows: the shared
# reshaping step behind both the detail sub-tables
# ([`_render_ratio_table`](@ref)) and the overall summary
# ([`_benchmark_summary_rows`](@ref)). Returns `(col_labels, groups)`; `groups`
# is empty when `suites` filters everything out (an unparseable `md` is the
# caller's concern — check `_history_table_parts(md)` first).
function _reshape_history_table(md::AbstractString,
        project_root::AbstractString; last_n::Integer = 5, suites = String[])
    col_labels, entries = _history_table_parts(md)
    col_labels, entries = _cap_columns(col_labels, entries, last_n)
    col_labels = _relabel_history_columns(col_labels, project_root)
    groups = _group_rows_by_suite(entries)
    if !isempty(suites)
        wanted = Set(String.(suites))
        groups = filter(g -> g.first in wanted, groups)
    end
    return (col_labels, groups)
end

# Write one grouped markdown sub-table (`| Benchmark | <cols...> |`).
function _write_history_subtable(io, col_labels, subrows)
    println(io, "| Benchmark | ", join(col_labels, " | "), " |")
    println(io, "|:---|", repeat(":---:|", max(length(col_labels), 1)))
    for (label, vals) in subrows
        println(io, "| ", label, " | ", join(vals, " | "), " |")
    end
    return
end

# Write the reshaped per-suite detail: the "_Most recent N revisions_"
# caption, one grouped `###` sub-table per suite, or a "no suites matched"
# note when `history_suites` filtered everything out. Takes the already
# reshaped `(col_labels, groups)` ([`_reshape_history_table`](@ref)) so a
# caller that already has them (the overall-summary orchestrator,
# [`_render_benchmark_overview`](@ref)) does not re-parse `table.md` and
# re-shell out to `git show` (once per column, for the commit-date
# relabelling) a second time.
function _write_reshaped_detail(io, col_labels, groups)
    if !isempty(col_labels)
        n = length(col_labels)
        println(io, "_Most recent ", n, n == 1 ? " revision" : " revisions",
            ", columns labelled by commit date._")
        println(io)
    end
    if isempty(groups)
        println(io,
            "_No benchmark suites matched the configured `history_suites`._")
        println(io)
        return
    end
    for (suite, subrows) in groups
        println(io, "### ", suite)
        println(io)
        _write_history_subtable(io, col_labels, subrows)
        println(io)
    end
    return
end

# Give a pipe table's header its benchmark-name label when the first cell is
# empty. benchpkgtable emits the leaf-name column with a blank header (`|   |
# rev | ... |`); spliced verbatim (the parse-failure fallback below), that
# empty leading header cell is misparsed by DocumenterVitepress's inventory
# writer into an anchored header with an empty anchor id, which aborts the
# deploy build with `ArgumentError: \`name\` must have non-zero length` (#204).
# The reshaped path already labels its tables (`| Benchmark |`/`| Suite |`); this
# hardens the one remaining verbatim path so no emitted table can carry an empty
# leading header cell. Only the first such row (the header) is relabelled.
function _label_empty_leading_header(
        md::AbstractString; label::AbstractString = "Benchmark")
    repl = SubstitutionString("\\1| " * label * " |")
    return replace(md, r"(?m)^([ \t]*)\|[ \t]*\|" => repl; count = 1)
end

# Reshape the raw `table.md` into grouped, capped, date-labelled per-suite
# tables (see [`_embed_benchmark_history`](@ref)). Falls back to splicing the
# table verbatim if it cannot be parsed, so a format change never blanks the
# page — sanitising the header first so the fallback cannot emit an empty
# anchor (#204).
function _render_ratio_table(io, md::AbstractString,
        project_root::AbstractString; last_n::Integer = 5,
        suites = String[])
    if isempty(_history_table_parts(md)[2])
        println(io, _label_empty_leading_header(rstrip(md)))
        println(io)
        return
    end
    col_labels, groups = _reshape_history_table(md, project_root;
        last_n = last_n, suites = suites)
    _write_reshaped_detail(io, col_labels, groups)
    return
end

# Collapse the per-benchmark plot wall behind a `<details>` so the page stays
# skimmable (#193). benchpkgplot names plots `plot_<Package>_<N>.png` with no
# suite in the filename, so they cannot be grouped per suite; they are shown as
# one collapsed block of raw-GitHub images.
function _embed_history_plots(io, repo::AbstractString, pngs)
    println(io, "### Per-benchmark timelines")
    println(io)
    println(io, "<details>")
    println(io, "<summary>Show ", length(pngs),
        length(pngs) == 1 ? " plot" : " plots", "</summary>")
    println(io)
    for p in pngs
        url = "https://raw.githubusercontent.com/$repo/benchmarks/$p"
        println(io, "![$(basename(p))]($url)")
        println(io)
    end
    println(io, "</details>")
    println(io)
    return
end

# ---- benchmark history: overall summary (#202) -----------------------------

# The leading number in a benchpkgtable cell, e.g. `"0.112 ± 0.0006 ms"` ->
# `0.112`, `"1.0"` -> `1.0`. `nothing` for a cell with no leading number
# (blank, "—", or an unexpected format), so a malformed cell never throws.
# Reads `m.match` rather than `m.captures[1]`: with no optional groups in the
# pattern, `match` cannot fail to capture, but `.captures` is typed
# `Vector{Union{Nothing,SubString}}` regardless (JET flags the ensuing
# `tryparse(Float64, ::Union{Nothing,SubString})` as a possible error);
# `.match` is always a concrete `SubString`.
function _parse_metric_value(cell::AbstractString)
    m = match(r"^\s*[0-9]+(?:\.[0-9]+)?", cell)
    m === nothing && return nothing
    return tryparse(Float64, strip(m.match))
end

# One value per (already capped) revision column: the median of a suite's
# per-benchmark values in that column, `missing` when none of the suite's
# rows parse for that column. A row whose width does not match `ncol` is
# skipped entirely (not read positionally): `_cap_columns` leaves a
# malformed row's original, uncapped-width cells untouched (#193), so
# indexing it as if it were capped would silently pair its stale, oldest
# values with the newest (capped) columns — wrong data with no visible sign
# of the misalignment, feeding straight into the headline summary/plot.
function _suite_column_medians(subrows, ncol::Integer)
    out = Vector{Union{Float64, Missing}}(missing, ncol)
    for j in 1:ncol
        vals = Float64[]
        for (_, cellvals) in subrows
            length(cellvals) == ncol || continue
            v = _parse_metric_value(cellvals[j])
            v === nothing || push!(vals, v)
        end
        isempty(vals) || (out[j] = Statistics.median(vals))
    end
    return out
end

# Normalise a suite's per-column medians to a ratio series against its first
# finite AND NON-ZERO value in the (capped) window, i.e. 1.0 at the oldest
# comparable revision. A zero baseline is skipped rather than divided by: a
# genuine `0.0` median (e.g. "0 bytes allocated") is valid data, but using it
# as the denominator would make the baseline itself `0/0 = NaN` and every
# later column `x/0 = ±Inf`, breaking the "1.0 at the oldest revision"
# invariant and silently defeating the finite-value checks downstream. All
# `missing` when no such baseline exists (nothing to compare against).
# `medians` is `AbstractVector` rather than the exact
# `Vector{Union{Float64,Missing}}` because a comprehension with no `missing`
# among its actual values narrows to `Vector{Float64}` (Julia infers a
# comprehension's eltype from the values it produces, not a declared type).
function _suite_ratio_series(medians::AbstractVector)
    baseline_idx = findfirst(v -> !ismissing(v) && v != 0, medians)
    baseline_idx === nothing &&
        return Vector{Union{Float64, Missing}}(missing, length(medians))
    baseline = medians[baseline_idx]
    return [ismissing(v) ? missing : v / baseline for v in medians]
end

# `(ratio, trend, status)` for one suite's ratio series. `ratio` is the most
# recent finite value (the change since the oldest shown revision; 1.0 == no
# change). `trend` compares it against `1 ± flat_threshold`. `status` flags a
# regression once `ratio` reaches `regression_threshold` — higher-is-worse,
# matching the runtime/memory metrics `table.md` reports. Fewer than two
# finite points give no signal. `finite` excludes `NaN`/`Inf` as well as
# `missing` — belt-and-suspenders alongside the zero-baseline guard in
# [`_suite_ratio_series`](@ref), so a future change that reintroduces a
# non-finite ratio degrades to "n/a" rather than comparing `NaN` against the
# thresholds (silently `false` every time, rendering as an unremarkable
# "no change" row instead of flagging the missing signal). `ratio_series` is
# `AbstractVector` for the same reason as `_suite_ratio_series`'s input.
function _suite_trend_status(ratio_series::AbstractVector;
        regression_threshold::Real = 1.1, flat_threshold::Real = 0.02)
    finite = findall(v -> !ismissing(v) && isfinite(v), ratio_series)
    length(finite) < 2 && return (missing, "→", "n/a")
    ratio = ratio_series[finite[end]]
    trend = if ratio >= 1 + flat_threshold
        "↗"
    elseif ratio <= 1 - flat_threshold
        "↘"
    else
        "→"
    end
    status = ratio >= regression_threshold ? "⚠ reg" : "ok"
    return (ratio, trend, status)
end

_fmt_ratio(::Missing) = "n/a"
_fmt_ratio(r::Real) = isfinite(r) ? string(round(r; digits = 2)) : "n/a"

# Per-suite ratio series from the same `(col_labels, groups)` shape
# [`_reshape_history_table`](@ref) produces — the shared input to both the
# summary table and the overall trend plot.
function _suite_ratio_series_by_group(groups, ncol::Integer)
    return [(suite, _suite_ratio_series(_suite_column_medians(subrows, ncol)))
            for (suite, subrows) in groups]
end

# One summary row per suite: `(suite, ratio, trend, status)`.
function _benchmark_summary_rows(series_by_suite;
        regression_threshold::Real = 1.1)
    rows = NamedTuple{(:suite, :ratio, :trend, :status),
        Tuple{String, Union{Float64, Missing}, String, String}}[]
    for (suite, series) in series_by_suite
        ratio, trend, status = _suite_trend_status(series;
            regression_threshold = regression_threshold)
        push!(rows, (suite = suite, ratio = ratio, trend = trend,
            status = status))
    end
    return rows
end

# Write the `## Benchmark summary (overall)` table: one row per suite, its
# ratio against the oldest shown revision, a trend arrow and a regression
# flag. Leads the page — the one thing worth skimming — above the collapsed
# per-suite detail. Deliberately tight (a table + one caption line, matching
# the terseness of CensoredDistributions.jl's own PR-comparison comment,
# e.g. "Cells are PR median / base median. \U0001F534 >=1.10 (slower), ..."
# — see `benchmark/comment/comment.jl`) rather than a multi-paragraph
# explainer.
function _write_benchmark_summary(io, rows)
    println(io, "## Benchmark summary (overall)")
    println(io)
    if isempty(rows)
        println(io, "_No benchmark suites to summarise._")
        println(io)
        return
    end
    println(io, "| Suite | Median ratio | Trend | Status |")
    println(io, "|:---|:---:|:---:|:---:|")
    for r in rows
        println(io, "| ", r.suite, " | ", _fmt_ratio(r.ratio), " | ",
            r.trend, " | ", r.status, " |")
    end
    println(io)
    println(io,
        "_Ratio: latest vs oldest shown revision (1.00 = no change, " *
        "higher = slower/larger). ⚠ reg = at/above the regression " *
        "threshold._")
    println(io)
    return
end

# Render the combined multi-suite trend plot to `dest_png`: one line per
# suite plotting its ratio series (against the oldest shown revision) across
# the (already date-relabelled) `col_labels`. Regenerated fresh on every docs
# build from the same `table.md` data as the summary table — unlike the
# per-benchmark plots (pre-rendered externally by `benchpkgplot`, embedded via
# raw-GitHub URL), there is nothing to fetch here. `Plots` (GR backend) is
# loaded lazily like every other heavy docs dependency in this module: a
# package only needs it once it sets `BENCHMARK_PAGE = true` (the scaffold
# seeds `docs/Project.toml` with it — see `_bench_docs_deps` — but an
# already-scaffolded package must add it by hand, `docs/Project.toml` being
# package-owned and never rewritten). Never fails the docs build: the two
# failure modes are logged and handled separately so a genuinely broken
# render (a real bug) is distinguishable from the expected "not installed
# yet" case — `Plots` missing degrades to `@info` (nothing plottable does
# too), a load-then-render failure degrades to `@warn`.
function _write_overall_trend_plot(dest_png::AbstractString, col_labels,
        series_by_suite)
    plottable = filter(series_by_suite) do (_, series)
        count(!ismissing, series) >= 2
    end
    if isempty(plottable)
        @info "benchmark history: fewer than two comparable revisions; " *
              "skipping the overall trend plot"
        return false
    end
    local Plots
    try
        Plots = _plots()
    catch err
        @info "benchmark history: `Plots` is not available in the docs " *
              "environment; add it to `docs/Project.toml` to enable the " *
              "overall trend plot" exception = err
        return false
    end
    try
        Base.invokelatest() do
            # GR's default Qt/X11 terminal hangs on a headless CI runner; the
            # null terminal renders straight to file with no display.
            ENV["GKSwstype"] = get(ENV, "GKSwstype", "100")
            Plots.gr()
            x = 1:length(col_labels)
            plt = Plots.plot(; xlabel = "Revision", ylabel = "Ratio",
                legend = :outertopright, size = (900, 500),
                xticks = (x, col_labels), xrotation = 30,
                title = "Overall benchmark trend")
            for (suite, series) in plottable
                Plots.plot!(plt, x, series; label = suite, marker = :circle)
            end
            mkpath(dirname(dest_png))
            Plots.savefig(plt, dest_png)
        end
        return true
    catch err
        @warn "benchmark history: the overall trend plot failed to " *
              "render; the summary table still renders without it" exception = err
        return false
    end
end

# Suite-qualified labels of leaf benchmarks whose EVERY capped-column cell
# fails to parse as a number — present in the published table but with no
# usable data in the shown window (an errored or skipped benchmark in the
# run), auto-surfaced alongside the maintainer's own notes. A no-`/` name
# (e.g. `time_to_load`) is its own single-row suite in `groups`
# (`_group_rows_by_suite`: `suite == label == name`); reconstruct the flat
# name as just that value rather than doubling it into `"name/name"`.
function _unparsed_benchmarks(groups)
    out = String[]
    for (suite, subrows) in groups
        for (label, vals) in subrows
            isempty(vals) && continue
            all(v -> _parse_metric_value(v) === nothing, vals) &&
                push!(out, label == suite ? label : "$suite/$label")
        end
    end
    return out
end

# Write the "Skipped & broken benchmarks" notes block: the package-owned
# `notes` prose (`docs/benchmarks_notes.md`, write-once like the narrative
# prose hook) plus any auto-detected no-data benchmarks. Rendered
# unconditionally near the top of the page, even before any history has
# published, so a maintainer can document a known-skipped suite ahead of CI
# ever running. Renders nothing when there is neither prose nor a detection.
function _write_benchmark_notes(io, notes::AbstractString,
        auto::AbstractVector{<:AbstractString} = String[])
    (isempty(strip(notes)) && isempty(auto)) && return
    println(io, "### Skipped & broken benchmarks")
    println(io)
    isempty(strip(notes)) || (println(io, notes); println(io))
    if !isempty(auto)
        println(io, "_No data in the shown revisions: ",
            join(("`$a`" for a in auto), ", "), "._")
        println(io)
    end
    return
end

# Orchestrates the `## Performance history` body: the
# `## Benchmark summary (overall)` table + combined trend plot + the
# "Skipped & broken benchmarks" notes, then the existing per-suite ratio
# detail ([`_write_reshaped_detail`](@ref)) and per-benchmark plot wall
# ([`_embed_history_plots`](@ref)) collapsed together behind one `<details>`
# block. When `table.md` does not parse, skips straight to the original
# unreshaped fallback so a format change never blanks the page. `plot_dest
# === nothing` skips plot generation entirely (e.g. a caller that only wants
# the tabular content). Reshapes `table.md` once and reuses the result for
# both the summary and the detail section (rather than calling
# [`_render_ratio_table`](@ref), which would re-parse and re-shell out to
# `git show` a second time).
function _render_benchmark_overview(io, md::AbstractString,
        project_root::AbstractString, pngs, repo::AbstractString;
        last_n::Integer = 5, suites = String[],
        regression_threshold::Real = 1.1,
        plot_dest::Union{Nothing, AbstractString} = nothing,
        notes::AbstractString = "")
    if isempty(_history_table_parts(md)[2])
        _write_benchmark_notes(io, notes)
        println(io, "### Ratio summary")
        println(io)
        _render_ratio_table(io, md, project_root; last_n = last_n,
            suites = suites)
        !isempty(pngs) && _embed_history_plots(io, repo, pngs)
        return
    end
    col_labels, groups = _reshape_history_table(md, project_root;
        last_n = last_n, suites = suites)
    series_by_suite = _suite_ratio_series_by_group(groups, length(col_labels))
    _write_benchmark_summary(io,
        _benchmark_summary_rows(series_by_suite;
            regression_threshold = regression_threshold))
    if plot_dest !== nothing &&
       _write_overall_trend_plot(plot_dest, col_labels, series_by_suite)
        println(io, "![Overall benchmark trend](", basename(plot_dest), ")")
        println(io)
    end
    _write_benchmark_notes(io, notes, _unparsed_benchmarks(groups))
    println(io, "<details>")
    println(io, "<summary>Per-suite detail</summary>")
    println(io)
    println(io, "### Ratio summary")
    println(io)
    _write_reshaped_detail(io, col_labels, groups)
    !isempty(pngs) && _embed_history_plots(io, repo, pngs)
    println(io, "</details>")
    println(io)
    return
end

# The package-owned seed files (`docs/benchmarks.md`,
# `docs/benchmarks_notes.md`) open with an HTML authoring-guidance comment.
# Strip a leading comment block so Documenter never renders it as literal
# text on the Benchmarks page (#145). Splice-side so it holds even though
# the seed is package-owned and sync never rewrites it.
function _strip_seed_comment(s::AbstractString)
    lstrip(replace(s, r"^\s*<!--.*?-->"s => ""))
end

# The package-owned seed file's content, or `default` when the file is
# absent (a package predating it, or one that opted out).
function _read_seed(file::AbstractString, default::AbstractString)
    isfile(file) || return default
    return _strip_seed_comment(rstrip(read(file, String)))
end

"""
    build_benchmark_page(; dest, repo, package, prose_file, embed_history=true,
                         project_root=dirname(dirname(dest)),
                         notes_file=joinpath(dirname(dirname(dest)),
                                              "benchmarks_notes.md"),
                         history_suites=String[], history_commits=5,
                         history_regression_threshold=1.1)

Generate `dest` (the benchmark docs page). The managed skeleton is deliberately
tight: the page heading, the package-owned `prose_file` spliced verbatim (all
narrative lives there, minus any leading HTML comment, which is stripped so the
seed's authoring guidance never renders), and a data-driven
`## Performance history` section that
renders the timeline published to the repo's `benchmarks` branch (see
[`_embed_benchmark_history`](@ref)). `notes_file` is a second package-owned
seed (`docs/benchmarks_notes.md`) for hand-written notes on skipped or broken
benchmarks, spliced under a "Skipped & broken benchmarks" heading near the top
of the page (below the overall summary and trend plot); any benchmark with no
parseable data across the shown revisions is auto-appended there too.
`history_suites` (when non-empty) restricts the history to the named headline
suites, `history_commits` caps the ratio table and trend plot to that many
most-recent revisions, and `history_regression_threshold` sets the
overall-summary ratio (relative to the oldest shown revision) at or above
which a suite's `Status` flags "⚠ reg". Returns the list of linkcheck-ignore
regexes for the history URLs (the branch may not be live yet).
"""
function build_benchmark_page(; dest::AbstractString, repo::AbstractString,
        package::AbstractString, prose_file::AbstractString,
        embed_history::Bool = true,
        project_root::AbstractString = dirname(dirname(dest)),
        notes_file::AbstractString = joinpath(
            dirname(dirname(dest)), "benchmarks_notes.md"),
        history_suites = String[], history_commits::Integer = 5,
        history_regression_threshold::Real = 1.1)
    prose = _read_seed(prose_file, "Performance benchmarks for `$package`.")
    notes = _read_seed(notes_file, "")
    mkpath(dirname(dest))
    # The overall trend plot is a build artefact regenerated from `table.md`
    # on every docs build (like `index.md`/the API pages), so it lives beside
    # `benchmarks.md` in the built `src/` tree rather than on the
    # `benchmarks` branch alongside the externally pre-rendered per-benchmark
    # plots.
    plot_dest = joinpath(dirname(dest), "overall_trend.png")
    open(dest, "w") do io
        println(io, "# [Benchmarks](@id benchmarks)")
        println(io)
        println(io, prose)
        println(io)
        println(io, "## Performance history")
        println(io)
        if embed_history
            _embed_benchmark_history(io, repo, project_root;
                history_suites = history_suites,
                history_commits = history_commits,
                history_regression_threshold = history_regression_threshold,
                overall_plot_dest = plot_dest, notes = notes)
        else
            println(io,
                "A performance timeline is published on each release.")
        end
    end
    println("Generated benchmarks.md (benchmark history page)")
    esc = replace(repo, "." => "\\.", "/" => "/")
    return Regex[
        Regex("raw\\.githubusercontent\\.com/$esc/benchmarks"),
        Regex("github\\.com/$esc/tree/benchmarks")
    ]
end

# ---- API reference pages --------------------------------------------------

# Whether `sym` is part of `mod`'s public API, matching how Documenter's
# `@autodocs` partitions Public/Private (`Base.ispublic` on >= 1.11, else
# exported).
function _is_public(mod::Module, sym::Symbol)
    return @static if isdefined(Base, :ispublic)
        Base.ispublic(mod, sym)
    else
        Base.isexported(mod, sym)
    end
end

# Whether `mod.sym` resolves to a documented binding, following re-export
# aliases to the owning module (#160). A binding re-exported from another
# module (or declared `public`/exported from a submodule) keeps its docstring
# in the module that *defines* it, not in `Base.Docs.meta(mod)`, so a scan of
# `mod`'s own meta alone misses it and the generated `@docs` block omits it —
# leaving every `@ref` to that name a broken link in the built HTML. `aliasof`
# walks the alias to the canonical binding; the docstring is present iff that
# binding's own module records it.
function _is_documented(mod::Module, sym::Symbol)
    isdefined(mod, sym) || return false
    b = Base.Docs.aliasof(Base.Docs.Binding(mod, sym))
    return haskey(Base.Docs.meta(b.mod), b)
end

"""
    api_bindings(mod) -> (public, private)

The bindings `mod` documents, split into public and private symbol vectors.
Each binding is listed once (not once per method signature, as `@autodocs`
would), so the rendered `@index` has one entry per function.

The scan covers both the docstrings defined directly in `mod` and the names
`mod` exports or declares `public` — including bindings re-exported from
another module or a submodule, whose docstrings live in the defining module
rather than `mod`'s own metadata (#160). A public/exported name is only
included when it actually resolves to a documented binding, so the generated
`@docs` block never lists an undocumented name (which Documenter would reject).
"""
function api_bindings(mod::Module)
    # `mod`'s own documented bindings (public + private) plus every name it
    # exports or declares `public` (`names` returns exported + public names,
    # re-exports included). De-duplicate by symbol.
    own = Set(b.var for b in keys(Base.Docs.meta(mod)))
    surface = Set(names(mod; all = false))
    candidates = sort!(collect(union(own, surface)); by = string)
    public = Symbol[]
    private = Symbol[]
    for v in candidates
        v === nameof(mod) && continue  # skip the module's own docstring
        # A re-exported / `public` name that carries no docstring is dropped so
        # the emitted `@docs` block stays render-safe; `mod`'s own meta entries
        # are documented by construction.
        (v in own || _is_documented(mod, v)) || continue
        push!(_is_public(mod, v) ? public : private, v)
    end
    return public, private
end

# Whether `m` is `root` or nested inside it (a submodule at any depth). The
# parent chain of a top-level module is itself; `Main`/`Base` terminate it.
function _within(m::Module, root::Module)
    while true
        m === root && return true
        p = parentmodule(m)
        p === m && return false
        m = p
    end
end

"""
    api_owning_modules(mod) -> Set{Module}

The external *owning* modules of the re-exported docstrings `mod` documents —
each module outside `mod`'s own module tree that records a docstring for one of
the bindings [`api_bindings`](@ref) lists.

`mod`'s generated `@docs` blocks list re-exported / `public`-declared bindings
by their `mod.name` (e.g. `ComposedDistributions.Convolved`), but Documenter's
`@docs` resolver only resolves a listed name when the module that *owns* its
docstring is in `makedocs`' `modules` (it filters found docstrings to that
set). A re-export's docstring lives in the defining module, not `mod`, so
[`build_docs`](@ref) folds this set into `modules` — otherwise every such
`@docs` entry raises Documenter's "no docs found ... in `@docs` block" warning
and its `@ref`s break in the built HTML (#175). The owner is found by the same
`Base.Docs.aliasof` walk `api_bindings` uses. `mod` and its own submodules are
excluded: Documenter already discovers a package's submodules from `mod`
itself, so only cross-package owners need adding.
"""
function api_owning_modules(mod::Module)
    public, private = api_bindings(mod)
    owners = Set{Module}()
    for v in Iterators.flatten((public, private))
        isdefined(mod, v) || continue
        b = Base.Docs.aliasof(Base.Docs.Binding(mod, v))
        haskey(Base.Docs.meta(b.mod), b) || continue
        _within(b.mod, mod) && continue
        push!(owners, b.mod)
    end
    return owners
end

function _write_api_page(path, title, anchor, page, intro, api_heading,
        mod, names)
    mkpath(dirname(path))
    open(path, "w") do io
        if anchor === nothing
            println(io, "# $title")
        else
            println(io, "# [$title](@id $anchor)")
        end
        println(io)
        println(io, intro)
        println(io)
        println(io, "## Contents")
        println(io)
        println(io, "```@contents")
        println(io, "Pages = [\"$page\"]")
        println(io, "Depth = 2:2")
        println(io, "```")
        println(io)
        println(io, "## Index")
        println(io)
        println(io, "```@index")
        println(io, "Pages = [\"$page\"]")
        println(io, "```")
        println(io)
        println(io, "## $api_heading")
        println(io)
        println(io, "```@docs")
        for name in names
            println(io, string(mod, ".", name))
        end
        println(io, "```")
    end
    return path
end

"""
    build_api_pages(mod, lib_dir)

Write `lib/public.md` and `lib/internals.md` under `lib_dir` from `mod`'s
documented bindings (see [`api_bindings`](@ref)).
"""
function build_api_pages(mod::Module, lib_dir::AbstractString)
    public, private = api_bindings(mod)
    _write_api_page(
        joinpath(lib_dir, "public.md"),
        "Public Documentation", "public-api", "public.md",
        "Documentation for `$mod`'s public interface.",
        "Public API", mod, public)
    _write_api_page(
        joinpath(lib_dir, "internals.md"),
        "Internal Documentation", nothing, "internals.md",
        "Documentation for `$mod`'s internal interface.",
        "Internal API", mod, private)
    println(
        "Generated API pages: $(length(public)) public, " *
        "$(length(private)) internal bindings")
    return public, private
end

# ---- Literate tutorial pipeline -------------------------------------------

# Render the Literate tutorial pipeline into `tutorials_dir`. Light tutorials
# emit `@example` blocks Documenter runs in-process; heavy tutorials are each
# executed once in a fresh subprocess (via the package-owned
# `run_literate_tutorial.jl`) so native/memory state cannot accumulate.
function _process_tutorials(docs_dir, tutorials_dir, light, heavy)
    (isempty(light) && isempty(heavy)) && return
    Literate = _literate()
    if !isempty(light)
        println("Building light Literate tutorials " *
                "(this may take several minutes)...")
        # `DocumenterFlavor` lives in a newer world age than this function
        # (Literate is lazily `Base.require`d), so construct it through
        # `invokelatest` like every other call into the lazily-loaded deps.
        flavor = Base.invokelatest(Literate.DocumenterFlavor)
        for file in light
            Base.invokelatest(Literate.markdown,
                joinpath(tutorials_dir, file), tutorials_dir;
                flavor = flavor, mdstrings = true, credit = false)
        end
    end
    if !isempty(heavy)
        tutorial_threads = get(ENV, "JULIA_NUM_THREADS", "4")
        println("Executing heavy Literate tutorials, one per subprocess " *
                "($(tutorial_threads) threads each)...")
        runner = joinpath(docs_dir, "run_literate_tutorial.jl")
        jl = Base.julia_cmd()
        for file in heavy
            input = joinpath(tutorials_dir, file)
            println("  executing $file in a fresh subprocess...")
            opts = `--threads=$(tutorial_threads) --project=$(docs_dir)`
            run(`$jl $opts $runner $input $tutorials_dir`)
        end
    end
    println("Literate tutorial processing complete")
    return
end

# The rendered `.md` basename Literate produces for a tutorial source file
# (`tutorial_stubs` is keyed by this name, `light`/`heavy_tutorials` by the
# `.jl` source name).
_tutorial_md_name(jl_file) = string(splitext(jl_file)[1], ".md")

# The rendered `.md` names for `files` (a subset of `light`/`heavy_tutorials`
# `.jl` source names), as the `Set` `tutorial_stubs` is keyed by.
_tutorial_md_names(files) = Set(_tutorial_md_name(f) for f in files)

# The tutorial-processing step of `build_docs`, split out so it can be unit
# tested directly (`build_docs` itself is an integration point, exercised by
# each package's own docs build rather than by the kit's own test suite).
# Under `skip_notebooks`, light tutorials still render in-process (they are
# cheap); only the heavy tutorials — the ones the flag exists to skip — fall
# back to `tutorial_stubs` heading stubs. Independent of `skip_notebooks`,
# any heavy tutorial named in `force_stub` never executes and always renders
# from its `tutorial_stubs` heading — the escape hatch for a heavy tutorial
# that is not just slow but has an unresolved model/identifiability problem
# (so running it is not a matter of CI budget, e.g. a hung/non-terminating
# sampler), while its siblings keep executing for real in their own
# subprocess (unaffected — no need to fall back to whole-build stubbing just
# because one tutorial cannot run yet).
function _render_tutorials(docs_dir, tutorials_dir, skip_notebooks::Bool,
        light, heavy, stubs; force_stub = String[])
    if !skip_notebooks
        run_heavy = filter(!in(force_stub), heavy)
        _process_tutorials(docs_dir, tutorials_dir, light, run_heavy)
        if !isempty(force_stub)
            force_stub_md = _tutorial_md_names(force_stub)
            _write_tutorial_stubs(tutorials_dir,
                filter(p -> first(p) in force_stub_md, stubs))
        end
    else
        println("Fast docs build: rendering light tutorials in-process, " *
                "stubbing heavy tutorials (--skip-notebooks or " *
                "SKIP_NOTEBOOKS=true)")
        _process_tutorials(docs_dir, tutorials_dir, light, String[])
        heavy_md = _tutorial_md_names(heavy)
        heavy_stubs = filter(p -> first(p) in heavy_md, stubs)
        _write_tutorial_stubs(tutorials_dir, heavy_stubs)
    end
    return nothing
end

# Fast-build stubs: a lightweight `.md` for each tutorial so the nav resolves
# and cross-references still anchor without running the heavy pipeline.
function _write_tutorial_stubs(tutorials_dir, stubs)
    isempty(stubs) && return
    mkpath(tutorials_dir)
    for (file, heading) in stubs
        open(joinpath(tutorials_dir, file), "w") do io
            println(io, heading)
            println(io)
            println(io,
                "_This tutorial is omitted from the fast documentation " *
                "build. Build the full documentation (`task docs`) to " *
                "render it._")
        end
    end
    println("Wrote fast-build tutorial stubs")
    return
end

# Copy every tutorial data directory into the matching build output dir so the
# bundled data ships with the rendered site. Generic over any tutorial that
# carries a `data` or `<name>-data` dir.
function _copy_tutorial_data(src_root, build_root)
    for (root, dirs, _) in walkdir(src_root)
        for d in dirs
            (d == "data" || endswith(d, "-data")) || continue
            src_data = joinpath(root, d)
            rel = relpath(src_data, src_root)
            dest_data = joinpath(build_root, rel)
            mkpath(dirname(dest_data))
            cp(src_data, dest_data; force = true)
            println("Copied tutorial data: $rel")
        end
    end
    return
end

# ---- orchestrator ---------------------------------------------------------

# Remove any `... => "benchmarks.md"` leaf from a Documenter `pages` nav tree
# (at any nesting depth). Used when the benchmark page is disabled but a
# package-owned `pages.jl` still lists the entry, so the built nav carries no
# dangling link. Every non-benchmark entry is kept unchanged.
function _strip_benchmark_nav(pages)
    kept = Any[]
    for entry in pages
        if entry isa Pair && entry.second isa AbstractString
            endswith(entry.second, "benchmarks.md") && continue
            push!(kept, entry)
        elseif entry isa Pair && entry.second isa AbstractVector
            push!(kept, entry.first => _strip_benchmark_nav(entry.second))
        else
            push!(kept, entry)
        end
    end
    return kept
end

# Verify the Documenter-processed home page was not silently truncated by the
# (`npm install` + `vitepress build`) pipeline (#91): reproduced (though not
# reliably — the failure appears to depend on `docs/node_modules`/instantiate
# ordering) on a clean `docs/build`/`docs/node_modules`, `docs/make.jl` can
# exit 0 having copied only a PARTIAL `docs/src/index.md` into the internal
# `docs/build/.documenter/index.md`, with no error or warning — silently
# hiding real content (and any dead links inside it) from a local
# contributor. A genuinely complete Documenter pass never drops prose lines
# (`@ref`/`@example`/docstring expansion only ever adds content), so
# comparing line counts against the kit-generated source (already past any
# package's own rewrites/`strip_sections`) catches the failure loudly instead
# of silently shipping a half-built home page. `built_dir` may lack an
# `index.md` for callers that skip the Documenter build entirely (tests
# exercising only the page generators); there is then nothing to check.
function _check_index_not_truncated(index_src::AbstractString,
        built_dir::AbstractString)
    isfile(index_src) || return nothing
    built = joinpath(built_dir, "index.md")
    isfile(built) || return nothing
    src_lines = countlines(index_src)
    built_lines = countlines(built)
    if built_lines < max(5, src_lines ÷ 2)
        error("docs build looks truncated (kit issue #91): the built home " *
              "page has $built_lines lines but the generated " *
              "docs/src/index.md has $src_lines lines. This matches the " *
              "silent npm/vitepress ordering failure from #91 — re-run the " *
              "docs build; if it persists, run `julia --project=docs -e " *
              "'using Pkg; Pkg.instantiate()'` once (so docs/node_modules " *
              "already exists) before running `docs/make.jl`.")
    end
    return nothing
end

"""
    build_docs(mod; repo, authors, pages, deploy_url=nothing,
               skip_notebooks=false, tutorials_subdir, light_tutorials=[],
               heavy_tutorials=[], tutorial_stubs=[], force_stub_tutorials=[],
               linkcheck_ignore=[], index_rewrites=[], readme_execute=true,
               index_strip_sections=[], benchmark_page=true,
               history_suites=[], history_commits=5,
               history_regression_threshold=1.1, extra_modules=[],
               build_vitepress=true, deploy=true)

Run the standard EpiAware documentation build for package module `mod`. All
paths derive from `pkgdir(mod)`, so the managed `docs/make.jl` only forwards the
package-owned config. Generates the home page, release notes, benchmark page,
and API pages, processes the Literate tutorials, then renders with
`DocumenterVitepress` and (when `deploy`) deploys. Under `skip_notebooks`,
light tutorials still render in-process (cheap: seconds, not minutes) and only
the heavy tutorials fall back to `tutorial_stubs` heading stubs — the flag
exists to skip the slow ones, not the cheap ones. Independent of
`skip_notebooks`, any `heavy_tutorials` entry named in `force_stub_tutorials`
never executes and always renders from its `tutorial_stubs` heading — for a
heavy tutorial with an unresolved problem of its own (e.g. a model that does
not terminate in reasonable time), so it need not block its siblings from
running for real. `deploy=false` builds without deploying, and
`build_vitepress=false` runs Documenter without the final VitePress (npm)
pass — both used by tests and fast local content builds. On the benchmark page,
`history_suites` (when non-empty) restricts the overall summary and detail to
the named headline suites, `history_commits` caps both to that many
most-recent revisions, and `history_regression_threshold` sets the overall
summary's regression-flag cutoff (see [`_embed_benchmark_history`](@ref)).

The owning modules of `mod`'s re-exported docstrings are auto-discovered (see
`api_owning_modules`) and folded into Documenter's `modules` so the
generated `@docs` blocks for those re-exports resolve (#175); `extra_modules`
adds any further owner modules auto-discovery cannot reach (e.g. a re-export
referenced only from prose). Because Documenter drives its missing-docstring
completeness check off the same `modules` list — with no working way to scope
that check while widening `@docs` resolution — the completeness check is
disabled whenever the resolution set is widened, so a package is never held
responsible for a dependency's own missing-docstring hygiene (`mod`'s own
completeness is already guaranteed by construction: `api_bindings` emits every
docstring `mod` owns).
"""
function build_docs(mod::Module; repo::AbstractString, authors::AbstractString,
        pages, deploy_url = nothing, skip_notebooks::Bool = false,
        tutorials_subdir::AbstractString = joinpath(
            "getting-started", "tutorials"),
        light_tutorials = String[], heavy_tutorials = String[],
        tutorial_stubs = Pair{String, String}[],
        force_stub_tutorials = String[],
        linkcheck_ignore = Regex[], index_rewrites = Pair{String, String}[],
        readme_execute::Bool = true, index_strip_sections = String[],
        benchmark_page::Bool = true, history_suites = String[],
        history_commits::Integer = 5,
        history_regression_threshold::Real = 1.1, extra_modules = Module[],
        build_vitepress::Bool = true, deploy::Bool = true)
    project_root = pkgdir(mod)
    # `pkgdir` returns `Union{Nothing,String}`; narrow to a concrete String up
    # front so the downstream `joinpath` calls never see `Nothing` (keeps JET
    # type-stable). A missing package directory is unrecoverable here.
    project_root === nothing &&
        error("Cannot locate the package directory for module $mod")
    docs_dir = joinpath(project_root, "docs")
    src_dir = joinpath(docs_dir, "src")
    tutorials_dir = joinpath(src_dir, tutorials_subdir)

    # --- tutorials ---------------------------------------------------------
    _render_tutorials(docs_dir, tutorials_dir, skip_notebooks, light_tutorials,
        heavy_tutorials, tutorial_stubs; force_stub = force_stub_tutorials)

    # --- generated pages ---------------------------------------------------
    build_index(; readme = joinpath(project_root, "README.md"),
        dest = joinpath(src_dir, "index.md"), repo = repo,
        execute = readme_execute, rewrites = index_rewrites,
        strip_sections = index_strip_sections)
    build_release_notes(; news = joinpath(project_root, "NEWS.md"),
        header_file = joinpath(docs_dir, "release_notes_header.jl"),
        dest = joinpath(src_dir, "release-notes.md"))
    benchmark_linkcheck = Regex[]
    if benchmark_page
        benchmark_linkcheck = build_benchmark_page(;
            dest = joinpath(src_dir, "benchmarks.md"), repo = repo,
            package = string(mod),
            prose_file = joinpath(docs_dir, "benchmarks.md"),
            project_root = project_root, history_suites = history_suites,
            history_commits = history_commits,
            history_regression_threshold = history_regression_threshold)
    else
        println("BENCHMARK_PAGE = false; skipping benchmark history page")
        # Drop any stale Benchmarks nav entry so a package that disabled the page
        # without regenerating its (package-owned) `pages.jl` still gets a nav
        # tree with no dangling "benchmarks.md" link.
        pages = _strip_benchmark_nav(pages)
    end
    build_api_pages(mod, joinpath(src_dir, "lib"))

    # --- render ------------------------------------------------------------
    Documenter = _documenter()
    DocumenterVitepress = _vitepress()
    Base.invokelatest(Documenter.DocMeta.setdocmeta!, mod, :DocTestSetup,
        Expr(:using, Expr(:., nameof(mod))); recursive = true)

    bib_path = joinpath(src_dir, "refs.bib")
    plugins = if isfile(bib_path)
        DocumenterCitations = _citations()
        [Base.invokelatest(DocumenterCitations.CitationBibliography, bib_path;
            style = :numeric)]
    else
        Documenter.Plugin[]
    end

    format = Base.invokelatest(DocumenterVitepress.MarkdownVitepress;
        repo = "github.com/$repo", devbranch = "main", devurl = "dev",
        deploy_url = deploy_url, build_vitepress = build_vitepress,
        keep = :patch)

    # The modules Documenter's `@docs` resolver searches. `mod` always leads;
    # the owning modules of `mod`'s re-exported docstrings follow so their
    # `@docs` entries resolve instead of raising "no docs found" (#175). A
    # package may name further owner modules via `extra_modules` (docs_config)
    # for a re-export auto-discovery cannot reach.
    owning_modules = union(Set{Module}(extra_modules), api_owning_modules(mod))
    delete!(owning_modules, mod)
    doc_modules = Module[mod]
    append!(doc_modules, collect(owning_modules))
    # Documenter drives its missing-docstring completeness check off this same
    # `modules` list, and there is no working way to scope that check to `mod`
    # while widening `@docs` resolution: `checkdocs_ignored_modules` does not
    # exclude a top-level owner module (Documenter's `submodules` always keeps
    # the roots it is handed), and no `checkdocs`-allowlist keyword exists. So
    # whenever we widen for re-export resolution we disable the completeness
    # check (`:none`), keeping a package off the hook for its dependencies'
    # own missing-docstring hygiene; `mod`'s own completeness needs no check
    # here because `api_bindings` emits every docstring `mod` owns by
    # construction. With no re-exports the default `:all` check over `mod`
    # alone is kept.
    checkdocs = length(doc_modules) > 1 ? :none : :all
    # `root` is pinned to the package's docs dir. Documenter otherwise defaults
    # it to the running script's directory; because the build now lives in the
    # kit rather than in `docs/make.jl`, the thin caller (or a test) may run
    # from anywhere, so set it explicitly. `source`/`build` keep their defaults
    # relative to `root` (`src`/`build`), matching the previous layout.
    Base.invokelatest(Documenter.makedocs; root = docs_dir,
        sitename = "$mod.jl",
        authors = authors, clean = true, doctest = false,
        linkcheck = !skip_notebooks,
        linkcheck_ignore = vcat(linkcheck_ignore, benchmark_linkcheck),
        warnonly = [
            :docs_block, :missing_docs, :autodocs_block, :cross_references],
        checkdocs = checkdocs,
        modules = doc_modules, pages = pages, format = format,
        plugins = plugins)

    # Fail loudly rather than silently ship a truncated home page (#91).
    _check_index_not_truncated(joinpath(src_dir, "index.md"),
        joinpath(docs_dir, "build", ".documenter"))

    _copy_tutorial_data(src_dir, joinpath(docs_dir, "build"))

    if deploy
        Base.invokelatest(DocumenterVitepress.deploydocs;
            repo = "github.com/$repo", target = "build", branch = "gh-pages",
            devbranch = "main", push_preview = true)
    end
    return
end

end # module DocsBuild
