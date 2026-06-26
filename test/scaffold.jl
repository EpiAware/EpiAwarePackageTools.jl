# Scaffolding into a fresh temp package writes every managed standard file plus
# the package-owned skeletons; `update` re-applies only the managed files and is
# idempotent, never touching package-owned files.

using EpiAwarePackageTools: SCAFFOLD_TEMPLATES, _templates_dir, scaffold_inputs
using Dates: year, now

# Build a minimal package root with a Project.toml so placeholder substitution
# (name, authors) has values to resolve.
function _fake_pkg(dir; name = "FakePkg",
        authors = "[\"Ada Lovelace\", \"FakeOrg contributors\"]")
    write(joinpath(dir, "Project.toml"),
        "name = \"$name\"\n" *
        "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
        "authors = $authors\n")
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
            # CI callers invoke the org reusables; `{{ORG}}` defaults to
            # EpiAware (no Project.toml org field), so the slug is filled.
            test_yaml = read(joinpath(dir, ".github/workflows/test.yaml"),
                String)
            @test occursin("EpiAware/.github/.github/workflows/tests.yml",
                test_yaml)
            @test occursin("downgrade.yml", test_yaml)
            @test !occursin("{{ORG}}", test_yaml)
        end
    end

    @testset "P0 runnability files present" begin
        mktempdir() do dir
            _fake_pkg(dir; name = "Wombat")
            scaffold(dir)
            # The pre-commit baseline, codecov flags, ad CI caller, and the
            # isolated-env manifests the managed runners need.
            for f in (".secrets.baseline", "codecov.yml",
                ".github/workflows/ad.yaml",
                "test/Project.toml", "test/jet/Project.toml",
                "test/formatter/Project.toml", "test/ad/Project.toml",
                "test/ADFixtures/Project.toml",
                "test/ADFixtures/src/ADFixtures.jl")
                @test isfile(joinpath(dir, f))
            end
            # codecov has the unit + ad-* flags; ad caller invokes the reusable.
            cov = read(joinpath(dir, "codecov.yml"), String)
            @test occursin("ad-forwarddiff", cov)
            @test occursin("carryforward", cov)
            adyaml = read(joinpath(dir, ".github/workflows/ad.yaml"), String)
            @test occursin("EpiAware/.github/.github/workflows/ad.yml", adyaml)

            # The seeded ADFixtures registry and the AD env agree on its UUID.
            reg = read(joinpath(dir, "test/ADFixtures/Project.toml"), String)
            adenv = read(joinpath(dir, "test/ad/Project.toml"), String)
            m = match(r"uuid = \"([^\"]+)\"", reg)
            @test m !== nothing
            @test occursin("ADFixtures = \"$(m.captures[1])\"", adenv)
            @test !occursin("{{ADFIXTURES_UUID}}", reg)
            # The jet env references the package by name + UUID.
            jetenv = read(joinpath(dir, "test/jet/Project.toml"), String)
            @test occursin("Wombat = \"00000000-0000-0000-0000-000000000000\"",
                jetenv)
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

    @testset "author/holder/org/repo/reviewer placeholders" begin
        mktempdir() do dir
            _fake_pkg(dir; name = "Wombat",
                authors = "[\"Ada Lovelace <ada@x.org>\", \"Wombat team\"]")
            scaffold(dir)

            # LICENSE holder defaults to the joined Project.toml authors
            # (emails stripped), with the current year.
            lic = read(joinpath(dir, "LICENSE"), String)
            @test occursin("Ada Lovelace, Wombat team", lic)
            @test occursin(string(year(now())), lic)
            @test !occursin("{{HOLDER}}", lic)
            @test !occursin("{{YEAR}}", lic)

            # Dependabot reviewer defaults to the org (no person hardcoded).
            dep = read(joinpath(dir, ".github/dependabot.yml"), String)
            @test occursin("- \"EpiAware\"", dep)
            @test !occursin("{{REVIEWER}}", dep)
            @test !occursin("seabbs", dep)
        end
    end

    @testset "input overrides win over Project.toml + defaults" begin
        mktempdir() do dir
            _fake_pkg(dir; name = "Wombat")
            scaffold(dir; org = "MyOrg", holder = "The Holder",
                reviewer = "octocat")
            lic = read(joinpath(dir, "LICENSE"), String)
            @test occursin("The Holder", lic)
            test_yaml = read(joinpath(dir, ".github/workflows/test.yaml"),
                String)
            @test occursin("MyOrg/.github/.github/workflows/tests.yml",
                test_yaml)
            dep = read(joinpath(dir, ".github/dependabot.yml"), String)
            @test occursin("- \"octocat\"", dep)
        end
    end

    @testset "scaffold_inputs derives repo + defaults" begin
        mktempdir() do dir
            _fake_pkg(dir; name = "Wombat")
            inp = scaffold_inputs(dir)
            @test inp.PACKAGE == "Wombat"
            @test inp.ORG == "EpiAware"
            @test inp.REPO == "EpiAware/Wombat.jl"
            @test inp.REVIEWER == "EpiAware"   # never a hardcoded person
            inp2 = scaffold_inputs(dir; org = "Acme", reviewer = "")
            @test inp2.REPO == "Acme/Wombat.jl"
            @test inp2.REVIEWER == ""
        end
    end

    @testset "no managed template hardcodes a person or owner" begin
        # The templates are the source of truth; none may carry a literal
        # person/owner name. (The kit's own name `EpiAwarePackageTools` and the
        # `EpiAware` org appear only via the `{{ORG}}`/`using EpiAwarePackageTools`
        # references, which are checked separately.)
        forbidden = ("seabbs", "Sam Abbott")
        tdir = _templates_dir()
        for (root, _, files) in walkdir(tdir), f in files

            path = joinpath(root, f)
            content = read(path, String)
            for bad in forbidden
                @test !occursin(bad, content)
            end
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
