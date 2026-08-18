# Generic AD-gradient harness scaffolding: given gradient scenarios (each
# carrying a ForwardDiff reference) and a list of backends, drives
# `DifferentiationInterfaceTest.test_differentiation` over the working
# scenarios and marks the rest broken. Scenarios stay package-owned; the
# harness talks to them only through the `ADRegistry` contract below.

"""
    ADRegistry

The contract a package's AD-fixture module must satisfy to drive the harness.

A registry `reg` is any object (commonly a package's `ADFixtures` module)
responding to:

  - `scenarios(reg; with_reference = true, kwargs...)` returning a vector of
    scenarios. Each scenario `s` exposes `s.name::String`, `s.f`, `s.x`,
    `s.contexts` (a tuple, possibly empty), and `s.res1` (the ForwardDiff
    reference gradient, or `nothing`). This matches a
    `DifferentiationInterfaceTest` scenario. Extra keyword arguments (e.g. a
    package's own scenario-group selector) are forwarded from the runners'
    `scenario_kwargs`.
  - `backends(reg)` returning a vector of named-tuples `(; name, backend)`,
    where `backend` is an `ADTypes` backend.

The remaining bookkeeping accessors are optional: a registry that owns no broken
or skipped scenarios may omit them, and the harness treats the missing accessor
as "none". Define them only when a package actually has such scenarios.

  - `broken_scenario_names(reg)` (optional) returning a collection of scenario
    names broken on every backend. Default: empty.
  - `backend_broken_scenarios(reg)` (optional) returning a
    `Dict{String, Set{String}}` of per-backend broken scenario names. Default:
    empty.
  - `backend_skip_scenarios(reg)` (optional) returning a
    `Dict{String, Set{String}}` of per-backend scenario names too unstable to
    run at all. Default: empty.

A package may implement these as plain functions taking the registry, or (the
common case) expose them as zero-argument functions on a module and pass the
module as `reg`; the harness calls `reg.f(...)` either way via property access.

This is a documentation-only marker; the harness duck-types on the methods
above.
"""
abstract type ADRegistry end

# Internal: resolve a registry method, supporting both a module exposing the
# zero/one-arg functions as properties and a struct with methods of the same
# name. We call through `getproperty` so a module registry works directly.
function _scenarios(reg; with_reference = true, scenario_kwargs = (;))
    return reg.scenarios(; with_reference = with_reference, scenario_kwargs...)
end
_backends(reg) = reg.backends()

# True when `reg` exposes a callable `name` accessor. A module registry exposes
# its functions as properties; a struct registry would carry them as fields.
function _has_accessor(reg, name::Symbol)
    return reg isa Module ? isdefined(reg, name) : hasproperty(reg, name)
end

# The broken/skip bookkeeping accessors are optional (see `ADRegistry`): a
# registry that defines none of them is treated as having no broken or skipped
# scenarios, so a package without such scenarios need not define empty stubs.
function _global_broken(reg)
    return _has_accessor(reg, :broken_scenario_names) ?
        reg.broken_scenario_names() : String[]
end
function _per_backend_broken(reg)
    return _has_accessor(reg, :backend_broken_scenarios) ?
        reg.backend_broken_scenarios() : Dict{String, Set{String}}()
end
function _per_backend_skip(reg)
    return _has_accessor(reg, :backend_skip_scenarios) ?
        reg.backend_skip_scenarios() : Dict{String, Set{String}}()
end

_entry(reg, name) = only(filter(e -> e.name == name, _backends(reg)))

# --- per-backend benchmark artefact (#443) ---------------------------------
#
# The scaffolded AD-comparison docs page can render pre-computed per-backend
# benchmark results instead of measuring every (backend, scenario) pair during
# the docs build, which for a large registry costs the whole AD matrix run
# serially in one process. The measurements are produced by
# [`benchmark_backend`](@ref), from its own CI job — a separate matrix leg
# from the one [`test_working_backend`](@ref) runs correctness in, and
# deliberately so: that job runs `--code-coverage=user`, and a timing taken
# under coverage instrumentation is not a benchmark. Splitting the leg also
# means benchmarking adds no time to the job the coverage gate waits on.

# JSON string escaping. The artefact schema is fixed and two levels deep, so it
# is written directly rather than through a JSON package: the AD test
# environment is package-owned and declares only what the harness needs, and
# this keeps a serialiser out of it. Backend and scenario names are free text
# from the registry, so they still have to be escaped properly.
function _json_escape(s::AbstractString)
    io = IOBuffer()
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif c < ' '
            print(io, "\\u", lpad(string(UInt32(c); base = 16), 4, '0'))
        else
            print(io, c)
        end
    end
    return String(take!(io))
end

# The gradient rows of a DIT benchmark table, in the artefact's units.
#
# Read through Tables.jl rather than by field: `test_differentiation` returns a
# `DifferentiationBenchmark` on current DIT and a `DataFrame` on older ones in
# the supported compat range, and both are Tables.jl row tables. Tables is a
# dependency of DIT itself, so it resolves wherever this can run.
#
# `value_and_gradient` rows are dropped, as the docs page has always done, and
# so are non-finite measurements: a scenario a backend could not produce a
# number for belongs absent rather than plotted at `Inf` on a log scale.
function _ad_benchmark_rows(result)
    Tables = _require_pkg("bd369af6-aec1-5ad0-b16a-f7cc5008161c", "Tables")
    rows = NamedTuple{
        (:name, :time_us, :bytes_kb), Tuple{String, Float64, Float64},
    }[]
    for row in Base.invokelatest(Tables.rows, result)
        getproperty(row, :operator) === :gradient || continue
        name = getproperty(getproperty(row, :scenario), :name)
        name === nothing && continue
        time_us = Float64(getproperty(row, :time)) * 1.0e6
        bytes_kb = Float64(getproperty(row, :bytes)) / 1024
        (isfinite(time_us) && isfinite(bytes_kb)) || continue
        push!(
            rows,
            (name = String(name), time_us = time_us, bytes_kb = bytes_kb)
        )
    end
    return rows
end

# A package may split its scenarios across several test items (by category, say)
# that share a backend and therefore an artefact path, and each of them calls
# `test_working_backend`. Writing them all to one name would leave only the last
# writer's subset on disk, with the rest silently missing from a published page,
# so a taken path takes a numbered sibling instead. The docs loader reads every
# `*.json` under the directory and concatenates files sharing a backend label,
# so the split is invisible to the page.
function _free_artifact_path(path::AbstractString)
    isfile(path) || return String(path)
    stem, ext = splitext(path)
    n = 1
    while isfile(string(stem, "-", n, ext))
        n += 1
    end
    return string(stem, "-", n, ext)
end

# Write one backend's artefact, returning the path written and how many
# scenarios it carries. `backend_name` is the registry label, which is what the
# docs page joins on, so it comes from the registry rather than from whatever
# the CI matrix called this job.
function _write_ad_benchmark_artifact(target, backend_name, result)
    rows = Base.invokelatest(_ad_benchmark_rows, result)
    io = IOBuffer()
    print(io, "{\"backend\": \"", _json_escape(backend_name), "\", ")
    print(io, "\"tag\": \"", _json_escape(target.tag), "\", ")
    print(io, "\"scenarios\": [")
    for (i, r) in enumerate(rows)
        i > 1 && print(io, ", ")
        print(io, "{\"name\": \"", _json_escape(r.name), "\", ")
        print(io, "\"time_us\": ", r.time_us, ", ")
        print(io, "\"bytes_kb\": ", r.bytes_kb, "}")
    end
    print(io, "]}")
    dir = dirname(target.path)
    isempty(dir) || mkpath(dir)
    path = _free_artifact_path(target.path)
    write(path, String(take!(io)))
    return (path = path, scenarios = length(rows))
end

"""
    check_broken(scenarios_list, backend; rtol = 5e-2, atol = 1e-6)

Run each scenario through plain `DifferentiationInterface.gradient` and record
whether it matches its reference.

A scenario passes (`@test true`) when the gradient is a finite vector matching
`scen.res1` within tolerance, and is marked `@test_broken` otherwise. This lets
a partial backend record the coverage it does have without an all-or-nothing
result. `DifferentiationInterface` must be loaded by the caller.
"""
function check_broken(scenarios_list, backend; rtol = 5.0e-2, atol = 1.0e-6)
    DI = _require_pkg(
        "a0c0ee7d-e4b9-4e03-894e-1c5f64a51d63",
        "DifferentiationInterface"
    )
    for scen in scenarios_list
        ok = try
            g = Base.invokelatest(
                DI.gradient, scen.f, backend, scen.x, scen.contexts...
            )
            ref = scen.res1
            g isa AbstractVector && all(isfinite, g) && ref !== nothing &&
                isapprox(g, ref; rtol = rtol, atol = atol)
        catch
            false
        end
        ok ? (@test ok) : (@test_broken ok)
    end
    return nothing
end

# Split a registry's scenarios for `name` into the runnable-and-ok set (fed to
# DIT) and the runnable-but-declared-broken set (fed to `check_broken`),
# applying the skip/broken bookkeeping shared by `test_working_backend` and
# `benchmark_backend` identically, so a scenario excluded from correctness
# testing is excluded from the benchmark for exactly the same reason.
function _split_scenarios(reg, name::AbstractString, scenario_kwargs)
    all_scenarios = _scenarios(
        reg; with_reference = true, scenario_kwargs = scenario_kwargs
    )
    global_broken = Set(_global_broken(reg))
    per_backend = get(_per_backend_broken(reg), name, Set{String}())
    skip = get(_per_backend_skip(reg), name, Set{String}())
    runnable = filter(s -> !(s.name in skip), all_scenarios)
    ok = filter(
        s -> !(s.name in global_broken) && !(s.name in per_backend), runnable
    )
    broken_scens = filter(
        s -> s.name in global_broken || s.name in per_backend, runnable
    )
    return (ok = ok, broken = broken_scens)
end

"""
    test_working_backend(reg, name; rtol = 5e-2, atol = 1e-6,
        scenario_intact = false)

Hard-test a working backend on the scenarios it supports.

Looks up the backend named `name` in `reg`, runs
`DifferentiationInterfaceTest.test_differentiation` (correctness only) over the
scenarios not listed as globally or per-backend broken and not in the backend's
skip set, then runs the broken scenarios through [`check_broken`] so they record
as `@test_broken`.

`scenario_intact` is forwarded to `test_differentiation`; it defaults to `false`
because a scenario carrying a `Missing`-bearing context trips DIT's default
post-run equality check (comparing a `missing`-containing vector with `==`
errors in a boolean context), while the gradients themselves stay correct.

`scenario_kwargs` is a `NamedTuple` of extra keyword arguments forwarded to the
registry's `scenarios` call, e.g. a package's own scenario-group selector
(`scenario_kwargs = (; category = :latent)`).

This never benchmarks: it runs in the coverage-instrumented per-backend CI job,
where a timing would not be a benchmark. See [`benchmark_backend`](@ref) for
the separate, uninstrumented producer of the AD-comparison page's numbers
(#443).

`DifferentiationInterface` and `DifferentiationInterfaceTest` must be loaded.
"""
function test_working_backend(
        reg, name::AbstractString;
        rtol = 5.0e-2, atol = 1.0e-6, scenario_intact::Bool = false,
        scenario_kwargs = (;)
    )
    DIT = _require_pkg(
        "a82114a7-5aa3-49a8-9643-716bb13727a3",
        "DifferentiationInterfaceTest"
    )
    backend = _entry(reg, name).backend
    split = _split_scenarios(reg, name, scenario_kwargs)
    Base.invokelatest(
        DIT.test_differentiation,
        [backend], split.ok;
        correctness = true,
        type_stability = :none,
        logging = false,
        scenario_intact = scenario_intact,
        rtol = rtol,
        atol = atol
    )
    check_broken(split.broken, backend; rtol = rtol, atol = atol)
    return nothing
end

"""
    benchmark_backend(reg, name, path; scenario_kwargs = (;),
        benchmark_seconds = 0.5, tag = nothing)

Benchmark a working backend and write the per-backend JSON artefact the
scaffolded AD-comparison docs page renders instead of measuring live (#443).

Runs `DifferentiationInterfaceTest.benchmark_differentiation` over the same
scenario split [`test_working_backend`](@ref) tests correctness on (excluding
globally/per-backend broken and per-backend skipped scenarios), so the
artefact's coverage matches what the gradient tests actually exercise.

This is meant for its own CI job, separate from and uninstrumented relative to
the per-backend correctness job: that job runs `--code-coverage=user`, so a
timing taken there would measure the coverage instrumentation, not the
backend. Deliberately unlike `test_working_backend`, a failure here is not
softened — this call exists to produce a number, and a job whose only purpose
is producing one should fail loudly if it cannot, rather than publish a page
silently short a backend.

`tag` sets the artefact's `tag` field and defaults to `path`'s basename.
`benchmark_seconds` is DIT's per-measurement budget. `DifferentiationInterface`,
`DifferentiationInterfaceTest` and `Chairmarks` must be loaded (DIT resolves
`run_benchmark!` only once `Chairmarks` is loaded).

Returns `(path, scenarios)`: the path actually written, which is `path` with a
numbered suffix inserted when `path` already exists, and how many scenarios it
carries.
"""
function benchmark_backend(
        reg, name::AbstractString, path::AbstractString;
        scenario_kwargs = (;), benchmark_seconds::Real = 0.5,
        tag::Union{Nothing, AbstractString} = nothing
    )
    DIT = _require_pkg(
        "a82114a7-5aa3-49a8-9643-716bb13727a3",
        "DifferentiationInterfaceTest"
    )
    backend = _entry(reg, name).backend
    split = _split_scenarios(reg, name, scenario_kwargs)
    # `benchmark_test = false`: correctness is `test_working_backend`'s job,
    # not this call's. `count_calls = false`: nothing here reads call counts,
    # and DIT counts them by preparing a second time against a
    # `CallCounter`-wrapped function — a distinct type, so for Enzyme and
    # Mooncake it is a whole extra rule compile per scenario, bought for a
    # field this discards. `benchmark_differentiation` has no `scenario_intact`
    # kwarg (unlike `test_differentiation`): with no correctness check to run
    # after, there is nothing for it to guard.
    result = Base.invokelatest(
        DIT.benchmark_differentiation,
        [backend], split.ok;
        logging = false,
        benchmark_test = false,
        count_calls = false,
        benchmark_seconds = benchmark_seconds
    )
    target = (
        path = String(path),
        tag = tag === nothing ? first(splitext(basename(path))) : String(tag),
    )
    return _write_ad_benchmark_artifact(target, name, result)
end

"""
    ad_backend_support_table(reg; scenario_kwargs = (;)) -> String

Render a Markdown table summarising, per registry backend, how many of the
registry's scenarios it supports and which are declared broken or skipped.

One row per `backends(reg)` entry, with the scenario coverage count
(`supported/total`) and the sorted names from the optional bookkeeping
accessors (`broken_scenario_names`, `backend_broken_scenarios`,
`backend_skip_scenarios`; a missing accessor means none — see
[`ADRegistry`](@ref)). The scaffolded AD-backends docs page calls this at
docs-build time, so a package's broken-scenario declarations live only in
its registry and the published support table can never drift from what the
gradient tests actually mark broken.

`scenario_kwargs` is forwarded to the registry's `scenarios` call, as in
[`test_working_backend`](@ref).
"""
function ad_backend_support_table(reg; scenario_kwargs = (;))
    entries = _backends(reg)
    scens = _scenarios(
        reg; with_reference = false, scenario_kwargs = scenario_kwargs
    )
    names = [String(s.name) for s in scens]
    total = length(names)
    global_broken = Set(String.(_global_broken(reg)))
    per_broken = _per_backend_broken(reg)
    per_skip = _per_backend_skip(reg)
    fmt(v) = isempty(v) ? "none" : join(v, ", ")
    lines = [
        "| Backend | Scenarios | Declared broken | Skipped |",
        "|:---|:---:|:---|:---|",
    ]
    for e in entries
        broken = sort!(
            [
                n
                    for n in names
                    if n in global_broken ||
                    n in get(per_broken, e.name, Set{String}())
            ]
        )
        skipped = sort!(
            [
                n for n in names
                    if n in get(per_skip, e.name, Set{String}())
            ]
        )
        n_ok = total - length(union(Set(broken), Set(skipped)))
        push!(
            lines,
            "| " * e.name * " | " * string(n_ok) * "/" * string(total) *
                " | " * fmt(broken) * " | " * fmt(skipped) * " |"
        )
    end
    return join(lines, "\n")
end

"""
    test_partial_backend(reg, name; rtol = 5e-2, atol = 1e-6)

Test a partially-supported backend by running every scenario through
[`check_broken`].

Each scenario the backend supports passes; the rest are marked `@test_broken`.
Use this for a backend that cannot run the full `test_differentiation` sweep
without crashing.
"""
function test_partial_backend(
        reg, name::AbstractString;
        rtol = 5.0e-2, atol = 1.0e-6, scenario_kwargs = (;)
    )
    backend = _entry(reg, name).backend
    scens = _scenarios(
        reg; with_reference = true, scenario_kwargs = scenario_kwargs
    )
    check_broken(scens, backend; rtol = rtol, atol = atol)
    return nothing
end

"""
    run_selected(reg; backends = String[], scenarios = String[],
        rtol = 5e-2, atol = 1e-6, scenario_kwargs = (;), verbose = true)

Run a named subset of scenarios against a named subset of backends, for
fast diagnosis of a single scenario/backend combination outside the full
per-backend suite.

`backends` and `scenarios` are repeatable, case-insensitive substring
filters against `backends(reg)`/`scenarios(reg)` names; an empty filter
(the default) selects everything. Errors when a filter matches nothing, so
a typo'd name fails loudly rather than silently running zero cases.

For each selected `(scenario, backend)` pair already declared in
`backend_skip_scenarios(reg)` for that backend, records `:skipped` without
attempting the call — those skips exist for combinations that can crash
the process rather than merely throw, so a diagnostic tool must not
attempt them either. Otherwise calls `DifferentiationInterface.gradient`
on `scen.f`, the backend, `scen.x`, and `scen.contexts...` (the same call
[`check_broken`](@ref) makes) inside a `try`/`catch`, classifying the
result `:pass` when the gradient is a finite vector matching `scen.res1`
within tolerance, `:mismatch` when it is not, and `:error` on an
exception.

Returns a `Vector{<:NamedTuple}` of `(scenario, backend, status, detail)`
so a caller can assert on results directly; the padded PASS/MISMATCH/
ERROR/SKIPPED table is only printed when `verbose = true`.

`scenario_kwargs` is forwarded to the registry's `scenarios` call, as in
[`test_working_backend`](@ref). `DifferentiationInterface` must be loaded
by the caller.
"""
function run_selected(
        reg; backends::AbstractVector{<:AbstractString} = String[],
        scenarios::AbstractVector{<:AbstractString} = String[],
        rtol = 5.0e-2, atol = 1.0e-6, scenario_kwargs = (;),
        verbose::Bool = true
    )
    DI = _require_pkg(
        "a0c0ee7d-e4b9-4e03-894e-1c5f64a51d63",
        "DifferentiationInterface"
    )
    matches(filters, s) = isempty(filters) ||
        any(f -> occursin(lowercase(f), lowercase(s)), filters)

    all_scens = _scenarios(
        reg; with_reference = true, scenario_kwargs = scenario_kwargs
    )
    all_backends = _backends(reg)
    sel_scens = [s for s in all_scens if matches(scenarios, String(s.name))]
    sel_backends = [b for b in all_backends if matches(backends, b.name)]

    isempty(sel_scens) && error("no scenarios match: $scenarios")
    isempty(sel_backends) && error("no backends match: $backends")

    skip = _per_backend_skip(reg)
    results = NamedTuple[]
    for s in sel_scens
        sname = String(s.name)
        for b in sel_backends
            if sname in get(skip, b.name, Set{String}())
                push!(
                    results,
                    (
                        scenario = sname, backend = b.name,
                        status = :skipped, detail = "SKIPPED",
                    )
                )
                continue
            end
            status, detail = try
                g = Base.invokelatest(
                    DI.gradient, s.f, b.backend, s.x, s.contexts...
                )
                ref = s.res1
                finite = all(isfinite, g)
                ok = g isa AbstractVector && finite && ref !== nothing &&
                    isapprox(g, ref; rtol = rtol, atol = atol)
                ok ? (:pass, "PASS") :
                    (:mismatch, "MISMATCH (finite=$finite)")
            catch e
                msg = replace(sprint(showerror, e), '\n' => ' ')
                (:error, "ERROR: " * first(msg, 90))
            end
            push!(
                results,
                (
                    scenario = sname, backend = b.name,
                    status = status, detail = detail,
                )
            )
        end
    end

    if verbose
        println(
            "Scenarios (", length(sel_scens), "): ",
            join([String(s.name) for s in sel_scens], "; ")
        )
        println(
            "Backends (", length(sel_backends), "): ",
            join([b.name for b in sel_backends], "; ")
        )
        println()
        for r in results
            println(rpad(r.scenario, 46), rpad(r.backend, 22), r.detail)
        end
        println()
        npass = count(r -> r.status == :pass, results)
        println("done: ", npass, " PASS")
    end

    return results
end
