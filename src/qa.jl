# Generic QA-helper wrappers that fill the gap left by `quality.jl`: docstring
# format conventions, per-extension method-ambiguity checks, doctests, and code
# formatting/linting. Each EpiAware package previously carried its own copy of
# these checks; the package-specific parts (ignore lists, extension names,
# allowed cross-references) are caller-supplied arguments, never baked in.

using Test: @testset, @test, @test_skip, @test_broken, detect_ambiguities
using Markdown: Markdown

"""
    test_doctest(mod)

Run Documenter's `doctest` over `mod`.

A thin wrapper that runs the package doctests in one `@testset`. Documenter must
be a dependency of the calling test environment.
"""
function test_doctest(mod::Module)
    # See `test_aqua` for why this goes through `invokelatest`.
    Documenter = Base.require(Base.PkgId(
        Base.UUID("e30172f5-a6a5-5a46-863b-614d45cd2de4"), "Documenter"))
    return @testset "doctest: $(nameof(mod))" begin
        Base.invokelatest(Documenter.doctest, mod)
    end
end

"""
    test_formatting(dirs; style = "sciml", verbose = true)
    test_formatting(mod; ...)

Check that the given source trees are JuliaFormatter-clean.

`dirs` is a collection of directory paths; non-existent entries are skipped, and
each existing directory is checked without modification. Passing a `Module`
defaults to checking the `src`, `test`, `docs`, and `benchmark` directories of
the package that owns `mod`. `style` selects the JuliaFormatter style (the
EpiAware standard is `"sciml"`); the `.JuliaFormatter.toml` at the package root
still takes precedence when present.

The test passes when every directory is already formatted. JuliaFormatter must
be a dependency of the calling environment; to keep its `JuliaSyntax` pin from
clashing with JET, run this from an isolated formatter environment (see the
`templates/Taskfile.yml` `test-formatting` target).

Pass `env` (the path to an isolated formatter project directory holding
JuliaFormatter) to run the check in a subprocess via that project's
`runtests.jl`, exactly as [`test_jet`](@ref) isolates JET. The test then passes
when the subprocess exits zero, and JuliaFormatter need not be a dependency of
the calling environment — the recommended layout when the test items share an
environment with JET. `style`/`verbose`/`dirs` are ignored in `env` mode (the
isolated `runtests.jl` owns that configuration).
"""
function test_formatting(dirs; style::AbstractString = "sciml",
        verbose::Bool = true,
        env::Union{Nothing, AbstractString} = nothing)
    env === nothing || return _test_formatting_env(env)
    # See `test_aqua` for why this goes through `invokelatest`.
    JF = Base.require(Base.PkgId(
        Base.UUID("98e50ef6-434e-11e9-1051-2b60c6c9e899"), "JuliaFormatter"))
    existing = filter(isdir, collect(String, dirs))
    return @testset "formatting" begin
        if isempty(existing)
            @test_skip "no source directories found to format-check"
        else
            sty = _formatter_style(JF, style)
            all_ok = all(existing) do dir
                Base.invokelatest(JF.format, dir;
                    style = sty, verbose = verbose, overwrite = false)
            end
            @test all_ok
        end
    end
end

# Run the formatter check in an isolated subprocess (cf. `test_jet`'s `env`
# path): instantiate `env`, then run its `runtests.jl` and assert a zero exit.
function _test_formatting_env(env::AbstractString)
    Pkg = Base.require(Base.PkgId(
        Base.UUID("44cfe95a-1eb2-52ea-b672-e2afdf69b78f"), "Pkg"))
    isdir(env) && isfile(joinpath(env, "Project.toml")) ||
        error("formatter env $env has no Project.toml")
    runner = joinpath(env, "runtests.jl")
    isfile(runner) || error("formatter env $env has no runtests.jl")
    current = Base.active_project()
    Pkg.activate(env)
    Pkg.instantiate()
    Pkg.activate(current)
    return @testset "formatting" begin
        result = run(
            pipeline(`$(Base.julia_cmd()) --project=$env $runner`,
                stdout = stdout, stderr = stderr);
            wait = true)
        @test result.exitcode == 0
    end
end

# Map a style name to a JuliaFormatter style instance. A `.JuliaFormatter.toml`
# at the package root still overrides this per directory.
function _formatter_style(JF, style::AbstractString)
    s = lowercase(style)
    # `JF` is loaded at call time via `Base.require`, so its style constructors
    # live in a newer world age; build through `invokelatest` (cf. `test_aqua`).
    s == "sciml" && return Base.invokelatest(JF.SciMLStyle)
    s == "blue" && return Base.invokelatest(JF.BlueStyle)
    s == "yas" && return Base.invokelatest(JF.YASStyle)
    s in ("default", "") && return Base.invokelatest(JF.DefaultStyle)
    error("unknown JuliaFormatter style $style")
end

function test_formatting(mod::Module; kwargs...)
    src = pathof(mod)
    src === nothing && error("module $(nameof(mod)) has no source path")
    root = dirname(dirname(src))
    dirs = [joinpath(root, d) for d in ("src", "test", "docs", "benchmark")]
    return test_formatting(dirs; kwargs...)
end

"""
    test_linting(mod; kwargs...)

Run JET static analysis (code linting) over `mod`.

An alias for [`test_jet`](@ref) under the "linting" name used by the standard
package test layout; all keyword arguments forward unchanged. Prefer running JET
in an isolated environment via `env = joinpath(@__DIR__, "jet")` to keep JET's
dependency pins from clashing with the rest of the test environment.
"""
test_linting(mod::Module; kwargs...) = test_jet(mod; kwargs...)

# --- docstring format -------------------------------------------------------

# Render one `DocStr`'s text vector to a string, keeping only the authored
# prose. A `DocStr.text` is a vector of pieces: plain interpolation splits it
# into several `AbstractString` fragments, and with `DocStringExtensions.
# @template` registered the package's `@template` directive wraps each docstring
# as `[Template{:before}, "<prose>", Template{:after}]`, so the prose is an
# interior element, not the last one. Keep the `AbstractString` / `Markdown.MD`
# pieces (joining all fragments, so an interpolated docstring is read whole) and
# drop the `Template` directives, so a templated package reads the same as a
# plain one. (Taking only `text[end]` returned the appended `Template` object or
# the final interpolation fragment, dropping the rest of the prose.)
function _docstr_text(docstr)
    text = try
        docstr.text
    catch
        return string(docstr)
    end
    pieces = String[]
    for t in text
        if t isa AbstractString || t isa Markdown.MD
            push!(pieces, string(t))
        end
    end
    # No authored prose survived the filter (e.g. a bare `@template`): fall
    # back to stringifying the whole `DocStr` rather than dropping it.
    return isempty(pieces) ? string(docstr) : join(pieces, "\n")
end

# Resolve a binding's docstring to a single string, collapsing the `MultiDoc`
# case (one entry per documented signature) into one block. Returns an empty
# string when nothing is documented, so callers test `isempty`.
function _docstring_content(mod::Module, name::Symbol)
    try
        binding = Base.Docs.Binding(mod, name)
        meta = Base.Docs.meta(mod)
        haskey(meta, binding) || return ""
        doc_obj = meta[binding]
        if doc_obj isa Base.Docs.MultiDoc
            blocks = String[]
            for (_, docstr) in doc_obj.docs
                push!(blocks, _docstr_text(docstr))
            end
            return join(blocks, "\n\n")
        else
            return _docstr_text(doc_obj)
        end
    catch
        return ""
    end
end

# True when `name` in `mod` resolves to a type rather than a function/value.
function _is_type(mod::Module, name::Symbol)
    try
        return getfield(mod, name) isa Type
    catch
        return false
    end
end

# Distinct, user-meaningful positional argument names across all methods of a
# function, plus whether any method takes keyword arguments. Internal/generated
# names (`#...`, `var"..."`, `##...`) are filtered out.
function _method_args(obj)
    args = Set{Symbol}()
    has_kwargs = false
    for m in methods(obj)
        try
            names = Base.method_argnames(m)
            for arg in (length(names) > 1 ? names[2:end] : Symbol[])
                s = string(arg)
                if arg != Symbol("#unused#") && !startswith(s, "#") &&
                   !startswith(s, "var\"") && arg != Symbol("") &&
                   !occursin("##", s) && length(s) > 1
                    push!(args, arg)
                end
            end
            m.nkw > 0 && (has_kwargs = true)
        catch
            continue
        end
    end
    return collect(args), has_kwargs
end

"""
    test_docstring_format(mod; exported_only_examples = true,
        require_field_docs = true, crossref_ignore = ())

Check the docstrings of every exported and public symbol in `mod` against the
EpiAware docstring conventions.

For each documented symbol with a meaningful docstring the checks are:

  - structs document each field name somewhere in the docstring (when
    `require_field_docs`);
  - functions with positional arguments include an `# Arguments` section, and
    functions with keyword arguments include a `# Keyword Arguments` section
    (both skipped when `require_arg_sections = false`, for a package whose API
    docs are reference-style rather than sectioned);
  - exported (and public) functions include an `@example` block (skipped when
    `exported_only_examples` is `false`, which requires examples of every
    function instead; set `require_examples = false` to drop the `@example`
    requirement entirely, e.g. for a tooling package whose helpers need external
    fixtures to exemplify);
  - the docstring carries either a `TYPEDSIGNATURES` directive or the symbol's
    own name (i.e. a signature is shown);
  - `[`name`](@ref)` cross-references resolve to another exported/public symbol;
    names in `crossref_ignore` (a tuple of `Symbol`s for upstream names a
    package legitimately links to, e.g. `:pdf`, `:cdf`) are allowed.

Symbols without a docstring are skipped here (leave existence to Aqua's
`undocumented_names` check). The cross-reference check warns rather than fails,
matching the original package-level check.
"""
function test_docstring_format(mod::Module; exported_only_examples::Bool = true,
        require_field_docs::Bool = true, require_arg_sections::Bool = true,
        require_examples::Bool = true, crossref_ignore::Tuple = ())
    syms = names(mod)
    types = [s for s in syms if _is_type(mod, s)]
    funcs = [s for s in syms if !_is_type(mod, s)]
    ignore = Set{Symbol}(crossref_ignore)
    return @testset "docstring format: $(nameof(mod))" begin
        @testset "types" begin
            for name in types
                _check_type_docstring(mod, name; require_field_docs)
            end
        end
        @testset "functions" begin
            for name in funcs
                _check_func_docstring(mod, name; exported_only_examples,
                    require_arg_sections, require_examples)
            end
        end
        @testset "cross-references" begin
            _check_crossrefs(mod, vcat(types, funcs), ignore)
        end
    end
end

# A docstring counts as "meaningful" when it is more than the bare name plus a
# little boilerplate; mirrors the original per-package heuristic.
function _meaningful(doc::AbstractString, name::Symbol)
    return !isempty(doc) && length(strip(doc)) > length(string(name)) + 10
end

function _check_type_docstring(mod, name; require_field_docs)
    @testset "$name" begin
        obj = try
            getfield(mod, name)
        catch
            @test_skip "could not resolve $name"
            return
        end
        doc = _docstring_content(mod, name)
        if !_meaningful(doc, name)
            @test_skip "$name has no meaningful docstring"
            return
        end
        if require_field_docs && isstructtype(obj)
            fields = try
                fieldnames(obj)
            catch
                Symbol[]
            end
            for f in fields
                @test occursin(string(f), doc)
            end
            isempty(fields) && @test true
        else
            @test true
        end
    end
end

function _check_func_docstring(mod, name; exported_only_examples,
        require_arg_sections, require_examples)
    @testset "$name" begin
        obj = try
            getfield(mod, name)
        catch
            @test_skip "could not resolve $name"
            return
        end
        doc = _docstring_content(mod, name)
        if !_meaningful(doc, name)
            @test_skip "$name has no meaningful docstring"
            return
        end
        args, has_kwargs = _method_args(obj)
        if require_arg_sections
            !isempty(args) && @test occursin("# Arguments", doc)
            has_kwargs && @test occursin("# Keyword Arguments", doc)
        end
        if require_examples && (!exported_only_examples || name in names(mod))
            @test occursin("@example", doc)
        end
        @test occursin("TYPEDSIGNATURES", doc) || occursin(string(name), doc)
    end
end

function _check_crossrefs(mod, allnames, ignore)
    nameset = Set{Symbol}(allnames)
    for name in allnames
        doc = _docstring_content(mod, name)
        _meaningful(doc, name) || continue
        for m in eachmatch(r"`([^`]+)`\]\(@ref\)", doc)
            ref = Symbol(m.captures[1])
            if ref ∉ nameset && ref ∉ ignore
                @warn "$name references unknown $ref in an @ref cross-reference"
            end
        end
    end
    # The cross-reference check is advisory (warnings), so it always passes.
    @test true
end

# --- extension ambiguities --------------------------------------------------

# True when method `m` is defined in a module whose name starts with one of the
# allowed surface prefixes (the package, its extensions, or a named trigger).
function _on_surface(m, prefixes)
    mn = string(m.module)
    return any(p -> startswith(mn, p), prefixes)
end

"""
    raw_ambiguity_count(mod, extname)

Total (unfiltered) method-ambiguity count over `(mod, ext)`, where `ext` is the
loaded extension named `extname`. Useful as a sanity check that third-party
phantom ambiguities are present before [`test_ext_ambiguities`](@ref) filters
them out (so the on-surface filter is doing real work, not trivially empty).
"""
function raw_ambiguity_count(mod::Module, extname::Symbol)
    ext = Base.get_extension(mod, extname)
    ext === nothing && error("extension $extname is not loaded")
    return length(detect_ambiguities(mod, ext; recursive = false))
end

"""
    on_surface_ambiguities(mod, extname; prefixes = (string(nameof(mod)),))

The ambiguous method pairs over `(mod, ext)` that `mod` or its extension owns:
both methods live in a module whose name starts with one of `prefixes`. This
drops pairs owned by an unrelated third party (e.g. a `::Num` overload from a
Symbolics integration that collides with every concrete `f(::Dist, ::Real)`),
keeping only ambiguities the package or its extension actually introduces.

`prefixes` defaults to the package name (which also covers its extensions, since
extension modules are named `<Package>...Ext`); pass extra prefixes for trigger
packages whose methods participate in a legitimate pair (e.g.
`("MyPkg", "Distributions")`).
"""
function on_surface_ambiguities(mod::Module, extname::Symbol;
        prefixes = (string(nameof(mod)),))
    ext = Base.get_extension(mod, extname)
    ext === nothing && error("extension $extname is not loaded")
    pre = collect(String, prefixes)
    amb = detect_ambiguities(mod, ext; recursive = false)
    return filter(
        p -> _on_surface(p[1], pre) && _on_surface(p[2], pre), amb)
end

"""
    test_ext_ambiguities(mod, extname; prefixes = (string(nameof(mod)),),
        expect_phantoms = false, broken = false)

Assert the loaded extension `extname` of `mod` introduces no method ambiguity on
the package's own surface.

`Aqua.test_ambiguities` runs in a subprocess with no extensions loaded, so it
never sees an extension's method table; this check loads in-process and filters
to ambiguities `mod` or its extension owns (see
[`on_surface_ambiguities`](@ref)). The caller is responsible for `import`-ing
the extension's trigger package(s) before calling so the extension is loaded.

  - `prefixes` is the set of allowed surface module-name prefixes (see
    [`on_surface_ambiguities`](@ref)).
  - `expect_phantoms = true` additionally asserts the raw count is positive,
    proving third-party phantom pairs exist and the on-surface filter is doing
    real work (use for an extension pulling in e.g. a Symbolics integration).
  - `broken = true` records the no-ambiguity assertion as `@test_broken`, for
    quarantining a known, issue-tracked extension-only ambiguity without
    silencing it; the test flips green when the bug is fixed.
"""
function test_ext_ambiguities(mod::Module, extname::Symbol;
        prefixes = (string(nameof(mod)),), expect_phantoms::Bool = false,
        broken::Bool = false)
    return @testset "ext ambiguities: $extname" begin
        expect_phantoms && @test raw_ambiguity_count(mod, extname) > 0
        amb = on_surface_ambiguities(mod, extname; prefixes = prefixes)
        if broken
            @test_broken isempty(amb)
        else
            @test isempty(amb)
        end
    end
end
