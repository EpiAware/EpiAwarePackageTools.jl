# Exercise the `[sources]` registry bootstrap (#216).
#
# AirspeedVelocity's `benchpkg` installs the benchmarked package into its own
# temp project, where a *dependency's* `[sources]` section is ignored, so a
# dependency pinned by git url/rev because it is not yet registered fails to
# resolve ("has no known versions!"). The bootstrap registers each such pin
# into a throwaway registry in the runner's depot, which every environment on
# that runner (including benchpkg's temp projects) can resolve by name.
#
# The tests cover the parser, the no-op guard (a package with no unregistered
# pins must do no registry work at all), and one end-to-end registration
# against a local git repo, kept offline by using `file://` paths throughout.

@testitem "Benchmarks [sources] parsing" begin
    using Test
    using EpiAwarePackageTools.Benchmarks: git_sources, unregistered_sources

    function write_project(content)
        dir = mktempdir()
        write(joinpath(dir, "Project.toml"), content)
        return dir
    end

    @testset "no [sources] section" begin
        dir = write_project("""
        name = "NoSources"
        uuid = "1e0d3f8c-9e1e-4a1a-8f8e-8a0a0a0a0a01"
        version = "0.1.0"
        """)
        @test isempty(git_sources(dir))
        @test isempty(unregistered_sources(dir))
    end

    @testset "git-pinned sources are parsed" begin
        dir = write_project("""
        name = "HasSources"
        uuid = "1e0d3f8c-9e1e-4a1a-8f8e-8a0a0a0a0a02"
        version = "0.1.0"

        [sources]
        Zed = {url = "https://example.invalid/Zed.jl", rev = "v1.2.3"}
        Alpha = {url = "https://example.invalid/Alpha.jl", rev = "main"}
        """)
        srcs = git_sources(dir)
        @test length(srcs) == 2
        # Sorted by name so the bootstrap registers deterministically.
        @test [s.name for s in srcs] == ["Alpha", "Zed"]
        @test srcs[2].url == "https://example.invalid/Zed.jl"
        @test srcs[2].rev == "v1.2.3"
    end

    @testset "a url source with no rev is kept with an empty rev" begin
        dir = write_project("""
        name = "NoRev"
        uuid = "1e0d3f8c-9e1e-4a1a-8f8e-8a0a0a0a0a03"
        version = "0.1.0"

        [sources]
        Alpha = {url = "https://example.invalid/Alpha.jl"}
        """)
        srcs = git_sources(dir)
        @test length(srcs) == 1
        @test srcs[1].rev == ""
    end

    @testset "path-only sources are ignored" begin
        # A path source needs no registration: it either resolves relative to
        # the environment or is staged into place (the ADFixtures trick, #125).
        dir = write_project("""
        name = "PathSources"
        uuid = "1e0d3f8c-9e1e-4a1a-8f8e-8a0a0a0a0a04"
        version = "0.1.0"

        [sources]
        Fixtures = {path = "test/ADFixtures"}
        """)
        @test isempty(git_sources(dir))
        @test isempty(unregistered_sources(dir))
    end

    @testset "a Project.toml path is accepted directly" begin
        dir = write_project("""
        name = "Direct"
        uuid = "1e0d3f8c-9e1e-4a1a-8f8e-8a0a0a0a0a05"
        version = "0.1.0"

        [sources]
        Alpha = {url = "https://example.invalid/Alpha.jl", rev = "main"}
        """)
        @test length(git_sources(joinpath(dir, "Project.toml"))) == 1
    end

    @testset "a missing Project.toml yields no sources" begin
        @test isempty(git_sources(mktempdir()))
    end

    @testset "registered names are dropped, unregistered kept" begin
        # JSON3 is in General (reachable in any environment that runs this
        # suite), so it needs no scratch registration; the invented name is
        # in no registry and must be kept.
        dir = write_project("""
        name = "Mixed"
        uuid = "1e0d3f8c-9e1e-4a1a-8f8e-8a0a0a0a0a06"
        version = "0.1.0"

        [sources]
        JSON3 = {url = "https://github.com/quinnj/JSON3.jl", rev = "main"}
        NotInAnyRegistry216 = {url = "https://example.invalid/N.jl", rev = "m"}
        """)
        @test length(git_sources(dir)) == 2
        names = [s.name for s in unregistered_sources(dir)]
        @test names == ["NotInAnyRegistry216"]
    end
end

@testitem "Benchmarks bootstrap_sources_registry no-op guard" begin
    using Test
    using EpiAwarePackageTools.Benchmarks: bootstrap_sources_registry

    # A package with no unregistered git `[sources]` must do no registry work
    # at all: nothing is created in the depot and nothing is returned. This is
    # what makes the workflow step safe for every existing package.
    @testset "no [sources] at all" begin
        dir = mktempdir()
        write(joinpath(dir, "Project.toml"), """
        name = "Plain"
        uuid = "1e0d3f8c-9e1e-4a1a-8f8e-8a0a0a0a0a07"
        version = "0.1.0"
        """)
        depot = mktempdir()
        @test bootstrap_sources_registry(dir; depot = depot) == String[]
        @test !isdir(joinpath(depot, "registries"))
    end

    @testset "only path and registered sources" begin
        dir = mktempdir()
        write(joinpath(dir, "Project.toml"), """
        name = "PlainToo"
        uuid = "1e0d3f8c-9e1e-4a1a-8f8e-8a0a0a0a0a08"
        version = "0.1.0"

        [sources]
        Fixtures = {path = "test/ADFixtures"}
        JSON3 = {url = "https://github.com/quinnj/JSON3.jl", rev = "main"}
        """)
        depot = mktempdir()
        @test bootstrap_sources_registry(dir; depot = depot) == String[]
        @test !isdir(joinpath(depot, "registries"))
    end
end

@testitem "Benchmarks bootstrap_sources_registry registers a git pin" begin
    using Test
    using EpiAwarePackageTools.Benchmarks: bootstrap_sources_registry
    import Pkg

    # End-to-end, offline: a throwaway git repo holds a dummy package, a
    # synthetic consumer pins it by url/rev in `[sources]`, and the bootstrap
    # must register it into a scratch registry inside a temp depot such that a
    # fresh environment on that depot resolves it BY NAME (which is what
    # benchpkg's temp project does). Everything is local, so no network.
    #
    # The temp dirs are kept (`cleanup = false`): they hold live git repos (the
    # dummy package, the scratch registry, the clone) and Windows refuses to
    # unlink a file another handle still holds, so at-exit cleanup would raise
    # an EBUSY error out of a passing test. The runner's temp dir is thrown
    # away with the runner anyway.
    root = mktempdir(; cleanup = false)
    pkg = joinpath(root, "DummyDep216.jl")
    mkpath(joinpath(pkg, "src"))
    write(joinpath(pkg, "Project.toml"), """
    name = "DummyDep216"
    uuid = "1e0d3f8c-9e1e-4a1a-8f8e-8a0a0a0a0a09"
    version = "0.1.0"
    """)
    write(joinpath(pkg, "src", "DummyDep216.jl"),
        "module DummyDep216\nanswer() = 42\nend\n")
    run(`git -C $pkg init --quiet -b main`)
    run(`git -C $pkg add -A`)
    git = `git -C $pkg -c user.name=t -c user.email=t@t.invalid`
    run(`$git commit --quiet -m init`)
    rev = strip(read(`git -C $pkg rev-parse HEAD`, String))

    # A Windows temp path is full of backslashes, and `\U`, `\A`, `\D` are not
    # valid TOML string escapes, so a raw path in the fixture's `[sources]`
    # fails to parse before any of the code under test runs. Forward slashes
    # are accepted by TOML, git and Pkg on every platform.
    url = replace(pkg, '\\' => '/')
    consumer = mktempdir(; cleanup = false)
    write(joinpath(consumer, "Project.toml"), """
    name = "Consumer216"
    uuid = "1e0d3f8c-9e1e-4a1a-8f8e-8a0a0a0a0a10"
    version = "0.1.0"

    [deps]
    DummyDep216 = "1e0d3f8c-9e1e-4a1a-8f8e-8a0a0a0a0a09"

    [sources]
    DummyDep216 = {url = "$url", rev = "$rev"}
    """)

    depot = mktempdir(; cleanup = false)
    work_dir = mktempdir(; cleanup = false)
    registered = bootstrap_sources_registry(
        consumer; depot = depot, work_dir = work_dir)
    @test registered == ["DummyDep216"]

    regdir = joinpath(depot, "registries", "EpiAwareScratch")
    @test isfile(joinpath(regdir, "Registry.toml"))
    reg = Pkg.TOML.parsefile(joinpath(regdir, "Registry.toml"))
    @test any(p -> p["name"] == "DummyDep216", values(reg["packages"]))
    entry = joinpath(regdir, "D", "DummyDep216")
    @test isfile(joinpath(entry, "Package.toml"))
    versions = Pkg.TOML.parsefile(joinpath(entry, "Versions.toml"))
    @test haskey(versions, "0.1.0")

    # A second call is idempotent: the registry already carries the version,
    # so it is left as it is rather than erroring on re-registration. It clones
    # afresh, so it gets its own work dir (as the default does).
    again = bootstrap_sources_registry(consumer; depot = depot,
        work_dir = mktempdir(; cleanup = false))
    @test again == ["DummyDep216"]

    # The payoff: a fresh environment on that depot resolves the dep BY NAME,
    # with no `[sources]` pin in sight — exactly what benchpkg's temp project
    # needs. Run in a subprocess whose *first* depot is the temp one, so
    # everything Pkg writes (the install, the manifest) lands there and this
    # depot is only read: its precompile caches are reused, which keeps the
    # subprocess to a few seconds rather than recompiling Pkg from scratch.
    script = """
    using Pkg
    Pkg.activate(; temp = true)
    Pkg.add("DummyDep216")
    using DummyDep216
    DummyDep216.answer() == 42 || error("wrong answer")
    print("resolved")
    """
    depots = join([depot; DEPOT_PATH], Sys.iswindows() ? ';' : ':')
    out = withenv("JULIA_DEPOT_PATH" => depots, "JULIA_LOAD_PATH" => nothing,
        "JULIA_PROJECT" => nothing) do
        read(`$(Base.julia_cmd()) --startup-file=no -e $script`, String)
    end
    @test occursin("resolved", out)
end
