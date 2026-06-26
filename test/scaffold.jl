# Scaffolding into a fresh temp package writes every managed standard file plus
# the package-owned skeletons; `update` re-applies only the managed files and is
# idempotent, never touching package-owned files.

using EpiAwareTestUtils: SCAFFOLD_TEMPLATES

# Build a minimal package root with a Project.toml so `{{PACKAGE}}` substitution
# has a name to resolve.
function _fake_pkg(dir; name = "FakePkg")
    write(joinpath(dir, "Project.toml"),
        "name = \"$name\"\nuuid = \"00000000-0000-0000-0000-000000000000\"\n")
    return dir
end

# The managed / package-owned destination paths, derived from the manifest so
# the test tracks the real set.
const MANAGED_DESTS = [t.dest for t in SCAFFOLD_TEMPLATES if t.managed]
const OWNED_DESTS = [t.dest for t in SCAFFOLD_TEMPLATES if !t.managed]

@testset "scaffold + update" begin
    @testset "scaffold writes managed + owned" begin
        mktempdir() do dir
            _fake_pkg(dir)
            res = scaffold(dir)
            # Everything is newly created; nothing updated or preserved.
            @test length(res.created) == length(SCAFFOLD_TEMPLATES)
            @test isempty(res.updated)
            @test isempty(res.preserved)
            for t in SCAFFOLD_TEMPLATES
                @test isfile(joinpath(dir, t.dest))
            end
        end
    end

    @testset "managed CI callers + test infra present" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            # A representative slice of the managed infra.
            for f in (".github/workflows/test.yaml",
                ".github/workflows/document.yaml",
                ".github/dependabot.yml",
                "test/package/quality.jl",
                "test/jet/runtests.jl",
                "test/formatter/runtests.jl",
                "test/ad/setup.jl",
                "test/ad/runtests.jl",
                "benchmark/run.jl",
                "benchmark/compare.jl")
                @test isfile(joinpath(dir, f))
            end
            # CI callers invoke the org reusables.
            test_yaml = read(joinpath(dir, ".github/workflows/test.yaml"),
                String)
            @test occursin("EpiAware/.github/.github/workflows/tests.yml",
                test_yaml)
            @test occursin("downgrade.yml", test_yaml)
        end
    end

    @testset "package-owned skeletons present" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            for f in ("test/runtests.jl", "test/package/qa_config.jl",
                "test/ad/scenarios.jl", "benchmark/benchmarks.jl")
                @test isfile(joinpath(dir, f))
            end
        end
    end

    @testset "{{PACKAGE}} substitution" begin
        mktempdir() do dir
            _fake_pkg(dir; name = "Wombat")
            scaffold(dir)
            cfg = read(joinpath(dir, "test/package/qa_config.jl"), String)
            @test occursin("using Wombat", cfg)
            @test !occursin("{{PACKAGE}}", cfg)
            jet = read(joinpath(dir, "test/jet/runtests.jl"), String)
            @test occursin("JET.test_package(Wombat", jet)
        end
    end

    @testset "update re-applies only managed files, idempotently" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)

            # Mutate a package-owned file and a managed file to simulate drift.
            owned = joinpath(dir, "test/package/qa_config.jl")
            managed = joinpath(dir, "test/package/quality.jl")
            owned_marker = "# PACKAGE EDIT — keep me\n"
            write(owned, owned_marker * read(owned, String))
            write(managed, "# drifted\n")

            res = update(dir)
            # Only managed files are touched; all of them already existed, so
            # they are `updated`, none `created`, none `preserved`.
            @test isempty(res.created)
            @test Set(res.updated) ==
                  Set(joinpath(dir, d) for d in MANAGED_DESTS)
            @test isempty(res.preserved)

            # The managed file's drift was overwritten back to the template.
            @test occursin("Quality: Aqua", read(managed, String))
            # The package-owned file's edit was preserved (update skips it).
            @test occursin(owned_marker, read(owned, String))
            # No package-owned file appears in the update manifest at all.
            for d in OWNED_DESTS
                @test joinpath(dir, d) ∉ res.updated
            end

            # Idempotent: a second update produces no content change.
            before = Dict(f => read(joinpath(dir, f), String)
            for f in MANAGED_DESTS)
            update(dir)
            for (f, c) in before
                @test read(joinpath(dir, f), String) == c
            end
        end
    end

    @testset "scaffold preserves owned, rewrites managed on re-run" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            res = scaffold(dir)   # second adopt, no force
            @test isempty(res.created)
            @test Set(res.updated) ==
                  Set(joinpath(dir, d) for d in MANAGED_DESTS)
            @test Set(res.preserved) ==
                  Set(joinpath(dir, d) for d in OWNED_DESTS)
        end
    end

    @testset "force overwrites owned too" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            res = scaffold(dir; force = true)
            @test isempty(res.created)
            @test isempty(res.preserved)
            @test length(res.updated) == length(SCAFFOLD_TEMPLATES)
        end
    end

    @testset "errors on missing target" begin
        @test_throws ErrorException scaffold(
            joinpath(tempdir(), "no-such-scaffold-target-xyz"))
    end

    @testset "errors when substitution needs a name but none given" begin
        mktempdir() do dir
            # No Project.toml, so `{{PACKAGE}}` cannot be resolved.
            @test_throws ErrorException scaffold(dir)
        end
    end
end
