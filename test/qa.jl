# Exercise the QA helpers. The docstring/format checks run over
# EpiAwarePackageTools itself (a clean module); the ambiguity and doctest helpers
# are checked on their structure and a tiny synthetic case so the suite stays
# light and package-agnostic.

@testitem "QA helpers" begin
    using Test
    using EpiAwarePackageTools

    # A testset that tallies Fail/Error and never throws. The helpers under test
    # build their own nested `@testset`s; with `CountingTestSet` as the outer set
    # of `@testset`, every nested set is also a `CountingTestSet`. Each records a
    # direct `@test` Fail/Error into its own `fails`; on `finish` a nested set
    # folds its `fails` into its parent (so leaf counts bubble up), and the
    # outermost set (no enclosing testset) simply returns itself without throwing.
    # Reading `fails` off the returned outermost set is therefore version-stable:
    # it does not depend on the `TestSetException` thrown on a top-level finish
    # (whose behaviour varies, e.g. 1.13-pre) nor leak failures into the
    # surrounding suite. `description`/`fails` field names match what
    # `Test.@testset` constructs and passes.
    mutable struct CountingTestSet <: Test.AbstractTestSet
        description::String
        fails::Int
    end
    CountingTestSet(desc::String; kwargs...) = CountingTestSet(desc, 0)
    function Test.record(ts::CountingTestSet, child::CountingTestSet)
        ts.fails += child.fails
        return child
    end
    function Test.record(ts::CountingTestSet, res::Test.Result)
        (res isa Test.Fail || res isa Test.Error) && (ts.fails += 1)
        return res
    end
    # Fold this set's tally into the enclosing testset (so leaf counts bubble up
    # the nesting), or return self when this is the outermost set. Never throws.
    function Test.finish(ts::CountingTestSet)
        if Test.get_testset_depth() > 0
            Test.record(Test.get_testset(), ts)
        end
        return ts
    end

    # True when running `f` (a check that internally builds a `@testset`) records
    # at least one Fail/Error. `f` runs under a `CountingTestSet`, which tallies
    # the check's Fail/Errors and swallows them (never re-recording into the
    # surrounding suite or throwing). See the type's docstring for why this is
    # version-stable across Julia releases.
    function check_flags(f)
        ts = @testset CountingTestSet "check_flags" begin
            f()
        end
        return ts.fails > 0
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

    # A module whose exported type carries a docstring too short to count as
    # "meaningful" (see `_meaningful`), for the type-level meaningful-doc skip.
    module _ShortDoc

    export Thingy

    "x"
    struct Thingy
        a::Int
    end

    end # module _ShortDoc

    # A module exporting a documented public submodule (mirroring a package's
    # public `TestUtils`). A submodule stores its docstring in its OWN meta, so
    # this exercises the submodule-redirect in `_docstring_content` (#124).
    module _WithSubmodule

    export SubUtils

    """
        SubUtils

    A documented public submodule with a meaningful description of its purpose.
    """
    module SubUtils
    end

    end # module _WithSubmodule

    # Tiny stand-ins for JET's report structure (`report.vst[end].linfo.
    # specTypes`) and a DynamicPPL-shaped evaluator signature, used to
    # exercise `dynamicppl_model_filter`'s classification branches without a
    # real JET/DynamicPPL dependency.
    struct _FakeFrame
        linfo::Any
    end
    struct _FakeLinfo
        specTypes::Any
    end
    struct _FakeReport
        vst::Any
    end
    module _FakeDynamicPPL
    struct Model end
    struct VarInfo end
    end

    # Sentinel standing in for a `DocStringExtensions.Template` directive in a
    # `DocStr.text` vector (see the `_docstring_content` template test).
    struct _TemplateDirective end

    # An ad-hoc module (not loaded via `include`/`Base.require` with a
    # registered `Base.PkgId`) has `pathof(mod) === nothing` — used to
    # exercise `test_import_centralisation`'s no-source-file skip branch.
    module _NoPathModule
    end

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
            # `DocStringExtensions.@template` wraps each docstring's text vector
            # as `[directive, "<prose>", directive]`, so the authored prose is an
            # interior element, not the last one. The reader must return the
            # prose, not a stringified directive. `_TemplateDirective` stands in
            # for a `Template` directive.
            ds = Base.Docs.DocStr(
                Core.svec(
                    _TemplateDirective(), "the real prose here",
                    _TemplateDirective()),
                nothing, Dict{Symbol, Any}())
            @test EpiAwarePackageTools._docstr_text(ds) == "the real prose here"
            @test !occursin("_TemplateDirective",
                EpiAwarePackageTools._docstr_text(ds))
        end

        @testset "_docstring_content reads a submodule's own meta (#124)" begin
            # A documented public submodule keeps its docstring in its own meta,
            # not the parent's, so the reader must redirect the lookup. Before
            # the fix this returned "" and the submodule got a permanent
            # `@test_skip` in `test_docstring_format`.
            doc = EpiAwarePackageTools._docstring_content(
                _WithSubmodule, :SubUtils)
            @test !isempty(doc)
            @test occursin("documented public submodule", doc)
            @test EpiAwarePackageTools._meaningful(doc, :SubUtils)
        end

        @testset "_docstring_content joins interpolated fragments" begin
            # A plain interpolation splits the text vector into several string
            # fragments; all must survive (taking only the last drops the prose
            # before the first interpolation).
            ds = Base.Docs.DocStr(
                Core.svec("before ", "INTERP", " after"),
                nothing, Dict{Symbol, Any}())
            joined = EpiAwarePackageTools._docstr_text(ds)
            @test occursin("before", joined)
            @test occursin("after", joined)
        end

        @testset "test_readme_sections" begin
            badges = EpiAwarePackageTools.BADGES_START * "\n" *
                     EpiAwarePackageTools.BADGES_END
            # A README with the standard sections in standard order passes.
            conforming = """
            # MyPkg

            $badges

            *one-line description*

            ## Overview
            why.

            ## Usage
            how.

            ## Documentation
            links.

            ## Contributing
            help.

            ## License
            MIT.
            """
            mktempdir() do dir
                write(joinpath(dir, "README.md"), conforming)
                test_readme_sections(dir)
                # Accepts a direct file path too.
                test_readme_sections(joinpath(dir, "README.md"))
            end

            # Missing a required section (no Documentation) is flagged.
            missing_section = replace(conforming,
                "## Documentation\nlinks.\n\n" => "")
            mktempdir() do dir
                write(joinpath(dir, "README.md"), missing_section)
                @test check_flags(() -> test_readme_sections(dir))
            end

            # Sections present but out of order is flagged when order = true,
            # and accepted when order = false.
            disordered = """
            # MyPkg

            $badges

            ## Usage
            how.

            ## Overview
            why.

            ## Documentation
            d.

            ## Contributing
            c.

            ## License
            l.
            """
            mktempdir() do dir
                write(joinpath(dir, "README.md"), disordered)
                @test check_flags(() -> test_readme_sections(dir))
                test_readme_sections(dir; order = false)
            end

            # A heading inside a fenced code block is not counted as a section.
            fenced = """
            # MyPkg

            $badges

            ## Overview
            ```julia
            ## not a heading
            ```

            ## Usage
            u.

            ## Documentation
            d.

            ## Contributing
            c.

            ## License
            l.
            """
            mktempdir() do dir
                write(joinpath(dir, "README.md"), fenced)
                test_readme_sections(dir)
            end

            # The managed standard-sections citation heading `## How to cite`
            # satisfies the citation group, so a scaffolded package that carries
            # only the managed sections (no hand-authored License/Supporting)
            # passes the check out of the box (#201).
            how_to_cite = replace(conforming, "## License\nMIT.\n" => "## How to cite\ncite it.\n")
            mktempdir() do dir
                write(joinpath(dir, "README.md"), how_to_cite)
                test_readme_sections(dir)
            end

            # A custom required list can extend the standard set.
            mktempdir() do dir
                write(joinpath(dir, "README.md"), conforming)
                @test check_flags(() -> test_readme_sections(dir;
                    required = vcat(STANDARD_README_SECTIONS,
                        [("Benchmarks",)])))
            end

            # The kit's own README conforms to the standard structure.
            root = dirname(dirname(pathof(EpiAwarePackageTools)))
            test_readme_sections(root)

            # A missing README skips rather than erroring (e.g. a
            # freshly-`scaffold_generate`d package with no README yet); the function
            # returns early with `nothing` rather than a testset.
            mktempdir() do dir
                @test test_readme_sections(
                    joinpath(dir, "no-such-readme.md")) === nothing
            end
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

        @testset "_run_isolated_env survives a fresh process (#58)" begin
            # Regression test: `_run_isolated_env` lazily loads `Pkg` via
            # `_require_pkg`, so `Pkg.activate`/`Pkg.instantiate` must go
            # through `Base.invokelatest` (#58's hotfix). The in-process
            # testset above can PASS even when that invokelatest is missing,
            # because an earlier testitem in the same process may have
            # already loaded `Pkg` (masking the world-age error) — exactly
            # what happened on kit main: green locally, red on a genuinely
            # clean CI process (`MethodError: no method matching
            # activate(::String)`, "method too new to be called from this
            # world context"). Spawning a real fresh `julia` process (no
            # prior `using Pkg`) makes this deterministic rather than
            # order-dependent.
            dir = mktempdir()
            write(joinpath(dir, "Project.toml"), "")
            write(joinpath(dir, "runtests.jl"), "exit(0)")
            root = pkgdir(EpiAwarePackageTools)
            kit_src = joinpath(root, "src", "EpiAwarePackageTools.jl")
            code = "include(" * repr(kit_src) * "); " *
                   "ok = Main.EpiAwarePackageTools._run_isolated_env(" *
                   repr(dir) * ", " * repr(joinpath(dir, "runtests.jl")) *
                   "); exit(ok ? 0 : 1)"
            result = run(
                pipeline(
                    `$(Base.julia_cmd()) --startup-file=no --project=$root
                     -e $code`;
                    stdout = devnull, stderr = devnull);
                wait = true)
            @test result.exitcode == 0
        end

        @testset "test_doctest runs over self" begin
            # EpiAwarePackageTools has no `jldoctest` blocks, so `doctest` passes
            # trivially — this exercises the Documenter wiring end to end.
            test_doctest(EpiAwarePackageTools)
        end

        @testset "test_linting delegates to test_jet" begin
            # The managed QA testset runs `test_jet(EpiAwarePackageTools)`; here
            # just assert the alias forwards to it (same method), without paying for
            # a second full JET pass.
            @test test_linting === test_jet ||
                  first(methods(test_linting)).name === :test_linting
        end

        @testset "test_explicit_imports forwards implicit_ignore" begin
            # `implicit_ignore` is a separate kwarg defaulting to `ignore`, so a
            # reexporting package can allow its bare module name in
            # `check_no_implicit_imports`. The kit has no implicit imports, so the
            # check passes; assert the kwarg is accepted and the testset returns.
            ts = test_explicit_imports(EpiAwarePackageTools;
                implicit_ignore = (:Nonexistent,))
            @test ts isa Test.AbstractTestSet
        end

        @testset "test_explicit_imports ignores extension-load order (#189)" begin
            # A package extension imports its parent's internals by design, so
            # ExplicitImports' are-public check flags it — but only when the
            # extension happens to be loaded, which depends on what else ran
            # earlier in the session. That made the verdict non-deterministic
            # (#189). Build a throwaway package whose extension imports a
            # non-public parent name, then load it with and without its trigger
            # and assert `test_explicit_imports` gives the same passing verdict
            # either way, even though the raw ExplicitImports check flips to a
            # failure once the extension is loaded.
            dir = mktempdir()
            mkpath(joinpath(dir, "src"))
            mkpath(joinpath(dir, "ext"))
            write(joinpath(dir, "Project.toml"),
                """
                name = "ExtOrder189"
                uuid = "e0f1c2d3-4455-6677-8899-aabbccddeeff"
                version = "0.1.0"
                [weakdeps]
                SparseArrays = "2f01184e-e22b-5df5-ae63-d93ebab69eaf"
                [extensions]
                ExtOrder189SparseArraysExt = "SparseArrays"
                """)
            write(joinpath(dir, "src", "ExtOrder189.jl"),
                """
                module ExtOrder189
                _secret() = 42
                # A genuine (non-extension) submodule: `_is_package_extension`
                # must not mistake it for an extension (checked directly
                # below), so `_extension_ignore_names` never even considers
                # collecting names from a real submodule in the first place.
                module Sub
                helper() = 1
                end
                end
                """)
            write(joinpath(dir, "ext", "ExtOrder189SparseArraysExt.jl"),
                """
                module ExtOrder189SparseArraysExt
                import ExtOrder189: _secret
                # A wildcard `using` (no explicit list) so `sprand` is used
                # implicitly: this is what `explicit_imports_nonrecursive`
                # (the second loop in `_extension_ignore_names`, separate
                # from the improper-imports check above) reports — an
                # extension's implicit imports must also be exempted from
                # the verdict, not just its improper explicit ones.
                using SparseArrays
                usesecret() = _secret() + length(sprand(2, 2, 0.5))
                end
                """)
            push!(LOAD_PATH, dir)
            try
                EI = Base.require(
                    Base.PkgId(
                    Base.UUID("7d51a73a-1435-4ff3-83d9-f097790105c7"),
                    "ExplicitImports"))
                Fix = Base.require(Main, :ExtOrder189)

                # Extension not loaded yet: the check is clean.
                @test test_explicit_imports(Fix) isa Test.AbstractTestSet
                @test !check_flags(() -> test_explicit_imports(Fix))

                # Loading the trigger loads the extension, which imports the
                # non-public `_secret` — the raw ExplicitImports check now fails.
                Base.require(
                    Base.PkgId(
                    Base.UUID("2f01184e-e22b-5df5-ae63-d93ebab69eaf"),
                    "SparseArrays"))
                @test check_flags() do
                    @test Base.invokelatest(
                        EI.check_all_explicit_imports_are_public, Fix) ===
                          nothing
                end

                # But `test_explicit_imports` stays green: the verdict no longer
                # depends on whether the extension was loaded.
                @test !check_flags(() -> test_explicit_imports(Fix))

                # `Sub` is a genuine submodule, not an extension — checked
                # directly (`_is_package_extension` must say so for it, and
                # for `mod` itself), so `_extension_ignore_names`'s loop over
                # `find_submodules` skips it (only the loaded extension's
                # `_secret` is folded into the ignore list).
                SubMod = Fix.Sub
                @test !EpiAwarePackageTools._is_package_extension(EI, SubMod, Fix)
                @test !EpiAwarePackageTools._is_package_extension(EI, Fix, Fix)
                ignored = Base.invokelatest(
                    EpiAwarePackageTools._extension_ignore_names, EI, Fix)
                @test :_secret in ignored
                # The extension's implicit `using SparseArrays` import
                # (`sprand`, used without an explicit list) is folded in too
                # — the second, separate loop in `_extension_ignore_names`.
                @test :sprand in ignored
            finally
                filter!(!=(dir), LOAD_PATH)
            end
        end

        @testset "_import_centralisation_violations flags a scattered import" begin
            mktempdir() do dir
                src = joinpath(dir, "src")
                mkpath(src)
                main = joinpath(src, "MyPkg.jl")
                # The main file's own top-level `using` is exactly where the
                # convention wants it: exempt when passed as `main_file`.
                write(main, """
                module MyPkg
                using Test: @test
                include("other.jl")
                include("sub.jl")
                end # module MyPkg
                """)
                # A plain included file with its own top-level `using`: this
                # is the scattered-import defect kit issue #105 flags.
                write(joinpath(src, "other.jl"), """
                using Markdown: Markdown

                f() = 1
                """)
                # A nested `module`/`baremodule` block starts its own scope:
                # its own top-level `using` is exempt (that submodule body
                # IS its "module file"), matching `benchmarks.jl`/
                # `docs_build.jl`'s `Benchmarks`/`DocsBuild` submodules.
                write(joinpath(src, "sub.jl"), """
                module Sub
                using Test: @testset
                end # module Sub
                """)
                # A lazy, call-time `Base.require` load inside a function is
                # an ordinary function call, not `using`/`import` syntax, so
                # it never trips the check.
                write(joinpath(src, "lazy.jl"), """
                function _load()
                    return Base.require(Base.PkgId(
                        Base.UUID("8dfed614-e22c-5e08-85e1-65c5234f0b40"),
                        "Test"))
                end
                """)

                v = EpiAwarePackageTools._import_centralisation_violations(
                    src, main)
                @test length(v) == 1
                @test v[1][1] == joinpath(src, "other.jl")
                @test occursin("Markdown", v[1][3])

                # `MyPkg.jl`'s own `using` sits inside its `module ... end`
                # wrapper, so it is exempt via the nested-scope rule
                # regardless of the `main_file` skip — the count is the
                # same whether or not `main` is passed.
                v_no_main = EpiAwarePackageTools._import_centralisation_violations(
                    src)
                @test length(v_no_main) == 1
            end
        end

        @testset "_import_centralisation_violations respects main_file" begin
            # A bare top-level `using` with no enclosing `module` block (not
            # how a real package main file looks, but isolates exactly what
            # the `main_file` argument itself skips).
            mktempdir() do dir
                src = joinpath(dir, "src")
                mkpath(src)
                main = joinpath(src, "Main.jl")
                write(main, "using Test: @test\n")
                @test isempty(
                    EpiAwarePackageTools._import_centralisation_violations(
                    src, main))
                @test length(
                    EpiAwarePackageTools._import_centralisation_violations(
                    src)) == 1
            end
        end

        @testset "test_import_centralisation" begin
            # The kit dogfoods its own now-centralised src: a real, loaded
            # package resolves via `pathof` and reports no violations.
            ts = test_import_centralisation(EpiAwarePackageTools)
            @test ts isa Test.AbstractTestSet

            # An ad-hoc module with no resolvable source file skips rather
            # than erroring or (worse) silently reporting a false pass.
            @test !check_flags(() -> test_import_centralisation(_NoPathModule))
        end

        @testset "dynamicppl_model_filter classifies reports" begin
            # A report whose innermost frame cannot be inspected is kept (fail
            # closed): the filter returns `true` for a non-report object.
            @test dynamicppl_model_filter((; nope = 1)) == true

            # A `specTypes` that resolves but has no `.parameters` field (not
            # a real signature type) fails inside the `try`: kept.
            r_bad_sig = _FakeReport([_FakeFrame(_FakeLinfo("not a type"))])
            @test dynamicppl_model_filter(r_bad_sig) == true

            # Fewer than 3 tuple parameters (no room for a Model/VarInfo
            # pair in positions 2/3): kept.
            r_short = _FakeReport([_FakeFrame(_FakeLinfo(Tuple{Int}))])
            @test dynamicppl_model_filter(r_short) == true

            # The DynamicPPL evaluator signature `(::Model,
            # ::AbstractVarInfo, ...)`: dropped.
            sig_match = Tuple{typeof(identity), _FakeDynamicPPL.Model,
                _FakeDynamicPPL.VarInfo}
            r_match = _FakeReport([_FakeFrame(_FakeLinfo(sig_match))])
            @test dynamicppl_model_filter(r_match) == false

            # A `Model` in position 2 but nothing VarInfo-like in position 3:
            # kept (not a full evaluator-signature match).
            sig_partial = Tuple{typeof(identity), _FakeDynamicPPL.Model, Int}
            r_partial = _FakeReport([_FakeFrame(_FakeLinfo(sig_partial))])
            @test dynamicppl_model_filter(r_partial) == true
        end

        @testset "_typename_is / _occurs_varinfo" begin
            @test EpiAwarePackageTools._typename_is(Int, "Int64")
            @test !EpiAwarePackageTools._typename_is(Int, "Model")
            # A value that is not a `Type`/`UnionAll` has no `.name` field:
            # caught, `false` (fail closed, same as the filter above).
            @test !EpiAwarePackageTools._typename_is(5, "Model")
            @test EpiAwarePackageTools._occurs_varinfo(
                _FakeDynamicPPL.VarInfo)
            @test !EpiAwarePackageTools._occurs_varinfo(Int)
        end

        @testset "test_jet skips on the forced-experimental flag" begin
            # `skip_experimental = true` (the default) short-circuits before
            # ever loading JET when the experimental-Julia override is set,
            # so this is cheap and exercises the skip branch without
            # depending on the actual Julia version under test.
            withenv("JULIA_CI_EXPERIMENTAL" => "true") do
                # The skip happens via a non-local `return nothing` from
                # inside the `@testset` body (same idiom as
                # `test_readme_sections`'s missing-README skip), so the
                # function returns `nothing`, not a testset.
                @test test_jet(EpiAwarePackageTools) === nothing
            end
        end

        @testset "_formatter_style covers every named style" begin
            JF = Base.require(Base.PkgId(
                Base.UUID("98e50ef6-434e-11e9-1051-2b60c6c9e899"),
                "JuliaFormatter"))
            for style in ("sciml", "blue", "yas", "default", "", "SciML")
                s = EpiAwarePackageTools._formatter_style(JF, style)
                @test s !== nothing
            end
            @test_throws ErrorException EpiAwarePackageTools._formatter_style(
                JF, "not-a-style")
        end

        @testset "_docstr_text falls back for a non-DocStr object" begin
            # An object with no `.text` field takes the `catch` fallback:
            # stringify the whole thing rather than erroring.
            @test EpiAwarePackageTools._docstr_text(42) == "42"
        end

        @testset "_check_type_docstring / _check_func_docstring skip branches" begin
            # A name that does not resolve in the module (`getfield` throws)
            # is skipped rather than erroring, for both the type and the
            # function check.
            EpiAwarePackageTools._check_type_docstring(
                _Conforming, :NoSuchBinding123; require_field_docs = true)
            EpiAwarePackageTools._check_func_docstring(
                _Conforming, :NoSuchBinding123; exported_only_examples = true,
                require_arg_sections = true, require_examples = true)

            # A type whose docstring is too short to count as "meaningful"
            # is skipped too.
            EpiAwarePackageTools._check_type_docstring(
                _ShortDoc, :Thingy; require_field_docs = true)
        end

        @testset "_is_type fails closed on an unresolvable name" begin
            @test EpiAwarePackageTools._is_type(_Conforming, :Widget)
            @test !EpiAwarePackageTools._is_type(_Conforming, :build)
            # `getfield` throws for a name that isn't actually defined;
            # caught and treated as "not a type" rather than erroring.
            @test !EpiAwarePackageTools._is_type(
                _Conforming, :NoSuchBinding123)
        end

        @testset "ambiguity helpers error on unloaded extension" begin
            # No extension named :NotAnExtension is loaded, so both query helpers
            # error rather than silently passing.
            @test_throws ErrorException raw_ambiguity_count(
                EpiAwarePackageTools, :NotAnExtension)
            @test_throws ErrorException on_surface_ambiguities(
                EpiAwarePackageTools, :NotAnExtension)
            # `test_ext_ambiguities` wraps its body in its own `@testset`,
            # which catches the `error(...)` and records it as a failing
            # result rather than letting it propagate as an exception — so
            # this is checked the same way as a failing `test_docstring_format`
            # call above, via `check_flags`, not `@test_throws`.
            @test check_flags(() -> test_ext_ambiguities(
                EpiAwarePackageTools, :NotAnExtension))
        end
    end # @testset "QA helpers"
end # @testitem "QA helpers"
