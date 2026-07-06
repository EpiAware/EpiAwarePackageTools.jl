# Scaffolding into a fresh temp package writes every managed standard file plus
# the package-owned skeletons; `update` re-applies only the managed files and is
# idempotent, never touching package-owned files.

@testitem "scaffold + update (logic)" begin
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
            run(pipeline(
                `$exe --startup-file=no --history-file=no --project=$env
                 -e "using Pkg; Pkg.instantiate()"`;
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

    @testset "scaffold + update" begin
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

        @testset "update preserves docs_subdomain without re-passing it (#123)" begin
            # A subdomain-hosted package is not reverted to project-pages when a
            # resync (the scheduled template-sync's `update`) omits the kwarg.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; docs_subdomain = true)
                mk = joinpath(dir, "docs/make.jl")
                @test occursin("deploy_url = \"wombat.epiaware.org\"",
                    read(mk, String))
                # The common maintenance call: no docs_subdomain kwarg.
                update(dir)
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
                update(dir)
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
                # re-run update — the managed .gitignore must follow the new path.
                cfg = joinpath(dir, "docs", "docs_config.jl")
                write(cfg,
                    replace(read(cfg, String),
                        "const TUTORIALS_SUBDIR = " *
                        "joinpath(\"getting-started\", \"tutorials\")" => "const TUTORIALS_SUBDIR = \"how-to/walkthroughs\""))
                update(dir)
                txt = read(joinpath(dir, ".gitignore"), String)
                @test occursin("docs/src/how-to/walkthroughs/*.md", txt)
                @test !occursin(
                    "docs/src/getting-started/tutorials/*.md", txt)
            end
        end

        @testset ".gitignore package-owned tail survives update (#65)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                res = scaffold(dir)
                @test res.gitignore === :created
                gi = joinpath(dir, ".gitignore")
                # A package adds its own ignore rule after the managed block.
                keep = "!docs/src/getting-started/tutorials/data/**"
                write(gi, read(gi, String) * "\n# Keep bundled data.\n" * keep * "\n")
                res2 = update(dir)
                @test res2.gitignore === :refreshed
                txt = read(gi, String)
                @test occursin(keep, txt)
                # The managed block is still correctly refreshed alongside it.
                @test occursin("Manifest.toml", txt)
                # A further no-op update changes nothing (idempotent with a
                # package-owned tail present).
                before = read(gi, String)
                res3 = update(dir)
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
                res = update(dir)
                @test res.gitignore === :injected
                txt = read(joinpath(dir, ".gitignore"), String)
                @test occursin(keep, txt)
                @test occursin("# managed:start", txt)
                @test occursin("# managed:end", txt)
                # Idempotent once markers exist.
                before = txt
                update(dir)
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
                scaffold(dir; benchmarks = true)

                # Mutate a package-owned file and a managed file to simulate drift.
                owned = joinpath(dir, "test/package/qa_config.jl")
                managed = joinpath(dir, "test/package/quality.jl")
                owned_marker = "# PACKAGE EDIT — keep me\n"
                write(owned, owned_marker * read(owned, String))
                write(managed, "# drifted\n")

                res = update(dir; benchmarks = true)
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
                update(dir; benchmarks = true)
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
                update(dir)
                update(dir)

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

            @testset "update() refreshes an already-adopted package" begin
                # A package scaffolds against the current backend set, then a
                # 7th backend is added and `update()` is run again — the
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
                        update(dir)
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
                # The seeded body follows CD's section structure.
                @test occursin("## Why Fresh?", txt)
                @test occursin("## Contributing", txt)
                @test occursin("## Code of conduct", txt)
                @test occursin("CODE_OF_CONDUCT.md", txt)
                # The seeded "Supporting and citing" carries a BibTeX block +
                # DOI placeholder (package-owned citation content, #67/#80).
                @test occursin("## Supporting and citing", txt)
                @test occursin("```bibtex", txt)
                @test occursin("@software{Fresh_jl", txt)
                @test occursin("title        = {Fresh.jl}", txt)
                @test occursin("10.5281/zenodo", txt)
                # Authors are threaded from Project.toml into the BibTeX entry.
                @test occursin("Ada Lovelace", txt)
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

                # A deliberate licence change must not be reverted by update.
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

        @testset "update preserves a package-owned with: input (#73)" begin
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
                update(dir)
                after = read(caller, String)
                # The `with:` overrides survive the resync ...
                @test occursin("julia_versions: '[\"1.11\", \"1\"]'", after)
                @test occursin("julia_version: '1.11'", after)
                # ... the rest of the caller is still managed and re-applied,
                # and a second update is idempotent on the preserved inputs.
                update(dir)
                @test read(caller, String) == after
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
                # own `ad` + `benchmarks` values and is fully substituted.
                sync = read(
                    joinpath(dir, ".github/workflows/template-sync.yaml"),
                    String)
                @test occursin(
                    "update(\".\"; ad = false, benchmarks = false)", sync)
                # The kit placeholders are resolved (GitHub Actions `${{ }}`
                # expressions legitimately remain).
                @test !occursin("{{AD}}", sync)
                @test !occursin("{{BENCHMARKS}}", sync)
                @test !occursin("{{SYNC_INSTALL}}", sync)
                # It is managed: an update re-applies it.
                res = update(dir; ad = false)
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
                # Injected once; a later update preserves it (a package may
                # extend `projects`, so it is never reverted).
                res2 = update(dir; ad = false)
                @test res2.workspace === :preserved
                @test read(joinpath(dir, "Project.toml"), String) == proj
            end
        end

        @testset "benchmark CI workflows + comment env present" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; benchmarks = true)
                for f in (".github/workflows/benchmark.yaml",
                    ".github/workflows/benchmark-history.yaml",
                    "benchmark/comment/comment.jl",
                    "benchmark/comment/Project.toml")
                    @test isfile(joinpath(dir, f))
                end
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
                # The comment script uses the shared kit harness.
                cj = read(joinpath(dir, "benchmark/comment/comment.jl"), String)
                @test occursin("EpiAwarePackageTools.Benchmarks", cj)
                cp = read(joinpath(dir, "benchmark/comment/Project.toml"),
                    String)
                @test occursin("JSON3", cp)
                @test occursin("EpiAwarePackageTools", cp)
                @test occursin("Wombat = \"00000000", cp)
                @test !occursin("{{", cp)
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
                # The hardcoded `seabbs` assignee is replaced by {{REVIEWER}}.
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
                @test occursin("include(\"pages.jl\")", mk)
                @test occursin("include(\"docs_config.jl\")", mk)
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
                generate(dir, "FreshPkg"; authors = ["Ada"], ad = false)
                # generate wires the dep + include automatically.
                proj = read(joinpath(dir, "Project.toml"), String)
                @test occursin("DocStringExtensions", proj)
                mod = read(joinpath(dir, "src/FreshPkg.jl"), String)
                @test occursin("include(\"docstrings.jl\")", mod)
                @test isfile(joinpath(dir, "src/docstrings.jl"))
                # generate wires the `using` into the module's own import
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
                generate(dir, "EnvPkg"; authors = ["Ada Lovelace"])

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
                    # Two fully local environments carry no EpiAwarePackageTools
                    # dependency at all, so instantiating them exercises nothing
                    # beyond the generated package + registry deps already
                    # primed by the kit's own test run.
                    for env in ("test/ADFixtures", "docs")
                        @test _env_instantiates(joinpath(dir, env))
                    end

                    # The remaining envs pin EpiAwarePackageTools by git
                    # (`rev = "main"`) so a fresh adopter resolves out of the
                    # box; that network fetch is an extra dependency the kit's
                    # own tests should not take on. Patch the pin to the local
                    # kit checkout instead — the same switch the template
                    # comments themselves suggest for kit development — so the
                    # rest of each env (every other dep/compat bound) is proven
                    # to resolve hermetically.
                    # Forward-slash the absolute path: a backslashed Windows
                    # path (`C:\...`) in a TOML basic string is an invalid
                    # escape sequence, and Julia/Pkg resolve forward slashes on
                    # every platform.
                    kit_root = replace(
                        pkgdir(EpiAwarePackageTools), '\\' => '/')
                    kit_pin = r"EpiAwarePackageTools = \{url = \"[^\"]+\", " *
                              r"rev = \"main\"\}"
                    for env in ("test", "test/jet")
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
                # Managed: `update` re-applies it (not merely preserved).
                res = update(dir)
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
                # Package-owned: a caller's own entry survives `update`.
                write(news, "## v1.0.0\n\nFirst release.\n")
                res2 = update(dir)
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
                # `update`.
                write(logo, "<svg><!-- real logo --></svg>\n")
                update(dir)
                @test occursin("real logo", read(logo, String))
            end
        end

        @testset "README logo title" begin
            @testset "no logo file: title is left alone" begin
                mktempdir() do dir
                    _fake_pkg(dir; name = "Wombat")
                    write(joinpath(dir, "README.md"), "# Wombat\n\nbody\n")
                    # `update` never writes package-owned files (including the
                    # logo), so this exercises the no-logo-yet path directly.
                    res = update(dir)
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
                    res = update(dir)
                    @test res.logo === :preserved
                    txt = read(joinpath(dir, "README.md"), String)
                    @test occursin("width=\"50\"", txt)
                end
            end
        end
    end # @testset "scaffold + update"
end # @testitem "scaffold + update (logic)"
