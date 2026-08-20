# Reading the AD gradient numbers the scaffolded
# `docs/src/benchmarks/ad-comparison.jl` page renders.
#
# The benchmark suite already measures every (backend, scenario) pair the
# `ADFixtures` registry declares, under the shared `"AD gradients"` group, and
# `benchmark-history.yaml` publishes its results to the `benchmarks` branch.
# This finds that file, on the branch or where the package names one, and reads
# it so the docs build reports those numbers instead of measuring the whole
# grid again in the docs process.
#
# Included into `DocsBuild` so it sits with the rest of the docs machinery, but
# it is deliberately free of any Documenter/Literate coupling: it takes a path
# and returns data, so it can be unit tested directly.

# One (backend, scenario) measurement, the row shape the page's `bench_long`
# frame has: `time_us` is the median time in microseconds and `bytes_kb` the
# allocated memory in kibibytes.
const ADBenchmarkRow = @NamedTuple{
    backend::String, scenario::String, time_us::Float64, bytes_kb::Float64,
}

"""
    ADBenchmarkResults

AD gradient measurements read from a published benchmark results file, plus
what was not in it.

Built by [`load_ad_benchmarks`](@ref); described for the reader by
[`ad_benchmark_note`](@ref).

# Fields

  - `source`: the file that was read, or `""` when none was found.
  - `rows`: every measurement found, ordered by the expected backend order.
  - `backends`: the backend labels a measurement was found for, same order.
  - `missing_backends`: expected labels with no measurement.
"""
struct ADBenchmarkResults
    source::String
    rows::Vector{ADBenchmarkRow}
    backends::Vector{String}
    missing_backends::Vector{String}
end

# `JSON` rather than `JSON3`: it is already resolvable in every adopter's docs
# manifest as a dependency of Documenter/Literate, so this adds nothing to
# `docs/Project.toml` (see `_json`).

# Median of a vector of times, robust to empties and unsorted input.
function _median_time(times)
    xs = sort(Float64[t for t in times if t isa Real])
    n = length(xs)
    n == 0 && return NaN
    return isodd(n) ? xs[(n + 1) ÷ 2] : (xs[n ÷ 2] + xs[n ÷ 2 + 1]) / 2
end

# Flatten a published benchmark group into `key path => (time_ns, bytes)`.
# Inner groups carry `"data"`; leaves carry a `"times"` vector in nanoseconds
# and a scalar `"memory"` in bytes. This is the shape AirspeedVelocity writes
# for each revision it benchmarks.
function _flatten_benchmarks!(out, node, prefix::String)
    node isa AbstractDict || return out
    if haskey(node, "times")
        times = node["times"]
        memory = get(node, "memory", nothing)
        if times isa AbstractVector && !isempty(times) && memory isa Real
            out[prefix] = (_median_time(times), Float64(memory))
        end
    elseif haskey(node, "data") && node["data"] isa AbstractDict
        for (k, v) in node["data"]
            key = isempty(prefix) ? String(k) : prefix * "/" * String(k)
            _flatten_benchmarks!(out, v, key)
        end
    end
    return out
end

# Split `"<group>/<scenario>/<backend>"` into scenario and backend. A scenario
# name may itself contain `/`, so the backend is the last segment and the
# scenario everything between the group and it.
function _split_ad_key(key::AbstractString, group::AbstractString)
    rest = key[(length(group) + 2):end]
    idx = findlast('/', rest)
    idx === nothing && return nothing
    scenario = rest[1:(idx - 1)]
    backend = rest[(idx + 1):end]
    (isempty(scenario) || isempty(backend)) && return nothing
    return (scenario, backend)
end

# The file the benchmark run names as the revision it was triggered for. The
# publishing workflow writes it beside the per-revision files, so a reader can
# pick the right one out of a git checkout, where every file carries the
# checkout time and modification order says nothing.
const AD_RESULTS_LATEST = "latest.json"

# The published results file, given a file or a directory. A directory is what
# `benchpkg --output-dir` writes and what the published `history/results/`
# folder holds: one file per revision benchmarked. `latest.json` names the
# wanted revision and is preferred wherever it is present. Failing that, in a
# working directory of `benchpkg` output, the most recently written file is the
# newest revision, with the name settling ties.
function _ad_results_file(source::AbstractString)
    isfile(source) && return String(source)
    isdir(source) || return nothing
    files = String[]
    latest = String[]
    for (root, _, names) in walkdir(source), name in names
        endswith(lowercase(name), ".json") || continue
        path = joinpath(root, name)
        push!(name == AD_RESULTS_LATEST ? latest : files, path)
    end
    isempty(latest) || return first(sort!(latest))
    isempty(files) && return nothing
    return last(sort!(files; by = f -> (mtime(f), f)))
end

"""
    load_ad_benchmarks(source, expected_backends; group = "AD gradients")
        -> ADBenchmarkResults

Read the AD gradient measurements published by the package's benchmark run.

`source` is a benchmark results JSON file, or a directory holding one or more
of them, in which case a `latest.json` wins and otherwise the most recently
written file does. `group` is the benchmark group the gradient benchmarks live
under, the same convention
[`EpiAwarePackageTools.Benchmarks.compare_comment`](@ref) folds into its AD
matrix, so one suite definition feeds both the pull request comment and this
page.

`expected_backends` is the registry's backend labels, in the order the page
wants them. It fixes the row order and is what "missing" is measured against,
so a benchmark's last key segment must be the registry label exactly.

Nothing here is fatal. A missing file, one that is not valid JSON, and a suite
with no gradient group all produce an `ADBenchmarkResults` describing what was
found; the page renders that and reports the gap in prose. Measurements for a
backend outside `expected_backends` are kept and listed after the expected
ones.
"""
function load_ad_benchmarks(
        source::AbstractString, expected_backends;
        group::AbstractString = "AD gradients"
    )
    expected = String[String(b) for b in expected_backends]
    file = _ad_results_file(source)
    if file === nothing
        return ADBenchmarkResults("", ADBenchmarkRow[], String[], expected)
    end
    flat = try
        JSON = _json()
        data = Base.invokelatest(JSON.parsefile, file)
        Base.invokelatest(
            _flatten_benchmarks!, Dict{String, Tuple{Float64, Float64}}(),
            data, ""
        )
    catch
        Dict{String, Tuple{Float64, Float64}}()
    end
    found = Dict{String, Vector{ADBenchmarkRow}}()
    order = String[]
    for key in sort!(collect(keys(flat)))
        startswith(key, group * "/") || continue
        parts = _split_ad_key(key, group)
        parts === nothing && continue
        scenario, backend = parts
        time_ns, bytes = flat[key]
        time_us = time_ns / 1.0e3
        bytes_kb = bytes / 1024
        # A backend that produced no number for a scenario belongs absent from
        # the table rather than plotted as `Inf` on a log scale.
        (isfinite(time_us) && isfinite(bytes_kb)) || continue
        haskey(found, backend) || push!(order, backend)
        push!(
            get!(found, backend, ADBenchmarkRow[]),
            (
                backend = backend, scenario = scenario,
                time_us = time_us, bytes_kb = bytes_kb,
            )
        )
    end
    # Expected order first, then anything the registry did not ask for, so a
    # renamed backend still shows its numbers instead of vanishing.
    labels = vcat(
        filter(in(keys(found)), expected), filter(!in(expected), order)
    )
    rows = ADBenchmarkRow[]
    for label in labels
        append!(rows, found[label])
    end
    return ADBenchmarkResults(
        file, rows, labels, filter(!in(labels), expected)
    )
end

# Join names as prose: "A", "A and B", "A, B and C".
function _join_prose(items)
    parts = String[string(i) for i in items]
    length(parts) <= 1 && return join(parts)
    return string(join(parts[1:(end - 1)], ", "), " and ", parts[end])
end

"""
    ad_benchmark_note(r::ADBenchmarkResults) -> String

Markdown prose describing what `r` is missing, or `""` when it is complete.

The page renders this above its tables so a gap is stated rather than showing
as a silently short table. Two things get their own sentence: no gradient
measurements at all, and backends the published run carried no numbers for.

Plain paragraphs rather than an admonition, because the page emits this through
Literate as captured `text/markdown` output.
"""
function ad_benchmark_note(r::ADBenchmarkResults)
    lines = String[]
    if isempty(r.backends)
        push!(
            lines,
            "**No measurements for this build.** This page is configured to " *
                "render published benchmark results, and none were found. " *
                "That is the normal state before the benchmark workflow has " *
                "run on `main`; the published page carries the measured " *
                "numbers."
        )
    elseif !isempty(r.missing_backends)
        one = length(r.missing_backends) == 1
        push!(
            lines,
            "**Partial measurements.** The published benchmark run carried " *
                "no gradient numbers for " * _join_prose(r.missing_backends) *
                ", so " * (one ? "it is" : "they are") * " absent from the " *
                "tables and plots below rather than shown as zero. That can " *
                "mean the benchmark suite does not cover that backend, or " *
                "that it names it differently from the registry. It says " *
                "nothing about whether that backend differentiates these " *
                "scenarios, which the gradient tests cover separately."
        )
    end
    return join(lines, "\n\n")
end

"""
    ad_benchmark_results_path(docs_dir, configured) -> Union{Nothing,String}

Resolve where the published AD benchmark results are, or `nothing` when this
build is not rendering from them at all.

`configured` is the package-owned `AD_BENCHMARK_RESULTS` from `docs_config.jl`.
The `AD_BENCHMARK_RESULTS` environment variable overrides it when set and
non-empty, so CI can point the build at a checkout without the package editing
its (write-once) config. Either one being set is what opts the page into
rendering published numbers; with neither, the page measures live.

A relative path resolves against `docs_dir`, matching `TUTORIAL_ENVIRONMENTS`.
The result is absolute because the page runs in a subprocess whose working
directory the build does not control.
"""
function ad_benchmark_results_path(
        docs_dir::AbstractString, configured::Union{Nothing, AbstractString}
    )
    from_env = get(ENV, "AD_BENCHMARK_RESULTS", "")
    raw = isempty(from_env) ? configured : from_env
    (raw === nothing || isempty(raw)) && return nothing
    return isabspath(raw) ? String(raw) : abspath(joinpath(docs_dir, raw))
end

"""
    published_ad_benchmark_results(project_root) -> Union{Nothing,String}

The gradient results this package's benchmark run deployed to its `benchmarks`
branch, extracted to a temporary file, or `nothing`.

`benchmark-history.yaml` publishes each run under `history/results/`, so the
branch is read with git rather than checked out, the same way the
performance-history page reads `history/table.md`. Nothing here is required to
succeed: no branch, no network, and no `latest.json` on it all give `nothing`.

A run that carried no gradient measurements also gives `nothing`, so a package
whose suite benchmarks evaluation alone is left measuring the AD grid in the
docs build rather than handed an empty file and a page reporting no numbers.
"""
function published_ad_benchmark_results(project_root::AbstractString)
    ref = _benchmarks_ref(project_root)
    ref === nothing && return nothing
    path = "history/results/" * AD_RESULTS_LATEST
    dest = joinpath(mktempdir(), AD_RESULTS_LATEST)
    try
        open(dest, "w") do io
            run(
                pipeline(
                    `git -C $project_root show $ref:$path`;
                    stdout = io, stderr = devnull
                )
            )
        end
    catch
        return nothing
    end
    isempty(load_ad_benchmarks(dest, String[]).rows) && return nothing
    return dest
end

# Publish the resolved path to the benchmark page's subprocess, which inherits
# this process's environment. Writing it back as an absolute path also
# normalises the relative form a `docs_config.jl` may have used, so the page
# itself only ever reads one thing.
#
# What the package configured wins, so a package naming its own location keeps
# it. With nothing configured the branch its benchmark run publishes to is
# tried, which is what leaves an ordinary package rendering measured numbers
# without configuring anything.
function _export_ad_benchmark_results(docs_dir, configured, project_root)
    path = ad_benchmark_results_path(docs_dir, configured)
    if path === nothing
        path = published_ad_benchmark_results(project_root)
    end
    path === nothing && return nothing
    ENV["AD_BENCHMARK_RESULTS"] = path
    println("AD benchmark results: rendering from $path")
    return path
end
