# Compatibility shim for the scaffolded `test/runtests.jl` of packages that
# adopted the kit before the managed `JuliaTestItems.toml`.
#
# `run_package_tests` used to be a transcription of `TestItemRunner.run_tests`
# that reached into that package's internals to root discovery at `test/`
# (#191). TestItemRunner 1.3 does that declaratively instead: the managed
# `JuliaTestItems.toml` at the package root scopes discovery to `test/**`, and
# the VS Code extension reads the same file, so editor and `Pkg.test` agree.
#
# `test/runtests.jl` is package-owned — `update` writes it once and never
# overwrites it — so an adopting package still calls this function after it
# syncs. It now just forwards to TestItemRunner's public entry point, rooted at
# the package root so the config file and the default `using <Package>` import
# both resolve. Removing it would break every existing adopter's suite.
#
# TestItemRunner is a test-environment dep of adopting packages, not a hard dep
# of the kit, so it is loaded lazily and the call goes through
# `Base.invokelatest` (see `_require_pkg`).

const _TESTITEMRUNNER_UUID = "f8b46487-2199-4994-9208-9a1283c18c0a"

"""
    run_package_tests(testdir = pwd(); filter = nothing, verbose = false)

Run the `@testitem`s of the package whose `test/` tree is `testdir`.

!!! warning "Deprecated"
    Call TestItemRunner's `@run_package_tests` directly instead. Discovery is
    scoped by the managed `JuliaTestItems.toml` at the package root, so this
    function no longer does anything `@run_package_tests` does not:

    ```julia
    using TestItemRunner
    @run_package_tests filter = ti -> !(:ad in ti.tags)
    ```

    Kept so a package scaffolded before that config file keeps working after a
    sync, since `test/runtests.jl` is package-owned and never rewritten.
"""
function run_package_tests(
        testdir::AbstractString = pwd(); filter = nothing,
        verbose::Bool = false
    )
    testdir = abspath(testdir)
    root = dirname(testdir)

    if !isfile(joinpath(root, "JuliaTestItems.toml"))
        @warn(
            "No JuliaTestItems.toml at $(root), so test discovery is not " *
                "scoped to test/ and a nested worktree can shadow a " *
                "@testsnippet. Run EpiAwarePackageTools.update to write it.",
            maxlog = 1
        )
    end
    Base.depwarn(
        "run_package_tests is deprecated; call TestItemRunner's " *
            "@run_package_tests instead. Discovery is scoped by the managed " *
            "JuliaTestItems.toml at the package root.",
        :run_package_tests
    )

    TIR = _require_pkg(_TESTITEMRUNNER_UUID, "TestItemRunner")
    return Base.invokelatest(
        TIR.run_tests, root; filter = filter, verbose = verbose
    )
end
