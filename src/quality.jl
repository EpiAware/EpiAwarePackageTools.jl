# Generic package-quality wrappers: Aqua, JET, and ExplicitImports over a
# target module. Each EpiAware package previously carried its own copy of these;
# the only per-package input is the module under test (and an ExplicitImports
# `ignore` list for unavoidably non-public imports).

using Test: @testset, @test, @test_skip

# Validate that `env` looks like a usable isolated project (a `Project.toml`
# plus a `runtests.jl`), returning the runner path. Raises a plain
# `ErrorException` directly — NOT wrapped in `@test`/`@testset` — so a
# malformed `env` surfaces immediately to the caller (matching each site's
# original behaviour, and what `test/qa.jl`'s
# `"test_formatting env mode runs a subprocess runner"` asserts via
# `@test_throws ErrorException`), rather than being swallowed into a
# `Test.TestSetException`. Shared by `test_jet`'s `env` path and
# `_test_formatting_env` (in qa.jl) (#58).
function _validate_isolated_env(env::AbstractString, label::AbstractString)
    isdir(env) && isfile(joinpath(env, "Project.toml")) ||
        error("$label env $env has no Project.toml")
    runner = joinpath(env, "runtests.jl")
    isfile(runner) || error("$label env $env has no runtests.jl")
    return runner
end

# Instantiate `env` (assumed already `_validate_isolated_env`-checked) and run
# `runner` in an isolated subprocess, reporting whether it exited zero. Shared
# by `test_jet`'s `env` path and `_test_formatting_env`, which both isolate a
# heavy QA dependency (JET / JuliaFormatter) from the rest of the test
# environment by pinning it in its own project and running it out-of-process,
# rather than loading it alongside deps it may clash with (#58). Callers wrap
# the returned `Bool` in their own labelled `@testset`/`@test`.
function _run_isolated_env(env::AbstractString, runner::AbstractString)
    Pkg = _require_pkg("44cfe95a-1eb2-52ea-b672-e2afdf69b78f", "Pkg")
    current = Base.active_project()
    Pkg.activate(env)
    Pkg.instantiate()
    Pkg.activate(current)
    result = run(
        pipeline(`$(Base.julia_cmd()) --project=$env $runner`,
            stdout = stdout, stderr = stderr);
        wait = true)
    return result.exitcode == 0
end

"""
    test_aqua(mod; kwargs...)

Run the standard Aqua.jl quality suite over `mod`.

Wraps the individual `Aqua.test_*` checks (unbound args, undefined exports,
project extras, stale deps, deps compat, undocumented names, piracies,
ambiguities) in one `@testset`. Keyword arguments forward to each check that
accepts them, so a package can relax a single check without re-listing the rest
(e.g. `test_aqua(MyPkg; ambiguities = false)` to skip the ambiguity check).

Aqua must be a dependency of the calling test environment.
"""
function test_aqua(mod::Module; ambiguities = true, unbound_args = true,
        undefined_exports = true, project_extras = true, stale_deps = true,
        deps_compat = true, undocumented_names = true, piracies = true)
    Aqua = _require_pkg("4c88cf16-eb10-579e-8560-4a9242c79595", "Aqua")
    return @testset "Aqua.jl: $(nameof(mod))" begin
        unbound_args && @testset "unbound args" begin
            Base.invokelatest(Aqua.test_unbound_args, mod)
        end
        undefined_exports && @testset "undefined exports" begin
            Base.invokelatest(Aqua.test_undefined_exports, mod)
        end
        project_extras && @testset "project extras" begin
            Base.invokelatest(Aqua.test_project_extras, mod)
        end
        stale_deps && @testset "stale deps" begin
            Base.invokelatest(Aqua.test_stale_deps, mod)
        end
        deps_compat && @testset "deps compat" begin
            Base.invokelatest(Aqua.test_deps_compat, mod)
        end
        undocumented_names && @testset "undocumented names" begin
            Base.invokelatest(Aqua.test_undocumented_names, mod)
        end
        piracies && @testset "piracies" begin
            Base.invokelatest(Aqua.test_piracies, mod)
        end
        ambiguities && @testset "ambiguities" begin
            Base.invokelatest(Aqua.test_ambiguities, mod)
        end
    end
end

"""
    test_explicit_imports(mod; ignore = (), implicit_ignore = ignore)

Run the ExplicitImports.jl conformance checks over `mod`.

Asserts there are no stale explicit imports, no implicit imports, that every
explicit import is public in its source module, and that imports come from their
owning module.

  - `ignore` — a tuple of `Symbol`s for unavoidable non-public explicit
    imports (e.g. an upstream internal used by an extension); forwarded to
    `check_all_explicit_imports_are_public`.
  - `implicit_ignore` — a tuple of names that are legitimately implicit and
    must not fail `check_no_implicit_imports`; defaults to `ignore`. The common
    case is a `@reexport using SomePkg`, which makes the bare module name
    `SomePkg` an implicit import that no amount of explicit listing removes —
    pass `implicit_ignore = (:SomePkg,)` so a reexporting package conforms.

ExplicitImports must be a dependency of the calling test environment.
"""
function test_explicit_imports(mod::Module; ignore::Tuple = (),
        implicit_ignore::Tuple = ignore)
    EI = _require_pkg("7d51a73a-1435-4ff3-83d9-f097790105c7", "ExplicitImports")
    return @testset "ExplicitImports: $(nameof(mod))" begin
        @test Base.invokelatest(
            EI.check_no_stale_explicit_imports, mod) === nothing
        @test Base.invokelatest(
            EI.check_no_implicit_imports, mod;
            ignore = implicit_ignore) === nothing
        @test Base.invokelatest(
            EI.check_all_explicit_imports_are_public, mod;
            ignore = ignore) === nothing
        @test Base.invokelatest(
            EI.check_all_explicit_imports_via_owners, mod) === nothing
    end
end

# --- README section structure ----------------------------------------------

"""
    STANDARD_README_SECTIONS

The standard EpiAware README section structure, in order, distilled from the
CensoredDistributions gold standard and used as the default `required` set by
[`test_readme_sections`](@ref).

Each entry is a tuple of accepted `##`-heading texts (case-insensitive,
substring match), and the check passes if any variant is present; the H1 title
and the badge block (between the markers, refreshed by `update`) precede these
and are checked separately. A package may title the equivalent section
differently (e.g. "Getting started" vs "Usage"), so a tuple lists the accepted
alternatives. Extend or relax it per package via the `required` keyword of
[`test_readme_sections`](@ref).
"""
const STANDARD_README_SECTIONS = [
    ("Why", "Overview", "Features", "About"),
    ("Getting started", "Usage", "Quickstart", "Quick start"),
    ("Documentation", "Where to learn more", "Learn more"),
    ("Contributing",),
    ("Citing", "Citation", "License", "Supporting")
]

# Render one section group as a human-readable label for failure messages.
_section_label(group::Tuple) = join(group, " / ")

# True when any heading line of `readme` matches `group` (a tuple of accepted
# heading texts), case-insensitively as a substring. `headings` is the ordered
# vector of heading texts already extracted from the README.
function _has_section(headings::Vector{String}, group::Tuple)
    return any(headings) do h
        any(v -> occursin(lowercase(v), lowercase(h)), group)
    end
end

# Index of the first heading matching `group`, or `nothing` when absent.
function _section_index(headings::Vector{String}, group::Tuple)
    for (i, h) in pairs(headings)
        any(v -> occursin(lowercase(v), lowercase(h)), group) && return i
    end
    return nothing
end

# Extract the ordered `##`-level (or deeper) Markdown heading texts from a
# README body, ignoring the H1 title and fenced code blocks (so a `#` inside a
# ```code``` block is not mistaken for a heading).
function _readme_headings(body::AbstractString)
    headings = String[]
    in_fence = false
    for line in split(body, '\n')
        s = strip(line)
        if startswith(s, "```")
            in_fence = !in_fence
            continue
        end
        in_fence && continue
        m = match(r"^(#{2,6})\s+(.+?)\s*$", s)
        m === nothing && continue
        # `(.+?)` always matches when `m !== nothing`, but its capture is typed
        # `Union{Nothing, SubString}`; the explicit guard keeps that from being
        # a `String(::Nothing)` call (which JET flags).
        text = m.captures[2]
        text === nothing || push!(headings, String(text))
    end
    return headings
end

"""
    test_readme_sections(path; required = STANDARD_README_SECTIONS, order = true)

Assert the README at `path` carries the standard EpiAware section structure.

`path` is a README file or the directory containing a `README.md`. The check
reads the `##`-level (and deeper) headings, skipping the H1 title and any
heading inside a fenced code block, then asserts each entry of `required` is
present and (when `order = true`) that the present sections appear in the given
order.

`required` is a vector of heading groups; each group is a tuple of accepted
heading texts matched case-insensitively as a substring, so a package may title
the section to taste (e.g. `("Getting started", "Usage")`). The default is the
standard structure ([`STANDARD_README_SECTIONS`](@ref)): a Why/Overview section,
a Getting started / Usage section, a Documentation section, a Contributing
section, and a Citing / License section. A package overrides or extends the list
via its `qa_config.jl` (pass its own `required`).

The H1 title and the managed badge block are checked here too: the README must
open with a single `#` title and contain the badge markers the scaffolder
manages (see [`scaffold`](@ref)).

# Keyword Arguments
  - `required`: the ordered heading groups to require; default the standard set.
  - `order`: when `true`, also assert the present sections are in order.

```julia
test_readme_sections(pkgdir(MyPackage))
# extend the standard set with a package-specific section:
test_readme_sections(pkgdir(MyPackage);
    required = vcat(EpiAwarePackageTools.STANDARD_README_SECTIONS,
        [("Benchmarks",)]))
```
"""
function test_readme_sections(path::AbstractString;
        required = STANDARD_README_SECTIONS, order::Bool = true)
    file = isdir(path) ? joinpath(path, "README.md") : path
    return @testset "README sections: $(basename(dirname(abspath(file))))" begin
        if !isfile(file)
            @test_skip "no README at $file"
            return nothing
        end
        body = read(file, String)
        # H1 title and the managed badge markers (`scaffold.jl` owns the marker
        # constants; this file is included before it, so reference them at call
        # time, not parse time).
        @test occursin(r"(?m)^#\s+\S", body)
        @test occursin(BADGES_START, body)
        @test occursin(BADGES_END, body)

        headings = _readme_headings(body)
        for group in required
            @testset "$(_section_label(group))" begin
                @test _has_section(headings, group)
            end
        end
        if order
            @testset "section order" begin
                idxs = Int[]
                for group in required
                    i = _section_index(headings, group)
                    i === nothing || push!(idxs, i)
                end
                @test issorted(idxs)
            end
        end
    end
end

# A report is "in a DynamicPPL `@model`-generated method" when its innermost
# frame's `MethodInstance` takes the DynamicPPL model-evaluator signature
# `(::Model, ::AbstractVarInfo, ...)`. `@model` lowers each `~`/`:=` line into
# this evaluator, hiding the assignment from JET's static analysis, so JET emits
# spurious `UndefVarErrorReport`s for every `~`-assigned local and
# `MethodErrorReport`s through the `:=` tracking machinery. Matching on the
# evaluator signature (by type name, so DynamicPPL need not be loaded here)
# drops exactly those artefacts while keeping every genuine report.
"""
    dynamicppl_model_filter(report) -> Bool

A `report_filter` for [`test_jet`](@ref) that DROPS reports arising inside a
DynamicPPL `@model`-generated method (matched on the model-evaluator signature
`(::Model, ::AbstractVarInfo, ...)`), and keeps every other report.

Use this for a Turing/DynamicPPL package whose public surface is `@model`
functions: `test_jet(MyPkg; report_filter = dynamicppl_model_filter)`. Without
it, JET reports a false `UndefVarErrorReport` for every `~`-assigned variable
(and `MethodErrorReport`s through the `:=` tracker), none of which is a real
defect.
"""
function dynamicppl_model_filter(report)
    sig = try
        mi = report.vst[end].linfo
        mi.specTypes
    catch
        return true  # cannot classify: keep the report (fail closed)
    end
    params = try
        Base.unwrap_unionall(sig).parameters
    catch
        return true
    end
    length(params) >= 3 || return true
    is_model = _typename_is(params[2], "Model")
    is_vi = _typename_is(params[3], "AbstractVarInfo") ||
            _typename_is(params[3], "VarInfo") ||
            _occurs_varinfo(params[3])
    # Drop (return false) only when both the model and varinfo positions match.
    return !(is_model && is_vi)
end

# True when the type `t`'s name is exactly `name` (ignoring its defining
# module), tolerant of UnionAll/abstract wrappers.
function _typename_is(t, name::AbstractString)
    return try
        string(Base.unwrap_unionall(t).name.name) == name
    catch
        false
    end
end

_occurs_varinfo(t) = occursin("VarInfo", string(t))

"""
    test_jet(mod; target_modules = (mod,), env = nothing,
        skip_experimental = true, report_filter = nothing)

Run JET over `mod`.

JET is run in an isolated environment to keep its `JuliaSyntax` / dependency
pins from clashing with the rest of the test environment. Pass `env` as the path
to a project directory holding JET plus the package; that project's
`runtests.jl` is run in a subprocess and the test passes if it exits zero. When
`env` is `nothing` JET is loaded into the current environment and run directly
(simpler, but only safe when JET coexists with the test deps).

`report_filter` is an optional predicate `report -> Bool`: when supplied, JET is
run via `report_package` and the test asserts that no report for which the
predicate returns `true` survives (a report is KEPT when the predicate returns
`true`). This lets a package suppress known false positives without silencing
the whole check. For a DynamicPPL `@model` package, pass
[`dynamicppl_model_filter`](@ref), which drops the macro's spurious
`~`/`:=` reports. When `report_filter` is `nothing` (default), JET runs via
`test_package` and fails on any report. `report_filter` is ignored in `env` mode
(the isolated `runtests.jl` owns that configuration).

By default JET is skipped on experimental / pre-release Julia (and when
`JULIA_CI_EXPERIMENTAL=true`), where JET often lags the compiler.
"""
function test_jet(mod::Module; target_modules = (mod,),
        env::Union{Nothing, AbstractString} = nothing,
        skip_experimental::Bool = true,
        report_filter::Union{Nothing, Function} = nothing)
    return @testset "JET: $(nameof(mod))" begin
        if skip_experimental && (VERSION >= v"1.13-" ||
            get(ENV, "JULIA_CI_EXPERIMENTAL", "false") == "true")
            @test_skip "JET skipped on experimental Julia"
            return nothing
        end
        if env === nothing
            # See `test_aqua` for why this goes through `invokelatest`.
            JET = _require_pkg("c3a54625-cd67-489e-a8e7-0a5a0ff4e31b", "JET")
            if report_filter === nothing
                Base.invokelatest(JET.test_package, mod;
                    target_modules = target_modules)
            else
                result = Base.invokelatest(JET.report_package, mod;
                    target_modules = target_modules)
                reports = Base.invokelatest(JET.get_reports, result)
                kept = filter(report_filter, reports)
                if !isempty(kept)
                    for r in kept
                        @info "JET report (not filtered)" report = sprint(
                            show, r)
                    end
                end
                @test isempty(kept)
            end
        else
            runner = _validate_isolated_env(env, "JET")
            @test _run_isolated_env(env, runner)
        end
    end
end
