# Scaffolding into a fresh temp package writes every managed standard file plus
# the package-owned skeletons; `update` re-applies only the managed files and is
# idempotent, never touching package-owned files.

@testitem "scaffold + update (logic)" begin
    using Test
    using EpiAwarePackageTools
    using EpiAwarePackageTools: SCAFFOLD_TEMPLATES, _templates_dir,
                                scaffold_inputs, _ad_selected
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

    # The templates emitted for a given `ad` value (an AD/no-AD variant pair writes
    # to the same `dest`, so only one of the pair fires). Default scaffold/update use
    # `ad = true`.
    _selected(ad) = [t for t in SCAFFOLD_TEMPLATES if _ad_selected(t, ad)]

    # The managed / package-owned destination paths, derived from the manifest so
    # the test tracks the real set. Computed for the AD-enabled standard (the
    # default), since the bulk of the tests scaffold with `ad = true`.
    const MANAGED_DESTS = [t.dest for t in _selected(true) if t.managed]
    const OWNED_DESTS = [t.dest for t in _selected(true) if !t.managed]

    @testset "scaffold + update" begin
        @testset "scaffold writes managed + owned" begin
            mktempdir() do dir
                _fake_pkg(dir)
                res = scaffold(dir)
                # Everything selected for ad=true is newly created; nothing updated
                # or preserved. (AD/no-AD variant pairs map to one dest each.)
                @test length(res.created) == length(_selected(true))
                @test isempty(res.updated)
                @test isempty(res.preserved)
                for t in _selected(true)
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

        @testset "DocumenterVitepress docs setup present + parameterised" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # The standard org docs build (Documenter + DocumenterVitepress).
                for f in ("docs/make.jl", "docs/Project.toml", "docs/pages.jl",
                    "docs/package.json", "docs/versions.js",
                    "docs/src/.vitepress/config.mts",
                    "docs/src/.vitepress/theme/index.ts",
                    "docs/src/.vitepress/theme/style.css",
                    "docs/src/components/VersionPicker.vue")
                    @test isfile(joinpath(dir, f))
                end
                # make.jl uses DocumenterVitepress, not a plain Documenter.HTML
                # format, and is fully substituted.
                mk = read(joinpath(dir, "docs/make.jl"), String)
                @test occursin("using DocumenterVitepress", mk)
                @test occursin("DocumenterVitepress.MarkdownVitepress", mk)
                @test occursin("DocumenterVitepress.deploydocs", mk)
                @test occursin("using Wombat", mk)
                @test occursin("github.com/EpiAware/Wombat.jl", mk)
                # Default docs hosting is project-pages: deploy_url = nothing
                # (no custom subdomain), so DocumenterVitepress derives the base
                # from the repo name and the site needs no DNS.
                @test occursin("deploy_url = nothing", mk)
                @test !occursin("wombat.epiaware.org", mk)
                @test !occursin("Documenter.HTML", mk)
                @test !occursin("{{", mk)
                # The docs env depends on DocumenterVitepress with compat.
                dp = read(joinpath(dir, "docs/Project.toml"), String)
                @test occursin("DocumenterVitepress", dp)
                @test occursin("Wombat = \"00000000", dp)
                @test !occursin("{{", dp)
                # The VitePress config keeps the DocumenterVitepress markers and
                # points social links at the package repo.
                cfg = read(joinpath(dir, "docs/src/.vitepress/config.mts"),
                    String)
                @test occursin("REPLACE_ME_DOCUMENTER_VITEPRESS", cfg)
                @test occursin("github.com/EpiAware/Wombat.jl", cfg)
                @test !occursin("{{", cfg)
                # The node deps pin vitepress + DocumenterVitepress plugins.
                pj = read(joinpath(dir, "docs/package.json"), String)
                @test occursin("vitepress", pj)
            end
        end

        @testset "docs_subdomain opts into a custom subdomain deploy" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                # `true` selects the conventional <pkg>.epiaware.org host.
                scaffold(dir; docs_subdomain = true)
                mk = read(joinpath(dir, "docs/make.jl"), String)
                @test occursin("deploy_url = \"wombat.epiaware.org\"", mk)
                @test !occursin("deploy_url = nothing", mk)
                @test !occursin("{{", mk)
                txt = read(joinpath(dir, "README.md"), String)
                @test occursin("wombat.epiaware.org/stable/", txt)
                @test occursin("wombat.epiaware.org/dev/", txt)
                @test !occursin("epiaware.org/Wombat.jl/stable/", txt)
            end
        end

        @testset "docs_subdomain accepts a bespoke host string" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; docs_subdomain = "docs.example.org")
                mk = read(joinpath(dir, "docs/make.jl"), String)
                @test occursin("deploy_url = \"docs.example.org\"", mk)
                txt = read(joinpath(dir, "README.md"), String)
                @test occursin("docs.example.org/stable/", txt)
            end
        end

        @testset ".gitignore present and ignores Manifest + docs build" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                gi = joinpath(dir, ".gitignore")
                @test isfile(gi)
                txt = read(gi, String)
                @test occursin("Manifest.toml", txt)
                @test occursin("docs/build", txt)
                @test occursin("docs/node_modules", txt)
            end
        end

        @testset "benchmark env present so --project=benchmark resolves" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                bp = joinpath(dir, "benchmark/Project.toml")
                @test isfile(bp)
                txt = read(bp, String)
                @test occursin("BenchmarkTools", txt)
                @test occursin("EpiAwarePackageTools", txt)
                @test occursin("Wombat = \"00000000", txt)
                @test !occursin("{{", txt)
            end
        end

        @testset "test envs pin EpiAwarePackageTools via [sources]" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # Every env that depends on the kit must resolve it: an active
                # (not commented-out) [sources] git pin, since it is unregistered.
                for f in ("test/Project.toml", "test/ad/Project.toml",
                    "test/jet/Project.toml", "benchmark/Project.toml")
                    txt = read(joinpath(dir, f), String)
                    @test occursin(
                        r"(?m)^EpiAwarePackageTools = \{url = ", txt)
                end
                # The jet runner depends on the kit (for the report filter).
                jp = read(joinpath(dir, "test/jet/Project.toml"), String)
                @test occursin("EpiAwarePackageTools =", jp)
            end
        end

        @testset "license badge reflects the selected licence" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                write(joinpath(dir, "README.md"), "# Wombat\n\nbody\n")
                scaffold(dir; license = "Apache-2.0", ad = false)
                txt = read(joinpath(dir, "README.md"), String)
                @test occursin("License: Apache-2.0", txt)
                @test !occursin("License: MIT", txt)
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

                # Dependabot sets NO reviewers/assignees: GitHub cannot assign an
                # org (or any bare placeholder) as a reviewer, so the template
                # omits them entirely (and never hardcodes a person).
                dep = read(joinpath(dir, ".github/dependabot.yml"), String)
                @test !occursin("reviewers:", dep)
                @test !occursin("assignees:", dep)
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
                @test length(res.updated) == length(_selected(true))
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

        @testset "ad = false opts out of the AD infra" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Tooly")
                res = scaffold(dir; ad = false)
                # None of the AD-only infra is written.
                for f in (".github/workflows/ad.yaml",
                    "test/ad/setup.jl", "test/ad/runtests.jl",
                    "test/ad/scenarios.jl", "test/ad/Project.toml",
                    "test/ADFixtures/Project.toml",
                    "test/ADFixtures/src/ADFixtures.jl")
                    @test !isfile(joinpath(dir, f))
                end
                @test !isdir(joinpath(dir, "test/ad"))
                @test !isdir(joinpath(dir, "test/ADFixtures"))
                # The non-AD infra is still written.
                for f in ("Taskfile.yml", "codecov.yml", "test/Project.toml",
                    ".github/workflows/test.yaml", "test/package/quality.jl")
                    @test isfile(joinpath(dir, f))
                end
                # The no-AD variants are emitted: no per-backend codecov flags, no
                # test-ad task, no AD deps in the test env.
                cov = read(joinpath(dir, "codecov.yml"), String)
                @test occursin("unit:", cov)
                @test !occursin("ad-forwarddiff", cov)
                tf = read(joinpath(dir, "Taskfile.yml"), String)
                @test !occursin("test-ad:", tf)
                @test !occursin("test/ad", tf)
                tp = read(joinpath(dir, "test/Project.toml"), String)
                @test !occursin("DifferentiationInterface", tp)
                @test !occursin("ForwardDiff", tp)
                # The manifest count matches the ad=false selection.
                @test length(res.created) == length(_selected(false))
            end
        end

        @testset "ad = true still ships the AD infra (default)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Numeric")
                scaffold(dir)   # default ad = true
                for f in (".github/workflows/ad.yaml", "test/ad/setup.jl",
                    "test/ad/scenarios.jl", "test/ADFixtures/src/ADFixtures.jl")
                    @test isfile(joinpath(dir, f))
                end
                cov = read(joinpath(dir, "codecov.yml"), String)
                @test occursin("ad-forwarddiff", cov)
            end
        end

        @testset "update respects ad = false" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Tooly")
                scaffold(dir; ad = false)
                res = update(dir; ad = false)
                # No AD managed file appears in the update manifest.
                @test !any(p -> occursin("workflows/ad.yaml", p), res.updated)
                @test !any(p -> occursin("test/ad/", p), res.updated)
                # The no-AD codecov is re-applied (not the AD-flagged one).
                @test !occursin("ad-forwarddiff",
                    read(joinpath(dir, "codecov.yml"), String))
            end
        end

        @testset "generate makes a fresh package then scaffolds it" begin
            mktempdir() do base
                dir = joinpath(base, "FreshPkg")
                res = generate(dir, "FreshPkg"; authors = ["Ada Lovelace"])
                # The package skeleton is laid down.
                @test isfile(joinpath(dir, "Project.toml"))
                @test isfile(joinpath(dir, "src", "FreshPkg.jl"))
                proj = read(joinpath(dir, "Project.toml"), String)
                @test occursin("name = \"FreshPkg\"", proj)
                # Substitution drew the new package's name through.
                qa = read(joinpath(dir, "test/package/qa_config.jl"), String)
                @test occursin("using FreshPkg", qa)
                @test !occursin("{{", qa)
                # ad = true by default, so AD infra is present.
                @test isfile(joinpath(dir, ".github/workflows/ad.yaml"))
            end
        end

        @testset "generate with ad = false opts out" begin
            mktempdir() do base
                dir = joinpath(base, "ToolPkg")
                generate(dir, "ToolPkg"; authors = ["Ada"], ad = false)
                @test isfile(joinpath(dir, "src", "ToolPkg.jl"))
                @test !isfile(joinpath(dir, ".github/workflows/ad.yaml"))
                @test !isdir(joinpath(dir, "test/ad"))
            end
        end

        @testset "managed README badge block" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                body = "# Wombat\n\nIntro paragraph.\n\n## Usage\nstuff\n"
                readme = joinpath(dir, "README.md")
                write(readme, body)

                # First update injects the marker block after the title and
                # leaves the body untouched.
                res = update(dir; ad = false)
                @test res.readme === :injected
                txt = read(readme, String)
                @test occursin("<!-- badges:start -->", txt)
                @test occursin("<!-- badges:end -->", txt)
                @test occursin("Intro paragraph.", txt)
                @test occursin("## Usage", txt)
                # Parameterised from REPO/PACKAGE — no hardcoded owner/repo.
                @test occursin("EpiAware/Wombat.jl", txt)
                # Default docs badges point at the project-pages URL, not a
                # custom subdomain.
                @test occursin("epiaware.org/Wombat.jl/stable/", txt)
                @test occursin("epiaware.org/Wombat.jl/dev/", txt)
                @test !occursin("wombat.epiaware.org", txt)
                # ad = false: no per-backend AD badge rows.
                @test !occursin("AD CI", txt)
                @test !occursin("ad-forwarddiff", txt)

                # A second update is idempotent (refresh, no content change).
                before = read(readme, String)
                res2 = update(dir; ad = false)
                @test res2.readme === :refreshed
                @test read(readme, String) == before

                # Editing only outside the markers is preserved; the block is
                # re-rendered in place without disturbing the surrounding text.
                edited = replace(read(readme, String),
                    "Intro paragraph." => "Edited intro.")
                write(readme, edited * "\n\nNew trailing section.\n")
                update(dir; ad = false)
                final = read(readme, String)
                @test occursin("Edited intro.", final)
                @test occursin("New trailing section.", final)
                @test count("<!-- badges:start -->", final) == 1
            end
        end

        @testset "badge block opts into AD rows with ad = true" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Numeric")
                write(joinpath(dir, "README.md"), "# Numeric\n\nbody\n")
                update(dir; ad = true)
                txt = read(joinpath(dir, "README.md"), String)
                @test occursin("AD CI", txt)
                @test occursin("ad-forwarddiff", txt)
                @test occursin("AD coverage", txt)
            end
        end

        @testset "scaffold creates a README with badges when absent" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Fresh")
                res = scaffold(dir; ad = false)
                @test res.readme === :created
                txt = read(joinpath(dir, "README.md"), String)
                @test occursin("# Fresh", txt)
                @test occursin("<!-- badges:start -->", txt)
            end
        end

        @testset "LICENSE is package-owned and write-once" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat",
                    authors = "[\"Ada Lovelace\"]")
                # scaffold writes the MIT licence by default with holder + year.
                res = scaffold(dir)
                @test res.license === :created
                lic = joinpath(dir, "LICENSE")
                @test isfile(lic)
                txt = read(lic, String)
                @test occursin("MIT License", txt)
                @test occursin("Ada Lovelace", txt)
                @test occursin(string(year(now())), txt)
                @test !occursin("{{HOLDER}}", txt)
                @test !occursin("{{YEAR}}", txt)

                # A deliberate licence change must NOT be reverted by update.
                custom = "Custom proprietary licence — all rights reserved.\n"
                write(lic, custom)
                ures = update(dir)
                @test ures.license === :skipped
                @test read(lic, String) == custom

                # A second scaffold preserves the existing LICENSE too.
                sres = scaffold(dir)
                @test sres.license === :preserved
                @test read(lic, String) == custom
            end
        end

        @testset "scaffold license = Apache-2.0 writes Apache text" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat",
                    authors = "[\"Ada Lovelace\"]")
                res = scaffold(dir; license = "Apache-2.0")
                @test res.license === :created
                txt = read(joinpath(dir, "LICENSE"), String)
                @test occursin("Apache License", txt)
                @test occursin("Version 2.0", txt)
                @test occursin("Ada Lovelace", txt)
                @test !occursin("MIT License", txt)
                @test !occursin("{{HOLDER}}", txt)
                @test !occursin("{{YEAR}}", txt)
            end
        end

        @testset "scaffold_inputs rejects an unsupported license" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                @test_throws ErrorException scaffold_inputs(dir; license = "GPL-3.0")
            end
        end

        @testset "generate writes the license too" begin
            mktempdir() do base
                dir = joinpath(base, "GenPkg")
                res = generate(dir, "GenPkg"; authors = ["Ada"],
                    license = "Apache-2.0")
                @test res.license === :created
                @test occursin("Apache License",
                    read(joinpath(dir, "LICENSE"), String))
            end
        end

        @testset "update preserves a Dependabot-bumped reusable ref" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                caller = joinpath(dir, ".github/workflows/test.yaml")
                # Simulate Dependabot bumping the reusable SHA in the live
                # caller (the case that used to fail self-drift).
                bumped = replace(read(caller, String),
                    r"(tests\.yml@)\S+" =>
                        s"\1deadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
                write(caller, bumped)
                update(dir)
                after = read(caller, String)
                # update keeps the bumped ref (never reverts Dependabot) ...
                @test occursin(
                    "tests.yml@deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", after)
                # ... the rest of the caller is still re-applied managed, and a
                # second update is idempotent on the preserved ref.
                update(dir)
                @test read(caller, String) == after
            end
        end

        @testset "org issue/PR templates + scheduled sync are managed" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false)
                for f in (".github/workflows/template-sync.yaml",
                    ".github/ISSUE_TEMPLATE/bug_report.md",
                    ".github/ISSUE_TEMPLATE/feature_request.md",
                    ".github/ISSUE_TEMPLATE/scientific_improvement.md",
                    ".github/ISSUE_TEMPLATE/config.yml",
                    ".github/PULL_REQUEST_TEMPLATE.md")
                    @test isfile(joinpath(dir, f))
                end
                # The sync workflow re-applies the standard with the package's
                # own `ad` value and is fully substituted.
                sync = read(
                    joinpath(dir, ".github/workflows/template-sync.yaml"),
                    String)
                @test occursin("update(\".\"; ad = false)", sync)
                # The kit placeholders are resolved (GitHub Actions `${{ }}`
                # expressions legitimately remain).
                @test !occursin("{{AD}}", sync)
                @test !occursin("{{SYNC_INSTALL}}", sync)
                # config.yml points its security link at the package repo.
                cfg = read(joinpath(dir, ".github/ISSUE_TEMPLATE/config.yml"),
                    String)
                @test occursin("EpiAware/Wombat.jl", cfg)
                @test !occursin("{{", cfg)
                # They are managed: an update re-applies them.
                res = update(dir; ad = false)
                @test joinpath(dir, ".github/workflows/template-sync.yaml") in
                      res.updated
            end
        end

        @testset "docstrings template shipped + wired by generate" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false)
                # The @template conventions ship as a package-owned src file.
                ds = joinpath(dir, "src/docstrings.jl")
                @test isfile(ds)
                txt = read(ds, String)
                @test occursin("@template", txt)
                @test occursin("TYPEDSIGNATURES", txt)
                # CODEOWNERS is seeded (package-owned, commented placeholder).
                @test isfile(joinpath(dir, ".github/CODEOWNERS"))
            end
            mktempdir() do base
                dir = joinpath(base, "FreshPkg")
                generate(dir, "FreshPkg"; authors = ["Ada"], ad = false)
                # generate wires the dep + include automatically.
                proj = read(joinpath(dir, "Project.toml"), String)
                @test occursin("DocStringExtensions", proj)
                mod = read(joinpath(dir, "src/FreshPkg.jl"), String)
                @test occursin("include(\"docstrings.jl\")", mod)
                @test isfile(joinpath(dir, "src/docstrings.jl"))
            end
        end
    end # @testset "scaffold + update"
end # @testitem "scaffold + update (logic)"
