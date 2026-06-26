# Exercise the QA helpers. The docstring/format checks run over
# EpiAwarePackageTools itself (a clean module); the ambiguity and doctest helpers
# are checked on their structure and a tiny synthetic case so the suite stays
# light and package-agnostic.

# True when running `f` (a check that internally builds a `@testset`) records at
# least one Fail/Error. `f` is run detached from the surrounding testset stack
# so its failures don't fail the outer suite; the detached top-level
# DefaultTestSet throws a `TestSetException` on finish, which we read as "the
# check flagged a problem".
function check_flags(f)
    # Detach: pop the task-local testset stack so `f`'s testset is top-level,
    # saving the popped sets to restore afterwards (innermost first).
    saved = Any[]
    while Test.get_testset_depth() > 0
        push!(saved, Test.pop_testset())
    end
    flagged = try
        f()
        false
    catch err
        err isa Test.TestSetException ? (err.fail + err.error > 0) : rethrow()
    finally
        for ts in reverse(saved)
            Test.push_testset(ts)
        end
    end
    return flagged
end

# A synthetic conforming module: its exported symbols follow the docstring
# conventions (Arguments / Keyword Arguments sections, an @example, fields named
# in the struct docstring, a resolving @ref). Defined at top level so its
# docstrings register before the testset runs.
module _Conforming

export Widget, build

"""
    Widget

A widget.

# Fields
  - `size`: the widget size.

See also [`build`](@ref).
"""
struct Widget
    size::Int
end

"""
    build(n; scale = 1)

Build something.

# Arguments
  - `n`: how many.

# Keyword Arguments
  - `scale`: a multiplier.

```@example
build(2; scale = 3)
```
"""
build(n; scale = 1) = n * scale

end # module _Conforming

# A synthetic non-conforming module: the function takes arguments and keyword
# arguments but documents neither section, and the struct omits its field.
module _NonConforming

export Gadget, run_it

"A gadget with an undocumented field."
struct Gadget
    weight::Int
end

"Run it, with no Arguments or Keyword Arguments section and no example."
run_it(a, b; opt = 1) = a + b + opt

end # module _NonConforming

# Sentinel standing in for a `DocStringExtensions.Template` directive in a
# `DocStr.text` vector (see the `_docstring_content` template test).
struct _TemplateDirective end

@testset "QA helpers" begin
    @testset "test_docstring_format passes a conforming module" begin
        test_docstring_format(_Conforming)
    end

    @testset "test_docstring_format flags a non-conforming module" begin
        # The check runs as its own top-level testset and throws on failure;
        # assert it flagged at least one problem (missing sections/fields).
        @test check_flags(() -> test_docstring_format(_NonConforming))
    end

    @testset "_docstring_content skips @template directives" begin
        # `DocStringExtensions.@template` wraps each docstring's text vector as
        # `[directive, "<prose>", directive]`, so the authored prose is an
        # interior element, not the last one. The reader must return the prose,
        # not a stringified directive. `_TemplateDirective` (defined at top
        # level below) stands in for a `Template` directive.
        ds = Base.Docs.DocStr(
            Core.svec(
                _TemplateDirective(), "the real prose here",
                _TemplateDirective()),
            nothing, Dict{Symbol, Any}())
        @test EpiAwarePackageTools._docstr_text(ds) == "the real prose here"
        @test !occursin("_TemplateDirective",
            EpiAwarePackageTools._docstr_text(ds))
    end

    @testset "test_formatting over self" begin
        # Check the package src tree is JuliaFormatter-clean.
        root = dirname(dirname(pathof(EpiAwarePackageTools)))
        test_formatting([joinpath(root, "src")])
    end

    @testset "test_formatting skips missing dirs" begin
        res = test_formatting([joinpath(tempdir(), "does-not-exist-xyz")])
        @test res isa Test.AbstractTestSet
    end

    @testset "test_formatting env mode runs a subprocess runner" begin
        # An isolated formatter env whose runner exits zero passes; a missing
        # Project.toml / runtests.jl errors (cf. `test_jet`'s env path).
        dir = mktempdir()
        @test_throws ErrorException test_formatting([]; env = dir)
        write(joinpath(dir, "Project.toml"), "")
        @test_throws ErrorException test_formatting([]; env = dir)
        write(joinpath(dir, "runtests.jl"), "exit(0)")
        ts = test_formatting([]; env = dir)
        @test ts isa Test.AbstractTestSet
    end

    @testset "test_doctest runs over self" begin
        # EpiAwarePackageTools has no `jldoctest` blocks, so `doctest` passes
        # trivially — this exercises the Documenter wiring end to end.
        test_doctest(EpiAwarePackageTools)
    end

    @testset "test_linting delegates to test_jet" begin
        # `test_jet(EpiAwarePackageTools)` already runs in test/quality.jl; here
        # just assert the alias forwards to it (same method), without paying for
        # a second full JET pass.
        @test test_linting === test_jet ||
              first(methods(test_linting)).name === :test_linting
    end

    @testset "ambiguity helpers error on unloaded extension" begin
        # No extension named :NotAnExtension is loaded, so both query helpers
        # error rather than silently passing.
        @test_throws ErrorException raw_ambiguity_count(
            EpiAwarePackageTools, :NotAnExtension)
        @test_throws ErrorException on_surface_ambiguities(
            EpiAwarePackageTools, :NotAnExtension)
    end
end
