# Regression tests for the managed `JuliaTestItems.toml` (kit #191).
#
# TestItemRunner walks the whole package root, and `@testsnippet`s register
# globally by name with last-write-wins, so a nested worktree checked out under
# the root (the EpiAware `worktrees/wt-*` convention) puts a stale copy of a
# snippet after the real one and silently shadows it. An item-level `filter`
# cannot close this: it runs after discovery and never sees snippets.
#
# The managed config scopes discovery to the package's own `test/` tree, which
# closes it for `Pkg.test` and for the VS Code extension at the same time,
# since both read this file.
#
# Each scenario runs in a fresh subprocess (a real test process, exit code =
# pass/fail) rather than in-process, since the driver runs its own test sets
# that would otherwise fold into this suite.

@testitem "JuliaTestItems.toml: a nested worktree cannot shadow a @testsnippet (#191)" begin
    using Test
    using EpiAwarePackageTools: _templates_dir

    # Lay down a package with its own `test/` copy of a `@testsnippet` and a
    # stale copy under a nested `worktrees/wt-*` checkout, plus an item that
    # asserts it saw the current snippet, not the stale one.
    function _build_probe(dir; current = "CURRENT", stale = "STALE")
        write(
            joinpath(dir, "Project.toml"),
            """
            name = "ShadowProbe191"
            uuid = "b1b1b1b1-0191-4191-8191-b1b1b1b1b1b1"
            version = "0.1.0"
            """
        )
        mkpath(joinpath(dir, "test", "sub"))
        mkpath(joinpath(dir, "worktrees", "wt-old", "test", "sub"))
        write(
            joinpath(dir, "test", "sub", "setup.jl"),
            "@testsnippet Helper begin\n    const MARK = \"$current\"\nend\n"
        )
        write(
            joinpath(dir, "test", "sub", "item.jl"),
            """
            @testitem "reads snippet" setup=[Helper] default_imports=false begin
                using Test
                @test MARK == "$current"
            end
            """
        )
        # Stale worktree copy: same snippet name, different value, plus an item
        # that must never run.
        write(
            joinpath(dir, "worktrees", "wt-old", "test", "sub", "setup.jl"),
            "@testsnippet Helper begin\n    const MARK = \"$stale\"\nend\n"
        )
        write(
            joinpath(dir, "worktrees", "wt-old", "test", "sub", "item.jl"),
            """
            @testitem "worktree item must not run" default_imports=false begin
                using Test
                @test false
            end
            """
        )
        return dir
    end

    _install_config(dir) = cp(
        joinpath(_templates_dir(), "JuliaTestItems.toml"),
        joinpath(dir, "JuliaTestItems.toml")
    )

    proj = dirname(Base.active_project())

    # Run a driver in a subprocess against the current test env (which carries
    # TestItemRunner). Returns `true` on success. Output is silenced (one
    # scenario fails on purpose): only the exit code, which reflects whether
    # the driver's test items all passed, is asserted.
    function _run_driver(dir, body)
        drv = joinpath(dir, "drive.jl")
        write(drv, body)
        cmd = `$(Base.julia_cmd()) --project=$proj --startup-file=no $drv`
        p = run(pipeline(ignorestatus(cmd); stdout = devnull, stderr = devnull))
        return success(p)
    end

    _drive(root) = """
    using TestItemRunner
    TestItemRunner.run_tests(raw"$root")
    """

    @testset "the config keeps the worktree copy out of discovery" begin
        mktempdir() do dir
            _build_probe(dir)
            _install_config(dir)
            # A real checkout under `worktrees/` carries its own copy of the
            # managed config. Scope is the intersection over every enclosing
            # config, so this one cannot widen the root's.
            cp(
                joinpath(dir, "JuliaTestItems.toml"),
                joinpath(dir, "worktrees", "wt-old", "JuliaTestItems.toml")
            )
            @test _run_driver(dir, _drive(dir))
        end
    end

    @testset "without the config the worktree copy wins" begin
        mktempdir() do dir
            _build_probe(dir)
            # No config: proves the probe genuinely reproduces #191 rather than
            # passing for some unrelated reason.
            @test !_run_driver(dir, _drive(dir))
        end
    end

    @testset "the package's own default imports still resolve" begin
        # An item with the default `using <Package>` import. The package is not
        # installed, so a correctly root-derived package name makes the item
        # error with "ShadowProbe191 not found". Pointing the runner at the
        # root (rather than at `test/`, whose project carries no `name`) is
        # what keeps that name available.
        mktempdir() do dir
            _build_probe(dir)
            _install_config(dir)
            write(
                joinpath(dir, "test", "sub", "item.jl"),
                """
                @testitem "default import" begin
                    @test true
                end
                """
            )
            rm(joinpath(dir, "test", "sub", "setup.jl"))
            imported = !_run_driver(dir, _drive(dir))
            @test imported  # `using ShadowProbe191` was attempted and failed
        end
    end
end

@testitem "JuliaTestItems.toml is scaffolded and managed" tags = [:scaffold] begin
    using Test
    using EpiAwarePackageTools: scaffold, update

    mktempdir() do dir
        write(
            joinpath(dir, "Project.toml"),
            """
            name = "Wombat"
            uuid = "c2c2c2c2-0191-4191-8191-c2c2c2c2c2c2"
            version = "0.1.0"
            """
        )
        mkpath(joinpath(dir, "src"))
        write(joinpath(dir, "src", "Wombat.jl"), "module Wombat\nend\n")

        scaffold(dir)
        cfg = joinpath(dir, "JuliaTestItems.toml")
        @test isfile(cfg)

        body = read(cfg, String)
        @test occursin("config-version = 1", body)
        # Anchored, so `worktrees/<name>/test/...` does not match it.
        @test occursin("include = [\"/test/**\"]", body)
        @test occursin("MANAGED by EpiAwarePackageTools.scaffold", body)

        # Managed, so a hand edit is restored rather than preserved.
        write(cfg, "config-version = 1\n")
        update(dir)
        @test occursin("include = [\"/test/**\"]", read(cfg, String))
    end
end

@testitem "run_package_tests still runs a pre-config package's suite" begin
    using Test
    using EpiAwarePackageTools: _templates_dir

    # `test/runtests.jl` is package-owned, so a package that adopted the kit
    # before the managed config still calls `run_package_tests` after it syncs.
    # The shim has to keep that suite running, and stay scoped by the config
    # the same sync writes.
    function _probe(dir; with_config)
        write(
            joinpath(dir, "Project.toml"),
            """
            name = "ShimProbe"
            uuid = "d3d3d3d3-0191-4191-8191-d3d3d3d3d3d3"
            version = "0.1.0"
            """
        )
        mkpath(joinpath(dir, "test", "sub"))
        mkpath(joinpath(dir, "worktrees", "wt-old", "test", "sub"))
        write(
            joinpath(dir, "test", "sub", "setup.jl"),
            "@testsnippet Helper begin\n    const MARK = \"CURRENT\"\nend\n"
        )
        write(
            joinpath(dir, "test", "sub", "item.jl"),
            """
            @testitem "reads snippet" setup=[Helper] default_imports=false begin
                using Test
                @test MARK == "CURRENT"
            end
            """
        )
        write(
            joinpath(dir, "worktrees", "wt-old", "test", "sub", "setup.jl"),
            "@testsnippet Helper begin\n    const MARK = \"STALE\"\nend\n"
        )
        with_config && cp(
            joinpath(_templates_dir(), "JuliaTestItems.toml"),
            joinpath(dir, "JuliaTestItems.toml")
        )
        return joinpath(dir, "test")
    end

    proj = dirname(Base.active_project())
    function _run_driver(dir, testdir)
        drv = joinpath(dir, "drive.jl")
        write(
            drv,
            """
            using EpiAwarePackageTools: run_package_tests
            run_package_tests(raw"$testdir")
            """
        )
        cmd = `$(Base.julia_cmd()) --project=$proj --startup-file=no $drv`
        p = run(pipeline(ignorestatus(cmd); stdout = devnull, stderr = devnull))
        return success(p)
    end

    @testset "the old entry point keeps working, scoped by the config" begin
        mktempdir() do dir
            testdir = _probe(dir; with_config = true)
            @test _run_driver(dir, testdir)
        end
    end

    @testset "without the config the shim cannot scope discovery" begin
        mktempdir() do dir
            testdir = _probe(dir; with_config = false)
            # Proves the shim's scoping comes from the config rather than from
            # anything it does itself, which is why it warns when it is absent.
            @test !_run_driver(dir, testdir)
        end
    end
end
