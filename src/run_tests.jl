# Managed test-entry runner for the scaffolded `test/runtests.jl`.
#
# TestItemRunner's `@run_package_tests` walks the whole *package root* to
# collect `@testitem`s and `@testsnippet`s, then runs the items its `filter`
# keeps. Two properties of that walk bite a package whose worktrees live under
# its own root (the EpiAware `worktrees/wt-*` convention):
#
#   * the `filter` only selects test *items* — `@testsnippet`s are registered
#     globally by name with last-write-wins, and the walk order puts a nested
#     `worktrees/…` copy after the real `test/` one, so a stale worktree's copy
#     of a same-named snippet silently shadows the package's own (kit #191);
#   * even the item-level `in_this_package` path filter cannot help, because it
#     runs *after* discovery and never sees snippets.
#
# `run_package_tests` closes both holes by rooting the scan at the package's own
# `test/` tree, so a sibling `worktrees/…` checkout is never walked and cannot
# contribute items or snippets. It is otherwise a faithful transcription of
# `TestItemRunner.run_tests` (v1.1.x), with exactly two deviations from the
# upstream body:
#
#   1. the walk is rooted at `testdir` rather than the package root, and
#   2. `package_name` (which drives each item's default `using <Package>`) is
#      read from the *package root* `Project.toml` — the parent of `testdir` —
#      since `testdir` itself carries the unnamed test-environment project.
#
# TestItemRunner is loaded lazily (it is a test-environment dep of adopting
# packages, not a hard dep of the kit), so every call into it goes through
# `Base.invokelatest` — see `_require_pkg`.

const _TESTITEMRUNNER_UUID = "f8b46487-2199-4994-9208-9a1283c18c0a"

"""
    run_package_tests(testdir = pwd(); filter = nothing, verbose = false)

Discover and run the `@testitem`s under `testdir` (a package's `test/` tree),
scoped so a nested worktree checked out under the package root cannot inject or
shadow items or `@testsnippet`s (kit #191).

Drop-in replacement for `TestItemRunner.@run_package_tests` in a scaffolded
`test/runtests.jl`: call it with `@__DIR__` and the same `filter` predicate.
`filter` receives a `(; filename, name, tags)` named tuple per item and keeps
those for which it returns `true`; `verbose` forwards to the test sets. The
default `using <Package>` import in each item still works — the package name is
taken from the package-root `Project.toml`, the parent of `testdir`.
"""
function run_package_tests(testdir::AbstractString = pwd(); filter = nothing,
        verbose::Bool = false)
    TIR = _require_pkg(_TESTITEMRUNNER_UUID, "TestItemRunner")
    JS = TIR.JuliaSyntax
    TID = TIR.TestItemDetection

    testdir = abspath(testdir)

    # Deviation (2): package_name comes from the package root, not `testdir`
    # (the test env's project has no `name`), so the default `using <Package>`
    # import keeps working under the scoped scan.
    root = dirname(testdir)
    package_name = something(
        _project_string(joinpath(root, "Project.toml"), "name"),
        _project_string(joinpath(root, "JuliaProject.toml"), "name"),
        "")

    # Deviation (1): walk only `testdir`, so a sibling `worktrees/…` checkout
    # under the package root is never scanned.
    julia_files = String[]
    for (dir, _, files) in walkdir(testdir)
        for file in files
            _, ext = splitext(file)
            if isvalid(ext) && lowercase(ext) == ".jl"
                push!(julia_files, normpath(joinpath(dir, file)))
            end
        end
    end

    testitems = Dict{String, Vector}()
    testsetups = Dict{Symbol, Any}()
    for file in julia_files
        content = read(file, String)
        stream = Base.invokelatest(JS.ParseStream, content; version = VERSION)
        Base.invokelatest(JS.parse!, stream; rule = :all)
        tree = Base.invokelatest(JS.build_tree, JS.SyntaxNode, stream)

        items = []
        setups = []
        errors = []
        Base.invokelatest(TID.find_test_detail!, tree, items, setups, errors)
        if !isempty(errors)
            @warn "Error in your test item or test setup definition" file errors
            error("There is an error in a test item or test setup definition.")
        end

        if !isempty(items)
            testitems[file] = [(filename = file, code = content[i.code_range],
                                   name = i.name, option_tags = i.option_tags,
                                   option_default_imports = i.option_default_imports,
                                   option_setup = i.option_setup,
                                   Base.invokelatest(TIR.compute_line_column,
                                       content, i.code_range.start)...)
                               for i in items]
        end
        for i in setups
            testsetups[i.name] = (filename = file, code = content[i.code_range],
                name = Symbol(i.name), kind = i.kind,
                Base.invokelatest(TIR.compute_line_column, content,
                    i.code_range.start)...)
        end
    end

    if filter !== nothing
        for file in keys(testitems)
            testitems[file] = Base.filter(
                i -> filter((filename = file, name = i.name,
                    tags = i.option_tags)), testitems[file])
            isempty(testitems[file]) && pop!(testitems, file)
        end
    end

    setup_module = Core.eval(Main, :(module $(gensym()) end))
    setup_set = Base.invokelatest(TIR.TestSetupModuleSet, setup_module,
        Set{Symbol}())

    _testset(args...; kw...) = Base.invokelatest(TIR.testset, args...; kw...)
    _run(args...) = Base.invokelatest(TIR.run_testitem, args...)

    function _eval_module_setups(file, item)
        for setup in item.option_setup
            haskey(testsetups, setup) ||
                error("Test setup $(setup) is not defined.")
            s = testsetups[setup]
            s.kind == :module && Base.invokelatest(TIR.ensure_evaled, setup_set,
                s.filename, s.code, s.name, s.line, s.column, dirname(file))
        end
    end

    @static if VERSION ≤ v"1.13-"
        Test.push_testset(_testset("Package"; verbose))
        try
            for (file, items) in pairs(testitems)
                Test.push_testset(_testset(relpath(file, testdir); verbose))
                try
                    for item in items
                        _eval_module_setups(file, item)
                        Test.push_testset(_testset(item.name; verbose))
                        ts = Test.get_testset()
                        try
                            _run(item.filename, item.option_default_imports,
                                item.option_setup, package_name, item.code,
                                item.line, item.column, setup_set, testsetups)
                        catch err
                            err isa InterruptException && rethrow()
                            Test.record(ts,
                                Test.Error(:nontest_error,
                                    Expr(:tuple), err, Base.current_exceptions(),
                                    LineNumberNode(item.line, Symbol(item.filename))))
                        finally
                            Test.finish(Test.pop_testset())
                        end
                    end
                finally
                    Test.finish(Test.pop_testset())
                end
            end
        finally
            Base.invokelatest(Test.finish, Test.pop_testset())
        end
    else
        outer = _testset("Package"; verbose)
        Test.@with_testset outer begin
            for (file, items) in pairs(testitems)
                perfile = _testset(relpath(file, testdir); verbose)
                Test.@with_testset perfile begin
                    for item in items
                        _eval_module_setups(file, item)
                        inner = _testset(item.name; verbose)
                        Test.@with_testset inner begin
                            try
                                _run(item.filename, item.option_default_imports,
                                    item.option_setup, package_name, item.code,
                                    item.line, item.column, setup_set, testsetups)
                            catch err
                                err isa InterruptException && rethrow()
                                Test.record(inner,
                                    Test.Error(:nontest_error,
                                        Expr(:tuple), err, Base.current_exceptions(),
                                        LineNumberNode(item.line,
                                            Symbol(item.filename))))
                            end
                        end
                        Test.finish(inner)
                    end
                end
                Test.finish(perfile)
            end
        end
        Base.invokelatest(Test.finish, outer)
    end
end
