# Generic package-quality wrappers: Aqua, JET, and ExplicitImports over a
# target module. Each EpiAware package previously carried its own copy of these;
# the only per-package input is the module under test (and an ExplicitImports
# `ignore` list for unavoidably non-public imports).

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
    # See `test_aqua` for why this goes through `invokelatest`: `Pkg` is
    # lazily loaded above, so its methods live in a world age newer than
    # this function unless a caller happened to load Pkg earlier in the
    # same process (masking the bug locally while it still reproduces on
    # a clean process/CI run — see #58's hotfix).
    Base.invokelatest(Pkg.activate, env)
    Base.invokelatest(Pkg.instantiate)
    Base.invokelatest(Pkg.activate, current)
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

`stale_deps` also accepts a `NamedTuple` of keywords forwarded to
`Aqua.test_stale_deps` (e.g. `stale_deps = (; ignore = [:LinearAlgebra])`), so
a package that deliberately keeps a dependency ahead of using it (#217) can
allow just that one rather than disabling the whole check with `false`.

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
        stale_deps !== false && @testset "stale deps" begin
            sd_kwargs = stale_deps isa NamedTuple ? stale_deps : NamedTuple()
            Base.invokelatest(Aqua.test_stale_deps, mod; sd_kwargs...)
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

# A submodule found by `ExplicitImports.find_submodules(mod)` is a package
# extension (rather than a genuine submodule) exactly when `Base.get_extension`
# resolves its name back to it. Extensions are self-parented (their
# `parentmodule` is themselves), so they are never a true submodule of `mod`.
function _is_package_extension(EI, sub::Module, mod::Module)
    sub !== mod && Base.get_extension(mod, nameof(sub)) === sub
end

# Names any currently-loaded extension of `mod` imports in a way ExplicitImports
# would otherwise flag (non-public / non-owner / stale explicit imports, plus
# implicit imports). `ExplicitImports.find_submodules` includes an extension
# only when it happens to be loaded, which depends on what else ran earlier in
# the same session — so folding these names into every check's `ignore` makes an
# extension contribute nothing to the verdict whether or not it is loaded,
# removing the extension-load-order dependence of #189. The nonrecursive
# analysis functions already apply ExplicitImports' own improper/implicit
# filters, so we only read the reported `name`s; the pass/fail verdict still
# comes from the real `check_*` functions below.
function _extension_ignore_names(EI, mod::Module)
    names = Symbol[]
    for (sub, path) in EI.find_submodules(mod)
        (path === nothing || !_is_package_extension(EI, sub, mod)) && continue
        for row in EI.improper_explicit_imports_nonrecursive(sub, path;
            strict = false)
            push!(names, row.name)
        end
        for row in EI.explicit_imports_nonrecursive(sub, path)
            push!(names, row.name)
        end
    end
    return Tuple(unique(names))
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

Package extensions are handled automatically: an extension imports its parent's
(and its trigger's) internals by design, and ExplicitImports walks an extension
only when it is loaded, so the verdict used to flip with extension-load order
(#189). The names a loaded extension imports are folded into every check's
`ignore` here, so the verdict is independent of whether extensions are loaded and
adopters no longer need to enumerate their extensions' import lists by hand.

ExplicitImports must be a dependency of the calling test environment.
"""
function test_explicit_imports(mod::Module; ignore::Tuple = (),
        implicit_ignore::Tuple = ignore)
    EI = _require_pkg("7d51a73a-1435-4ff3-83d9-f097790105c7", "ExplicitImports")
    ext_ignore = Base.invokelatest(_extension_ignore_names, EI, mod)
    ei = (ignore..., ext_ignore...)
    ii = (implicit_ignore..., ext_ignore...)
    return @testset "ExplicitImports: $(nameof(mod))" begin
        @test Base.invokelatest(
            EI.check_no_stale_explicit_imports, mod;
            ignore = ext_ignore) === nothing
        @test Base.invokelatest(
            EI.check_no_implicit_imports, mod;
            ignore = ii) === nothing
        @test Base.invokelatest(
            EI.check_all_explicit_imports_are_public, mod;
            ignore = ei) === nothing
        @test Base.invokelatest(
            EI.check_all_explicit_imports_via_owners, mod;
            ignore = ext_ignore) === nothing
    end
end

# Track the file's current source line as `_scan_scope!` walks a parsed
# expression tree, so a flagged `using`/`import` can report where it lives.
# `expr` shares the file's own top-level (module) scope when it is a bare
# `using`/`import`, or one of the wrapper forms (`:toplevel`, `:block`,
# `:if`, `:macrocall`) that do NOT introduce a new Julia scope — a
# `using`/`import` nested in an `if`/`begin`/`@static` still lands in the
# enclosing module. A `module`/`baremodule` node DOES start a fresh scope
# (that submodule's own top-level), so it is left un-recursed: its own
# `using`/`import` is exempt (that submodule body IS its "module file").
# Anything else (`function`, `for`, `while`, `let`, `try`, `do`,
# comprehensions...) cannot lexically contain `using`/`import` at all —
# Julia rejects that at parse time — so there is nothing left to find there.
function _scan_scope!(violations::Vector{Tuple{Int, String}}, expr,
        line::Base.RefValue{Int})
    if expr isa LineNumberNode
        line[] = expr.line
        return violations
    end
    expr isa Expr || return violations
    if expr.head in (:using, :import)
        push!(violations, (line[], string(expr)))
    elseif expr.head in (:toplevel, :block, :if, :macrocall)
        for a in expr.args
            _scan_scope!(violations, a, line)
        end
    end
    return violations
end

# `(line, statement text)` for every `using`/`import` in `path` that sits in
# the file's own top-level (module) scope — see `_scan_scope!`.
function _toplevel_import_violations(path::AbstractString)
    parsed = Meta.parseall(read(path, String); filename = path)
    violations = Tuple{Int, String}[]
    _scan_scope!(violations, parsed, Ref(0))
    return violations
end

# `(path, line, statement text)` for every scattered top-level `using`/
# `import` found by walking every `.jl` file under `root`, treating
# `main_file` (if given) as exempt — see `_scan_scope!` for what "top-level"
# means here. A pure filesystem walk (no `Module` involved), so it is
# directly unit-testable against a synthetic fixture tree, unlike
# [`test_import_centralisation`](@ref) which resolves `root`/`main_file`
# from a live `Module` via `pathof`.
function _import_centralisation_violations(root::AbstractString,
        main_file::Union{Nothing, AbstractString} = nothing)
    violations = Tuple{String, Int, String}[]
    for (dirpath, _, files) in walkdir(root)
        for f in files
            endswith(f, ".jl") || continue
            path = joinpath(dirpath, f)
            path == main_file && continue
            for (line, text) in _toplevel_import_violations(path)
                push!(violations, (path, line, text))
            end
        end
    end
    return violations
end

"""
    test_import_centralisation(mod::Module)

Assert every genuine `using`/`import` in `mod`'s package sits in the
top-level module file, not scattered across `include`d source files (kit
issue #105).

Walks every `.jl` file under `mod`'s package `src/` directory (as located
via `pathof(mod)`) and parses it looking for a `using`/`import` that shares
the file's own top-level scope — exactly the scope an `include`d file's
statements run in once spliced into the parent module. The main module
file itself is exempt (that is precisely where imports should live). A
nested `module`/`baremodule` block defined inside an included file (e.g. a
`Benchmarks`- or `DocsBuild`-style helper submodule) starts its own fresh
scope, so its own top-level `using`/`import` is exempt too.

Lazy, call-time dependency loads (`_require_pkg(...)`, `Base.require(...)`
inside a function body) are ordinary function calls, not `using`/`import`
syntax — and Julia disallows `using`/`import` inside a function entirely —
so they never trigger this check.
"""
function test_import_centralisation(mod::Module)
    main_file = pathof(mod)
    return @testset "Import centralisation: $(nameof(mod))" begin
        if main_file === nothing
            @test_skip "no source file for $(nameof(mod)) (pathof === nothing)"
            return nothing
        end
        offenders = _import_centralisation_violations(
            dirname(main_file), main_file)
        if !isempty(offenders)
            for (path, line, text) in offenders
                @error "Scattered top-level import (#105)" path line text
            end
        end
        @test isempty(offenders)
    end
end

# --- Eager option validation (kit#310) --------------------------------------

# A name outside `valid`, matching `valid`'s element flavour (`Symbol` vs
# `AbstractString`) so it round-trips through the same `string`/`repr`
# formatting the caller's own error message uses. Retries on a collision;
# the option-name spaces this checks are small enough in practice that a
# random 12-character suffix essentially never collides, but retrying keeps
# the fuzz honest rather than assuming that.
function _random_name_excluding(valid, rng::Random.AbstractRNG)
    taken = Set(string.(valid))
    as_symbol = !isempty(valid) && first(valid) isa Symbol
    for _ in 1:1000
        candidate = "fuzz_" * Random.randstring(rng, 'a':'z', 12)
        candidate in taken && continue
        return as_symbol ? Symbol(candidate) : candidate
    end
    error("could not find a name outside $(repr(valid)) after 1000 tries")
end

"""
    test_option_validation(f, valid; n = 50, rng = Random.default_rng())

Fuzz `f`'s eager validation of a named option.

Calls `f(bad)` with `n` random names outside `valid` and asserts each call
throws, with an error message that names the rejected value and lists
every entry of `valid` — the convention `scaffold`'s own licence check
follows (`unsupported license \$(repr(license)); choose one of ...`,
backed by `EpiAwarePackageTools.SUPPORTED_LICENSES`): a caller who
mistypes an option name gets an immediate, self-explaining failure naming
the mistake and the full valid set, rather than a value silently ignored
and the mistake surfacing later, far from its cause.

`f` is any single-argument callable performing the validation itself (and
throwing on rejection). A function that accepts a whole bag of named
options (keyword arguments, a scenario/backend registry, a set of sweep
axes) is exercised by wrapping it so one bad key reaches it, e.g.
`test_option_validation(k -> configure(; Dict(k => true)...), VALID_KEYS)`.

`valid` is the collection of legitimate values `f` accepts (`Symbol`s or
`AbstractString`s); fuzzed names are drawn from the same flavour so they
round-trip through `f`'s own formatting.

```julia
test_option_validation(
    lic -> EpiAwarePackageTools._validate_license(lic),
    EpiAwarePackageTools.SUPPORTED_LICENSES)
```
"""
function test_option_validation(f, valid; n::Integer = 50,
        rng::Random.AbstractRNG = Random.default_rng())
    return @testset "option validation" begin
        for _ in 1:n
            bad = _random_name_excluding(valid, rng)
            caught = nothing
            try
                f(bad)
            catch err
                caught = err
            end
            @testset "rejects $(repr(bad))" begin
                @test caught !== nothing
                if caught !== nothing
                    msg = sprint(showerror, caught)
                    @test occursin(string(bad), msg)
                    for v in valid
                        @test occursin(string(v), msg)
                    end
                end
            end
        end
    end
end

# --- README section structure ----------------------------------------------

"""
    STANDARD_README_SECTIONS

The standard EpiAware README section structure, in order, used as the default
`required` set by [`test_readme_sections`](@ref).

The order mirrors the sections the kit itself renders into a managed README —
Contributing, then the citation section (`## How to cite`), then Code of
conduct — so a freshly scaffolded package passes the `order = true` check out of
the box. The Contributing group therefore precedes the citing/license group by
design; a README that hand-places a `## License` or `## Supporting and citing`
section *above* Contributing must move it below to conform, rather than this
order being flipped (flipping it would fail every fresh scaffold, whose managed
block renders Contributing first).

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
    # "Cite" accepts the managed standard-sections heading `## How to cite`
    # (`_render_standard_sections`), so a freshly scaffolded package passes this
    # check out of the box rather than needing a hand-authored License/Supporting
    # section to satisfy it (#201).
    ("Citing", "Citation", "Cite", "License", "Supporting")
]

"""
    MANAGED_README_SECTIONS

The standard sections the kit manages, in the order `update` renders
them between the `standard-sections` markers (see [`scaffold`](@ref)).

The managed block is *appended* to a README that carries none of these sections
yet, so a package-owned section (commonly `## License`) can end up above,
between, or below the sections the kit writes. Only the order *within* the block
is the kit's to guarantee, and that is what [`test_readme_sections`](@ref)
checks when the markers are present (#236).
"""
const MANAGED_README_SECTIONS = [
    ("Contributing",), ("How to cite",), ("Code of conduct",)]

# Render one section group as a human-readable label for failure messages.
_section_label(group::Tuple) = join(group, " / ")

# True when `heading` matches `group` (a tuple of accepted heading texts),
# case-insensitively as a substring.
function _matches_section(heading::AbstractString, group::Tuple)
    return any(v -> occursin(lowercase(v), lowercase(heading)), group)
end

# True when any heading line of `readme` matches `group` (a tuple of accepted
# heading texts), case-insensitively as a substring. `headings` is the ordered
# vector of heading texts already extracted from the README.
function _has_section(headings::Vector{String}, group::Tuple)
    return any(h -> _matches_section(h, group), headings)
end

# Index of the first heading at or after `from` matching `group`, or `nothing`
# when absent.
function _section_index(headings::Vector{String}, group::Tuple; from::Int = 1)
    return findnext(h -> _matches_section(h, group), headings, from)
end

# True when the `required` groups appear as an ordered *subsequence* of
# `headings`: each present group matches a distinct heading, and those headings
# run in the required order. Extra package-owned headings may be interleaved
# anywhere, including ones that also match a group — a `## License` above the
# managed block no longer stands in for the managed `## How to cite` below it
# (#236). A group absent from `headings` is skipped here; its absence is
# reported by the presence check rather than failing twice. Greedy
# earliest-match is optimal for subsequence containment: taking the earliest
# admissible heading never rules out a match for a later group.
function _sections_in_order(headings::Vector{String}, required)
    from = 1
    for group in required
        _has_section(headings, group) || continue
        i = _section_index(headings, group; from = from)
        i === nothing && return false
        from = i + 1
    end
    return true
end

# The headings inside the managed standard-sections block, or `nothing` when the
# README carries no markers (a package-owned README the kit does not manage).
# Headings outside the markers are package-owned and excluded (`scaffold.jl`
# owns the marker constants; this file is included first, so they are referenced
# at call time).
function _managed_block_headings(body::AbstractString)
    si = findfirst(STANDARD_SECTIONS_START, body)
    ei = findlast(STANDARD_SECTIONS_END, body)
    (si === nothing || ei === nothing || first(ei) <= last(si)) &&
        return nothing
    return _readme_headings(body[(last(si) + 1):(first(ei) - 1)])
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
present and (when `order = true`) that the present sections appear as an ordered
subsequence of the headings.

Ordering is a subsequence, not an exact sequence: a package-owned section may
sit anywhere, including one whose heading also matches a `required` group (a
`## License` above the managed standard-sections block does not stand in for the
managed `## How to cite` below it, #236). When the README carries the managed
markers, the sections inside the block are additionally required to be all
present and in the order the kit renders them
([`MANAGED_README_SECTIONS`](@ref)) — the block's internal order is the only
section order the kit itself guarantees, since it appends the block to a README
whose own sections it does not move.

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
                @test _sections_in_order(headings, required)
            end
            # When the managed markers are present, the block's internal order
            # is the kit's to guarantee, so check it directly: a package-owned
            # section outside the markers cannot mask a managed section that is
            # missing from, or out of order inside, the block (#236).
            managed = _managed_block_headings(body)
            if managed !== nothing
                @testset "managed section order" begin
                    for group in MANAGED_README_SECTIONS
                        @test _has_section(managed, group)
                    end
                    @test _sections_in_order(managed, MANAGED_README_SECTIONS)
                end
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

A `report_filter` for [`test_jet`](@ref) that drops reports arising inside a
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
predicate returns `true` survives (a report is kept when the predicate returns
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
