# Scaffolding into a fresh temp package writes every managed standard file plus
# the package-owned skeletons; `scaffold_update` re-applies only the managed files and is
# idempotent, never touching package-owned files.

@testitem "scaffold + scaffold_update (logic)" begin
    using Test
    using Pkg
    using EpiAwarePackageTools
    using EpiAwarePackageTools: SCAFFOLD_TEMPLATES, _templates_dir,
                                scaffold_inputs, _ad_selected, _bench_selected
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

    # Actually `Pkg.instantiate` a generated environment in an isolated
    # subprocess (kit issue #59): file-presence and text-substitution checks
    # never prove an emitted Project.toml/[compat]/[sources] table actually
    # resolves, so a broken template can pass every check above and only
    # fail once a downstream adopter runs `Pkg.instantiate` for real. On
    # failure the resolve/install log is printed for diagnosis.
    function _env_instantiates(env::AbstractString)
        isfile(joinpath(env, "Project.toml")) || return false
        exe = joinpath(Sys.BINDIR, Base.julia_exename())
        out = IOBuffer()
        ok = try
            # Resolution/installation is what this proves; auto-precompiling
            # the resolved set adds minutes (the ad=true docs env now carries
            # the CairoMakie plotting stack for the AD-backends page) without
            # adding proof, so it is disabled for the subprocess.
            run(pipeline(
                addenv(
                    `$exe --startup-file=no --history-file=no --project=$env
                     -e "using Pkg; Pkg.instantiate()"`,
                    "JULIA_PKG_PRECOMPILE_AUTO" => "0");
                stdout = out, stderr = out))
            true
        catch
            false
        end
        ok || println(stderr,
            "Pkg.instantiate failed for $env:\n", String(take!(out)))
        return ok
    end

    # The templates emitted for a given (`ad`, `benchmarks`) pair. AD/no-AD and
    # benchmark-gated variants writing to the same `dest` collapse to one entry.
    # The bulk of the suite exercises the full standard (ad = true,
    # benchmarks = true); the opt-in benchmark gating (on/off) is covered
    # separately in the `benchmarks_gating` testitem, so tests here scaffold with
    # `benchmarks = true` where they assert the benchmark surface.
    function _selected(ad, benchmarks)
        return [t
                for t in SCAFFOLD_TEMPLATES
                if _ad_selected(t, ad) && _bench_selected(t, benchmarks)]
    end

    # The managed / package-owned destination paths for the full standard.
    const MANAGED_DESTS = [t.dest for t in _selected(true, true) if t.managed]
    const OWNED_DESTS = [t.dest for t in _selected(true, true) if !t.managed]

    @testset "scaffold + scaffold_update" begin
        @testset "scaffold writes managed + owned" begin
            mktempdir() do dir
                _fake_pkg(dir)
                res = scaffold(dir; benchmarks = true)
                # Everything selected for the full standard is newly created;
                # nothing updated or preserved. (Variant pairs map to one dest.)
                @test length(res.created) == length(_selected(true, true))
                @test isempty(res.updated)
                @test isempty(res.preserved)
                for t in _selected(true, true)
                    @test isfile(joinpath(dir, t.dest))
                end
            end
        end

        @testset "managed CI callers + test infra present" begin
            mktempdir() do dir
                _fake_pkg(dir)
                scaffold(dir; benchmarks = true)
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

                # Every managed workflow + dependabot + CODEOWNERS self-identifies
                # with the managed-by header so an adopter never edits it by hand.
                hdr = "MANAGED by EpiAwarePackageTools.scaffold"
                for f in (".github/workflows/test.yaml",
                    ".github/workflows/ad.yaml",
                    ".github/workflows/document.yaml",
                    ".github/workflows/codecoverage.yaml",
                    ".github/workflows/downstream.yaml",
                    ".github/workflows/pre-commit.yaml",
                    ".github/workflows/TagBot.yaml",
                    ".github/workflows/docpreviewcleanup.yaml",
                    ".github/workflows/cancel-on-close.yaml",
                    ".github/workflows/try-this-pr.yaml",
                    ".github/workflows/claude.yml",
                    ".github/workflows/claude-code-review.yml",
                    ".github/dependabot.yml", ".github/CODEOWNERS",
                    "codecov.yml", ".pre-commit-config.yaml",
                    ".JuliaFormatter.toml", "Taskfile.yml")
                    @test occursin(hdr,
                        read(joinpath(dir, f), String))
                end
                # The org-standard bot/dev-experience callers are managed and
                # parameterised (no repo-specific literal left hardcoded).
                tpr = read(joinpath(dir, ".github/workflows/try-this-pr.yaml"),
                    String)
                @test occursin("github.com/EpiAware/FakePkg.jl", tpr)
                @test occursin("using FakePkg", tpr)
                # No kit placeholder remains (GitHub `${{ }}` expressions stay).
                @test !occursin(r"\{\{[A-Z_]+\}\}", tpr)
                coc = read(joinpath(dir, ".github/workflows/cancel-on-close.yaml"),
                    String)
                @test occursin(
                    "EpiAware/.github/.github/workflows/cancel-on-close.yml", coc)
                # Coverage hard-fails on upload error (org policy: red on a
                # missing CODECOV_TOKEN as a loud reminder to add it).
                cov_caller = read(
                    joinpath(dir, ".github/workflows/codecoverage.yaml"), String)
                @test occursin("fail_ci_if_error: true", cov_caller)
                @test !occursin("fail_ci_if_error: false", cov_caller)
            end
        end

        @testset "formatter version is single-sourced (#114)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "FmtPkg")
                scaffold(dir; ad = false)
                ver = EpiAwarePackageTools._JULIAFORMATTER_VERSION
                # The pre-commit CI caller passes the pinned version to the
                # shared format-check workflow (otherwise CI installs its own
                # default and reformats code the local hook left intact).
                pc = read(joinpath(dir, ".github/workflows/pre-commit.yaml"),
                    String)
                @test occursin("juliaformatter_version: '$ver'", pc)
                # No kit placeholder remains (GitHub `${{ }}` expressions stay).
                @test !occursin(r"\{\{[A-Z_]+\}\}", pc)
                # The local pre-commit hook `rev` and the isolated formatter
                # env compat pin agree with the same single source.
                cfg = read(joinpath(dir, ".pre-commit-config.yaml"), String)
                @test occursin("rev: v$ver", cfg)
                fmt = read(joinpath(dir, "test/formatter/Project.toml"), String)
                @test occursin("JuliaFormatter = \"=$ver\"", fmt)
                @test !occursin("{{", fmt)
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
                # The ad=true codecov gates status until every flag upload lands
                # (unit + six AD backends = seven), parameterised by backend count.
                @test occursin("after_n_builds: 7", cov)
                @test occursin("wait_for_ci: true", cov)
                @test occursin("target: auto", cov)
                @test !occursin("{{", cov)
                adyaml = read(joinpath(dir, ".github/workflows/ad.yaml"), String)
                @test occursin("EpiAware/.github/.github/workflows/ad.yml", adyaml)
                # Docs-only changes skip the heavy 6-backend AD sweep on both
                # push and pull_request (a mixed docs+src PR still runs it).
                @test count("paths-ignore:", adyaml) == 2
                @test occursin("'docs/**'", adyaml)
                @test occursin("'**/*.md'", adyaml)
                @test occursin("'LICENSE'", adyaml)

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
                    "docs/src/components/VersionPicker.vue",                 # The GitHub-stars navbar widget + its star-count loader.
                    "docs/src/components/StarUs.vue",
                    "docs/src/components/stargazers.data.ts",                 # Authored source pages distinct from the README home page.
                    "docs/src/getting-started/index.md",
                    "docs/src/getting-started/infrastructure.md")
                    @test isfile(joinpath(dir, f))
                end
                # The stars widget targets the adopting repo (no owner/repo
                # hardcoded) and its theme + package.json wiring is present.
                star = read(joinpath(dir, "docs/src/components/StarUs.vue"),
                    String)
                @test occursin("github.com/EpiAware/Wombat.jl", star)
                @test !occursin("{{REPO}}", star)
                data_ts = read(
                    joinpath(dir, "docs/src/components/stargazers.data.ts"),
                    String)
                @test occursin("EpiAware/Wombat.jl", data_ts)
                theme = read(
                    joinpath(dir, "docs/src/.vitepress/theme/index.ts"), String)
                @test occursin("StarUs", theme)
                @test occursin("d3-format",
                    read(joinpath(dir, "docs/package.json"), String))
                # The getting-started + infrastructure pages are authored,
                # package-owned, and substituted (no unresolved placeholders).
                gs = read(joinpath(dir, "docs/src/getting-started/index.md"),
                    String)
                @test occursin("@id getting-started", gs)
                @test occursin("Pkg.add(\"Wombat\")", gs)
                @test !occursin("{{", gs)
                infra = read(
                    joinpath(dir, "docs/src/getting-started/infrastructure.md"),
                    String)
                @test occursin("@id infrastructure", infra)
                @test occursin("template-sync", infra)
                @test !occursin("{{", infra)
                # The nav wires the getting-started section into pages.jl.
                pgs = read(joinpath(dir, "docs/pages.jl"), String)
                @test occursin("getting-started/index.md", pgs)
                @test occursin("getting-started/infrastructure.md", pgs)
                # The maintainer-facing infrastructure page sits in its own
                # top-level Development section, not under Getting started, so a
                # new user's first section is not maintainer noise (#136).
                @test occursin("\"Development\"", pgs)
                dev_at = findfirst("\"Development\"", pgs)
                infra_at = findfirst("getting-started/infrastructure.md", pgs)
                @test dev_at !== nothing && infra_at !== nothing &&
                      first(dev_at) < first(infra_at)
                # make.jl is a thin caller into the kit's DocsBuild machinery
                # (DocumenterVitepress/Literate/makedocs all live in the kit
                # now), and is fully substituted.
                mk = read(joinpath(dir, "docs/make.jl"), String)
                @test occursin("using EpiAwarePackageTools", mk)
                @test occursin("build_docs(", mk)
                @test occursin("using Wombat", mk)
                @test occursin("EpiAware/Wombat.jl", mk)
                @test !occursin("makedocs", mk)
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
                # make.jl does `using EpiAwarePackageTools`, so the docs env
                # must carry the kit as a dep + (until registered) a git source,
                # or the docs build fails with "package not found" (#115).
                @test occursin(
                    "EpiAwarePackageTools = \"7aaea248", dp)
                @test occursin(
                    "EpiAwarePackageTools = {url = " *
                    "\"https://github.com/EpiAware/EpiAwarePackageTools.jl\", " *
                    "rev = \"main\"}", dp)
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

        @testset "managed docs/quality tolerate unseeded config (#163)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # Simulate an adopter predating the build_docs / readme-field
                # migrations: the package-owned config is absent, but scaffold_update()
                # (managed_only) re-emits the managed make.jl/quality.jl.
                rm(joinpath(dir, "docs/docs_config.jl"))
                rm(joinpath(dir, "docs/pages.jl"))
                scaffold_update(dir)
                # make.jl no longer hard-includes the missing config; the
                # include is guarded and pages falls back to a default.
                mk = read(joinpath(dir, "docs/make.jl"), String)
                @test occursin("isfile(joinpath(@__DIR__, _f))", mk)
                @test !occursin("\ninclude(\"docs_config.jl\")", mk)
                @test !occursin("\ninclude(\"pages.jl\")", mk)
                @test occursin("_cfg(:pages,", mk)
                # The guarded prelude actually loads with the config absent and
                # returns defaults rather than erroring on the missing files.
                prelude = joinpath(dir, "docs", "_prelude163.jl")
                write(prelude,
                    "for _f in (\"pages.jl\", \"docs_config.jl\")\n" *
                    "    isfile(joinpath(@__DIR__, _f)) &&\n" *
                    "        include(joinpath(@__DIR__, _f))\n" *
                    "end\n" *
                    "_cfg(sym, default) = isdefined(@__MODULE__, sym) ?\n" *
                    "                     getfield(@__MODULE__, sym) : default\n")
                m = Module()
                Base.include(m, prelude)
                @test Base.invokelatest(
                    getproperty(m, :_cfg), :pages, ["Home" => "index.md"]) ==
                      ["Home" => "index.md"]
                # quality.jl defaults a missing QA_CONFIG.readme field.
                ql = read(joinpath(dir, "test/package/quality.jl"), String)
                @test occursin("hasproperty(QA_CONFIG, :readme)", ql)
            end
        end

        @testset "guarded config fallbacks warn when they engage (#188)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # The docs fallback is loud: a bad sync that drops `pages.jl`
                # must not publish a Home-only nav from a green docs build.
                mk = read(joinpath(dir, "docs/make.jl"), String)
                @test occursin("@warn", mk)
                # The QA fallback is loud too: a typoed `readme` key must not
                # silently revert to the repo-root defaults.
                ql = read(joinpath(dir, "test/package/quality.jl"), String)
                @test occursin("@warn", ql)

                # The docs guard actually warns (and still returns the
                # default) when the package-owned config is absent.
                rm(joinpath(dir, "docs/pages.jl"))
                rm(joinpath(dir, "docs/docs_config.jl"))
                lines = split(mk, "\n")
                i = findfirst(l -> occursin("for _f in (", l), lines)
                j = findfirst(
                    l -> occursin("getfield(@__MODULE__, sym)", l), lines)
                prelude = joinpath(dir, "docs", "_prelude188.jl")
                write(prelude, join(lines[i:j], "\n") * "\n")
                m = Module()
                @test_logs (:warn,) (:warn,) match_mode=:any Base.include(
                    m, prelude)
                @test Base.invokelatest(
                    getproperty(m, :_cfg), :pages, ["Home" => "index.md"]) ==
                      ["Home" => "index.md"]
            end
        end

        @testset "scaffold_update preserves docs_subdomain without re-passing it (#123)" begin
            # A subdomain-hosted package is not reverted to project-pages when a
            # resync (the scheduled template-sync's `scaffold_update`) omits the kwarg.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; docs_subdomain = true)
                mk = joinpath(dir, "docs/make.jl")
                @test occursin("deploy_url = \"wombat.epiaware.org\"",
                    read(mk, String))
                # The common maintenance call: no docs_subdomain kwarg.
                scaffold_update(dir)
                @test occursin("deploy_url = \"wombat.epiaware.org\"",
                    read(mk, String))
                @test !occursin("deploy_url = nothing", read(mk, String))
                # The README badges stay on the subdomain host too.
                @test occursin("wombat.epiaware.org/stable/",
                    read(joinpath(dir, "README.md"), String))
            end
            # A project-pages package stays project-pages across a resync.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)  # default: project-pages
                mk = joinpath(dir, "docs/make.jl")
                @test occursin("deploy_url = nothing", read(mk, String))
                scaffold_update(dir)
                @test occursin("deploy_url = nothing", read(mk, String))
            end
        end

        @testset "_detect_docs_subdomain reads the committed deploy_url" begin
            using EpiAwarePackageTools: _detect_docs_subdomain
            mktempdir() do dir
                # No docs/make.jl yet -> :missing (fall back to the default).
                @test _detect_docs_subdomain(dir) === :missing
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; docs_subdomain = "docs.example.org")
                @test _detect_docs_subdomain(dir) == "docs.example.org"
            end
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)  # project-pages
                @test _detect_docs_subdomain(dir) === nothing
            end
        end

        @testset "_detect_doi recovers a committed DOI badge (#161)" begin
            using EpiAwarePackageTools: _detect_doi
            # No README yet -> nothing/nothing (a never-configured repo).
            mktempdir() do dir
                @test _detect_doi(dir) === (nothing, nothing)
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)  # no doi passed -> no DOI badge
                @test _detect_doi(dir) === (nothing, nothing)
            end
            # A DOI-bearing README reads back the (doi, zenodo_badge) pair.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; doi = "10.5281/zenodo.18474651",
                    zenodo_badge = "862539324")
                @test _detect_doi(dir) ==
                      ("10.5281/zenodo.18474651", "862539324")
            end
        end

        @testset "scaffold_update preserves an adopter's DOI badge (#161)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; doi = "10.5281/zenodo.18474651",
                    zenodo_badge = "862539324")
                txt = read(joinpath(dir, "README.md"), String)
                @test occursin("zenodo.org/badge/862539324.svg", txt)
                # A bare scaffold_update (as the scheduled template-sync runs) must not
                # strip the DOI badge.
                scaffold_update(dir)
                txt2 = read(joinpath(dir, "README.md"), String)
                @test occursin("zenodo.org/badge/862539324.svg", txt2)
                @test occursin("doi.org/10.5281/zenodo.18474651", txt2)
            end
        end

        @testset "kit dogfoods its own subdomain by default" begin
            mktempdir() do dir
                # The kit's own subdomain is DNS-wired, so with no explicit
                # choice the kit (and only the kit) defaults to it.
                _fake_pkg(dir; name = "EpiAwarePackageTools")
                inp = scaffold_inputs(dir)
                @test inp.DOCS_DEPLOY_URL ==
                      "\"epiawarepackagetools.epiaware.org\""
                @test inp.DOCS_URL == "epiawarepackagetools.epiaware.org"
                # An explicit opt-out still wins, even for the kit.
                inp2 = scaffold_inputs(dir; docs_subdomain = false)
                @test inp2.DOCS_DEPLOY_URL == "nothing"
                @test inp2.DOCS_URL == "epiaware.org/EpiAwarePackageTools.jl"
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
                # Generated docs pages: the release-notes page is generic; the
                # tutorial markdown path tracks docs_config.jl's TUTORIALS_SUBDIR
                # (the template default until the package customises it).
                @test occursin("docs/src/release-notes.md", txt)
                @test occursin(
                    "docs/src/getting-started/tutorials/*.md", txt)
                @test !occursin("{{", txt)
            end
        end

        @testset ".gitignore tutorial ignore tracks TUTORIALS_SUBDIR" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # docs_config.jl is package-owned; rewrite TUTORIALS_SUBDIR and
                # re-run scaffold_update — the managed .gitignore must follow the new path.
                cfg = joinpath(dir, "docs", "docs_config.jl")
                write(cfg,
                    replace(read(cfg, String),
                        "const TUTORIALS_SUBDIR = " *
                        "joinpath(\"getting-started\", \"tutorials\")" => "const TUTORIALS_SUBDIR = \"how-to/walkthroughs\""))
                scaffold_update(dir)
                txt = read(joinpath(dir, ".gitignore"), String)
                @test occursin("docs/src/how-to/walkthroughs/*.md", txt)
                @test !occursin(
                    "docs/src/getting-started/tutorials/*.md", txt)
            end
        end

        @testset ".gitignore package-owned tail survives scaffold_update (#65)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                res = scaffold(dir)
                @test res.gitignore === :created
                gi = joinpath(dir, ".gitignore")
                # A package adds its own ignore rule after the managed block.
                keep = "!docs/src/getting-started/tutorials/data/**"
                write(gi, read(gi, String) * "\n# Keep bundled data.\n" * keep * "\n")
                res2 = scaffold_update(dir)
                @test res2.gitignore === :refreshed
                txt = read(gi, String)
                @test occursin(keep, txt)
                # The managed block is still correctly refreshed alongside it.
                @test occursin("Manifest.toml", txt)
                # A further no-op scaffold_update changes nothing (idempotent with a
                # package-owned tail present).
                before = read(gi, String)
                res3 = scaffold_update(dir)
                @test res3.gitignore === :refreshed
                @test read(gi, String) == before
            end
        end

        @testset ".gitignore legacy (marker-less) file migrates without data loss" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                # Simulate a pre-fix kit version: a flat, marker-less .gitignore
                # with a package-owned keep-rule mixed into the managed copy
                # (the real CensoredDistributions.jl#65 scenario).
                keep = "!docs/src/getting-started/tutorials/data/**"
                write(joinpath(dir, ".gitignore"),
                    "# MANAGED by EpiAwarePackageTools.scaffold — do not edit by hand.\n" *
                    "Manifest.toml\n" *
                    "docs/src/release-notes.md\n" *
                    "docs/src/getting-started/tutorials/*.md\n" *
                    "# Keep the bundled tutorial data (redistributed with the docs).\n" *
                    keep * "\n")
                res = scaffold_update(dir)
                @test res.gitignore === :injected
                txt = read(joinpath(dir, ".gitignore"), String)
                @test occursin(keep, txt)
                @test occursin("# managed:start", txt)
                @test occursin("# managed:end", txt)
                # Idempotent once markers exist.
                before = txt
                scaffold_update(dir)
                @test read(joinpath(dir, ".gitignore"), String) == before
            end
        end

        @testset ".gitignore carries the managed-by header" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                txt = read(joinpath(dir, ".gitignore"), String)
                @test occursin("MANAGED by EpiAwarePackageTools.scaffold", txt)
            end
        end

        @testset "benchmark env present so --project=benchmark resolves" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; benchmarks = true)
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
                scaffold(dir; benchmarks = true)
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
                scaffold(dir; benchmarks = true)
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

                # With no `reviewer` handle, Dependabot sets no reviewers and
                # CODEOWNERS ships a commented placeholder: GitHub cannot assign
                # a bare org, so a person is never hardcoded.
                dep = read(joinpath(dir, ".github/dependabot.yml"), String)
                @test !occursin("reviewers:", dep)
                @test !occursin("assignees:", dep)
                @test !occursin("{{REVIEWER}}", dep)
                @test !occursin("{{DEPENDABOT_REVIEWERS}}", dep)
                @test !occursin("seabbs", dep)
                co = read(joinpath(dir, ".github/CODEOWNERS"), String)
                @test !occursin(r"^\* @", co)  # no active owner line
                @test !occursin("{{CODEOWNERS_LINE}}", co)
                # The increment-version assignee default must be empty (never
                # the bare org) so a bump PR does not fail with
                # `replaceActorsForAssignable` on the scaffold_update path (#122). The
                # action skips the `--assignee` flag when empty.
                act = read(
                    joinpath(dir,
                        ".github/actions/increment-version/action.yaml"), String)
                @test occursin("default: ''", act)
                @test !occursin("default: 'EpiAware'", act)
                @test !occursin("{{ASSIGNEE_DEFAULT}}", act)
                @test !occursin("{{REVIEWER}}", act)
                @test occursin("ASSIGNEE_ARGS", act)
            end
            # With a `reviewer` handle the same input drives CODEOWNERS, the
            # Dependabot reviewers, the version assignee, and the Claude gate.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; reviewer = "octocat")
                co = read(joinpath(dir, ".github/CODEOWNERS"), String)
                @test occursin("* @octocat", co)
                @test !occursin("{{", co)
                dep = read(joinpath(dir, ".github/dependabot.yml"), String)
                @test occursin("reviewers:", dep)
                @test occursin("- \"octocat\"", dep)
                @test !occursin("{{", dep)
                claude = read(joinpath(dir, ".github/workflows/claude.yml"),
                    String)
                @test occursin("github.actor == 'octocat'", claude)
                @test !occursin("{{REVIEWER}}", claude)
                review = read(
                    joinpath(dir, ".github/workflows/claude-code-review.yml"),
                    String)
                @test occursin("user.login == 'octocat'", review)
                # The version-bump assignee default is the handle (a real user
                # GitHub can assign), not empty.
                act = read(
                    joinpath(dir,
                        ".github/actions/increment-version/action.yaml"), String)
                @test occursin("default: 'octocat'", act)
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

        @testset "scaffold_update re-applies only managed files, idempotently" begin
            mktempdir() do dir
                _fake_pkg(dir)
                scaffold(dir; benchmarks = true)

                # Mutate a package-owned file and a managed file to simulate drift.
                owned = joinpath(dir, "test/package/qa_config.jl")
                managed = joinpath(dir, "test/package/quality.jl")
                owned_marker = "# PACKAGE EDIT — keep me\n"
                write(owned, owned_marker * read(owned, String))
                write(managed, "# drifted\n")

                res = scaffold_update(dir; benchmarks = true)
                # Only managed files are touched; all of them already existed, so
                # they are `updated`, none `created`, none `preserved`.
                @test isempty(res.created)
                @test Set(res.updated) ==
                      Set(joinpath(dir, d) for d in MANAGED_DESTS)
                @test isempty(res.preserved)

                # The managed file's drift was overwritten back to the template.
                @test occursin("Quality: Aqua", read(managed, String))
                # The package-owned file's edit was preserved (scaffold_update skips it).
                @test occursin(owned_marker, read(owned, String))
                # No package-owned file appears in the scaffold_update manifest at all.
                for d in OWNED_DESTS
                    @test joinpath(dir, d) ∉ res.updated
                end

                # Idempotent: a second scaffold_update produces no content change.
                before = Dict(f => read(joinpath(dir, f), String)
                for f in MANAGED_DESTS)
                scaffold_update(dir; benchmarks = true)
                for (f, c) in before
                    @test read(joinpath(dir, f), String) == c
                end
            end
        end

        @testset "reviewer handle persists across resyncs (#72)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; reviewer = "octocat")

                codeowners = joinpath(dir, ".github/CODEOWNERS")
                dependabot = joinpath(dir, ".github/dependabot.yml")
                action = joinpath(dir,
                    ".github/actions/increment-version/action.yaml")

                # scaffold writes the handle into every managed reviewer surface.
                @test occursin("* @octocat", read(codeowners, String))
                @test occursin("- \"octocat\"", read(dependabot, String))
                @test occursin("default: 'octocat'", read(action, String))

                # A scheduled resync does not re-pass `reviewer`; the handle must
                # be recovered from the destination (#72), not reverted to the org
                # placeholder. Two updates confirm it stays put.
                scaffold_update(dir)
                scaffold_update(dir)

                co = read(codeowners, String)
                dep = read(dependabot, String)
                act = read(action, String)
                @test occursin("* @octocat", co)
                @test occursin("reviewers:", dep)
                @test occursin("- \"octocat\"", dep)
                @test occursin("default: 'octocat'", act)
                # No reversion to the commented org placeholder / bare-org
                # assignee, the bug this guards.
                @test !occursin("# * @EpiAware/maintainers", co)
                @test !occursin("default: 'EpiAware'", act)
            end
        end

        @testset "scaffold preserves owned, rewrites managed on re-run" begin
            mktempdir() do dir
                _fake_pkg(dir)
                scaffold(dir; benchmarks = true)
                res = scaffold(dir; benchmarks = true)  # second adopt, no force
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
                scaffold(dir; benchmarks = true)
                res = scaffold(dir; benchmarks = true, force = true)
                @test isempty(res.created)
                @test isempty(res.preserved)
                @test length(res.updated) == length(_selected(true, true))
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
                # Single upload, so no multi-build status gate (ad=true only).
                @test !occursin("after_n_builds", cov)
                tf = read(joinpath(dir, "Taskfile.yml"), String)
                @test !occursin("test-ad:", tf)
                @test !occursin("test/ad", tf)
                tp = read(joinpath(dir, "test/Project.toml"), String)
                @test !occursin("DifferentiationInterface", tp)
                @test !occursin("ForwardDiff", tp)
                # No AD-backends docs page, and the docs seeds carry none of
                # its wiring: no Literate registration (the seeds' comments
                # may mention the entry, so match the quoted entries), no nav
                # entry, no AD deps.
                @test !isfile(joinpath(dir,
                    "docs/src/getting-started/tutorials/ad-backends.jl"))
                cfg = read(joinpath(dir, "docs/docs_config.jl"), String)
                @test occursin("const HEAVY_TUTORIALS = String[]", cfg)
                @test !occursin("\"ad-backends.jl\"", cfg)
                @test !occursin("\"ad-backends.md\"", cfg)
                pgs = read(joinpath(dir, "docs/pages.jl"), String)
                @test !occursin("ad-backends.md", pgs)
                @test !occursin("{{AD_TUTORIALS_NAV}}", pgs)
                dp = read(joinpath(dir, "docs/Project.toml"), String)
                @test !occursin("ADFixtures = ", dp)
                @test !occursin("CairoMakie = ", dp)
                @test !occursin("{{", dp)
                # The manifest count matches the ad=false, benchmarks=false
                # selection (the fresh default opts out of both).
                @test length(res.created) == length(_selected(false, false))
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

        @testset "ext is flagged under `unit` only (#180)" begin
            # AD jobs run without the weakdeps loaded, so an `ext` path under
            # an `ad-*` flag reports 0% and drags the aggregate down; only the
            # unit job (which loads them) may claim extension coverage.
            for ad in (true, false)
                mktempdir() do dir
                    _fake_pkg(dir; name = "Wombat")
                    scaffold(dir; ad = ad)
                    cov = read(joinpath(dir, "codecov.yml"), String)
                    @test count("      - ext", cov) == 1
                    unit = split(cov, "  unit:")[2]
                    @test occursin("- ext", split(unit, "carryforward")[1])
                end
            end
        end

        @testset "ad = true ships the AD-backends tutorial page" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                tut = joinpath(dir,
                    "docs/src/getting-started/tutorials/ad-backends.jl")
                @test isfile(tut)
                txt = read(tut, String)
                # Managed, substituted, and anchored for cross-references.
                @test occursin("MANAGED by EpiAwarePackageTools.scaffold", txt)
                @test occursin("@id ad-backends", txt)
                @test occursin("using Wombat", txt)
                @test occursin(
                    "github.com/EpiAware/Wombat.jl/actions/workflows/ad.yaml",
                    txt)
                @test !occursin("{{", txt)
                # The support table is rendered at docs-build time from the
                # package-owned registry, so broken-scenario declarations
                # never live in the (managed) page body.
                @test occursin("ad_backend_support_table(ADFixtures)", txt)
                # One coverage-flag badge per backend, from `_AD_BACKENDS`
                # (the same table the README badge block renders).
                n = length(EpiAwarePackageTools._AD_BACKENDS)
                @test count("graph/badge.svg?flag=ad-", txt) == n
                # The substituted script is valid Julia (Literate executes it
                # in the docs build): parse it whole and require no error or
                # incomplete trailing expression.
                parsed = Meta.parseall(txt)
                @test parsed isa Expr
                @test !any(
                    ex -> ex isa Expr && ex.head in (:error, :incomplete),
                    parsed.args)

                # Registered in the package-owned docs seeds: the Literate
                # pipeline (heavy tutorial + fast-build stub) and the nav.
                cfg = read(joinpath(dir, "docs/docs_config.jl"), String)
                @test occursin("\"ad-backends.jl\"", cfg)
                @test occursin(
                    "\"ad-backends.md\" => \"# [Automatic differentiation " *
                    "backends](@id ad-backends)\"", cfg)
                pgs = read(joinpath(dir, "docs/pages.jl"), String)
                @test occursin(
                    "getting-started/tutorials/ad-backends.md", pgs)
                @test occursin("\"Tutorials\"", pgs)

                # The docs env reaches the registry by path, keyed to the same
                # seeded ADFixtures UUID as the AD test env, and carries the
                # page's execution deps with compat.
                dp = read(joinpath(dir, "docs/Project.toml"), String)
                reg = read(
                    joinpath(dir, "test/ADFixtures/Project.toml"), String)
                m = match(r"uuid = \"([^\"]+)\"", reg)
                @test m !== nothing
                @test occursin("ADFixtures = \"$(m.captures[1])\"", dp)
                @test occursin(
                    "ADFixtures = {path = \"../test/ADFixtures\"}", dp)
                for dep in ("DifferentiationInterfaceTest", "CairoMakie",
                    "AlgebraOfGraphics", "DataFramesMeta", "Statistics",
                    "Markdown")
                    @test occursin(dep, dp)
                end
                @test occursin("CairoMakie = \"0.15\"", dp)
                @test !occursin("{{", dp)
            end
        end

        @testset "scaffold_update() refreshes the managed AD tutorial page" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                tut = joinpath(dir,
                    "docs/src/getting-started/tutorials/ad-backends.jl")
                # A drifted page body is re-applied from the kit (that is the
                # point: the page stays kit-current; declarations live in the
                # package-owned ADFixtures registry instead).
                write(tut, "# drifted by hand\n")
                res = scaffold_update(dir)
                @test tut in res.updated
                @test occursin("@id ad-backends", read(tut, String))
            end
        end

        @testset "ad setup opt-out preserves a package-owned driver (#162)" begin
            using EpiAwarePackageTools: _detect_ad_setup_owned,
                                        _AD_SETUP_OWNED_MARKER
            mktempdir() do dir
                _fake_pkg(dir; name = "Numeric")
                scaffold(dir)  # default ad = true, managed driver
                setup = joinpath(dir, "test/ad/setup.jl")
                # A freshly scaffolded driver is managed, not opted out.
                @test !_detect_ad_setup_owned(dir)
                # A bare scaffold_update() force-overwrites the managed driver.
                write(setup, "# hand-edited, no marker\n")
                res = scaffold_update(dir)
                @test setup in res.updated
                @test occursin("test_working_backend", read(setup, String))
                # Marking the driver package-owned makes scaffold_update() preserve it.
                owned = "# $(_AD_SETUP_OWNED_MARKER): keep this driver\n" *
                        "@testsnippet ADHelpers begin\n    # legacy driver\nend\n"
                write(setup, owned)
                @test _detect_ad_setup_owned(dir)
                res2 = scaffold_update(dir)
                @test setup in res2.preserved
                @test read(setup, String) == owned
                # scaffold(force = true) still re-lays the managed driver.
                scaffold(dir; force = true)
                @test occursin("test_working_backend", read(setup, String))
            end
        end

        @testset "AD backends single source of truth (#821)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Numeric")
                scaffold(dir)
                n = length(EpiAwarePackageTools._AD_BACKENDS)

                # One `ad-*` codecov flag block per backend; the build-count
                # gate is that count plus the `unit` upload — the two can
                # never desync since both derive from `_AD_BACKENDS`.
                cov = read(joinpath(dir, "codecov.yml"), String)
                @test count(r"(?m)^  ad-", cov) == n
                @test occursin("after_n_builds: $(n + 1)", cov)

                # The `ad.yaml` caller's `backends:` JSON carries one entry
                # per backend too, so the actual CI matrix matches.
                adyaml = read(joinpath(dir, ".github/workflows/ad.yaml"),
                    String)
                @test occursin("backends:", adyaml)
                @test count("\"tag\":", adyaml) == n

                # `test/ad/setup.jl`'s `using` line covers every distinct
                # package a backend needs.
                setup = read(joinpath(dir, "test/ad/setup.jl"), String)
                for pkg in unique(b.pkg for b in EpiAwarePackageTools._AD_BACKENDS)
                    @test occursin(pkg, setup)
                end

                # The `test/ad/scenarios.jl` starter seed has one `@testitem`
                # per backend.
                scenarios = read(joinpath(dir, "test/ad/scenarios.jl"),
                    String)
                @test count(r"(?m)^@testitem", scenarios) == n
            end

            @testset "round-trip: adding a 7th backend" begin
                n = length(EpiAwarePackageTools._AD_BACKENDS)
                push!(EpiAwarePackageTools._AD_BACKENDS,
                    (alt = "FakeAD", header = "FakeAD", slug = "ad-fakead",
                        tag = "fakead", pkg = "FakeADPkg"))
                try
                    mktempdir() do dir
                        _fake_pkg(dir; name = "Numeric7")
                        scaffold(dir)
                        n7 = length(EpiAwarePackageTools._AD_BACKENDS)
                        @test n7 == n + 1

                        cov = read(joinpath(dir, "codecov.yml"), String)
                        @test count(r"(?m)^  ad-", cov) == n7
                        @test occursin("after_n_builds: $(n7 + 1)", cov)
                        @test occursin("ad-fakead", cov)

                        adyaml = read(
                            joinpath(dir, ".github/workflows/ad.yaml"),
                            String)
                        @test count("\"tag\":", adyaml) == n7
                        @test occursin("\"fakead\"", adyaml)

                        setup = read(joinpath(dir, "test/ad/setup.jl"),
                            String)
                        @test occursin("FakeADPkg", setup)

                        scenarios = read(
                            joinpath(dir, "test/ad/scenarios.jl"), String)
                        @test count(r"(?m)^@testitem", scenarios) == n7
                        @test occursin("fakead", scenarios)
                    end
                finally
                    pop!(EpiAwarePackageTools._AD_BACKENDS)
                end
                @test length(EpiAwarePackageTools._AD_BACKENDS) == n
            end

            @testset "scaffold_update() refreshes an already-adopted package" begin
                # A package scaffolds against the current backend set, then a
                # 7th backend is added and `scaffold_update()` is run again — the
                # managed `ad.yaml` `with: backends:` block must refresh to
                # 7, not freeze at whatever `scaffold` first wrote (the #73
                # with:-preservation mechanism must not treat this
                # kit-managed value as a package-owned override).
                n = length(EpiAwarePackageTools._AD_BACKENDS)
                mktempdir() do dir
                    _fake_pkg(dir; name = "Numeric7Update")
                    scaffold(dir)
                    adyaml = read(
                        joinpath(dir, ".github/workflows/ad.yaml"), String)
                    @test count("\"tag\":", adyaml) == n

                    push!(EpiAwarePackageTools._AD_BACKENDS,
                        (alt = "FakeAD", header = "FakeAD",
                            slug = "ad-fakead", tag = "fakead",
                            pkg = "FakeADPkg"))
                    try
                        scaffold_update(dir)
                        adyaml2 = read(
                            joinpath(dir, ".github/workflows/ad.yaml"),
                            String)
                        @test count("\"tag\":", adyaml2) == n + 1
                        @test occursin("\"fakead\"", adyaml2)
                        cov2 = read(joinpath(dir, "codecov.yml"), String)
                        @test occursin("after_n_builds: $(n + 2)", cov2)
                    finally
                        pop!(EpiAwarePackageTools._AD_BACKENDS)
                    end
                end
                @test length(EpiAwarePackageTools._AD_BACKENDS) == n
            end
        end

        @testset "scaffold_update respects ad = false" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Tooly")
                scaffold(dir; ad = false)
                res = scaffold_update(dir; ad = false)
                # No AD managed file appears in the scaffold_update manifest.
                @test !any(p -> occursin("workflows/ad.yaml", p), res.updated)
                @test !any(p -> occursin("test/ad/", p), res.updated)
                # The no-AD codecov is re-applied (not the AD-flagged one).
                @test !occursin("ad-forwarddiff",
                    read(joinpath(dir, "codecov.yml"), String))
            end
        end

        @testset "scaffold_generate makes a fresh package then scaffolds it" begin
            mktempdir() do base
                dir = joinpath(base, "FreshPkg")
                res = scaffold_generate(dir, "FreshPkg"; authors = ["Ada Lovelace"])
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

        @testset "scaffold_generate with ad = false opts out" begin
            mktempdir() do base
                dir = joinpath(base, "ToolPkg")
                scaffold_generate(dir, "ToolPkg"; authors = ["Ada"], ad = false)
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

                # First scaffold_update injects the marker block after the title and
                # leaves the body untouched.
                res = scaffold_update(dir; ad = false)
                @test res.readme === :injected
                txt = read(readme, String)
                @test occursin("<!-- badges:start -->", txt)
                @test occursin("<!-- badges:end -->", txt)
                @test occursin("Intro paragraph.", txt)
                @test occursin("## Usage", txt)
                # Parameterised from REPO/PACKAGE — no hardcoded owner/repo.
                @test occursin("EpiAware/Wombat.jl", txt)
                # CD's five-column badge table shape with the Downloads column.
                @test occursin("**Documentation**", txt)
                @test occursin("**Downloads**", txt)
                @test occursin("juliapkgstats.com/pkg/Wombat", txt)
                # Default docs badges point at the project-pages URL, not a
                # custom subdomain.
                @test occursin("epiaware.org/Wombat.jl/stable/", txt)
                @test occursin("epiaware.org/Wombat.jl/dev/", txt)
                @test !occursin("wombat.epiaware.org", txt)
                # ad = false: no per-backend AD badge rows.
                @test !occursin("AD ForwardDiff", txt)
                @test !occursin("ad-forwarddiff", txt)

                # A second scaffold_update is idempotent (refresh, no content change).
                before = read(readme, String)
                res2 = scaffold_update(dir; ad = false)
                @test res2.readme === :refreshed
                @test read(readme, String) == before

                # Editing only outside the markers is preserved; the block is
                # re-rendered in place without disturbing the surrounding text.
                edited = replace(read(readme, String),
                    "Intro paragraph." => "Edited intro.")
                write(readme, edited * "\n\nNew trailing section.\n")
                scaffold_update(dir; ad = false)
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
                scaffold_update(dir; ad = true)
                txt = read(joinpath(dir, "README.md"), String)
                # One aggregate AD status badge in Build Status (we ship a single
                # `ad.yaml`, not six per-backend workflows).
                @test occursin(
                    "[![AD](https://github.com/EpiAware/Numeric.jl/actions/" *
                    "workflows/ad.yaml/badge.svg?branch=main)]", txt)
                # The six per-backend coverage flag badges are kept.
                @test occursin("cov ForwardDiff", txt)
                @test occursin("flag=ad-forwarddiff", txt)
                @test occursin("cov Mooncake forward", txt)
                # No per-backend status badges (those URLs would 404).
                @test !occursin("AD ForwardDiff", txt)
                @test !occursin("workflows/ad-forwarddiff.yaml", txt)
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
                # The package-owned seed carries the body sections.
                @test occursin("## Why Fresh?", txt)
                @test occursin("## Getting started", txt)
                @test occursin("## Where to learn more", txt)
                # The BibTeX citation is no longer inlined in the seed — the
                # citation content lives in CITATION.cff (#67).
                @test !occursin("```bibtex", txt)
            end
        end

        @testset "scaffold appends the managed standard sections" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Fresh")
                res = scaffold(dir; ad = false)
                @test res.standard_sections === :injected
                txt = read(joinpath(dir, "README.md"), String)
                # The three managed sections sit between the markers.
                @test occursin("<!-- standard-sections:start -->", txt)
                @test occursin("<!-- standard-sections:end -->", txt)
                @test occursin("## Contributing", txt)
                @test occursin("## How to cite", txt)
                @test occursin("## Code of conduct", txt)
                # Contributing precedes the citation section (the order
                # STANDARD_README_SECTIONS requires).
                @test findfirst("## Contributing", txt)[1] <
                      findfirst("## How to cite", txt)[1]
                # How to cite points at CITATION.cff via its GitHub URL (a bare
                # relative `CITATION.cff` link fails Documenter linkcheck); CoC
                # at the org COC.
                @test occursin(
                    "[`CITATION.cff`](https://github.com/EpiAware/Fresh.jl" *
                    "/blob/main/CITATION.cff)", txt)
                @test occursin("CODE_OF_CONDUCT.md", txt)
                # Parameterised, no hardcoded owner/repo.
                @test occursin("EpiAware/Fresh.jl", txt)
                @test occursin("EpiAware/.github/blob/main/CODE_OF_CONDUCT.md",
                    txt)
                # ad = false and no DOI passed: no version-DOI line.
                @test !occursin("doi.org", txt)

                # A second scaffold_update refreshes the block in place, idempotently.
                before = read(joinpath(dir, "README.md"), String)
                ures = scaffold_update(dir; ad = false)
                @test ures.standard_sections === :refreshed
                @test read(joinpath(dir, "README.md"), String) == before
                @test count("<!-- standard-sections:start -->", before) == 1

                # An edit outside the markers survives the refresh.
                edited = replace(before, "## Why Fresh?" => "## Why Fresh?!")
                write(joinpath(dir, "README.md"),
                    edited * "\n\n## Extra package section\n")
                scaffold_update(dir; ad = false)
                final = read(joinpath(dir, "README.md"), String)
                @test occursin("## Why Fresh?!", final)
                @test occursin("## Extra package section", final)
                @test count("<!-- standard-sections:start -->", final) == 1
            end
        end

        @testset "standard-sections DOI line follows a persisted DOI" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Fresh")
                scaffold(dir; ad = false, doi = "10.5281/zenodo.18474651",
                    zenodo_badge = "1046740844")
                txt = read(joinpath(dir, "README.md"), String)
                # The How-to-cite section references the version DOI, recovered
                # from the README DOI badge on the next sync.
                @test occursin("https://doi.org/10.5281/zenodo.18474651", txt)
                scaffold_update(dir; ad = false)  # no doi re-passed -> read back
                @test occursin("https://doi.org/10.5281/zenodo.18474651",
                    read(joinpath(dir, "README.md"), String))
            end
        end

        @testset "standard sections skip a bespoke marker-less README" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Fresh")
                # An adopter with its own Contributing prose and no markers: the
                # managed block must not be injected (a wording migration is a
                # deliberate per-repo change, #67).
                body = "# Fresh\n\nIntro.\n\n## Contributing\n\nOur own prose.\n"
                write(joinpath(dir, "README.md"), body)
                res = scaffold_update(dir; ad = false)
                @test res.standard_sections === :skipped
                txt = read(joinpath(dir, "README.md"), String)
                @test occursin("Our own prose.", txt)
                @test !occursin("<!-- standard-sections:start -->", txt)
                @test count("## Contributing", txt) == 1
            end
        end

        @testset "CITATION.cff is package-owned and write-once (#67)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Fresh")
                res = scaffold(dir; ad = false)
                @test res.citation === :created
                cff = joinpath(dir, "CITATION.cff")
                @test isfile(cff)
                txt = read(cff, String)
                @test occursin("cff-version: 1.2.0", txt)
                @test occursin("title: \"Fresh.jl\"", txt)
                @test occursin("EpiAware/Fresh.jl", txt)
                # Authors threaded from Project.toml as CFF author entries.
                @test occursin("- name: \"Ada Lovelace\"", txt)
                # No placeholder DOI: the doi field is omitted until a real one
                # is known, never seeded as `XXXXXXX` (release-prep, #67).
                @test !occursin("XXXXXXX", txt)
                @test !occursin("doi:", txt)

                # When a DOI is known it is written as a real doi field.
                mktempdir() do d2
                    _fake_pkg(d2; name = "Cited")
                    scaffold(d2; ad = false, doi = "10.5281/zenodo.18474651",
                        zenodo_badge = "1046740844")
                    ctxt = read(joinpath(d2, "CITATION.cff"), String)
                    @test occursin("doi: \"10.5281/zenodo.18474651\"", ctxt)
                    @test !occursin("XXXXXXX", ctxt)
                end

                # A hand-edited CITATION.cff survives scaffold_update untouched.
                custom = txt * "\nversion: 1.2.3\n"
                write(cff, custom)
                ures = scaffold_update(dir; ad = false)
                @test ures.citation === :skipped
                @test read(cff, String) == custom

                # A second scaffold preserves it too.
                sres = scaffold(dir; ad = false)
                @test sres.citation === :preserved
                @test read(cff, String) == custom
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

                # A deliberate licence change must not be reverted by scaffold_update.
                custom = "Custom proprietary licence — all rights reserved.\n"
                write(lic, custom)
                ures = scaffold_update(dir)
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

        @testset "scaffold_generate writes the license too" begin
            mktempdir() do base
                dir = joinpath(base, "GenPkg")
                res = scaffold_generate(dir, "GenPkg"; authors = ["Ada"],
                    license = "Apache-2.0")
                @test res.license === :created
                @test occursin("Apache License",
                    read(joinpath(dir, "LICENSE"), String))
            end
        end

        @testset "scaffold_update preserves a Dependabot-bumped reusable ref" begin
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
                scaffold_update(dir)
                after = read(caller, String)
                # scaffold_update keeps the bumped ref (never reverts Dependabot) ...
                @test occursin(
                    "tests.yml@deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", after)
                # ... the rest of the caller is still re-applied managed, and a
                # second scaffold_update is idempotent on the preserved ref.
                scaffold_update(dir)
                @test read(caller, String) == after
            end
        end

        @testset "scaffold_update preserves a package-owned with: input (#73)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                caller = joinpath(dir, ".github/workflows/test.yaml")
                # Simulate a package pinning a Julia floor/matrix on the
                # managed `test`/`downgrade-compat` callers, exactly the
                # override #73 reports being silently reverted.
                before = read(caller, String)
                overridden = replace(before,
                    r"(uses: \S+/tests\.yml@\S+\r?\n)" =>
                        s"\1    with:\n      julia_versions: '[\"1.11\", \"1\"]'\n",
                    r"(uses: \S+/downgrade\.yml@\S+\r?\n)" =>
                        s"\1    with:\n      julia_version: '1.11'\n")
                @test overridden != before
                write(caller, overridden)
                scaffold_update(dir)
                after = read(caller, String)
                # The `with:` overrides survive the resync ...
                @test occursin("julia_versions: '[\"1.11\", \"1\"]'", after)
                @test occursin("julia_version: '1.11'", after)
                # ... the rest of the caller is still managed and re-applied,
                # and a second scaffold_update is idempotent on the preserved inputs.
                scaffold_update(dir)
                @test read(caller, String) == after
            end
        end

        @testset "scaffold_update merges a package key into a managed with: block (#183)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # `codecoverage.yaml`'s caller renders its own non-empty `with:`
                # block from the template, so a package key added alongside it
                # (ComposedDistributions' `coverage_directories`, counting the
                # package extension) used to be replaced wholesale on resync.
                caller = joinpath(dir, ".github/workflows/codecoverage.yaml")
                before = read(caller, String)
                @test occursin("with:", before)
                overridden = replace(before,
                    r"([ \t]+)(julia_version:[^\r\n]*\r?\n)" =>
                        s"\1\2\1coverage_directories: 'src,ext'\n")
                @test overridden != before
                write(caller, overridden)
                scaffold_update(dir)
                after = read(caller, String)
                # The package key survives ...
                @test occursin("coverage_directories: 'src,ext'", after)
                # ... and the kit-rendered keys in the same block are still
                # managed (the template's value wins on a key collision).
                @test occursin("julia_version:", after)
                # Idempotent on the merged block.
                scaffold_update(dir)
                @test read(caller, String) == after
            end
        end

        @testset "scaffold_update removes retired managed paths (#185)" begin
            using EpiAwarePackageTools: RETIRED_PATHS
            # The kit retires managed files (the `benchmark/comment/` env went
            # with #126/#157). An adopter kept the dead env because
            # `scaffold_update` only ever wrote files, never removed them.
            @test "benchmark/comment" in RETIRED_PATHS
            # No retired path is also a live template destination.
            dests = Set(t.dest for t in SCAFFOLD_TEMPLATES)
            for p in RETIRED_PATHS
                @test !(p in dests)
                @test !any(startswith(d, p * "/") for d in dests)
            end
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; benchmarks = true)
                stale = joinpath(dir, "benchmark/comment")
                mkpath(stale)
                write(joinpath(stale, "Project.toml"), "name = \"asv_comment\"\n")
                res = scaffold_update(dir; benchmarks = true)
                @test !ispath(stale)
                @test stale in res.removed
                # Nothing to remove on the next sync: idempotent, and a package
                # with no retired path reports none.
                res2 = scaffold_update(dir; benchmarks = true)
                @test isempty(res2.removed)
            end
        end

        @testset "managed files are writable after scaffold_update (#187)" begin
            # A `Pkg.add`ed kit lives in the read-only depot; copying a template
            # verbatim used to preserve mode 444, so pre-commit hooks failed
            # with a PermissionError on the emitted file.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # Simulate the read-only depot: mark an emitted managed file
                # read-only, then resync it as a `Pkg.add`ed kit would.
                fmt = joinpath(dir, ".JuliaFormatter.toml")
                chmod(fmt, 0o444)
                scaffold_update(dir)
                for f in (".JuliaFormatter.toml", ".gitattributes",
                    ".github/workflows/test.yaml", "Taskfile.yml")
                    path = joinpath(dir, f)
                    @test isfile(path)
                    @test filemode(path) & 0o200 != 0
                end
            end
        end

        @testset "reusable-workflow seed refs are single-sourced (#186)" begin
            using EpiAwarePackageTools: _DOWNGRADE_SEED_REF, _templates_dir
            # Every template pins the org reusables at the same seed commit, so
            # a fresh scaffold never starts life behind on some workflows and
            # current on others (#186: the seed had drifted from `.github` head
            # on some callers and not others).
            wf = joinpath(_templates_dir(), ".github", "workflows")
            pins = String[]
            for f in readdir(wf; join = true)
                for m in eachmatch(
                    r"/\.github/\.github/workflows/[^@\s]+@([0-9a-f]{40})",
                    read(f, String))
                    push!(pins, String(m.captures[1]))
                end
            end
            @test !isempty(pins)
            @test all(==(_DOWNGRADE_SEED_REF), pins)
        end

        @testset "docs_timeout sets the Documenter build timeout (#154)" begin
            using EpiAwarePackageTools: _docs_timeout_with
            # No timeout -> no `with:` block (reusable's own 45-min default).
            @test _docs_timeout_with(nothing) == ""
            @test occursin("timeout_minutes: 90", _docs_timeout_with(90))
            @test_throws ErrorException _docs_timeout_with(0)
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)  # default: no explicit timeout
                doc = joinpath(dir, ".github/workflows/document.yaml")
                @test !occursin("timeout_minutes", read(doc, String))
                # Setting docs_timeout renders the with: block on the caller.
                scaffold(dir; force = true, docs_timeout = 120)
                txt = read(doc, String)
                @test occursin("with:", txt)
                @test occursin("timeout_minutes: 120", txt)
                # A bare resync (never re-passes docs_timeout) preserves it via
                # the package-owned with:-block mechanism (#73).
                scaffold_update(dir)
                @test occursin("timeout_minutes: 120", read(doc, String))
            end
        end

        @testset "scaffold_update preserves a with: block documented by comments (#117)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                caller = joinpath(dir, ".github/workflows/test.yaml")
                # A package documents its Julia floor override with a rationale
                # comment between `uses:` and `with:` (as EpiAwarePrototype.jl
                # does). #117: comments between the two used to break the
                # `uses:`->`with:` adjacency and silently drop the override.
                before = read(caller, String)
                overridden = replace(before,
                    r"(uses: \S+/tests\.yml@\S+\r?\n)" =>
                        s"""\1    # Floor is Julia 1.11 (Turing 0.45 needs it).
    # Test the floor and the latest release.
    with:
      julia_versions: '["1.11", "1", "pre"]'
""")
                @test overridden != before
                write(caller, overridden)
                scaffold_update(dir)
                after = read(caller, String)
                # Both the override and its rationale comment survive the resync.
                @test occursin("julia_versions: '[\"1.11\", \"1\", \"pre\"]'",
                    after)
                @test occursin("Floor is Julia 1.11", after)
                # Idempotent on the preserved block.
                scaffold_update(dir)
                @test read(caller, String) == after
            end
        end

        @testset "downgrade-compat job opt-out survives sync (#121)" begin
            using EpiAwarePackageTools: _detect_downgrade_compat
            # Default: a fresh scaffold keeps the downgrade-compat job.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false)
                tf = joinpath(dir, ".github/workflows/test.yaml")
                @test occursin("downgrade-compat:", read(tf, String))
                @test occursin("downgrade.yml", read(tf, String))
                @test _detect_downgrade_compat(dir)
                # Exactly one trailing newline (pre-commit end-of-file-fixer).
                @test endswith(read(tf, String), "secret\n")
                @test !endswith(read(tf, String), "\n\n")
            end
            # Opt out: the job is not emitted, and a resync (no kwarg) keeps it
            # out instead of unconditionally reintroducing a permanently-red job.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false, downgrade_compat = false)
                tf = joinpath(dir, ".github/workflows/test.yaml")
                txt = read(tf, String)
                @test !occursin("downgrade-compat:", txt)
                @test !occursin("downgrade.yml", txt)
                # The test job itself is still present and well-formed.
                @test occursin("tests.yml", txt)
                @test endswith(txt, "secret\n")
                @test !endswith(txt, "\n\n")
                @test !_detect_downgrade_compat(dir)
                # The common maintenance call: no downgrade_compat kwarg.
                scaffold_update(dir; ad = false)
                @test !occursin("downgrade-compat:", read(tf, String))
                # Idempotent.
                after = read(tf, String)
                scaffold_update(dir; ad = false)
                @test read(tf, String) == after
                # The sync workflow bakes the opt-out into its own scaffold_update call.
                sync = read(
                    joinpath(dir, ".github/workflows/template-sync.yaml"),
                    String)
                @test occursin("downgrade_compat = false", sync)
            end
        end

        @testset "scheduled sync is managed; community health not shipped" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false)
                @test isfile(
                    joinpath(dir, ".github/workflows/template-sync.yaml"))
                # The org-level community health files come from
                # EpiAware/.github org-wide, so the kit must not ship them
                # (shipping them would shadow the org defaults and drift).
                for f in (".github/ISSUE_TEMPLATE/bug_report.md",
                    ".github/ISSUE_TEMPLATE/feature_request.md",
                    ".github/ISSUE_TEMPLATE/scientific_improvement.md",
                    ".github/ISSUE_TEMPLATE/config.yml",
                    ".github/PULL_REQUEST_TEMPLATE.md",
                    "CONTRIBUTING.md", "CODE_OF_CONDUCT.md", "SUPPORT.md")
                    @test !ispath(joinpath(dir, f))
                end
                # The sync workflow re-applies the standard with the package's
                # own `ad` + `benchmarks` + `downgrade_compat` values and is
                # fully substituted (fresh package keeps downgrade-compat).
                sync = read(
                    joinpath(dir, ".github/workflows/template-sync.yaml"),
                    String)
                @test occursin(
                    "scaffold_update(\".\"; ad = false, benchmarks = false, " *
                    "downgrade_compat = true)", sync)
                # The kit placeholders are resolved (GitHub Actions `${{ }}`
                # expressions legitimately remain).
                @test !occursin("{{AD}}", sync)
                @test !occursin("{{BENCHMARKS}}", sync)
                @test !occursin("{{DOWNGRADE_COMPAT}}", sync)
                @test !occursin("{{SYNC_INSTALL}}", sync)
                # It is managed: a scaffold_update re-applies it.
                res = scaffold_update(dir; ad = false)
                @test joinpath(dir, ".github/workflows/template-sync.yaml") in
                      res.updated
            end
        end

        @testset "root [workspace] stanza injected + preserved" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                res = scaffold(dir; ad = false)
                @test res.workspace === :injected
                proj = read(joinpath(dir, "Project.toml"), String)
                @test occursin("[workspace]", proj)
                @test occursin("projects = [\"test\", \"docs\"]", proj)
                # Injected once; a later scaffold_update preserves it (a package may
                # extend `projects`, so it is never reverted).
                res2 = scaffold_update(dir; ad = false)
                @test res2.workspace === :preserved
                @test read(joinpath(dir, "Project.toml"), String) == proj
            end
        end

        @testset "benchmark CI workflows present, no comment env" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; benchmarks = true)
                for f in (".github/workflows/benchmark.yaml",
                    ".github/workflows/benchmark-history.yaml")
                    @test isfile(joinpath(dir, f))
                end
                # The unwired asv_comment env is not scaffolded (#126): the PR
                # comment comes from the BenchmarkTools `benchmark/compare.jl`
                # path, and the history workflow renders via benchpkg directly.
                @test !ispath(joinpath(dir, "benchmark/comment"))
                bench = read(joinpath(dir, ".github/workflows/benchmark.yaml"),
                    String)
                # `pull_request` (not `pull_request_target`): the comparison
                # runs the PR's own code, keeping the comment-posting token
                # scoped to same-repo PRs (#821 gap 1).
                @test occursin("on:\n  pull_request:", bench)
                @test !occursin("pull_request_target:", bench)
                # Triggers on every path that affects performance: sources, the
                # extensions, the benchmark suite, and the AD fixtures.
                for p in ("'src/**'", "'ext/**'", "'benchmark/**'",
                    "'test/ADFixtures/**'")
                    @test occursin(p, bench)
                end
                # Each revision (PR head vs main base) is benchmarked in its
                # own job/runner, so a single runner never loads two heavy AD
                # stacks (e.g. Enzyme + Mooncake) at once.
                @test occursin("  benchmark:", bench)
                @test occursin("  compare:", bench)
                @test occursin("matrix.name", bench)
                @test occursin("github.event.pull_request.head.sha", bench)
                @test occursin("github.event.pull_request.base.sha", bench)
                # The compare job runs the scaffolded, kit-backed script.
                @test occursin("benchmark/compare.jl", bench)
                # No kit placeholder remains (GitHub `${{ }}` expressions stay).
                @test !occursin(r"\{\{[A-Z_]+\}\}", bench)
                # benchmark-history resolves an unregistered package via --url
                # and bootstraps before the first tag without a leading-comma
                # revs list benchpkg rejects (#125).
                hist = read(
                    joinpath(dir, ".github/workflows/benchmark-history.yaml"),
                    String)
                @test occursin(
                    "--url=\"https://github.com/\${{ github.repository }}\"",
                    hist)
                @test occursin("revs=\${GITHUB_SHA}", hist)
                @test !occursin(r"\{\{[A-Z_]+\}\}", hist)
            end
        end

        @testset "version automation workflows + action present" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; reviewer = "octocat")
                for f in (".github/workflows/auto-version-increment.yaml",
                    ".github/workflows/version-on-demand.yaml",
                    ".github/actions/increment-version/action.yaml")
                    @test isfile(joinpath(dir, f))
                end
                act = read(
                    joinpath(dir, ".github/actions/increment-version/action.yaml"),
                    String)
                # The assignee default resolves to the reviewer handle (never a
                # hardcoded person or the bare org).
                @test occursin("octocat", act)
                @test !occursin("seabbs", act)
                # No kit placeholder remains (GitHub `${{ }}` expressions stay).
                @test !occursin(r"\{\{[A-Z_]+\}\}", act)
            end
        end

        @testset "docs build reproduces CD (Literate + citations + helpers)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; benchmarks = true)
                for f in ("docs/run_literate_tutorial.jl", "docs/docs_config.jl",
                    "docs/release_notes_header.jl")
                    @test isfile(joinpath(dir, f))
                end
                # The thin make.jl forwards the package-owned config into
                # build_docs; the Literate / citations / benchmark machinery
                # lives in the kit (tested in the DocsBuild testitem).
                mk = read(joinpath(dir, "docs/make.jl"), String)
                @test occursin("build_docs(", mk)
                # The package-owned config is wired in via a guarded include so
                # a missing file falls back to defaults rather than erroring
                # (#163); both files are still referenced.
                @test occursin("(\"pages.jl\", \"docs_config.jl\")", mk)
                @test occursin("isfile(joinpath(@__DIR__, _f))", mk)
                @test occursin("benchmark_page", mk)
                @test !occursin("{{", mk)
                # The docs env still carries the citation + Literate deps (the
                # kit lazy-loads them from the package's docs environment).
                dp = read(joinpath(dir, "docs/Project.toml"), String)
                @test occursin("DocumenterCitations", dp)
                @test occursin("Literate", dp)
                # The release-notes header is parameterised on the repo.
                rh = read(joinpath(dir, "docs/release_notes_header.jl"), String)
                @test occursin("EpiAware/Wombat.jl", rh)
                @test !occursin("{{", rh)
                # The benchmark-history page: a package-owned prose hook, a nav
                # entry, and the managed make.jl generation + config flag.
                @test isfile(joinpath(dir, "docs/benchmarks.md"))
                bh = read(joinpath(dir, "docs/benchmarks.md"), String)
                @test occursin("Wombat", bh)
                @test !occursin("{{", bh)
                @test occursin("benchmarks.md", read(
                    joinpath(dir, "docs/pages.jl"), String))
                # The home page strip is package-config driven (no hardcoded
                # named strip in the managed build), and the benchmark page is
                # config-gated.
                dc = read(joinpath(dir, "docs/docs_config.jl"), String)
                @test occursin("BENCHMARK_PAGE", dc)
                @test occursin("INDEX_STRIP_SECTIONS", dc)
                @test !occursin("README_STRIP_TABLES", dc)
            end
        end

        @testset "test env carries bounded [compat]" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                tp = read(joinpath(dir, "test/Project.toml"), String)
                @test occursin("[compat]", tp)
                @test occursin("Aqua = \"0.8\"", tp)
                @test occursin("ForwardDiff =", tp)
                # The path/source-pinned packages carry no compat bound: the
                # package + kit are absent from the [compat] section.
                compat = tp[first(findfirst("[compat]", tp)):end]
                compat = split(compat, "[sources]")[1]
                @test !occursin("Wombat", compat)
                @test !occursin("EpiAwarePackageTools", compat)
            end
            mktempdir() do dir
                _fake_pkg(dir; name = "Tooly")
                scaffold(dir; ad = false)
                tp = read(joinpath(dir, "test/Project.toml"), String)
                @test occursin("[compat]", tp)
                @test occursin("Aqua = \"0.8\"", tp)
                # No AD deps in the no-AD compat block.
                @test !occursin("ForwardDiff", tp)
                @test !occursin("DifferentiationInterface", tp)
            end
        end

        @testset "docstrings template shipped + wired by scaffold_generate" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false)
                # The @template conventions ship as a package-owned src file.
                ds = joinpath(dir, "src/docstrings.jl")
                @test isfile(ds)
                txt = read(ds, String)
                @test occursin("@template", txt)
                @test occursin("TYPEDSIGNATURES", txt)
                # The `using` lives in the module file, not this
                # package-owned, write-once template (#105). (A worked
                # example inside the header comment mentions the phrase, so
                # match a genuine top-level statement, not any occurrence.)
                @test !occursin(r"(?m)^using DocStringExtensions", txt)
                # CODEOWNERS is managed; with no reviewer handle it ships a
                # commented placeholder (a bare org is never a code owner).
                co = read(joinpath(dir, ".github/CODEOWNERS"), String)
                @test occursin("MANAGED by EpiAwarePackageTools", co)
                @test occursin("# * @", co)
                @test !occursin("{{", co)
            end
            mktempdir() do base
                dir = joinpath(base, "FreshPkg")
                scaffold_generate(dir, "FreshPkg"; authors = ["Ada"], ad = false)
                # scaffold_generate wires the dep + include automatically.
                proj = read(joinpath(dir, "Project.toml"), String)
                @test occursin("DocStringExtensions", proj)
                mod = read(joinpath(dir, "src/FreshPkg.jl"), String)
                @test occursin("include(\"docstrings.jl\")", mod)
                @test isfile(joinpath(dir, "src/docstrings.jl"))
                # scaffold_generate wires the `using` into the module's own import
                # block, before the docstrings.jl include (#105).
                @test occursin("using DocStringExtensions", mod)
                using_idx = findfirst("using DocStringExtensions", mod)
                include_idx = findfirst("include(\"docstrings.jl\")", mod)
                @test first(using_idx) < first(include_idx)
                ds_txt = read(joinpath(dir, "src/docstrings.jl"), String)
                @test !occursin(r"(?m)^using DocStringExtensions", ds_txt)
            end
        end

        @testset "generated environments actually resolve" begin
            mktempdir() do base
                dir = joinpath(base, "EnvPkg")
                scaffold_generate(dir, "EnvPkg"; authors = ["Ada Lovelace"])

                # Every emitted Project.toml must round-trip through a real
                # TOML parser: a duplicate key, an unbalanced `[sources]`
                # table, or a malformed compat string passes every
                # `occursin`-based check above but not this.
                proj_files = String[]
                for (root, _, files) in walkdir(dir)
                    "Project.toml" in files &&
                        push!(proj_files, joinpath(root, "Project.toml"))
                end
                @test !isempty(proj_files)
                for f in proj_files
                    parsed = try
                        Pkg.TOML.parsefile(f)
                    catch err
                        err
                    end
                    @test parsed isa AbstractDict
                end

                # Instantiating the generated environments needs Pkg
                # `[sources]` (the path/git dep pins), which only exists on
                # Julia >= 1.11. On the LTS (1.10) `[sources]` is ignored, so
                # these envs cannot resolve their local/unregistered pins at
                # all — the same reason an adopter's full env needs >= 1.11
                # until the kit is registered. The TOML round-trip above still
                # runs on every version.
                if VERSION >= v"1.11"
                    # The ADFixtures registry skeleton carries no
                    # EpiAwarePackageTools dependency at all, so instantiating it
                    # exercises nothing beyond the generated package + registry
                    # deps already primed by the kit's own test run.
                    for env in ("test/ADFixtures",)
                        @test _env_instantiates(joinpath(dir, env))
                    end

                    # The remaining envs pin EpiAwarePackageTools by git
                    # (`rev = "main"`) so a fresh adopter resolves out of the
                    # box; that network fetch is an extra dependency the kit's
                    # own tests should not take on. The `docs` env carries the
                    # same git pin now that `make.jl` uses the kit (#115). Patch
                    # the pin to the local kit checkout instead — the same switch
                    # the template comments themselves suggest for kit
                    # development — so the rest of each env (every other
                    # dep/compat bound) is proven to resolve hermetically.
                    # Forward-slash the absolute path: a backslashed Windows
                    # path (`C:\...`) in a TOML basic string is an invalid
                    # escape sequence, and Julia/Pkg resolve forward slashes on
                    # every platform.
                    kit_root = replace(
                        pkgdir(EpiAwarePackageTools), '\\' => '/')
                    kit_pin = r"EpiAwarePackageTools = \{url = \"[^\"]+\", " *
                              r"rev = \"main\"\}"
                    for env in ("test", "test/jet", "docs")
                        proj = joinpath(dir, env, "Project.toml")
                        txt = read(proj, String)
                        patched = replace(txt,
                            kit_pin =>
                                "EpiAwarePackageTools = {path = \"" *
                                kit_root * "\"}")
                        @test patched != txt
                        write(proj, patched)
                        @test _env_instantiates(joinpath(dir, env))
                    end
                end
            end
        end

        @testset "Register.yml is managed and self-identifying" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                reg = joinpath(dir, ".github/workflows/Register.yml")
                @test isfile(reg)
                txt = read(reg, String)
                @test occursin("MANAGED by EpiAwarePackageTools.scaffold", txt)
                @test occursin("workflow_dispatch", txt)
                @test occursin("issue_comment", txt)
                @test occursin("@JuliaRegistrator register", txt)
                # No kit `{{PLACEHOLDER}}`s remain (the `${{ ... }}` GitHub
                # Actions expression syntax is not one).
                @test !occursin(r"\{\{[A-Z_]+\}\}", txt)
                # The job needs `contents: write` (the commit-comment API
                # call that triggers JuliaRegistrator) and `issues: write`
                # (the permission-denied reaction). A `permissions:` block
                # zeroes every unlisted scope, so both must be listed
                # explicitly or the workflow 403s on every real run.
                @test occursin(r"(?m)^\s*contents:\s*write\s*$", txt)
                @test occursin(r"(?m)^\s*issues:\s*write\s*$", txt)
                @test !occursin(r"(?m)^\s*contents:\s*read\s*$", txt)
                # Managed: `scaffold_update` re-applies it (not merely preserved).
                res = scaffold_update(dir)
                @test joinpath(dir, ".github/workflows/Register.yml") in
                      res.updated
            end
        end

        @testset "NEWS.md is package-owned (write-once)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                res = scaffold(dir)
                news = joinpath(dir, "NEWS.md")
                @test isfile(news)
                @test news in res.created
                @test occursin("Unreleased", read(news, String))
                # Package-owned: a caller's own entry survives `scaffold_update`.
                write(news, "## v1.0.0\n\nFirst release.\n")
                res2 = scaffold_update(dir)
                @test news ∉ res2.updated
                @test read(news, String) == "## v1.0.0\n\nFirst release.\n"
            end
        end

        @testset "logo.svg is package-owned and substituted" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                res = scaffold(dir)
                logo = joinpath(dir, "docs/src/assets/logo.svg")
                @test isfile(logo)
                @test logo in res.created
                txt = read(logo, String)
                @test occursin("Wombat", txt)
                @test !occursin("{{", txt)
                # Package-owned: a real logo the caller drops in survives
                # `scaffold_update`.
                write(logo, "<svg><!-- real logo --></svg>\n")
                scaffold_update(dir)
                @test occursin("real logo", read(logo, String))
            end
        end

        @testset "README logo title" begin
            @testset "no logo file: title is left alone" begin
                mktempdir() do dir
                    _fake_pkg(dir; name = "Wombat")
                    write(joinpath(dir, "README.md"), "# Wombat\n\nbody\n")
                    # `scaffold_update` never writes package-owned files (including the
                    # logo), so this exercises the no-logo-yet path directly.
                    res = scaffold_update(dir)
                    @test res.logo === :skipped
                    txt = read(joinpath(dir, "README.md"), String)
                    @test !occursin("<img", txt)
                end
            end

            @testset "logo present: title gets the img tag once" begin
                mktempdir() do dir
                    _fake_pkg(dir; name = "Wombat")
                    res = scaffold(dir)
                    @test res.logo === :injected
                    txt = read(joinpath(dir, "README.md"), String)
                    @test occursin(
                        "# Wombat <img src=\"docs/src/assets/logo.svg\"", txt)
                    # Idempotent: re-scaffolding does not duplicate the tag.
                    res2 = scaffold(dir)
                    @test res2.logo === :preserved
                    txt2 = read(joinpath(dir, "README.md"), String)
                    @test count("<img", txt2) == 1
                end
            end

            @testset "custom title tag is never overwritten" begin
                mktempdir() do dir
                    _fake_pkg(dir; name = "Wombat")
                    mkpath(joinpath(dir, "docs/src/assets"))
                    write(joinpath(dir, "docs/src/assets/logo.svg"),
                        "<svg></svg>\n")
                    write(joinpath(dir, "README.md"),
                        "# Wombat <img src=\"docs/src/assets/logo.svg\" " *
                        "width=\"50\">\n\nbody\n")
                    res = scaffold_update(dir)
                    @test res.logo === :preserved
                    txt = read(joinpath(dir, "README.md"), String)
                    @test occursin("width=\"50\"", txt)
                end
            end
        end
    end # @testset "scaffold + scaffold_update"
end # @testitem "scaffold + scaffold_update (logic)"
