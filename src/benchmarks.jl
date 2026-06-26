# Generic benchmark-reporting harness.
#
# This is the package-agnostic core of the EpiAware benchmark tooling: the
# parts that every package's benchmark CI would otherwise copy. It turns
# benchmark result data into a legible Markdown PR comment, with no knowledge
# of which distributions or models a package benchmarks.
#
# Two result shapes are handled, matching the two ways EpiAware packages run
# benchmarks:
#
#   - AirspeedVelocity's `results_<pkg>@<rev>.json` files (a nested JSON group
#     of `times` vectors). [`flatten_asv`] reads one into a flat
#     `path => median_ns` dict; [`asv_comment`] compares a base/head pair into
#     a comment.
#   - A pair of in-process BenchmarkTools result files (e.g. saved by
#     [`run_suite`]). [`compare_comment`] reads both via BenchmarkTools and
#     builds a comment with a bucketed summary.
#
# The AD-gradients special-casing keys off the `"AD gradients/"` group name
# that the shared AD harness (`ad_harness.jl`) and every package's benchmark
# suite use, so the per-(scenario x backend) AD rows stay legible instead of
# flooding the table. Set `ad_prefix` to retarget or `""` to disable.
#
# BenchmarkTools and JSON3 are loaded at call time via `Base.require` (as the
# quality wrappers do) so they stay out of the main package's dependencies; a
# caller only needs them in whichever environment runs the benchmark job.

"""
    EpiAwarePackageTools.Benchmarks

Generic benchmark-reporting harness shared across EpiAware packages.

Turns benchmark result data into a legible Markdown PR comment without knowing
which distributions or models a package benchmarks. Two result shapes are
supported:

  - AirspeedVelocity `results_<pkg>@<rev>.json` files, read by
    [`flatten_asv`](@ref) and compared by [`asv_comment`](@ref).
  - A pair of in-process BenchmarkTools result files, compared by
    [`compare_comment`](@ref). [`run_suite`](@ref) runs a package's `SUITE` and
    saves such a file.

Per-(scenario x backend) AD-gradient rows are folded into a compact matrix via
the shared `"AD gradients/"` group convention; set the relevant `ad_prefix`
keyword to retarget or `""` to disable. A package keeps its own benchmark
definitions and calls into this module to run and report them.

`BenchmarkTools` and `JSON3` are loaded at call time, so they are only needed in
the environment that runs the benchmark job, not as package dependencies.
"""
module Benchmarks

export flatten_asv, asv_comment, compare_comment, run_suite
export fmt_time, fmt_ratio

# ---- lazy dependency loading ----------------------------------------------

# Resolve JSON3 / BenchmarkTools at call time so they are not hard
# dependencies of EpiAwarePackageTools. Calls into them go through `invokelatest`
# because the loaded methods live in a newer world age than these functions.
function _json3()
    return Base.require(Base.PkgId(
        Base.UUID("0f8b85d8-7281-11e9-16c2-39a750bddbf1"), "JSON3"))
end

function _benchmarktools()
    return Base.require(Base.PkgId(
        Base.UUID("6e4b80f9-dd63-53aa-95a3-0cdb28fa8baf"), "BenchmarkTools"))
end

# ---- shared formatting -----------------------------------------------------

const RATIO_THRESHOLD = 1.05   # |ratio - 1| >= 5% counts as "changed"
const TOP_N = 15               # rows shown in the "most changed" table

"""
    fmt_time(ns)

Format a nanosecond duration as a short human string (`ns`/`μs`/`ms`/`s`).
Returns `"—"` for `NaN`.
"""
function fmt_time(ns::Real)
    isnan(ns) && return "—"
    if ns < 1e3
        return string(round(ns; digits = 1), " ns")
    elseif ns < 1e6
        return string(round(ns / 1e3; digits = 2), " μs")
    elseif ns < 1e9
        return string(round(ns / 1e6; digits = 2), " ms")
    else
        return string(round(ns / 1e9; digits = 2), " s")
    end
end

"""
    fmt_ratio(r)

Format a head/base ratio to three digits. Returns `"—"` for `NaN`.
"""
fmt_ratio(r::Real) = isnan(r) ? "—" : string(round(r; digits = 3))

# Ratio with a colour cue so notable moves catch the eye in Markdown.
function _ratio_cell(r::Real)
    isnan(r) && return "—"
    s = fmt_ratio(r)
    if r >= 1.10
        return "🔴 " * s        # slower by >=10%
    elseif r <= 0.91
        return "🟢 " * s        # faster by >=10%
    else
        return s
    end
end

# Median of a vector of times, robust to empties and unsorted input.
function _median(times)
    xs = sort(collect(Float64, times))
    n = length(xs)
    n == 0 && return NaN
    isodd(n) ? xs[(n + 1) ÷ 2] : (xs[n ÷ 2] + xs[n ÷ 2 + 1]) / 2
end

# Split a full AD key "<prefix><scenario>/<backend>" into its parts.
function _ad_parts(key::AbstractString, prefix::AbstractString)
    rest = key[(length(prefix) + 1):end]
    idx = findlast('/', rest)
    idx === nothing && return (rest, "")
    return (rest[1:(idx - 1)], rest[(idx + 1):end])
end

# ---- AirspeedVelocity result loading --------------------------------------

# Recursively flatten a BenchmarkTools/JSON3 group into `path => median_ns`.
# Leaf groups have a "times" vector (nanoseconds); inner groups have "data".
function _flatten!(out::Dict{String, Float64}, node, prefix::String)
    (node isa AbstractDict || nameof(typeof(node)) === :Object) || return out
    if haskey(node, "times")
        times = node["times"]
        if !isempty(times)
            out[prefix] = _median(times)
        end
    elseif haskey(node, "data")
        for (k, v) in pairs(node["data"])
            key = String(k)
            next = isempty(prefix) ? key : prefix * "/" * key
            _flatten!(out, v, next)
        end
    end
    return out
end

# Locate `results_<pkg>@<rev>...json`, matching the rev as a prefix so a full
# SHA on the command line still finds a file benchpkg truncated.
function _find_results(dir::AbstractString, pkg::AbstractString,
        rev::AbstractString)
    candidates = filter(readdir(dir; join = true)) do f
        endswith(f, ".json") && occursin("results_" * pkg * "@", basename(f))
    end
    isempty(candidates) && error("no results json for $pkg in $dir")
    for f in candidates
        tag = match(r"@(.+)\.json$", basename(f))
        tag === nothing && continue
        t = tag.captures[1]
        if startswith(rev, t) || startswith(t, rev) || rev == t
            return f
        end
    end
    length(candidates) == 1 && return only(candidates)
    error("could not match rev $rev among $(basename.(candidates))")
end

"""
    flatten_asv(dir, pkg, rev) -> Dict{String, Float64}

Read the AirspeedVelocity `results_<pkg>@<rev>.json` file in `dir` and return a
flat map from benchmark key path (joined with `/`) to its median time in
nanoseconds.

The `rev` is matched as a prefix of the rev embedded in the filename (and vice
versa), because the AirspeedVelocity action passes a full SHA while benchpkg
may truncate it on disk. `JSON3` must be available in the calling environment.
"""
function flatten_asv(dir::AbstractString, pkg::AbstractString,
        rev::AbstractString)
    JSON3 = _json3()
    file = _find_results(dir, pkg, rev)
    data = open(file, "r") do io
        Base.invokelatest(JSON3.read, read(io, String))
    end
    out = Dict{String, Float64}()
    _flatten!(out, data, "")
    return out
end

# ---- AirspeedVelocity comment sections ------------------------------------

function _most_changed_section(io, base, head)
    rows = Tuple{String, Float64, Float64, Float64}[]
    for (k, h) in head
        haskey(base, k) || continue
        b = base[k]
        (b <= 0 || h <= 0) && continue
        push!(rows, (k, b, h, h / b))
    end
    changed = filter(r -> abs(r[4] - 1) >= (RATIO_THRESHOLD - 1), rows)
    println(io, "### Most changed (median time)\n")
    if isempty(changed)
        println(io,
            "No benchmark moved by more than ",
            round(Int, (RATIO_THRESHOLD - 1) * 100),
            "%. ", length(rows), " benchmarks compared.\n")
        return
    end
    sort!(changed; by = r -> abs(r[4] - 1), rev = true)
    println(io, "| Benchmark | base | PR | PR / base |")
    println(io, "|:--|--:|--:|--:|")
    for r in first(changed, TOP_N)
        println(io, "| `", r[1], "` | ", fmt_time(r[2]), " | ",
            fmt_time(r[3]), " | ", _ratio_cell(r[4]), " |")
    end
    if length(changed) > TOP_N
        println(io, "\n", length(changed) - TOP_N,
            " further benchmarks changed (see full results below).")
    end
    println(io)
end

function _ad_section(io, base, head, prefix)
    isempty(prefix) && return
    ad_keys = filter(k -> startswith(k, prefix), keys(head))
    println(io, "### AD gradients (PR / base, median time)\n")
    if isempty(ad_keys)
        println(io, "No AD-gradient benchmarks in this run.\n")
        return
    end
    scenarios = String[]
    backends = String[]
    cell = Dict{Tuple{String, String}, Float64}()
    for k in ad_keys
        scen, back = _ad_parts(k, prefix)
        haskey(base, k) || continue
        b = base[k]
        h = head[k]
        (b <= 0 || h <= 0) && continue
        scen in scenarios || push!(scenarios, scen)
        back in backends || push!(backends, back)
        cell[(scen, back)] = h / b
    end
    if isempty(cell)
        println(io,
            "AD benchmarks ran but had no comparable base counterpart.\n")
        return
    end
    sort!(scenarios)
    sort!(backends)
    print(io, "| Scenario |")
    for b in backends
        print(io, " ", b, " |")
    end
    println(io)
    print(io, "|:--|")
    for _ in backends
        print(io, "--:|")
    end
    println(io)
    for s in scenarios
        print(io, "| ", s, " |")
        for b in backends
            r = get(cell, (s, b), NaN)
            print(io, " ", _ratio_cell(r), " |")
        end
        println(io)
    end
    println(io,
        "\nCells are PR median / base median. 🔴 ≥1.10 (slower), ",
        "🟢 ≤0.91 (faster). Blank = backend skipped on that scenario.\n")
end

function _full_section(io, base, head, prefix)
    keys_all = sort(collect(keys(head)))
    has_ad = !isempty(prefix)
    non_ad = has_ad ? filter(k -> !startswith(k, prefix), keys_all) : keys_all
    ad = has_ad ? filter(k -> startswith(k, prefix), keys_all) : String[]
    println(io, "<details><summary>Full results</summary>\n")
    for (title, ks) in (("Core benchmarks", non_ad),
        ("AD gradients (raw)", ad))
        isempty(ks) && continue
        println(io, "\n#### ", title, "\n")
        println(io, "| Benchmark | base | PR | PR / base |")
        println(io, "|:--|--:|--:|--:|")
        for k in ks
            h = get(head, k, NaN)
            b = get(base, k, NaN)
            r = (b > 0 && h > 0) ? h / b : NaN
            println(io, "| `", k, "` | ", fmt_time(b), " | ",
                fmt_time(h), " | ", fmt_ratio(r), " |")
        end
    end
    println(io, "\n</details>")
end

"""
    asv_comment(base, head; ad_prefix = "AD gradients/") -> String

Build a Markdown PR comment comparing two flat result maps (as returned by
[`flatten_asv`]).

`base` and `head` map benchmark key path to median nanoseconds. The comment
has three parts: a "most changed" summary (largest median-time moves), a
compact AD scenario x backend ratio matrix for keys under `ad_prefix`, and the
full table folded behind a `<details>` block. Set `ad_prefix = ""` to skip the
AD matrix and treat every benchmark as a core benchmark.
"""
function asv_comment(base::AbstractDict, head::AbstractDict;
        ad_prefix::AbstractString = "AD gradients/")
    io = IOBuffer()
    println(io, "## Benchmark results\n")
    println(io,
        "Comparing PR head against the base branch ",
        "(median time; ratio = PR / base, <1 is faster).\n")
    _most_changed_section(io, base, head)
    _ad_section(io, base, head, ad_prefix)
    _full_section(io, base, head, ad_prefix)
    println(io,
        "\n<sub>Generated from AirspeedVelocity results by ",
        "EpiAwarePackageTools.Benchmarks.</sub>")
    return String(take!(io))
end

"""
    asv_comment(dir, pkg, base_rev, head_rev; ad_prefix = "AD gradients/")
        -> String

Convenience wrapper that loads the AirspeedVelocity result files for `base_rev`
and `head_rev` from `dir` (via [`flatten_asv`]) and returns the comment.
"""
function asv_comment(dir::AbstractString, pkg::AbstractString,
        base_rev::AbstractString, head_rev::AbstractString;
        ad_prefix::AbstractString = "AD gradients/")
    base = flatten_asv(dir, pkg, base_rev)
    head = flatten_asv(dir, pkg, head_rev)
    return asv_comment(base, head; ad_prefix = ad_prefix)
end

# ---- BenchmarkTools pair comparison ---------------------------------------

const CHANGE_THRESHOLD = 0.05  # 5% time change = ±5% bucket edge

# Time buckets for the summary table, keyed on PR time as a percentage of base
# (so < 100% is faster). Edges mirror around 100%.
const BUCKETS = [
    ("🟢 <50%", 50.0),
    ("🟢 50–75%", 75.0),
    ("🟢 75–95%", 95.0),
    ("⚪ 95–105%", 105.0),
    ("🔴 105–125%", 125.0),
    ("🔴 125–150%", 150.0),
    ("🔴 >150%", Inf)
]

# Map each benchmark key path (joined with " / ") to its minimum time (ns) and
# allocated memory (bytes). Minimum time is the stable like-for-like estimator.
function _index_results(BT, group)
    out = Dict{String, NamedTuple{(:time, :memory), Tuple{Float64, Float64}}}()
    for (keypath, trial) in Base.invokelatest(BT.leaves, group)
        name = join(string.(keypath), " / ")
        est = Base.invokelatest(minimum, trial)
        out[name] = (time = Float64(Base.invokelatest(BT.time, est)),
            memory = Float64(Base.invokelatest(BT.memory, est)))
    end
    return out
end

struct _Row
    name::String
    base_time::Float64
    pr_time::Float64
    base_mem::Float64
    pr_mem::Float64
    time_ratio::Float64   # NaN when the benchmark is new or removed
    status::Symbol        # :both, :new (PR only), :removed (base only)
end

function _build_rows(pr, base)
    rows = _Row[]
    for name in sort(collect(union(keys(pr), keys(base))))
        inpr, inbase = haskey(pr, name), haskey(base, name)
        pt = inpr ? pr[name].time : NaN
        bt = inbase ? base[name].time : NaN
        pm = inpr ? pr[name].memory : NaN
        bm = inbase ? base[name].memory : NaN
        ratio = (inpr && inbase) ? pt / bt : NaN
        status = inpr && inbase ? :both : inpr ? :new : :removed
        push!(rows, _Row(name, bt, pt, bm, pm, ratio, status))
    end
    return rows
end

function _fmt_ratio_x(r)
    isnan(r) ? "—" :
    string(r > 1 + CHANGE_THRESHOLD ? "🔴" :
           r < 1 - CHANGE_THRESHOLD ? "🟢" : "⚪",
        " ", round(r; digits = 2), "×")
end

_sort_key(r) = isnan(r.time_ratio) ? Inf : abs(r.time_ratio - 1)

function _status_note(r)
    r.status === :new && return " *(new)*"
    r.status === :removed && return " *(removed)*"
    return ""
end

function _render_table(rows)
    isempty(rows) && return "_none_\n"
    io = IOBuffer()
    println(io, "| Benchmark | base | PR | time | memory |")
    println(io, "|---|---|---|---|---|")
    for r in rows
        memratio = (isnan(r.pr_mem) || isnan(r.base_mem) || r.base_mem == 0) ?
                   NaN : r.pr_mem / r.base_mem
        println(io, "| ", r.name, _status_note(r),
            " | ", fmt_time(r.base_time),
            " | ", fmt_time(r.pr_time),
            " | ", _fmt_ratio_x(r.time_ratio),
            " | ", _fmt_ratio_x(memratio), " |")
    end
    return String(take!(io))
end

function _bucket_index(pct)
    for (i, (_, edge)) in enumerate(BUCKETS)
        pct < edge && return i
    end
    return length(BUCKETS)
end

function _summary_table(rows, group_of, group_order)
    counts = Dict{String, Vector{Int}}()
    for r in rows
        isnan(r.time_ratio) && continue
        v = get!(counts, group_of(r.name), zeros(Int, length(BUCKETS)))
        v[_bucket_index(100 * r.time_ratio)] += 1
    end
    groups = String[]
    for g in group_order
        haskey(counts, g) && push!(groups, g)
    end
    for g in sort(collect(keys(counts)))
        g in groups || push!(groups, g)
    end
    io = IOBuffer()
    println(io, "| Group | ", join(first.(BUCKETS), " | "), " |")
    println(io, "|---|", repeat("---|", length(BUCKETS)))
    for g in groups
        cells = [c == 0 ? "·" : string(c) for c in counts[g]]
        println(io, "| ", g, " | ", join(cells, " | "), " |")
    end
    return String(take!(io))
end

"""
    compare_comment(pr_file, base_file; ad_prefix = "AD gradients",
        backend_order = String[],
        marker = "<!-- benchmark-comparison -->") -> String

Compare two BenchmarkTools result files and build a Markdown PR comment.

`pr_file` and `base_file` are paths BenchmarkTools can `load`. The comment
opens with `marker` (so the CI step can find and update its own comment), then
a bucketed summary table (counts of benchmarks per PR/base time bucket, grouped
into "Evaluation" plus one row per AD backend), then collapsed per-benchmark
tables for the non-AD ("Evaluation") and AD groups, each sorted by how much the
time moved.

Benchmarks whose key path starts with `ad_prefix` are treated as AD gradients,
grouped by their last path segment (the backend); pass `backend_order` to fix
the summary row order for known backends. `BenchmarkTools` must be available.
"""
function compare_comment(pr_file::AbstractString, base_file::AbstractString;
        ad_prefix::AbstractString = "AD gradients",
        backend_order::AbstractVector{<:AbstractString} = String[],
        marker::AbstractString = "<!-- benchmark-comparison -->")
    BT = _benchmarktools()
    load_group(path) = Base.invokelatest(BT.load, path)[1]
    pr = _index_results(BT, load_group(pr_file))
    base = _index_results(BT, load_group(base_file))
    rows = _build_rows(pr, base)

    is_ad(name) = !isempty(ad_prefix) && startswith(name, ad_prefix)
    group_of(name) = is_ad(name) ?
                     String(split(name, " / ")[end]) : "Evaluation"
    group_order = vcat(["Evaluation"], collect(String, backend_order))

    all_sorted = sort(rows; by = _sort_key, rev = true)
    eval_rows = filter(r -> !is_ad(r.name), all_sorted)
    ad_rows = filter(r -> is_ad(r.name), all_sorted)

    io = IOBuffer()
    println(io, marker)
    println(io, "## Benchmark comparison vs base\n")
    println(io,
        "Minimum time per call. Buckets are **PR time as a % of base, so ",
        "lower is faster** (🟢 faster, ⚪ within ",
        round(Int, 100CHANGE_THRESHOLD),
        "%, 🔴 slower). Counts of benchmarks per bucket:\n")
    print(io, _summary_table(rows, group_of, group_order))
    println(io, "\n<details><summary><b>Evaluation</b> — ", length(eval_rows),
        " benchmarks (by time change)</summary>\n")
    print(io, _render_table(eval_rows))
    println(io, "\n</details>")
    println(io, "\n<details><summary><b>AD gradients</b> — ", length(ad_rows),
        " benchmarks (by time change)</summary>\n")
    print(io, _render_table(ad_rows))
    println(io, "\n</details>")
    return String(take!(io))
end

# ---- in-process suite runner ----------------------------------------------

"""
    run_suite(suite; out_file = nothing, seconds = 1, verbose = true)

Run a BenchmarkTools `BenchmarkGroup` and optionally save it to JSON.

`suite` is the package's own `SUITE` (built by its `benchmarks.jl`); this only
owns the run/save boilerplate. A short per-benchmark `seconds` budget keeps CI
affordable while the minimum-time estimator used in [`compare_comment`] stays
stable well below the BenchmarkTools default. Returns the results group; when
`out_file` is given it is also saved there. `BenchmarkTools` must be available.
"""
function run_suite(suite; out_file::Union{Nothing, AbstractString} = nothing,
        seconds::Real = 1, verbose::Bool = true)
    BT = _benchmarktools()
    results = Base.invokelatest(
        BT.run, suite; verbose = verbose, seconds = seconds)
    if out_file !== nothing
        Base.invokelatest(BT.save, out_file, results)
    end
    return results
end

end # module Benchmarks
