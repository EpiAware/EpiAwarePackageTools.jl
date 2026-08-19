# Reading the per-backend AD benchmark artefacts the scaffolded
# `docs/src/benchmarks/ad-comparison.jl` page renders from.
#
# Each backend is benchmarked in its own CI run, and each run writes a small
# JSON file; the page reads those files rather than measuring every (backend,
# scenario) pair itself, which for a large registry is the whole `ad.yaml`
# matrix run serially in one docs job.
#
# Included into `DocsBuild` so it sits with the rest of the docs machinery, but
# it is deliberately free of any Documenter/Literate coupling: it takes a
# directory and returns data, so it can be unit tested directly.

# One (backend, scenario) measurement, the row shape the page's `bench_long`
# frame already has: `time_us` is DIT's `time` in microseconds and `bytes_kb`
# its `bytes` in kibibytes.
const ADBenchmarkRow = @NamedTuple{
    backend::String, scenario::String, time_us::Float64, bytes_kb::Float64,
}

"""
    ADBenchmarkArtifacts

Per-backend AD benchmark measurements read from a directory of JSON artefacts,
plus what was not there.

Built by [`load_ad_benchmarks`](@ref); described for the reader by
[`ad_benchmark_note`](@ref).

# Fields

  - `dir`: the directory that was read.
  - `rows`: every measurement found, ordered by the expected backend order.
  - `backends`: the backend labels an artefact was found for, same order.
  - `missing_backends`: expected labels no artefact was found for.
  - `unreadable`: basenames of files that could not be parsed as an artefact.
"""
struct ADBenchmarkArtifacts
    dir::String
    rows::Vector{ADBenchmarkRow}
    backends::Vector{String}
    missing_backends::Vector{String}
    unreadable::Vector{String}
end

# `JSON` rather than `JSON3`: it is already resolvable in every adopter's docs
# manifest as a dependency of Documenter/Literate, so the artefact reader adds
# nothing to `docs/Project.toml` (see `_json`).

# Every `.json` file under `dir`, at any depth. `actions/download-artifact`
# with a `pattern:` puts each artefact in its own subdirectory, while a
# single-artefact download lands flat; walking covers both without the
# workflow having to flatten anything.
#
# Ordered oldest-written first, with the path breaking ties so a build stays
# reproducible. That order is what decides which measurement survives when one
# scenario appears in two files (see `_dedupe_scenarios`), and modification
# time is the only honest signal of which is the newer: filename order is not,
# since the `x-1.json` sibling the harness writes beside `x.json` sorts before
# it, `-` preceding `.`.
function _ad_artifact_files(dir::AbstractString)
    isdir(dir) || return String[]
    files = String[]
    for (root, _, names) in walkdir(dir), name in names
        endswith(lowercase(name), ".json") && push!(files, joinpath(root, name))
    end
    return sort!(files; by = f -> (mtime(f), f))
end

# One scenario entry -> a row, or `nothing` when it is not a usable
# measurement. Non-finite values are dropped here for the same reason the live
# path filters them: a backend that failed to produce a number for a scenario
# should be absent from the table rather than plotted as `Inf` on a log scale.
function _ad_artifact_row(backend::AbstractString, entry)
    entry isa AbstractDict || return nothing
    name = get(entry, "name", nothing)
    time_us = get(entry, "time_us", nothing)
    bytes_kb = get(entry, "bytes_kb", nothing)
    (name isa AbstractString && !isempty(name)) || return nothing
    (time_us isa Real && bytes_kb isa Real) || return nothing
    (isfinite(time_us) && isfinite(bytes_kb)) || return nothing
    return (
        backend = String(backend), scenario = String(name),
        time_us = Float64(time_us), bytes_kb = Float64(bytes_kb),
    )
end

# Parse one artefact file into `label => rows`, or `nothing` when it is not a
# readable artefact. A file that is not JSON, is JSON of the wrong shape, or
# carries no backend label is reported as unreadable rather than throwing: a
# single corrupt upload must not red the docs build.
function _read_ad_artifact(path::AbstractString)
    return try
        JSON = _json()
        data = Base.invokelatest(JSON.parsefile, path)
        # A second `invokelatest`, for the shape checks rather than the parse:
        # the parsed value's own type was defined when JSON loaded, which is a
        # newer world than this method, so dispatching on it (`get`, `isa`) has
        # to be re-resolved too.
        Base.invokelatest(_ad_artifact_payload, data)
    catch
        nothing
    end
end

function _ad_artifact_payload(data)
    data isa AbstractDict || return nothing
    label = get(data, "backend", nothing)
    (label isa AbstractString && !isempty(label)) || return nothing
    scenarios = get(data, "scenarios", nothing)
    scenarios isa AbstractVector || return nothing
    rows = ADBenchmarkRow[]
    for entry in scenarios
        row = _ad_artifact_row(label, entry)
        row === nothing || push!(rows, row)
    end
    return String(label) => rows
end

# One row per scenario name, keeping the last. Files arrive oldest-first (see
# `_ad_artifact_files`), so the most recently written measurement wins, which is
# what a re-run into a directory still holding an older artefact should do.
# Order is otherwise preserved.
function _dedupe_scenarios(rows::Vector{ADBenchmarkRow})
    length(rows) < 2 && return rows
    last_at = Dict{String, Int}()
    for (i, r) in enumerate(rows)
        last_at[r.scenario] = i
    end
    return [r for (i, r) in enumerate(rows) if last_at[r.scenario] == i]
end

"""
    load_ad_benchmarks(dir, expected_backends) -> ADBenchmarkArtifacts

Read every per-backend AD benchmark artefact under `dir` (recursively; see
[`ADBenchmarkArtifacts`](@ref)).

`expected_backends` is the registry's backend labels, in the order the page
wants them. It fixes the row order and is what "missing" is measured against,
so an artefact's `"backend"` field must carry the registry label exactly.

Several files may carry the same backend, which is what happens when a package
splits its scenarios across test items that each write an artefact. Their
scenarios are concatenated, and a scenario named more than once keeps its last
measurement rather than being averaged in twice.

Nothing here is fatal. A missing directory, an empty one, a file that is not
valid JSON, and a backend whose CI job never uploaded anything all produce an
`ADBenchmarkArtifacts` describing what was found; the page renders that and
reports the gap in prose. Measurements for a backend outside
`expected_backends` are kept and listed after the expected ones.
"""
function load_ad_benchmarks(dir::AbstractString, expected_backends)
    expected = String[String(b) for b in expected_backends]
    found = Dict{String, Vector{ADBenchmarkRow}}()
    order = String[]
    unreadable = String[]
    for path in _ad_artifact_files(dir)
        parsed = _read_ad_artifact(path)
        if parsed === nothing
            push!(unreadable, basename(path))
            continue
        end
        label, rows = parsed
        if haskey(found, label)
            # Concatenated rather than replaced: one backend legitimately spans
            # several files when a package splits its scenarios across test
            # items that each write their own. Repeated scenario names are
            # collapsed below rather than counted twice in the geometric means.
            append!(found[label], rows)
        else
            found[label] = rows
            push!(order, label)
        end
    end
    for label in keys(found)
        found[label] = _dedupe_scenarios(found[label])
    end
    # Expected order first, then anything the registry did not ask for, so a
    # renamed backend still shows its numbers instead of vanishing.
    labels = vcat(
        filter(in(keys(found)), expected),
        filter(!in(expected), order)
    )
    rows = ADBenchmarkRow[]
    for label in labels
        append!(rows, found[label])
    end
    return ADBenchmarkArtifacts(
        String(dir), rows, labels, filter(!in(labels), expected), unreadable
    )
end

# Join names as prose: "A", "A and B", "A, B and C".
function _join_prose(items)
    parts = String[string(i) for i in items]
    length(parts) <= 1 && return join(parts)
    return string(join(parts[1:(end - 1)], ", "), " and ", parts[end])
end

"""
    ad_benchmark_note(a::ADBenchmarkArtifacts) -> String

Markdown prose describing what `a` is missing, or `""` when it is complete.

The page renders this above its tables so a gap is stated rather than showing
as a silently short table. Three things get their own sentence: no artefacts at
all (the normal state of a docs preview built before the benchmark jobs have
finished), backends with no artefact this run, and files that could not be
read.

Plain paragraphs rather than an admonition, because the page emits this through
Literate as captured `text/markdown` output.
"""
function ad_benchmark_note(a::ADBenchmarkArtifacts)
    lines = String[]
    if isempty(a.backends)
        push!(
            lines,
            "**No measurements for this build.** This page is configured to " *
                "render pre-computed benchmark artefacts, and none were found. " *
                "That is the normal state of a documentation preview built " *
                "before the per-backend benchmark jobs have finished; the " *
                "published page carries the measured numbers."
        )
    elseif !isempty(a.missing_backends)
        one = length(a.missing_backends) == 1
        push!(
            lines,
            "**Partial measurements.** No results were published for " *
                _join_prose(a.missing_backends) * ", so " *
                (one ? "it is" : "they are") * " absent from the tables and " *
                "plots below rather than shown as zero. That can mean the " *
                "benchmark job failed, that it had not finished when this " *
                "page was built, or that the CI matrix names a backend the " *
                "registry does not declare. It says nothing about whether " *
                "that backend differentiates these scenarios, which the " *
                "gradient tests cover separately."
        )
    end
    if !isempty(a.unreadable)
        push!(
            lines,
            "Skipped " * _join_prose(a.unreadable) *
                ": not readable as a benchmark artefact."
        )
    end
    return join(lines, "\n\n")
end

"""
    ad_benchmark_artifact_dir(docs_dir, configured) -> Union{Nothing,String}

Resolve where the AD benchmark artefacts are, or `nothing` when this build is
not rendering from artefacts at all.

`configured` is the package-owned `AD_BENCHMARK_ARTIFACTS_DIR` from
`docs_config.jl`. The `AD_BENCHMARK_ARTIFACTS_DIR` environment variable
overrides it when set and non-empty, so CI can point the build at a download
location without the package editing its (write-once) config. Either one being
set is what opts the page into artefact rendering; with neither, the page
measures live.

A relative path resolves against `docs_dir`, matching `TUTORIAL_ENVIRONMENTS`.
The result is absolute because the page runs in a subprocess whose working
directory the build does not control.
"""
function ad_benchmark_artifact_dir(
        docs_dir::AbstractString, configured::Union{Nothing, AbstractString}
    )
    from_env = get(ENV, "AD_BENCHMARK_ARTIFACTS_DIR", "")
    raw = isempty(from_env) ? configured : from_env
    (raw === nothing || isempty(raw)) && return nothing
    return isabspath(raw) ? String(raw) : abspath(joinpath(docs_dir, raw))
end

# Publish the resolved directory to the benchmark page's subprocess, which
# inherits this process's environment. Writing it back as an absolute path also
# normalises the relative form a `docs_config.jl` may have used, so the page
# itself only ever reads one thing.
function _export_ad_benchmark_dir(docs_dir, configured)
    dir = ad_benchmark_artifact_dir(docs_dir, configured)
    dir === nothing && return nothing
    ENV["AD_BENCHMARK_ARTIFACTS_DIR"] = dir
    println("AD benchmark artefacts: rendering from $dir")
    return dir
end
