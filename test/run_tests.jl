# Regression tests for `run_package_tests` (kit #191): the scaffolded main test
# entry must root discovery at the package's own `test/` tree so a nested
# worktree checked out under the repo root cannot inject test items or shadow a
# same-named `@testsnippet`, and must still detect `package_name` from the
# package root so an item's default `using <Package>` import keeps working.
#
# Each scenario runs in a fresh subprocess (a real test process, exit code =
# pass/fail) rather than in-process, since `run_package_tests` drives its own
# `DefaultTestSet`s that would otherwise fold into this suite.

@testitem "run_package_tests: nested worktree cannot shadow a @testsnippet (#191)" begin
    using Test

    # Lay down a package with its own `test/` copy of a `@testsnippet` and a
    # stale copy under a nested `worktrees/wt-*` checkout, plus an item that
    # asserts it saw the current snippet, not the stale one.
    function _build_probe(dir; current = "CURRENT", stale = "STALE")
        write(joinpath(dir, "Project.toml"),
            """
            name = "ShadowProbe191"
            uuid = "b1b1b1b1-0191-4191-8191-b1b1b1b1b1b1"
            version = "0.1.0"
            """)
        mkpath(joinpath(dir, "test", "sub"))
        mkpath(joinpath(dir, "worktrees", "wt-old", "test", "sub"))
        write(joinpath(dir, "test", "sub", "setup.jl"),
            "@testsnippet Helper begin\n    const MARK = \"$current\"\nend\n")
        write(joinpath(dir, "test", "sub", "item.jl"),
            """
            @testitem "reads snippet" setup=[Helper] default_imports=false begin
                using Test
                @test MARK == "$current"
            end
            """)
        # Stale worktree copy: same snippet name, different value.
        write(joinpath(dir, "worktrees", "wt-old", "test", "sub", "setup.jl"),
            "@testsnippet Helper begin\n    const MARK = \"$stale\"\nend\n")
        write(joinpath(dir, "worktrees", "wt-old", "test", "sub", "item.jl"),
            """
            @testitem "reads snippet" setup=[Helper] default_imports=false begin
                using Test
                @test MARK == "$stale"
            end
            """)
        return joinpath(dir, "test")
    end

    proj = dirname(Base.active_project())

    # Run a one-line driver in a subprocess against the current test env (which
    # carries EpiAwarePackageTools + TestItemRunner). Returns `true` on success.
    # Output is silenced (two scenarios fail on purpose): only the exit code,
    # which reflects whether the driver's test items all passed, is asserted.
    function _run_driver(dir, body)
        drv = joinpath(dir, "drive.jl")
        write(drv, body)
        cmd = `$(Base.julia_cmd()) --project=$proj --startup-file=no $drv`
        p = run(pipeline(ignorestatus(cmd); stdout = devnull, stderr = devnull))
        return success(p)
    end

    @testset "scoped runner ignores the worktree copy" begin
        mktempdir() do dir
            testdir = _build_probe(dir)
            ok = _run_driver(dir,
                """
                using EpiAwarePackageTools: run_package_tests
                run_package_tests(raw"$testdir")
                """)
            @test ok  # current snippet won -> the item passed
        end
    end

    @testset "whole-root scan (old behaviour) is shadowed by the worktree" begin
        mktempdir() do dir
            testdir = _build_probe(dir)
            root = dirname(testdir)
            sep = Base.Filesystem.path_separator
            # Reproduce the pre-fix `@run_package_tests` on the package root with
            # the item-level `in_this_package` path filter: items are scoped, but
            # the snippet is silently taken from the stale worktree copy.
            failed = !_run_driver(dir,
                """
                using TestItemRunner
                TEST_ROOT = raw"$testdir" * raw"$sep"
                TestItemRunner.run_tests(raw"$root";
                    filter = ti -> startswith(normpath(ti.filename), TEST_ROOT))
                """)
            @test failed  # proves the probe genuinely reproduces #191
        end
    end

    @testset "package_name is read from the package root" begin
        # An item with the default `using <Package>` import; the package is not
        # installed, so a correct root-derived `package_name` makes the item
        # error with "ShadowProbe191 not found". If the name were lost (read from
        # the unnamed test env instead), no import runs and the item passes.
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"),
                """
                name = "ShadowProbe191"
                uuid = "b1b1b1b1-0191-4191-8191-b1b1b1b1b1b1"
                version = "0.1.0"
                """)
            mkpath(joinpath(dir, "test"))
            write(joinpath(dir, "test", "item.jl"),
                """
                @testitem "default import" begin
                    @test true
                end
                """)
            testdir = joinpath(dir, "test")
            imported = !_run_driver(dir,
                """
                using EpiAwarePackageTools: run_package_tests
                run_package_tests(raw"$testdir")
                """)
            @test imported  # `using ShadowProbe191` was attempted and failed
        end
    end
end
