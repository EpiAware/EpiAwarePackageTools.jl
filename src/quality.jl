# Generic package-quality wrappers: Aqua, JET, and ExplicitImports over a
# target module. The only per-package input is the module (and an
# ExplicitImports `ignore` list for unavoidably non-public imports).

# Validate `env` is a usable isolated project (Project.toml + runtests.jl),
# returning the runner path. Raises directly (not via @test) so a malformed
# env fails immediately rather than as a Test.TestSetException. Shared by
# test_jet's env path and _test_formatting_env in qa.jl (#58).
function _validate_isolated_env(env::AbstractString, label::AbstractString)
    isdir(env) && isfile(joinpath(env, "Project.toml")) ||
        error("$label env $env has no Project.toml")
    runner = joinpath(env, "runtests.jl")
    isfile(runner) || error("$label env $env has no runtests.jl")
    return runner
end

# Instantiate `env` (already `_validate_isolated_env`-checked) and run
# `runner` in a subprocess, returning whether it exited zero. Isolates a
# heavy QA dependency (JET / Runic) from the test environment (#58);
# callers wrap the result in their own labelled @testset/@test.
function _run_isolated_env(env::AbstractString, runner::AbstractString)
    Pkg = _require_pkg("44cfe95a-1eb2-52ea-b672-e2afdf69b78f", "Pkg")
    current = Base.active_project()
    # See `test_aqua` for why this goes through `invokelatest`; masks
    # locally if Pkg was already loaded, but reproduces on a clean CI run.
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

# Names any loaded extension of `mod` imports in a way ExplicitImports would
# flag. `find_submodules` only sees an extension when it happens to be
# loaded, so folding these names into every check's `ignore` removes that
# load-order dependence (#189); the actual pass/fail verdict still comes
# from the `check_*` functions below.
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

# Walk a parsed expression tree looking for top-level `using`/`import`,
# tracking the current source line for reporting. Recurses only into forms
# that do not introduce a new scope (:toplevel, :block, :if, :macrocall);
# a `module`/`baremodule` node starts its own scope and is left un-recursed,
# since its own using/import is exempt. Other forms cannot lexically contain
# using/import (Julia rejects that at parse time).
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
# `import` under `root`, treating `main_file` as exempt (see `_scan_scope!`).
# A pure filesystem walk, unlike [`test_import_centralisation`](@ref) which
# resolves `root`/`main_file` from a live `Module` via `pathof`.
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

# A name outside `valid`, matching its element flavour (Symbol vs
# AbstractString) so it round-trips through the caller's own error
# formatting. Length exceeds every entry of `valid` by construction (the
# "fuzz_" prefix), so no retry loop is needed to guarantee exclusion.
function _random_name_excluding(valid, rng::Random.AbstractRNG)
    as_symbol = !isempty(valid) && first(valid) isa Symbol
    width = max(12, maximum(length ∘ string, valid; init = 0))
    candidate = "fuzz_" * Random.randstring(rng, 'a':'z', width)
    return as_symbol ? Symbol(candidate) : candidate
end

"""
    test_option_validation(f, valid; n = 50, rng = Random.default_rng())

Fuzz `f`'s eager validation of a named option.

Calls `f(bad)` with `n` random names outside `valid` and asserts each call
throws, with an error message naming the rejected value and listing every
entry of `valid` (the convention `scaffold`'s own licence check follows) —
so a caller who mistypes an option name gets an immediate, self-explaining
failure rather than a value silently ignored and the mistake surfacing
later, far from its cause.

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
    # One bullet per sibling package (#292), placed after Getting started
    # and before Documentation. Replaces "What packages work well with X?",
    # which `STALE_README_HEADINGS` reports as drift.
    ("Related packages",),
    ("Documentation", "Where to learn more", "Learn more"),
    ("Contributing",),
    # "Cite" accepts the managed `## How to cite` heading
    # (`_render_standard_sections`), so a fresh scaffold passes out of the
    # box without a hand-authored License/Supporting section (#201).
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

"""
    STALE_README_HEADINGS

Retired README headings, each paired with the heading that replaced it, reported
as drift by [`test_readme_sections`](@ref).

A renamed section would otherwise be caught only as a missing section, which
says what is absent but not what to rename. Each entry is a
`Regex => replacement` pair; the regex is matched against every `##`-level (and
deeper) heading text, so a heading that carries the package name still matches.

The one entry today is the pre-#292 `What packages work well with X?`, replaced
by `## Related packages`.
"""
const STALE_README_HEADINGS = [
    r"what packages work well with"i => "Related packages"]

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
# `headings`. Extra package-owned headings may interleave anywhere, including
# ones that also match a group — a `## License` above the managed block no
# longer stands in for `## How to cite` below it (#236). A group absent from
# `headings` is skipped here (reported by the presence check instead).
# Greedy earliest-match is optimal for subsequence containment.
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

# The headings inside the managed standard-sections block, or `nothing`
# when the README carries no markers. `scaffold.jl` owns the marker
# constants; this file is included first, so they are referenced at call
# time.
function _managed_block_headings(body::AbstractString)
    si = findfirst(STANDARD_SECTIONS_START, body)
    ei = findlast(STANDARD_SECTIONS_END, body)
    (si === nothing || ei === nothing || first(ei) <= last(si)) &&
        return nothing
    return _readme_headings(body[(last(si) + 1):(first(ei) - 1)])
end

# The README file a caller's `path` names: `path` itself when it is a file,
# otherwise the `README.md` inside it. Shared by every README check so they all
# accept a package root or a direct file path.
function _readme_file(path::AbstractString)
    return isdir(path) ? joinpath(path, "README.md") : path
end

# The name a README check labels its testset with: the directory holding the
# README (i.e. the package root), which is what a caller recognises in the
# test output.
_readme_label(file::AbstractString) = basename(dirname(abspath(file)))

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
        # The capture is typed Union{Nothing, SubString} even though it
        # always matches here; the guard avoids a String(::Nothing) call
        # that JET would flag.
        text = m.captures[2]
        text === nothing || push!(headings, String(text))
    end
    return headings
end

"""
    test_readme_sections(path; required = STANDARD_README_SECTIONS,
        order = true, stale = STALE_README_HEADINGS)

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
a Getting started / Usage section, a Related packages section, a Documentation
section, a Contributing section, and a Citing / License section. A package
overrides or extends the list via its `qa_config.jl` (pass its own `required`).

A heading retired by a design change is reported as drift, naming the heading
that replaced it, rather than only as a missing section
([`STALE_README_HEADINGS`](@ref)) — today the pre-#292
`What packages work well with X?` against `## Related packages`.

The H1 title and the managed badge block are checked here too: the README must
open with a single `#` title and contain the badge markers the scaffolder
manages (see [`scaffold`](@ref)).

The README standards this check exists to hold a package to, and the ones no
check covers, are listed in [Package standards](@ref standards).

# Keyword Arguments
  - `required`: the ordered heading groups to require; default the standard set.
  - `order`: when `true`, also assert the present sections are in order.
  - `stale`: `Regex => replacement` pairs for retired headings; default
    [`STALE_README_HEADINGS`](@ref). Pass `[]` to skip the drift report.

```julia
test_readme_sections(pkgdir(MyPackage))
# extend the standard set with a package-specific section:
test_readme_sections(pkgdir(MyPackage);
    required = vcat(EpiAwarePackageTools.STANDARD_README_SECTIONS,
        [("Benchmarks",)]))
```
"""
function test_readme_sections(path::AbstractString;
        required = STANDARD_README_SECTIONS, order::Bool = true,
        stale = STALE_README_HEADINGS)
    file = _readme_file(path)
    return @testset "README sections: $(_readme_label(file))" begin
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
        # Drift against a renamed section: report the retired heading and what
        # replaced it, so the fix is a rename rather than a hunt for what is
        # missing (#292).
        @testset "stale headings" begin
            for (pattern, replacement) in stale
                found = filter(h -> occursin(pattern, h), headings)
                for h in found
                    @error "Retired README heading (#292)" heading=h replacement
                end
                @test isempty(found)
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

# --- README placeholders, prose, and Why bullets (#292) ---------------------
#
# None of these three checks is wired into the scaffolded quality testset:
# most adopting READMEs don't meet the standard yet, so a package opts in
# from its own tests until that rollout is decided.

# Characters a regex treats specially, escaped by `_regex_escape`. Base has no
# regex-escape helper, and the strings escaped here (a fragment of the seeded
# README skeleton, a banned word) legitimately carry `.`, `(`, `?`, `'`.
const _REGEX_SPECIAL = Set{Char}("\\^\$.|?*+()[]{}")

# `s` escaped so it matches itself literally inside a `Regex`.
function _regex_escape(s::AbstractString)
    io = IOBuffer()
    for c in s
        c in _REGEX_SPECIAL && print(io, '\\')
        print(io, c)
    end
    return String(take!(io))
end

# Stand-in package name (and repo slug, with an `EpiAware/` owner + `.jl`)
# used to render the seeded README skeleton for placeholder extraction: its
# occurrences mark the parts that vary per package.
const _README_SENTINEL = "PkgNameSentinel"

# The placeholder text the scaffolder seeds into a fresh README, as regexes
# matching it for any package name. Derived from `_seed_readme_body`
# (scaffold.jl, called at run time) rendered with a sentinel name, so the
# check tracks the template: sentinel occurrences become `.+` in the regex.
function _seed_readme_placeholders()
    body = _seed_readme_body("EpiAware/" * _README_SENTINEL * ".jl",
        _README_SENTINEL, nothing)
    patterns = Regex[]
    for m in eachmatch(r"_[^_\n]+_", body)
        parts = split(m.match, _README_SENTINEL)
        push!(patterns, Regex(join(map(_regex_escape, parts), ".+")))
    end
    return unique(patterns)
end

"""
    test_readme_placeholders(path; patterns = _seed_readme_placeholders())

Assert the README at `path` carries no unfilled scaffold placeholder text.

`path` is a README file or the directory containing a `README.md`. A freshly
scaffolded README is a skeleton with the package-specific wording left as
italic placeholders (`_One-line description of MyPkg._` and friends); shipping
one unfilled publishes the template rather than the package, which is what
this check catches.

The patterns are derived from the seeded skeleton itself rather than listed
here, so adding a placeholder to the scaffold extends the check with it. A
placeholder must therefore be written as an italic `_..._` span to be tracked.

# Keyword Arguments
  - `patterns`: the placeholder regexes to search for; default the ones
    derived from the scaffolded skeleton.

```julia
test_readme_placeholders(pkgdir(MyPackage))
```
"""
function test_readme_placeholders(path::AbstractString;
        patterns = _seed_readme_placeholders())
    file = _readme_file(path)
    return @testset "README placeholders: $(_readme_label(file))" begin
        if !isfile(file)
            @test_skip "no README at $file"
            return nothing
        end
        body = read(file, String)
        if isempty(patterns)
            @test_skip "no seeded placeholders to check for"
            return nothing
        end
        for pattern in patterns
            @testset "$(pattern.pattern)" begin
                found = [String(m.match) for m in eachmatch(pattern, body)]
                for text in found
                    @error "Unfilled README placeholder (#292)" file text
                end
                @test isempty(found)
            end
        end
    end
end

"""
    BANNED_README_WORDS

Words and phrases the EpiAware writing standard keeps out of prose, used as the
default `banned` list by [`test_readme_prose`](@ref).

Each entry is matched case-insensitively at a word boundary by stem, with any
suffix allowed, so listing `leverage` also catches `leverages` and `leveraging`,
and `practitioner` catches `practitioners`. A few entries carry a hand-written
stem instead, where the general one either overreaches (`novel` must not match
`novelist`) or falls short (`synergy` has to reach `synergies` and
`synergistic`, `current approaches` the singular `current approach`).

`framework` and `harness` are the two context-sensitive entries: both are
legitimate when they name a specific thing (a test harness, a named framework)
and padding when they stand in for one. A package that uses either as a domain
term drops it from its own `banned` list rather than dropping the check.
"""
const BANNED_README_WORDS = ["comprehensive", "cornerstone",
    "current approaches", "facilitate", "foster", "framework", "harness",
    "landscape", "leverage", "multifaceted", "novel", "nuanced", "overarching",
    "pivotal", "practitioner", "robust", "streamline", "synergy", "utilise",
    "utilize"]

# Entries the stem rule below gets wrong, as the body of their own regex.
# `novel` needs a closed suffix list, since an open one reaches `novelist`.
# `synergy` and `current approaches` need a shorter stem than trimming a
# trailing `e` gives, to reach `synergies`, `synergistic`, and the singular
# `current approach`.
const _BANNED_WORD_PATTERNS = Dict("novel" => "novel(?:s|ly|ty|ties)?",
    "synergy" => "synerg(?:y|ies|i[sz]e[sd]?|i[sz]ing|istic(?:ally)?)",
    "current approaches" => "current\\s+approach(?:es)?")

# A banned word/phrase as a regex: case-insensitive, word-boundary anchored,
# any suffix allowed. A trailing `e` is trimmed off the final word so the
# `-ing`/`-ed` inflections are caught too (`leverage` must match
# `leveraging`); entries in `_BANNED_WORD_PATTERNS` carry their own body.
function _banned_word_regex(word::AbstractString)
    key = String(strip(word))
    body = get(_BANNED_WORD_PATTERNS, lowercase(key), nothing)
    if body === nothing
        stems = map(_regex_escape, split(key))
        stems[end] = replace(stems[end], r"e$" => "")
        body = join(stems, "\\s+") * "[a-z]*"
    end
    return Regex("\\b" * body * "\\b", "i")
end

# Markup scrubbed from one prose line: inline code spans, images, link targets
# (the link text stays, the URL goes), inline HTML tags, and bare URLs. Each is
# replaced by a space rather than deleted, so two words either side of it do not
# run together into one.
function _scrub_markup(line::AbstractString)
    text = replace(line, r"`[^`]*`" => " ")
    text = replace(text, r"!\[[^\]]*\]\([^)]*\)" => " ")
    text = replace(text, r"\[([^\]]*)\]\([^)]*\)" => s"\1")
    text = replace(text, r"<[^>]*>" => " ")
    text = replace(text, r"https?://\S+" => " ")
    return String(text)
end

# The prose lines of a README as `(line number, text)` pairs. Dropped whole:
# fenced code blocks, HTML comments (the badge/section markers are HTML
# comments), and table rows. Scrubbed within a line: see `_scrub_markup`.
# Line numbers are the README's own, so a failure points at the source line.
function _readme_prose_lines(body::AbstractString)
    lines = Tuple{Int, String}[]
    in_fence = false
    in_comment = false
    for (i, raw) in enumerate(split(body, '\n'))
        line = String(raw)
        if in_comment
            closer = findfirst("-->", line)
            closer === nothing && continue
            line = line[(last(closer) + 1):end]
            in_comment = false
        end
        if startswith(strip(line), "```")
            in_fence = !in_fence
            continue
        end
        in_fence && continue
        line = replace(line, r"<!--.*?-->" => " ")
        opener = findfirst("<!--", line)
        if opener !== nothing
            line = line[1:(first(opener) - 1)]
            in_comment = true
        end
        startswith(strip(line), "|") && continue
        push!(lines, (i, _scrub_markup(line)))
    end
    return lines
end

# True when `text` (already stripped) starts a new prose block: a Markdown
# heading, or a list item.
function _starts_prose_block(text::AbstractString)
    return occursin(r"^#{1,6}\s", text) || occursin(r"^([-*+]|\d+[.)])\s", text)
end

# Group prose lines into blocks a sentence can span: a run of non-blank
# lines, broken at a blank line, heading, or list-item start. A sentence
# wrapped over three lines is measured whole; adjacent bullets never merge.
# Each block is `(first line number, joined text)`.
function _prose_blocks(lines)
    blocks = Tuple{Int, String}[]
    current = String[]
    start = 0
    for (i, text) in lines
        s = strip(text)
        if (isempty(s) || _starts_prose_block(s)) && !isempty(current)
            push!(blocks, (start, join(current, " ")))
            empty!(current)
        end
        isempty(s) && continue
        isempty(current) && (start = i)
        push!(current, String(s))
    end
    isempty(current) || push!(blocks, (start, join(current, " ")))
    return blocks
end

# Abbreviations whose full stop never ends a sentence, but are commonly
# followed by a capital (`e.g. Gamma`), which would trip the capital rule
# below. Their dots are swapped for a one-dot leader before splitting, and
# back afterwards. `etc.` is deliberately absent: it does end sentences.
const _PROSE_ABBREVIATIONS = ("e.g.", "i.e.", "cf.", "vs.", "et al.")

const _DOT_LEADER = '\u2024'

# The end of a sentence: terminal punctuation, then whitespace, then something
# that can start a sentence. A dot with no whitespace after it is not a break
# (a version number, `Distributions.jl`), and neither is one followed by a
# lowercase word (`Gamma, LogNormal, etc. without extra work`).
const _SENTENCE_BREAK = r"(?<=[.!?])\s+(?=[A-Z0-9(\[\"'])"

# Split prose into sentences. The capital rule breaks at any abbreviation not
# listed above (`Fig. 1`, `Dr. Smith`), so one sentence can be reported as two:
# fine for the length check, which then measures fragments and passes, but the
# one-sentence bullet rule false-positives on it. Tracked in #347.
function _sentences(text::AbstractString)
    protected = text
    for abbrev in _PROSE_ABBREVIATIONS
        protected = replace(protected, abbrev => replace(abbrev, '.' =>
            _DOT_LEADER))
    end
    sentences = String[]
    for part in split(protected, _SENTENCE_BREAK)
        sentence = strip(replace(part, _DOT_LEADER => '.'))
        isempty(sentence) || push!(sentences, String(sentence))
    end
    return sentences
end

"""
    test_readme_prose(path; banned = BANNED_README_WORDS,
        max_sentence_words = 40)

Assert the README at `path` reads as plain prose: no banned word, no
overlong sentence.

`path` is a README file or the directory containing a `README.md`. Only prose
is in scope — fenced code blocks, tables (the managed badge table included),
HTML comments, inline code spans, link URLs, and bare URLs are all removed
before the check runs, so a banned word inside an identifier or a URL is not a
failure while the same word in a sentence is. Link text is kept: a reader reads
it.

Sentence length is measured in words over the prose lines of a block (a run of
lines a wrapped sentence can span), so a sentence split across three source
lines is measured once, whole.

# Keyword Arguments
  - `banned`: the words and phrases to reject; default
    [`BANNED_README_WORDS`](@ref). Each is matched case-insensitively at a word
    boundary with any suffix allowed.
  - `max_sentence_words`: the longest sentence accepted, in words.

```julia
test_readme_prose(pkgdir(MyPackage))
# a package whose domain term is on the default list:
test_readme_prose(pkgdir(MyPackage);
    banned = filter(!=("harness"), EpiAwarePackageTools.BANNED_README_WORDS))
```
"""
function test_readme_prose(path::AbstractString;
        banned = BANNED_README_WORDS, max_sentence_words::Integer = 40)
    file = _readme_file(path)
    return @testset "README prose: $(_readme_label(file))" begin
        if !isfile(file)
            @test_skip "no README at $file"
            return nothing
        end
        lines = _readme_prose_lines(read(file, String))
        @testset "banned words" begin
            hits = Tuple{Int, String, String}[]
            for word in banned
                pattern = _banned_word_regex(word)
                for (i, text) in lines
                    m = match(pattern, text)
                    m === nothing || push!(hits, (i, word, String(m.match)))
                end
            end
            for (line, word, found) in hits
                @error "Banned word in README prose" line word found
            end
            @test isempty(hits)
        end
        @testset "sentence length" begin
            long = Tuple{Int, Int, String}[]
            for (i, block) in _prose_blocks(lines)
                for sentence in _sentences(block)
                    words = length(split(sentence))
                    words > max_sentence_words &&
                        push!(long, (i, words, sentence))
                end
            end
            for (line, words, sentence) in long
                @error("README sentence over the word limit",
                    line, words, max_sentence_words, sentence)
            end
            @test isempty(long)
        end
    end
end

# The lines of the `##`-level section whose heading matches `group`, as
# `(line number, text)` pairs. A deeper (`###` or lower) heading inside the
# section is skipped rather than ending it; the next `##`-or-shallower heading
# ends it. Lines inside a fenced code block are dropped, so a bullet in a
# worked example is not read as a section bullet. Empty when the section is
# absent.
function _readme_section_lines(body::AbstractString, group::Tuple)
    lines = Tuple{Int, String}[]
    in_fence = false
    inside = false
    for (i, raw) in enumerate(split(body, '\n'))
        line = String(raw)
        stripped = strip(line)
        if startswith(stripped, "```")
            in_fence = !in_fence
            continue
        end
        in_fence && continue
        m = match(r"^(#{1,6})\s+(.+?)\s*$", stripped)
        if m !== nothing
            level = length(something(m.captures[1], ""))
            text = something(m.captures[2], "")
            if inside
                level <= 2 && break
                continue
            end
            inside = level == 2 && _matches_section(text, group)
            continue
        end
        inside && push!(lines, (i, line))
    end
    return lines
end

# The top-level bullets of a section as `(line number, text)` pairs, folding
# each bullet's indented continuation lines (and any nested bullet) into its
# text, so a wrapped bullet counts once and is measured whole. A blank line, or
# a non-indented line that is not itself a bullet, closes the bullet being
# folded, so prose framing the list is never mistaken for part of it.
function _section_bullets(lines)
    bullets = Tuple{Int, String}[]
    folding = false
    for (i, line) in lines
        if occursin(r"^[-*+]\s+\S", line)
            push!(bullets, (i, String(strip(line))))
            folding = true
        elseif folding && occursin(r"^\s+\S", line)
            j, text = bullets[end]
            bullets[end] = (j, text * " " * String(strip(line)))
        else
            folding = false
        end
    end
    return bullets
end

# A bullet in the disfavoured feature-inventory form: a bold label followed by a
# colon, in either placement of the colon (`**Label**: does X` or
# `**Label:** does X`). #292's first requirement rules this out for the Why
# section in favour of a sentence saying why a reader needs the package.
const _BULLET_FEATURE_LABEL = r"""
    ^[-*+]\s+\*\*[^*]+\*\*\s*:   # **Label**: does X
    |
    ^[-*+]\s+\*\*[^*]*:\*\*      # **Label:** does X
    """x

# A bullet's prose: the marker dropped and the markup scrubbed, ready to be
# split into sentences.
function _bullet_prose(text::AbstractString)
    return _scrub_markup(replace(text, r"^[-*+]\s+" => ""))
end

"""
    test_readme_bullets(path; heading = first(STANDARD_README_SECTIONS),
        min_bullets = 3, max_bullets = 6)

Assert the README's Why section is a short list of motivation sentences.

`path` is a README file or the directory containing a `README.md`. The check
reads the bullets under the Why (or Overview) heading, folding each bullet's
wrapped continuation lines into it, and asserts three things (#292).

  - No bullet opens with a bold label followed by a colon
    (`**Primary event censoring**: ...`). That form is a feature inventory; the
    standard asks for a sentence saying why a reader needs the package.
  - The bullet count is within `min_bullets:max_bullets`. Too few does not
    justify the package; too many is a feature list again.
  - No bullet runs to more than one sentence. Detail beyond the first sentence
    belongs in the documentation, not the pitch.

When the README has no Why section at all the check skips: that absence is
[`test_readme_sections`](@ref)' report to make, and failing here too would
report one drift twice.

# Keyword Arguments
  - `heading`: the accepted heading texts of the section to read, as a tuple
    matched case-insensitively by substring; default the standard set's first
    group (Why / Overview / Features / About).
  - `min_bullets`, `max_bullets`: the accepted bullet count range.

```julia
test_readme_bullets(pkgdir(MyPackage))
```
"""
function test_readme_bullets(path::AbstractString;
        heading::Tuple = first(STANDARD_README_SECTIONS),
        min_bullets::Integer = 3, max_bullets::Integer = 6)
    file = _readme_file(path)
    label = _section_label(heading)
    return @testset "README bullets: $(_readme_label(file))" begin
        if !isfile(file)
            @test_skip "no README at $file"
            return nothing
        end
        section = _readme_section_lines(read(file, String), heading)
        if isempty(section)
            @test_skip "no $label section in $file"
            return nothing
        end
        bullets = _section_bullets(section)
        @testset "bullet count" begin
            found = length(bullets)
            in_range = min_bullets <= found <= max_bullets
            in_range || @error("$label bullet count outside range (#292)",
                found, min_bullets, max_bullets)
            @test in_range
        end
        @testset "motivation, not a feature inventory" begin
            labelled = filter(b -> occursin(_BULLET_FEATURE_LABEL, b[2]),
                bullets)
            for (line, text) in labelled
                @error("$label bullet is a bold feature label rather than " *
                       "a motivation sentence (#292)", line, text)
            end
            @test isempty(labelled)
        end
        @testset "one sentence per bullet" begin
            multi = Tuple{Int, Int, String}[]
            for (i, text) in bullets
                sentences = _sentences(_bullet_prose(text))
                length(sentences) > 1 &&
                    push!(multi, (i, length(sentences), text))
            end
            for (line, sentences, text) in multi
                @error("$label bullet runs to more than one sentence (#292)",
                    line, sentences, text)
            end
            @test isempty(multi)
        end
    end
end

# Matched by type name (on the innermost frame's MethodInstance) so
# DynamicPPL need not be loaded here.
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
