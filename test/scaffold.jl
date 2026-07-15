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

    # Absolute native path of a scaffold destination, mirroring the scaffold's
    # own `_dest_path`. Destinations are written posix-style (`docs/make.jl`),
    # so `joinpath(dir, "docs/make.jl")` keeps the inner `/` and is a mixed
    # separator path on Windows, which never compares equal to the native path
    # the scaffold results report. Splitting on `/` gives the platform
    # separator, so these assertions mean the same thing on every OS.
    _dest(dir, rel) = joinpath(dir, split(rel, '/')...)

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
                test_yaml = read(_dest(dir, ".github/workflows/test.yaml"),
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
                    ".github/workflows/registrability.yaml",
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
                tpr = read(_dest(dir, ".github/workflows/try-this-pr.yaml"),
                    String)
                @test occursin("github.com/EpiAware/FakePkg.jl", tpr)
                @test occursin("using FakePkg", tpr)
                # No kit placeholder remains (GitHub `${{ }}` expressions stay).
                @test !occursin(r"\{\{[A-Z_]+\}\}", tpr)
                coc = read(_dest(dir, ".github/workflows/cancel-on-close.yaml"),
                    String)
                @test occursin(
                    "EpiAware/.github/.github/workflows/cancel-on-close.yml", coc)
                # The registrability caller invokes the org reusable, pins it
                # by SHA (like the other callers, so Dependabot can bump it),
                # and triggers only on a Project.toml change / dispatch / main.
                reg = read(
                    joinpath(dir, ".github/workflows/registrability.yaml"),
                    String)
                @test occursin(
                    "EpiAware/.github/.github/workflows/registrability.yml@",
                    reg)
                @test occursin("workflow_dispatch", reg)
                @test occursin("'Project.toml'", reg)
                @test !occursin("{{ORG}}", reg)
                # Coverage hard-fails on upload error (org policy: red on a
                # missing CODECOV_TOKEN as a loud reminder to add it).
                cov_caller = read(
                    _dest(dir, ".github/workflows/codecoverage.yaml"), String)
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
                pc = read(_dest(dir, ".github/workflows/pre-commit.yaml"),
                    String)
                @test occursin("juliaformatter_version: '$ver'", pc)
                # No kit placeholder remains (GitHub `${{ }}` expressions stay).
                @test !occursin(r"\{\{[A-Z_]+\}\}", pc)
                # The local pre-commit hook `rev` and the isolated formatter
                # env compat pin agree with the same single source.
                cfg = read(joinpath(dir, ".pre-commit-config.yaml"), String)
                @test occursin("rev: v$ver", cfg)
                fmt = read(_dest(dir, "test/formatter/Project.toml"), String)
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
                adyaml = read(_dest(dir, ".github/workflows/ad.yaml"), String)
                @test occursin("EpiAware/.github/.github/workflows/ad.yml", adyaml)
                # Docs-only changes skip the heavy 6-backend AD sweep on both
                # push and pull_request (a mixed docs+src PR still runs it).
                @test count("paths-ignore:", adyaml) == 2
                @test occursin("'docs/**'", adyaml)
                @test occursin("'**/*.md'", adyaml)
                @test occursin("'LICENSE'", adyaml)

                # The seeded ADFixtures registry and the AD env agree on its UUID.
                reg = read(_dest(dir, "test/ADFixtures/Project.toml"), String)
                adenv = read(_dest(dir, "test/ad/Project.toml"), String)
                m = match(r"uuid = \"([^\"]+)\"", reg)
                @test m !== nothing
                @test occursin("ADFixtures = \"$(m.captures[1])\"", adenv)
                @test !occursin("{{ADFIXTURES_UUID}}", reg)
                # The jet env references the package by name + UUID.
                jetenv = read(_dest(dir, "test/jet/Project.toml"), String)
                @test occursin("Wombat = \"00000000-0000-0000-0000-000000000000\"",
                    jetenv)
            end
        end

        @testset "main/AD test-env templates are is_kit-aware, like the JET env (#60)" begin
            # `test/Project.toml` (+ `.noad.toml`) and `test/ad/Project.toml`
            # hardcoded an EpiAwarePackageTools `[deps]`/`[sources]` entry with
            # no `is_kit` switch, unlike the JET env (`KIT_DEP_LINE`/
            # `KIT_SOURCE_LINE`). Scaffolding the kit onto itself would then
            # render `EpiAwarePackageTools = "<uuid>"` twice in `[deps]` (once
            # from the hardcoded line, once from `{{PACKAGE}}`) — a duplicate
            # TOML key — and a self-referential git `[sources]` pin clashing
            # with the package's own `{path = ...}` entry. These templates now
            # share the same `is_kit` placeholders as the JET env.
            mktempdir() do dir
                _fake_pkg(dir; name = EpiAwarePackageTools.KIT_NAME)
                scaffold(dir; ad = true)
                for f in ("test/Project.toml", "test/ad/Project.toml")
                    path = joinpath(dir, f)
                    txt = read(path, String)
                    @test !occursin("rev = \"main\"", txt)
                    @test !occursin("{{KIT_DEP_LINE}}", txt)
                    @test !occursin("{{KIT_SOURCE_LINE}}", txt)
                    # Valid TOML: a duplicate `EpiAwarePackageTools` [deps] key
                    # (the pre-#60 bug — the hardcoded line plus `{{PACKAGE}}`
                    # both resolving to the kit's own name) is a parse error.
                    parsed = try
                        Pkg.TOML.parsefile(path)
                    catch err
                        err
                    end
                    @test parsed isa AbstractDict
                end
            end
            # A normal (non-kit) adopter is unaffected: it still gets the kit
            # dep + git `[sources]` pin in both env variants.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = true)
                for f in ("test/Project.toml", "test/ad/Project.toml")
                    path = joinpath(dir, f)
                    txt = read(path, String)
                    @test occursin("rev = \"main\"", txt)
                    @test occursin(
                        "$(EpiAwarePackageTools.KIT_NAME) = " *
                        "\"$(EpiAwarePackageTools.KIT_UUID)\"", txt)
                    @test Pkg.TOML.parsefile(path) isa AbstractDict
                end
            end
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false)
                path = _dest(dir, "test/Project.toml")
                txt = read(path, String)
                @test occursin("rev = \"main\"", txt)
                @test Pkg.TOML.parsefile(path) isa AbstractDict
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
                    "docs/src/components/stargazers.data.ts",                 # The authored quickstart, distinct from the README home page.
                    "docs/src/getting-started/index.md")
                    @test isfile(joinpath(dir, f))
                end
                # The stars widget targets the adopting repo (no owner/repo
                # hardcoded) and its theme + package.json wiring is present.
                star = read(_dest(dir, "docs/src/components/StarUs.vue"),
                    String)
                @test occursin("github.com/EpiAware/Wombat.jl", star)
                @test !occursin("{{REPO}}", star)
                data_ts = read(
                    _dest(dir, "docs/src/components/stargazers.data.ts"),
                    String)
                @test occursin("EpiAware/Wombat.jl", data_ts)
                theme = read(
                    _dest(dir, "docs/src/.vitepress/theme/index.ts"), String)
                @test occursin("StarUs", theme)
                @test occursin("d3-format",
                    read(_dest(dir, "docs/package.json"), String))
                # The quickstart is authored, package-owned, and substituted
                # (no unresolved placeholders). It does not repeat the install
                # instructions the README-derived home page already carries
                # (#194), and it points at the kit's site rather than a seeded
                # copy of the kit's docs.
                gs = read(_dest(dir, "docs/src/getting-started/index.md"),
                    String)
                @test occursin("@id getting-started", gs)
                @test occursin("using Wombat", gs)
                @test !occursin("Pkg.add(\"Wombat\")", gs)
                @test !occursin("## Installation", gs)
                @test occursin("epiawarepackagetools.epiaware.org", gs)
                @test !occursin("{{", gs)
                # The nav wires the getting-started section into pages.jl.
                pgs = read(_dest(dir, "docs/pages.jl"), String)
                @test occursin("getting-started/index.md", pgs)
                # Kit meta-docs (customising the generated site, infrastructure
                # and template sync) describe the kit, not the adopting package,
                # so they are neither seeded nor navigated to (#194).
                for f in ("docs/src/getting-started/customising.md",
                    "docs/src/getting-started/infrastructure.md")
                    @test !ispath(joinpath(dir, f))
                end
                @test !occursin("customising.md", pgs)
                @test !occursin("infrastructure.md", pgs)
                # make.jl is a thin caller into the kit's DocsBuild machinery
                # (DocumenterVitepress/Literate/makedocs all live in the kit
                # now), and is fully substituted.
                mk = read(_dest(dir, "docs/make.jl"), String)
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
                dp = read(_dest(dir, "docs/Project.toml"), String)
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
                cfg = read(_dest(dir, "docs/src/.vitepress/config.mts"),
                    String)
                @test occursin("REPLACE_ME_DOCUMENTER_VITEPRESS", cfg)
                @test occursin("github.com/EpiAware/Wombat.jl", cfg)
                @test !occursin("{{", cfg)
                # The node deps pin vitepress + DocumenterVitepress plugins.
                pj = read(_dest(dir, "docs/package.json"), String)
                @test occursin("vitepress", pj)
            end
        end

        @testset "every seeded nav entry resolves to a page (#194)" begin
            # The nav used to point at `getting-started/customising.md`, a page
            # the scaffold never wrote: a fresh adopter's docs build started
            # with a dead nav entry and a dangling `@ref`. Hold the seeded nav
            # to pages the package writes or `make.jl` generates, for both the
            # AD and no-AD navs.
            generated = ["index.md", "lib/public.md", "lib/internals.md",
                "benchmarks.md"]
            for ad in (true, false)
                mktempdir() do dir
                    _fake_pkg(dir; name = "Wombat")
                    scaffold(dir; ad = ad, benchmarks = true)
                    src = joinpath(dir, "docs", "src")
                    pgs = read(_dest(dir, "docs/pages.jl"), String)
                    targets = [String(m.captures[1])
                               for m in eachmatch(r"\"([^\"]+\.md)\"", pgs)]
                    @test !isempty(targets)
                    for t in targets
                        t in generated && continue
                        # A Literate page is written as its `.jl` source and
                        # rendered to `.md` at build time.
                        @test isfile(joinpath(src, t)) ||
                              isfile(joinpath(src, replace(t, r"\.md$" => ".jl")))
                    end
                end
            end
        end

        @testset "docs_subdomain opts into a custom subdomain deploy" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                # `true` selects the conventional <pkg>.epiaware.org host.
                scaffold(dir; docs_subdomain = true)
                mk = read(_dest(dir, "docs/make.jl"), String)
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
                mk = read(_dest(dir, "docs/make.jl"), String)
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
                rm(_dest(dir, "docs/docs_config.jl"))
                rm(_dest(dir, "docs/pages.jl"))
                scaffold_update(dir)
                # make.jl no longer hard-includes the missing config; the
                # include is guarded and pages falls back to a default.
                mk = read(_dest(dir, "docs/make.jl"), String)
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
                ql = read(_dest(dir, "test/package/quality.jl"), String)
                @test occursin("hasproperty(QA_CONFIG, :readme)", ql)
            end
        end

        @testset "guarded config fallbacks warn when they engage (#188)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # The docs fallback is loud: a bad sync that drops `pages.jl`
                # must not publish a Home-only nav from a green docs build.
                mk = read(_dest(dir, "docs/make.jl"), String)
                @test occursin("@warn", mk)
                # The QA fallback is loud too: a typoed `readme` key must not
                # silently revert to the repo-root defaults.
                ql = read(_dest(dir, "test/package/quality.jl"), String)
                @test occursin("@warn", ql)

                # The docs guard actually warns (and still returns the
                # default) when the package-owned config is absent.
                rm(_dest(dir, "docs/pages.jl"))
                rm(_dest(dir, "docs/docs_config.jl"))
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
                mk = _dest(dir, "docs/make.jl")
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
                mk = _dest(dir, "docs/make.jl")
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
                bp = _dest(dir, "benchmark/Project.toml")
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
                jp = read(_dest(dir, "test/jet/Project.toml"), String)
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
                cfg = read(_dest(dir, "test/package/qa_config.jl"), String)
                @test occursin("using Wombat", cfg)
                @test !occursin("{{PACKAGE}}", cfg)
                jet = read(_dest(dir, "test/jet/runtests.jl"), String)
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
                dep = read(_dest(dir, ".github/dependabot.yml"), String)
                @test !occursin("reviewers:", dep)
                @test !occursin("assignees:", dep)
                @test !occursin("{{REVIEWER}}", dep)
                @test !occursin("{{DEPENDABOT_REVIEWERS}}", dep)
                @test !occursin("seabbs", dep)
                co = read(_dest(dir, ".github/CODEOWNERS"), String)
                @test !occursin(r"^\* @", co)  # no active owner line
                @test !occursin("{{CODEOWNERS_LINE}}", co)
                # The increment-version assignee default must be empty (never
                # the bare org) so a bump PR does not fail with
                # `replaceActorsForAssignable` on the scaffold_update path (#122). The
                # action skips the `--assignee` flag when empty.
                act = read(
                    _dest(dir,
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
                co = read(_dest(dir, ".github/CODEOWNERS"), String)
                @test occursin("* @octocat", co)
                @test !occursin("{{", co)
                dep = read(_dest(dir, ".github/dependabot.yml"), String)
                @test occursin("reviewers:", dep)
                @test occursin("- \"octocat\"", dep)
                @test !occursin("{{", dep)
                claude = read(_dest(dir, ".github/workflows/claude.yml"),
                    String)
                @test occursin("github.actor == 'octocat'", claude)
                @test !occursin("{{REVIEWER}}", claude)
                review = read(
                    _dest(dir, ".github/workflows/claude-code-review.yml"),
                    String)
                @test occursin("user.login == 'octocat'", review)
                # The version-bump assignee default is the handle (a real user
                # GitHub can assign), not empty.
                act = read(
                    _dest(dir,
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
                test_yaml = read(_dest(dir, ".github/workflows/test.yaml"),
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
                owned = _dest(dir, "test/package/qa_config.jl")
                managed = _dest(dir, "test/package/quality.jl")
                owned_marker = "# PACKAGE EDIT — keep me\n"
                write(owned, owned_marker * read(owned, String))
                write(managed, "# drifted\n")

                res = scaffold_update(dir; benchmarks = true)
                # Only managed files are touched; all of them already existed, so
                # they are `updated`, none `created`, none `preserved`.
                @test isempty(res.created)
                @test Set(res.updated) ==
                      Set(_dest(dir, d) for d in MANAGED_DESTS)
                @test isempty(res.preserved)

                # The managed file's drift was overwritten back to the template.
                @test occursin("Quality: Aqua", read(managed, String))
                # The package-owned file's edit was preserved (scaffold_update skips it).
                @test occursin(owned_marker, read(owned, String))
                # No package-owned file appears in the scaffold_update manifest at all.
                for d in OWNED_DESTS
                    @test _dest(dir, d) ∉ res.updated
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

                codeowners = _dest(dir, ".github/CODEOWNERS")
                dependabot = _dest(dir, ".github/dependabot.yml")
                action = _dest(dir,
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
                      Set(_dest(dir, d) for d in MANAGED_DESTS)
                @test Set(res.preserved) ==
                      Set(_dest(dir, d) for d in OWNED_DESTS)
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
                @test !isdir(_dest(dir, "test/ad"))
                @test !isdir(_dest(dir, "test/ADFixtures"))
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
                tp = read(_dest(dir, "test/Project.toml"), String)
                @test !occursin("DifferentiationInterface", tp)
                @test !occursin("ForwardDiff", tp)
                # No AD-backends docs page, and the docs seeds carry none of
                # its wiring: no Literate registration (the seeds' comments
                # may mention the entry, so match the quoted entries), no nav
                # entry, no AD deps.
                @test !isfile(_dest(dir,
                    "docs/src/getting-started/tutorials/ad-backends.jl"))
                cfg = read(_dest(dir, "docs/docs_config.jl"), String)
                @test occursin("const HEAVY_TUTORIALS = String[]", cfg)
                @test !occursin("\"ad-backends.jl\"", cfg)
                @test !occursin("\"ad-backends.md\"", cfg)
                pgs = read(_dest(dir, "docs/pages.jl"), String)
                @test !occursin("ad-backends.md", pgs)
                @test !occursin("{{AD_TUTORIALS_NAV}}", pgs)
                dp = read(_dest(dir, "docs/Project.toml"), String)
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
                tut = _dest(dir,
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
                cfg = read(_dest(dir, "docs/docs_config.jl"), String)
                @test occursin("\"ad-backends.jl\"", cfg)
                @test occursin(
                    "\"ad-backends.md\" => \"# [Automatic differentiation " *
                    "backends](@id ad-backends)\"", cfg)
                pgs = read(_dest(dir, "docs/pages.jl"), String)
                @test occursin(
                    "getting-started/tutorials/ad-backends.md", pgs)
                @test occursin("\"Tutorials\"", pgs)

                # The docs env reaches the registry by path, keyed to the same
                # seeded ADFixtures UUID as the AD test env, and carries the
                # page's execution deps with compat.
                dp = read(_dest(dir, "docs/Project.toml"), String)
                reg = read(
                    _dest(dir, "test/ADFixtures/Project.toml"), String)
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
                tut = _dest(dir,
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
                setup = _dest(dir, "test/ad/setup.jl")
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

        @testset "scaffold_update warns before clobbering a diverged, unmarked ad setup.jl" begin
            # A managed test/ad/setup.jl that diverges from the fresh render
            # but carries no ownership marker is a strong signal it was
            # customised and the marker was simply never added — the exact
            # footgun that nearly broke CensoredDistributions' AD CI:
            # scaffold_update silently overwrote a heavily customised,
            # unmarked driver. It still overwrites (managed files always
            # resync), but now warns rather than proceeding silently.
            mktempdir() do dir
                _fake_pkg(dir; name = "Numeric2")
                scaffold(dir)
                setup = _dest(dir, "test/ad/setup.jl")
                write(setup, "# hand-edited, no marker\n")
                local res
                @test_logs (:warn, r"test/ad/setup\.jl.*no.*marker"i) match_mode=:any begin
                    res = scaffold_update(dir)
                end
                @test !isempty(res.warnings)
                @test occursin("test/ad/setup.jl", res.warnings[1])
                @test setup in res.updated
            end
            # A never-touched managed driver (fresh scaffold, never
            # hand-edited) matches its own render exactly — no warning.
            mktempdir() do dir
                _fake_pkg(dir; name = "Numeric3")
                scaffold(dir)
                res = scaffold_update(dir)
                @test isempty(res.warnings)
            end
        end

        @testset "override marker preserves any managed file (#224)" begin
            using EpiAwarePackageTools: _detect_managed_override,
                                        _MANAGED_OVERRIDE_MARKER,
                                        _AD_SETUP_OWNED_MARKER
            # The third argument is the fresh render of the template, which the
            # guard reads only to check the kit is not itself shipping the
            # marker (see the template-marker testset below); a marker-free
            # stand-in is enough here.
            unmarked_render = "name: Test\n"
            mktempdir() do dir
                _fake_pkg(dir; name = "Override")
                scaffold(dir)
                wf = _dest(dir, ".github/workflows/test.yaml")
                # A freshly scaffolded managed file carries no marker, so a
                # resync overwrites it (the load-bearing "managed files always
                # resync" rule).
                @test !_detect_managed_override(
                    dir, ".github/workflows/test.yaml", unmarked_render)
                write(wf, "# hand-edited, no marker\n")
                res = scaffold_update(dir)
                @test wf in res.updated
                @test occursin("jobs:", read(wf, String))
                # Marking it makes scaffold_update() preserve it verbatim.
                owned = "# $(_MANAGED_OVERRIDE_MARKER): package-owned CI\n" *
                        "name: Test\non: [push]\n"
                write(wf, owned)
                @test _detect_managed_override(
                    dir, ".github/workflows/test.yaml", unmarked_render)
                res2 = scaffold_update(dir)
                @test wf in res2.preserved
                @test wf ∉ res2.updated
                @test read(wf, String) == owned
                # A marked, diverged file is a deliberate opt-out: no warning.
                @test isempty(res2.warnings)
                # The match is case-sensitive, as documented: a mis-cased
                # marker is not an opt-out and the file resyncs as usual.
                write(wf, "# epiaware_managed_override\nname: Test\n")
                @test !_detect_managed_override(
                    dir, ".github/workflows/test.yaml", unmarked_render)
                @test wf in scaffold_update(dir).updated
                # scaffold(force = true) still re-lays the managed file, so a
                # new package always starts managed.
                write(wf, owned)
                scaffold(dir; force = true)
                @test occursin("jobs:", read(wf, String))
            end
            # The marker works on any managed file, including test/ad/setup.jl,
            # whose older file-specific marker keeps working (back-compat).
            mktempdir() do dir
                _fake_pkg(dir; name = "Override2")
                scaffold(dir)
                setup = _dest(dir, "test/ad/setup.jl")
                legacy = "# $(_AD_SETUP_OWNED_MARKER): legacy driver\n"
                write(setup, legacy)
                @test _detect_managed_override(
                    dir, "test/ad/setup.jl", unmarked_render)
                res = scaffold_update(dir)
                @test setup in res.preserved
                @test read(setup, String) == legacy
                # The generic marker is accepted on the same file.
                generic = "# $(_MANAGED_OVERRIDE_MARKER): kept driver\n"
                write(setup, generic)
                res2 = scaffold_update(dir)
                @test setup in res2.preserved
                @test read(setup, String) == generic
            end
        end

        @testset "no bundled template ships the override marker (#224)" begin
            using EpiAwarePackageTools: _MANAGED_OVERRIDE_MARKER
            # A managed template carrying the marker literal would hand every
            # adopter a permanently self-preserving copy of that file on the
            # next sync: the kit would silently stop managing its own file,
            # everywhere. `_detect_managed_override` ignores a marker the fresh
            # render also carries, and this test fails loudly if a template ever
            # adds one, so the case is fixed in the kit rather than absorbed.
            mktempdir() do dir
                _fake_pkg(dir; name = "MarkerFree")
                inputs = scaffold_inputs(dir)
                for t in SCAFFOLD_TEMPLATES
                    src = joinpath(_templates_dir(), t.src)
                    @test !occursin(_MANAGED_OVERRIDE_MARKER, read(src, String))
                end
                # ... and nothing a real render produces carries it either.
                scaffold(dir)
                for (root, _, files) in walkdir(dir), f in files

                    path = joinpath(root, f)
                    @test !occursin(
                        _MANAGED_OVERRIDE_MARKER, read(path, String))
                end
            end
            # A marker in the template itself means nothing: the file stays
            # managed rather than pinning itself in every adopter forever.
            mktempdir() do dir
                _fake_pkg(dir; name = "MarkerInTemplate")
                scaffold(dir)
                wf = _dest(dir, ".github/workflows/test.yaml")
                marked = "# $(_MANAGED_OVERRIDE_MARKER) in the template\n"
                write(wf, marked)
                @test !EpiAwarePackageTools._detect_managed_override(
                    dir, ".github/workflows/test.yaml", marked)
                @test EpiAwarePackageTools._detect_managed_override(
                    dir, ".github/workflows/test.yaml", "name: Test\n")
            end
        end

        @testset "override marker does not cover managed regions (#224)" begin
            using EpiAwarePackageTools: _MANAGED_OVERRIDE_MARKER
            # The marker governs whole template-emitted files. The
            # marker-delimited regions the kit injects into otherwise
            # package-owned files (the .gitignore managed block, the README
            # badge and standard-sections blocks, Project.toml's [workspace])
            # have their own appliers and are refreshed regardless — as the
            # docs now say. Customisation there goes outside the markers.
            mktempdir() do dir
                _fake_pkg(dir; name = "Regions")
                scaffold(dir; repo = "FakeOrg/Regions.jl")
                gi = joinpath(dir, ".gitignore")
                readme = joinpath(dir, "README.md")
                write(gi, "# $(_MANAGED_OVERRIDE_MARKER)\nmy-own-rule\n")
                write(readme, "# Regions\n\n# $(_MANAGED_OVERRIDE_MARKER)\n")
                scaffold_update(dir; repo = "FakeOrg/Regions.jl")
                # The managed blocks come back despite the marker.
                @test occursin(
                    EpiAwarePackageTools.GITIGNORE_START, read(gi, String))
                body = read(readme, String)
                @test occursin(EpiAwarePackageTools.BADGES_START, body)
                @test occursin(
                    EpiAwarePackageTools.STANDARD_SECTIONS_START, body)
            end
        end

        @testset "no divergence warning for stale managed files (#224)" begin
            # A managed file that diverges from a fresh render is the *normal*
            # state right before a routine scaffold_update (the adopter is
            # simply on an older kit version), so divergence alone cannot
            # distinguish "customised" from "stale". Only test/ad/setup.jl —
            # where a clobber breaks every AD CI job — warns.
            mktempdir() do dir
                _fake_pkg(dir; name = "Stale")
                scaffold(dir)
                wf = _dest(dir, ".github/workflows/test.yaml")
                write(wf, "# an older template version\nname: Test\n")
                res = scaffold_update(dir)
                @test wf in res.updated
                @test isempty(res.warnings)
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
                adyaml = read(_dest(dir, ".github/workflows/ad.yaml"),
                    String)
                @test occursin("backends:", adyaml)
                @test count("\"tag\":", adyaml) == n

                # `test/ad/setup.jl`'s `using` line covers every distinct
                # package a backend needs.
                setup = read(_dest(dir, "test/ad/setup.jl"), String)
                for pkg in unique(b.pkg for b in EpiAwarePackageTools._AD_BACKENDS)
                    @test occursin(pkg, setup)
                end

                # The `test/ad/scenarios.jl` starter seed has one `@testitem`
                # per backend.
                scenarios = read(_dest(dir, "test/ad/scenarios.jl"),
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
                            _dest(dir, ".github/workflows/ad.yaml"),
                            String)
                        @test count("\"tag\":", adyaml) == n7
                        @test occursin("\"fakead\"", adyaml)

                        setup = read(_dest(dir, "test/ad/setup.jl"),
                            String)
                        @test occursin("FakeADPkg", setup)

                        scenarios = read(
                            _dest(dir, "test/ad/scenarios.jl"), String)
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
                        _dest(dir, ".github/workflows/ad.yaml"), String)
                    @test count("\"tag\":", adyaml) == n

                    push!(EpiAwarePackageTools._AD_BACKENDS,
                        (alt = "FakeAD", header = "FakeAD",
                            slug = "ad-fakead", tag = "fakead",
                            pkg = "FakeADPkg"))
                    try
                        scaffold_update(dir)
                        adyaml2 = read(
                            _dest(dir, ".github/workflows/ad.yaml"),
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
                # Compared as whole native paths, not by `/`-bearing substring:
                # the manifest holds platform-separated paths, so an
                # `occursin("test/ad/", p)` here would simply never match on
                # Windows and the assertion would pass whatever the manifest
                # said.
                @test _dest(dir, ".github/workflows/ad.yaml") ∉ res.updated
                ad_dir = _dest(dir, "test/ad")
                @test !any(p -> startswith(p, ad_dir), res.updated)
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
                qa = read(_dest(dir, "test/package/qa_config.jl"), String)
                @test occursin("using FreshPkg", qa)
                @test !occursin("{{", qa)
                # ad = true by default, so AD infra is present.
                @test isfile(_dest(dir, ".github/workflows/ad.yaml"))
            end
        end

        @testset "scaffold_generate seeds a passing ad = true AD suite out of the box (#217)" begin
            mktempdir() do base
                dir = joinpath(base, "FreshAdPkg")
                scaffold_generate(dir, "FreshAdPkg"; authors = ["Ada Lovelace"])
                fixtures = read(
                    _dest(dir, "test/ADFixtures/src/ADFixtures.jl"), String)
                scenarios = read(_dest(dir, "test/ad/scenarios.jl"), String)
                # Every backend `test/ad/scenarios.jl` calls
                # `test_working_backend(...)` for must have a matching seeded
                # `backends()` entry, or a fresh scaffold errors
                # (`ArgumentError: Collection is empty...`) on that backend
                # out of the box (#217). Before this the seed only ever
                # registered ForwardDiff.
                backend_calls = [String(m.captures[1])
                                 for m in eachmatch(
                    r"test_working_backend\(\"([^\"]+)\"\)", scenarios)]
                @test !isempty(backend_calls)
                for name in backend_calls
                    @test occursin("name = \"$name\"", fixtures)
                end
                @test !occursin("{{", fixtures)
                @test Meta.parseall(fixtures) isa Expr
                # The isolated AD env + ADFixtures env both carry every
                # backend package the seeded `backends()` now constructs.
                ad_proj = read(_dest(dir, "test/ad/Project.toml"), String)
                adfix_proj = read(
                    _dest(dir, "test/ADFixtures/Project.toml"), String)
                for pkg in ("Enzyme", "Mooncake", "ReverseDiff", "ForwardDiff")
                    @test occursin(pkg, ad_proj)
                    @test occursin(pkg, adfix_proj)
                end
            end
        end

        @testset "scaffold_generate's module docstring includes an @example (#217)" begin
            mktempdir() do base
                dir = joinpath(base, "FreshDocPkg")
                scaffold_generate(dir, "FreshDocPkg"; authors = ["Ada Lovelace"])
                src = read(_dest(dir, "src/FreshDocPkg.jl"), String)
                # `test_docstring_format` treats the module's own exported
                # symbol like any other and requires an `@example` block on
                # it (`exported_only_examples = true` is the default) — the
                # bare skeleton docstring had none, so a fresh scaffold
                # failed its own docstring-format QA out of the box (#217).
                @test occursin("@example", src)
            end
        end

        @testset "scaffold_generate with ad = false opts out" begin
            mktempdir() do base
                dir = joinpath(base, "ToolPkg")
                scaffold_generate(dir, "ToolPkg"; authors = ["Ada"], ad = false)
                @test isfile(joinpath(dir, "src", "ToolPkg.jl"))
                @test !isfile(_dest(dir, ".github/workflows/ad.yaml"))
                @test !isdir(_dest(dir, "test/ad"))
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

                # The managed `## How to cite` heading satisfies the citation
                # group of STANDARD_README_SECTIONS, so the scaffolded README
                # passes the kit's own README-sections quality check out of the
                # box, with no hand-authored License/Supporting section (#201).
                headings = EpiAwarePackageTools._readme_headings(txt)
                @test EpiAwarePackageTools._has_section(headings,
                    EpiAwarePackageTools.STANDARD_README_SECTIONS[end])

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
                caller = _dest(dir, ".github/workflows/test.yaml")
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
                caller = _dest(dir, ".github/workflows/test.yaml")
                # Simulate a package pinning a Julia floor/matrix on the
                # managed `test`/`downgrade-compat` callers, exactly the
                # override #73 reports being silently reverted.
                #
                # Both callers now carry a kit-seeded `with:` block (#246),
                # so a package overrides the seeded key rather than adding a
                # block of its own — the key is a seed default, and the
                # destination wins on it.
                before = read(caller, String)
                overridden = replace(before,
                    r"(?m)^      julia_versions: .*$" => "      julia_versions: '[\"1.11\", \"1\"]'",
                    r"(?m)^      julia_version: .*$" => "      julia_version: '1.12'")
                @test overridden != before
                write(caller, overridden)
                scaffold_update(dir)
                after = read(caller, String)
                # The `with:` overrides survive the resync ...
                @test occursin("julia_versions: '[\"1.11\", \"1\"]'", after)
                @test occursin("julia_version: '1.12'", after)
                # ... the rest of the caller is still managed and re-applied,
                # and a second scaffold_update is idempotent on the preserved inputs.
                scaffold_update(dir)
                @test read(caller, String) == after
            end
        end

        @testset "scaffold_update preserves a Dependabot-bumped action pin (#215)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # A managed workflow that directly pins third-party actions (not
                # only the org reusables). Dependabot's github-actions ecosystem
                # bumps these pins in the live repo just like a reusable SHA.
                wf = _dest(dir, ".github/workflows/claude.yml")
                before = read(wf, String)
                @test occursin("actions/checkout@v6", before)
                # Simulate Dependabot bumping the third-party pin in the live
                # workflow (the case #215 reports being reverted on resync).
                bumped = replace(before,
                    r"(uses:\s*actions/checkout@)\S+" => s"\1v99")
                @test bumped != before
                write(wf, bumped)
                scaffold_update(dir)
                after = read(wf, String)
                # scaffold_update keeps the bumped pin (never reverts Dependabot,
                # regardless of the branch the resync runs on) ...
                @test occursin("actions/checkout@v99", after)
                @test !occursin("actions/checkout@v6", after)
                # ... and a second scaffold_update is idempotent on the pin.
                scaffold_update(dir)
                @test read(wf, String) == after
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
                caller = _dest(dir, ".github/workflows/codecoverage.yaml")
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
                #
                # Asserted on the VALUE, not merely the key's presence: the
                # coverage caller's `julia_version` shares its name with the
                # downgrade caller's seed-default key (#246), and a key-presence
                # check stays green even if this one were quietly un-managed.
                @test occursin("julia_version: '1'", after)
                # Idempotent on the merged block.
                scaffold_update(dir)
                @test read(caller, String) == after
            end
        end

        @testset "scaffold_update preserves a comment documenting a merged with: key (#212)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # Symptom 1 (ad.yaml): a package-owned key preceded by a
                # multi-line guard comment, added alongside a job whose
                # `with:` block the template renders from scratch (`backends:`
                # only, no comment of its own). Before #212 the comment was
                # attached to the *preceding* key (`backends`) during parsing,
                # so it was dropped wholesale when that seeded key won.
                ad_caller = _dest(dir, ".github/workflows/ad.yaml")
                ad_before = read(ad_caller, String)
                @test occursin("backends:", ad_before)
                guard_comment = string(
                    "      # Count extension lines too (the Mooncake ext is exercised by\n",
                    "      # this suite). Re-added by hand (#88).\n")
                ad_overridden = replace(ad_before,
                    r"([ \t]+)(backends:[^\r\n]*\r?\n)" =>
                        SubstitutionString(
                            "\\1\\2" * guard_comment *
                            "\\1coverage_directories: 'src,ext'\n"))
                @test ad_overridden != ad_before
                write(ad_caller, ad_overridden)

                # Symptom 2 (codecoverage.yaml): a package-owned key inserted
                # *before* a template-rendered key that itself already carries
                # a preceding comment (`fail_ci_if_error`). Before #212 the
                # package's own preceding comment was captured as a
                # continuation of the *previous* key instead of attached to
                # `coverage_directories`, and the template's own
                # `fail_ci_if_error` comment was then duplicated onto the
                # relocated package key.
                cov_caller = _dest(dir, ".github/workflows/codecoverage.yaml")
                cov_before = read(cov_caller, String)
                @test occursin("fail_ci_if_error:", cov_before)
                pkg_comment = string(
                    "      # Package extensions carry real code; count their\n",
                    "      # lines too. Re-added by hand (#88).\n")
                cov_overridden = replace(cov_before,
                    r"([ \t]+)(julia_version:[^\r\n]*\r?\n)" =>
                        SubstitutionString(
                            "\\1\\2" * pkg_comment *
                            "\\1coverage_directories: 'src,ext'\n"))
                @test cov_overridden != cov_before
                write(cov_caller, cov_overridden)

                scaffold_update(dir)
                ad_after = read(ad_caller, String)
                cov_after = read(cov_caller, String)

                # The package key and its own guard comment both survive ...
                @test occursin("coverage_directories: 'src,ext'", ad_after)
                @test occursin("Count extension lines too", ad_after)
                @test occursin("coverage_directories: 'src,ext'", cov_after)
                @test occursin("Package extensions carry real code", cov_after)
                # ... exactly once each (no duplication) ...
                @test count("Count extension lines too", ad_after) == 1
                @test count("Package extensions carry real code", cov_after) == 1
                # ... and the template's own comment/key are neither dropped
                # nor duplicated by the merge.
                @test count("Hard-fail the coverage check", cov_after) == 1
                @test occursin("fail_ci_if_error:", cov_after)
                @test occursin("backends:", ad_after)

                # Idempotent on the merged block.
                scaffold_update(dir)
                @test read(ad_caller, String) == ad_after
                @test read(cov_caller, String) == cov_after
            end
        end

        @testset "_merge_with_blocks keeps a destination's own dangling trailing comment" begin
            using EpiAwarePackageTools: _merge_with_blocks
            # A comment with no key after it at all (nothing between it and
            # the block's end) is package-owned unmatched content, exactly
            # like an extra key — it must survive the merge, not be dropped.
            seed = "    with:\n      backends: '[\"A\"]'\n"
            existing = "    with:\n      backends: '[\"A\"]'\n" *
                       "      # dangling comment, no key follows\n"
            merged = _merge_with_blocks(seed, existing)
            @test occursin("dangling comment, no key follows", merged)
            @test count("dangling comment, no key follows", merged) == 1
            @test occursin("backends:", merged)
            # Idempotent: re-merging the already-merged block against the
            # same seed leaves it unchanged.
            @test _merge_with_blocks(seed, merged) == merged
        end

        @testset "_merge_with_blocks keeps a package-only key's multi-line value intact" begin
            using EpiAwarePackageTools: _merge_with_blocks
            # A package-owned key whose value spans multiple lines (e.g. a
            # YAML block list) has continuation lines that are neither a key
            # nor a comment/blank — they must stay attached to that key
            # through the merge, not get dropped or misfiled.
            seed = "    with:\n      backends: '[\"A\"]'\n"
            existing = "    with:\n      backends: '[\"A\"]'\n" *
                       "      extra_matrix:\n        - x\n        - y\n"
            merged = _merge_with_blocks(seed, existing)
            @test occursin(
                "extra_matrix:\n        - x\n        - y", merged)
            @test occursin("backends:", merged)
            @test _merge_with_blocks(seed, merged) == merged
        end

        @testset "scaffold_update preserves the downstreams list (#234)" begin
            using EpiAwarePackageTools: _preserve_downstreams
            entry = "'[{\"repo\":\"FakeOrg/Downstream.jl\"}]'"
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                wf = _dest(dir, ".github/workflows/downstream.yaml")
                before = read(wf, String)
                # The template seeds an empty list; the list itself is adopter
                # configuration, not managed content (#234).
                @test occursin("downstreams: '[]'", before)
                owned = replace(before, "downstreams: '[]'" =>
                    "downstreams: " * entry)
                # Also drift the managed part of the file, to prove the resync
                # still repairs everything except the owned input.
                owned = replace(owned, "name: Downstream" => "name: Bogus")
                write(wf, owned)
                res = scaffold_update(dir)
                after = read(wf, String)
                # The package-owned list survives the resync ...
                @test occursin("downstreams: " * entry, after)
                @test !occursin("downstreams: '[]'", after)
                # ... the rest of the workflow is still managed and re-applied
                # (the file stays a resynced managed file, not a preserved one)
                @test occursin("name: Downstream", after)
                @test !occursin("name: Bogus", after)
                @test wf in res.updated
                @test wf ∉ res.preserved
                # ... and a second scaffold_update is idempotent on the list.
                scaffold_update(dir)
                @test read(wf, String) == after
                # scaffold(force = true) re-lays the managed workflow but, like
                # every other destination-reading pass in `_emit` (Dependabot
                # pins, package-owned `with:` inputs), still keeps the committed
                # list: `force` overwrites package-owned *files*, it does not
                # discard configuration recovered from the repo.
                scaffold(dir; force = true)
                @test occursin("downstreams: " * entry, read(wf, String))
            end
            # A package that never set a list keeps the seed default: no
            # spurious preservation.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat2")
                scaffold(dir)
                wf = _dest(dir, ".github/workflows/downstream.yaml")
                before = read(wf, String)
                scaffold_update(dir)
                @test read(wf, String) == before
                @test occursin("downstreams: '[]'", read(wf, String))
            end
            # First adoption (no destination yet) and a committed workflow that
            # sets no list at all both leave the template's seed alone.
            mktempdir() do dir
                seed = "    with:\n      downstreams: '[]'\n"
                dest = joinpath(dir, "downstream.yaml")
                @test _preserve_downstreams(seed, dest) == seed
                write(dest, "jobs:\n  downstream:\n    uses: x\n")
                @test _preserve_downstreams(seed, dest) == seed
                # A template with no `downstreams:` key is untouched.
                plain = "name: Test\n"
                @test _preserve_downstreams(plain, dest) == plain
            end
        end

        @testset "_detect_license recovers a committed licence (#235)" begin
            using EpiAwarePackageTools: _detect_license
            # A never-scaffolded target has nothing to recover.
            mktempdir() do dir
                @test _detect_license(dir) === nothing
                _fake_pkg(dir; name = "Wombat")
                @test _detect_license(dir) === nothing
            end
            # The managed README badge is the source of truth ...
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; license = "Apache-2.0", ad = false)
                @test _detect_license(dir) == "Apache-2.0"
            end
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false)
                @test _detect_license(dir) == "MIT"
            end
            # ... with the Project.toml `license` field as a fallback for a
            # repo whose README carries no badge block yet.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                open(joinpath(dir, "Project.toml"), "a") do io
                    write(io, "license = \"Apache-2.0\"\n")
                end
                @test _detect_license(dir) == "Apache-2.0"
            end
        end

        @testset "scaffold_update preserves a non-MIT licence badge (#235)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; license = "Apache-2.0", ad = false)
                # A bare scaffold_update (as the scheduled template-sync runs,
                # with no `license` kwarg) must not flip the badge to MIT.
                scaffold_update(dir; ad = false)
                txt = read(joinpath(dir, "README.md"), String)
                @test occursin("License: Apache-2.0", txt)
                @test !occursin("License: MIT", txt)
                # An explicit licence still overrides the detected one.
                scaffold_update(dir; ad = false, license = "MIT")
                txt2 = read(joinpath(dir, "README.md"), String)
                @test occursin("License: MIT", txt2)
            end
            # An MIT package is unaffected (no spurious preservation).
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat2")
                scaffold(dir; ad = false)
                scaffold_update(dir; ad = false)
                txt = read(joinpath(dir, "README.md"), String)
                @test occursin("License: MIT", txt)
                @test !occursin("License: Apache-2.0", txt)
            end
        end

        @testset "override marker keeps a bespoke docs/make.jl (#237)" begin
            using EpiAwarePackageTools: _MANAGED_OVERRIDE_MARKER
            mktempdir() do dir
                _fake_pkg(dir; name = "Bespoke")
                scaffold(dir)
                mk = joinpath(dir, "docs", "make.jl")
                @test occursin("build_docs", read(mk, String))
                # A bespoke DocumenterVitepress build, unmarked, is still
                # force-migrated to the managed `build_docs` entry point.
                bespoke = "using Documenter\nmakedocs(; sitename = \"Bespoke\")\n"
                write(mk, bespoke)
                res = scaffold_update(dir)
                @test mk in res.updated
                @test occursin("build_docs", read(mk, String))
                # Marking the file package-owned (#224) keeps it: the answer to
                # the docs-migration opt-out #237 asks for.
                marked = "# $(_MANAGED_OVERRIDE_MARKER): bespoke docs build\n" *
                         bespoke
                write(mk, marked)
                res2 = scaffold_update(dir)
                @test mk in res2.preserved
                @test mk ∉ res2.updated
                @test read(mk, String) == marked
                # No divergence warning for a deliberate, marked opt-out.
                @test isempty(res2.warnings)
                # scaffold(force = true) still lays the managed make.jl down
                # fresh, so a new package always starts managed.
                scaffold(dir; force = true)
                @test occursin("build_docs", read(mk, String))
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

            # Destinations are relative posix paths, so `_dest_path` can split
            # them into path segments. A leading/trailing slash or an empty
            # segment would make it emit a malformed path (and would defeat the
            # `p * "/"` prefix check above), so hold the manifests to that.
            for d in union(dests, Set(RETIRED_PATHS))
                @test !startswith(d, '/')
                @test !endswith(d, '/')
                @test !occursin("//", d)
                @test !isempty(d)
            end
        end

        @testset "scaffold results report native paths (#237)" begin
            using EpiAwarePackageTools: _dest_path
            # Destinations are stored posix-style, so joining one onto a root
            # with a plain `joinpath` keeps the inner `/` and yields a mixed
            # separator path on Windows (`C:\pkg\docs/make.jl`). Windows
            # tolerates that for io, so the scaffold still works — but the
            # result manifests are public API, and a caller comparing against
            # their own `joinpath(dir, "docs", "make.jl")` would never match.
            # Asserted OS-independently (both sides are native by
            # construction), so a regression to plain `joinpath` fails here and
            # not only on Windows CI.
            @test _dest_path("root", "docs/make.jl") ==
                  joinpath("root", "docs", "make.jl")
            @test _dest_path("root", ".github/workflows/test.yaml") ==
                  joinpath("root", ".github", "workflows", "test.yaml")
            # A slash-free destination is just a child of the root.
            @test _dest_path("root", "Taskfile.yml") ==
                  joinpath("root", "Taskfile.yml")
            # And every reported path is already normalised: `normpath` rewrites
            # a separator that is not the platform's own, so a mixed path like
            # `C:\pkg\docs/make.jl` is not a fixed point of it. On a posix
            # platform `/` is the native separator, so this holds trivially —
            # it is the Windows run that has teeth.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                res = scaffold(dir)
                reported = vcat(res.created, res.updated, res.preserved,
                    res.removed)
                @test !isempty(reported)
                @test all(p -> p == normpath(p), reported)
            end
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; benchmarks = true)
                stale = _dest(dir, "benchmark/comment")
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
            using EpiAwarePackageTools: _DOWNGRADE_SEED_REF,
                                        _REGISTRABILITY_SEED_REF, _templates_dir
            # Every template pins the org reusables at the same seed commit, so
            # a fresh scaffold never starts life behind on some workflows and
            # current on others (#186: the seed had drifted from `.github` head
            # on some callers and not others). The registrability caller is the
            # one documented exception: `registrability.yml` post-dates the
            # shared seed, so it pins its own newer seed until that commit
            # merges to `.github` main and Dependabot converges the pins.
            wf = joinpath(_templates_dir(), ".github", "workflows")
            pins = String[]
            for f in readdir(wf; join = true)
                expected = endswith(f, "registrability.yaml") ?
                           _REGISTRABILITY_SEED_REF : _DOWNGRADE_SEED_REF
                for m in eachmatch(
                    r"/\.github/\.github/workflows/[^@\s]+@([0-9a-f]{40})",
                    read(f, String))
                    @test String(m.captures[1]) == expected
                    push!(pins, String(m.captures[1]))
                end
            end
            @test !isempty(pins)
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
                doc = _dest(dir, ".github/workflows/document.yaml")
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
                caller = _dest(dir, ".github/workflows/test.yaml")
                # A package documents its Julia floor override with a rationale
                # comment between `uses:` and `with:` (as EpiAwarePrototype.jl
                # does). #117: comments between the two used to break the
                # `uses:`->`with:` adjacency and silently drop the override.
                # The caller now carries a kit-seeded `with:` block (#246), so
                # the package's rationale comments sit above it and its override
                # replaces the seeded key.
                before = read(caller, String)
                overridden = replace(before,
                    r"(uses: \S+/tests\.yml@\S+\r?\n)" =>
                        s"""\1    # Floor is Julia 1.11 (Turing 0.45 needs it).
    # Test the floor and the latest release.
""")
                overridden = replace(overridden,
                    r"(?m)^      julia_versions: .*$" => "      julia_versions: '[\"1.11\", \"1\", \"pre\"]'")
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
                tf = _dest(dir, ".github/workflows/test.yaml")
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
                tf = _dest(dir, ".github/workflows/test.yaml")
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
                    _dest(dir, ".github/workflows/template-sync.yaml"),
                    String)
                @test occursin("downgrade_compat = false", sync)
            end
        end

        @testset "scheduled sync is managed; community health not shipped" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false)
                @test isfile(
                    _dest(dir, ".github/workflows/template-sync.yaml"))
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
                    _dest(dir, ".github/workflows/template-sync.yaml"),
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
                @test _dest(dir, ".github/workflows/template-sync.yaml") in
                      res.updated
            end
        end

        @testset "sync never pushes to a branch it did not open (#215)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false)
                sync = read(
                    joinpath(dir, ".github/workflows/template-sync.yaml"),
                    String)
                # The workflow must never commit/push a re-apply on a branch it
                # did not open. Doing so silently reverted package-owned
                # overrides living in managed files, turning a single-purpose
                # Dependabot bump into a regression on merge.
                @test !occursin("git push", sync)
                @test !occursin("git commit", sync)
                # On a pull request the job is a clean no-op: it cannot push
                # (#215) and cannot access what a sync needs under Dependabot's
                # restricted token (#256). The heavy steps are gated off the PR
                # event, and a skip step runs instead.
                @test occursin("Skip on a pull request", sync)
                @test occursin(
                    "if: github.event_name != 'pull_request'", sync)
                # The scheduled/manual path is unchanged: it re-applies the
                # standard and opens (or refreshes) its own PR, a branch it owns.
                @test occursin("scaffold_update", sync)
                @test occursin("peter-evans/create-pull-request", sync)
                @test occursin("branch: chore/template-sync", sync)
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
                @test !ispath(_dest(dir, "benchmark/comment"))
                bench = read(_dest(dir, ".github/workflows/benchmark.yaml"),
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
                    _dest(dir, ".github/workflows/benchmark-history.yaml"),
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
                    _dest(dir, ".github/actions/increment-version/action.yaml"),
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
                mk = read(_dest(dir, "docs/make.jl"), String)
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
                dp = read(_dest(dir, "docs/Project.toml"), String)
                @test occursin("DocumenterCitations", dp)
                @test occursin("Literate", dp)
                # The release-notes header is parameterised on the repo.
                rh = read(_dest(dir, "docs/release_notes_header.jl"), String)
                @test occursin("EpiAware/Wombat.jl", rh)
                @test !occursin("{{", rh)
                # The benchmark-history page: a package-owned prose hook, a nav
                # entry, and the managed make.jl generation + config flag.
                @test isfile(_dest(dir, "docs/benchmarks.md"))
                bh = read(_dest(dir, "docs/benchmarks.md"), String)
                @test occursin("Wombat", bh)
                @test !occursin("{{", bh)
                @test occursin("benchmarks.md", read(
                    _dest(dir, "docs/pages.jl"), String))
                # The "Skipped & broken benchmarks" notes: a second
                # package-owned hook, seeded with a placeholder (#202).
                @test isfile(_dest(dir, "docs/benchmarks_notes.md"))
                bn = read(_dest(dir, "docs/benchmarks_notes.md"), String)
                @test occursin("No known skipped or broken benchmarks", bn)
                @test !occursin("{{", bn)
                # The docs env carries the trend-plot dependency (matching the
                # `[deps]` key line, not just the explanatory comment prose
                # above it, which also mentions "Plots").
                @test occursin("Plots =", dp)
                # The home page strip is package-config driven (no hardcoded
                # named strip in the managed build), and the benchmark page is
                # config-gated.
                dc = read(_dest(dir, "docs/docs_config.jl"), String)
                @test occursin("BENCHMARK_PAGE", dc)
                @test occursin("HISTORY_REGRESSION_THRESHOLD", dc)
                @test occursin("INDEX_STRIP_SECTIONS", dc)
                @test !occursin("README_STRIP_TABLES", dc)
            end
        end

        @testset "benchmarks_notes.md round-trips scaffold_update (#202)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; benchmarks = true)
                notes = _dest(dir, "docs/benchmarks_notes.md")
                edit = "\n## Known-broken\n\n`slow_path` skipped: see #123.\n"
                write(notes, read(notes, String) * edit)
                scaffold_update(dir; benchmarks = true)
                @test occursin(edit, read(notes, String))
            end
            # `benchmarks = false` writes neither benchmark docs seed.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; benchmarks = false)
                @test !isfile(_dest(dir, "docs/benchmarks.md"))
                @test !isfile(_dest(dir, "docs/benchmarks_notes.md"))
                # No trend-plot dependency without a benchmark page either
                # (the `[deps]` key line; the explanatory comment above it
                # mentions "Plots" regardless of `benchmarks`).
                @test !occursin("Plots =",
                    read(_dest(dir, "docs/Project.toml"), String))
            end
        end

        @testset "test env carries bounded [compat]" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                tp = read(_dest(dir, "test/Project.toml"), String)
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
                tp = read(_dest(dir, "test/Project.toml"), String)
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
                ds = _dest(dir, "src/docstrings.jl")
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
                co = read(_dest(dir, ".github/CODEOWNERS"), String)
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
                mod = read(_dest(dir, "src/FreshPkg.jl"), String)
                @test occursin("include(\"docstrings.jl\")", mod)
                @test isfile(_dest(dir, "src/docstrings.jl"))
                # scaffold_generate wires the `using` into the module's own import
                # block, before the docstrings.jl include (#105).
                @test occursin("using DocStringExtensions", mod)
                using_idx = findfirst("using DocStringExtensions", mod)
                include_idx = findfirst("include(\"docstrings.jl\")", mod)
                @test first(using_idx) < first(include_idx)
                ds_txt = read(_dest(dir, "src/docstrings.jl"), String)
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
                reg = _dest(dir, ".github/workflows/Register.yml")
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
                @test _dest(dir, ".github/workflows/Register.yml") in
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
                logo = _dest(dir, "docs/src/assets/logo.svg")
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
                    mkpath(_dest(dir, "docs/src/assets"))
                    write(_dest(dir, "docs/src/assets/logo.svg"),
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

@testitem "Julia 1.11 floor in the managed standard (#246)" begin
    using Test
    using EpiAwarePackageTools
    using EpiAwarePackageTools: _JULIA_FLOOR, _JULIA_COMPAT,
                                _julia_compat_below_floor,
                                _julia_versions_below_floor

    function _fake_pkg(dir; name = "Wombat", julia = nothing)
        compat = julia === nothing ? "" : "\n[compat]\njulia = \"$(julia)\"\n"
        write(joinpath(dir, "Project.toml"),
            "name = \"$name\"\n" *
            "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
            "authors = [\"Ada Lovelace\"]\n" * compat)
        return dir
    end
    _p(dir, rel) = joinpath(dir, split(rel, '/')...)

    @testset "the floor is 1.11 (where [sources] starts working)" begin
        # `[sources]` — how test/Project.toml pins the kit to main — is a Pkg
        # 1.11 feature, silently ignored on 1.10. That is the whole reason for
        # the floor, so pin it rather than let it drift.
        @test _JULIA_FLOOR == v"1.11"
        @test _JULIA_COMPAT == "1.11, 1.12"
    end

    @testset "the test caller drops the lts leg" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            wf = read(_p(dir, ".github/workflows/test.yaml"), String)
            # The reusable defaults to ["1", "lts", "pre"]; a leg on lts (1.10)
            # silently resolves the registered kit, not the pinned rev.
            #
            # Asserted against the `julia_versions:` line itself, not the whole
            # file: the block's own comment names the lts leg it drops, and a
            # naive `occursin("lts", wf)` would match that comment rather than
            # the matrix — passing or failing for the wrong reason.
            lines = split(wf, '\n')
            vline = only(filter(l -> occursin("julia_versions:", l), lines))
            @test occursin("[\"1\", \"pre\"]", vline)
            @test !occursin("lts", vline)
            # And no placeholder survives into the emitted workflow.
            @test !occursin("{{JULIA_TEST_VERSIONS}}", wf)
        end
    end

    @testset "the downgrade caller is pinned above the floor" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; downgrade_compat = true)
            wf = read(_p(dir, ".github/workflows/test.yaml"), String)
            @test occursin("downgrade-compat:", wf)
            # downgrade.yml's own default is '1.10' — exactly the version where
            # the [sources] pin is ignored — so the job must be given a version
            # above the floor. The current release, not the floor itself: the
            # standard's test env cannot resolve on 1.11 (JET ships nothing for
            # 1.11 past 0.9.20, and that needs JuliaSyntax 0.4, which the pinned
            # JuliaFormatter 2.10.1 rules out), so pinning the job to the floor
            # would only go red on a conflict unrelated to the package.
            @test occursin("julia_version: '1'", wf)
            @test !occursin("julia_version: '1.10'", wf)
        end
    end

    @testset "the JET lower bound is one downgrade can actually resolve" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            compat = read(_p(dir, "test/Project.toml"), String)
            # The downgrade job pins every dep to the LOWEST version its compat
            # admits, so a lower bound that cannot resolve is not a lower bound
            # — it is a red CI job waiting to happen. JET 0.9 admits only
            # 0.9.19/0.9.20 on 1.11 and nothing at all on 1.12, and both need
            # JuliaSyntax 0.4, which the pinned JuliaFormatter 2.10.1
            # (JuliaSyntax 1) rules out. 0.10.2 is the lowest JET that resolves
            # alongside it. Declaring 0.9 claimed support the standard never had.
            @test occursin("JET = \"0.10.2\"", compat)
            @test !occursin("JET = \"0.9", compat)
        end
    end

    @testset "a generated package is seeded at the floor" begin
        mktempdir() do dir
            scaffold_generate(dir, "Fresh"; authors = ["Ada Lovelace"])
            proj = read(joinpath(dir, "Project.toml"), String)
            @test occursin("julia = \"1.11, 1.12\"", proj)
            @test !occursin("1.10", proj)
        end
    end

    @testset "a package still claiming 1.10 is warned, not silently broken" begin
        mktempdir() do dir
            _fake_pkg(dir; julia = "1.10, 1.11, 1.12")
            res = scaffold(dir)
            @test any(w -> occursin("1.11", w) && occursin("sources", w),
                res.warnings)
            # The kit does not rewrite the package-owned compat itself.
            @test occursin("julia = \"1.10, 1.11, 1.12\"",
                read(joinpath(dir, "Project.toml"), String))
        end
        # A package already at the floor is not nagged.
        mktempdir() do dir
            _fake_pkg(dir; julia = "1.11, 1.12")
            res = scaffold(dir)
            @test !any(w -> occursin("#246", w), res.warnings)
        end
        # Nor is one with no julia compat at all (nothing claimed).
        mktempdir() do dir
            _fake_pkg(dir)
            res = scaffold(dir)
            @test !any(w -> occursin("#246", w), res.warnings)
        end
    end

    @testset "the seeded matrix is a default, not a diktat (#73/#117)" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            caller = _p(dir, ".github/workflows/test.yaml")
            # A package may still choose its own matrix, with its rationale —
            # that is what #73/#117 exist for. The kit seeds the floor; it does
            # not overwrite a deliberate choice.
            before = read(caller, String)
            write(caller,
                replace(before,
                    r"(?m)^      julia_versions: .*$" =>
                        "      # Pin the floor explicitly (Turing needs it).\n" *
                        "      julia_versions: '[\"1.11\", \"1\", \"pre\"]'"))
            res = scaffold_update(dir)
            after = read(caller, String)
            @test occursin("julia_versions: '[\"1.11\", \"1\", \"pre\"]'", after)
            @test occursin("Pin the floor explicitly", after)
            # An override at or above the floor draws no warning.
            @test !any(w -> occursin("below the", w), res.warnings)
            # Idempotent on the preserved override.
            scaffold_update(dir)
            @test read(caller, String) == after
        end
    end

    @testset "an override that reaches below the floor is warned" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            caller = _p(dir, ".github/workflows/test.yaml")
            # Putting the lts leg back is allowed — the kit does not fight the
            # package — but it silently tests a stale kit, so it must be said.
            write(caller,
                replace(read(caller, String),
                    r"(?m)^      julia_versions: .*$" => "      julia_versions: '[\"1\", \"lts\", \"pre\"]'"))
            res = scaffold_update(dir)
            @test occursin("julia_versions: '[\"1\", \"lts\", \"pre\"]'",
                read(caller, String))
            @test any(w -> occursin("lts", w) && occursin("stale kit", w),
                res.warnings)
        end
    end

    @testset "seed-defaults are scoped to their caller, not the key name" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            # `codecoverage.yaml`'s coverage caller renders a `julia_version` of
            # its own, and it is MANAGED — the kit moves the whole fleet's
            # coverage job when it moves. It happens to share a name with the
            # downgrade caller's seed-default key, so a seed-default set keyed on
            # the bare name would quietly un-manage it: every adopter frozen at
            # whatever they carry, and one able to sit on 1.10 — the very version
            # this floor exists to keep them off — unwarned.
            cov = _p(dir, ".github/workflows/codecoverage.yaml")
            @test occursin("julia_version: '1'", read(cov, String))
            write(cov,
                replace(read(cov, String),
                    r"(?m)^      julia_version: .*$" => "      julia_version: '1.10'"))
            res = scaffold_update(dir)
            after = read(cov, String)
            # The kit reclaims its managed value ...
            @test occursin("julia_version: '1'", after)
            @test !occursin("julia_version: '1.10'", after)
            # ... and the downgrade caller's same-named key is still the
            # package's to override, in the same run.
            caller = _p(dir, ".github/workflows/test.yaml")
            write(caller,
                replace(read(caller, String),
                    r"(?m)^      julia_version: .*$" => "      julia_version: '1.12'"))
            scaffold_update(dir)
            @test occursin("julia_version: '1.12'",
                read(caller, String))
            @test occursin("julia_version: '1'", read(cov, String))
        end
    end

    @testset "the floor scan reads every workflow, not just test.yaml" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            # The scan runs after the managed files are re-applied, so a MANAGED
            # below-floor value is already gone by then — the kit fixed it, and
            # there is nothing to warn about (asserted above). The scan exists
            # for the values the kit does not overwrite: the seed-default keys,
            # and anything in a workflow the package owns outright.
            own = _p(dir, ".github/workflows/nightly.yaml")
            write(own,
                "jobs:\n  x:\n    with:\n      julia_version: '1.10'\n")
            res = scaffold_update(dir)
            @test any(w -> occursin("nightly.yaml", w) && occursin("1.10", w),
                res.warnings)
        end
    end

    @testset "an inline comment is not read as a version" begin
        # A note explaining which leg was dropped must not warn about a leg that
        # is not there.
        @test _julia_versions_below_floor(
            "      julia_versions: '[\"1\", \"pre\"]'  # was [\"1\",\"lts\"]\n") ==
              String[]
    end

    @testset "_julia_versions_below_floor names the offending legs" begin
        @test _julia_versions_below_floor(
            "      julia_versions: '[\"1\", \"pre\"]'\n") == String[]
        @test _julia_versions_below_floor(
            "      julia_versions: '[\"1\", \"lts\", \"pre\"]'\n") == ["lts"]
        @test _julia_versions_below_floor(
            "      julia_versions: '[\"1.10\", \"1\"]'\n") == ["1.10"]
        @test _julia_versions_below_floor(
            "      julia_versions: '[\"1.11\", \"1.12\"]'\n") == String[]
        # The downgrade caller's singular key is read too.
        @test _julia_versions_below_floor(
            "      julia_version: '1.10'\n") == ["1.10"]
        @test _julia_versions_below_floor(
            "      julia_version: '1.11'\n") == String[]
    end

    @testset "_julia_compat_below_floor reads the lowest bound named" begin
        @test _julia_compat_below_floor("1.10, 1.11, 1.12") == v"1.10"
        @test _julia_compat_below_floor("1.10") == v"1.10"
        # A bare "1" admits 1.0, far below the floor.
        @test _julia_compat_below_floor("1") == v"1.0"
        @test _julia_compat_below_floor("1.9, 1.12") == v"1.9"
        # At or above the floor: nothing to warn about.
        @test _julia_compat_below_floor("1.11, 1.12") === nothing
        @test _julia_compat_below_floor("1.11") === nothing
        @test _julia_compat_below_floor("1.12") === nothing
        # Order within the entry does not matter: the lowest bound wins.
        @test _julia_compat_below_floor("1.12, 1.10") == v"1.10"
        # No version named at all.
        @test _julia_compat_below_floor("") === nothing
    end
end

@testitem "opt-in EpiAware org branding (#242)" begin
    using Test
    using EpiAwarePackageTools
    using EpiAwarePackageTools: _detect_org_branding, _org_footer_message,
                                _ORG_LOGO_REL, _ORG_SITE, _ORG_GITHUB

    function _fake_pkg(dir; name = "Wombat")
        write(joinpath(dir, "Project.toml"),
            "name = \"$name\"\n" *
            "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
            "authors = [\"Ada Lovelace\"]\n")
        return dir
    end
    _p(dir, rel) = joinpath(dir, split(rel, '/')...)
    _cfg(dir) = joinpath(dir, "docs", "docs_config.jl")
    # Flip the package-owned opt-in, the one line an adopter writes.
    function _set_branding!(dir, on::Bool)
        cfg = _cfg(dir)
        text = read(cfg, String)
        write(cfg,
            replace(text, r"const ORG_BRANDING = (true|false)" => "const ORG_BRANDING = $(on)"))
        return dir
    end

    @testset "default is off: a third-party adopter gets no branding" begin
        mktempdir() do dir
            _fake_pkg(dir)
            res = scaffold(dir)
            # The scaffolded config carries the flag, defaulted off.
            @test occursin("const ORG_BRANDING = false", read(_cfg(dir), String))
            @test !_detect_org_branding(dir)
            @test res.org_branding == :skipped
            # No org logo asset, and the package's own logo is untouched.
            @test !isfile(_p(dir, _ORG_LOGO_REL))
            @test isfile(_p(dir, "docs/src/assets/logo.svg"))
            # No org line in the managed README block.
            readme = read(joinpath(dir, "README.md"), String)
            @test !occursin("EpiAware ecosystem", readme)
            @test occursin("## Contributing", readme)
            # No org branding in the docs footer, just the standard credit.
            mts = read(_p(dir, "docs/src/.vitepress/config.mts"), String)
            @test occursin("DocumenterVitepress.jl", mts)
            @test !occursin("epiaware-logo.svg", mts)
            @test !occursin(_ORG_SITE, mts)
            # And no placeholder survives into the emitted file.
            @test !occursin("{{ORG_FOOTER_MESSAGE}}", mts)
        end
    end

    @testset "opting in adds the README section, footer and logo" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            _set_branding!(dir, true)
            @test _detect_org_branding(dir)
            res = scaffold_update(dir)
            @test res.org_branding == :created

            # The kit-provided org logo lands, distinct from the package logo.
            org_logo = _p(dir, _ORG_LOGO_REL)
            @test isfile(org_logo)
            @test occursin("EpiAware", read(org_logo, String))
            @test read(org_logo, String) !=
                  read(_p(dir, "docs/src/assets/logo.svg"), String)

            # The README gains the managed org section, inside the markers.
            readme = read(joinpath(dir, "README.md"), String)
            @test occursin("## Part of the EpiAware ecosystem", readme)
            @test occursin(_ORG_SITE, readme)
            si = findfirst("<!-- standard-sections:start -->", readme)
            ei = findlast("<!-- standard-sections:end -->", readme)
            bi = findfirst("Part of the EpiAware ecosystem", readme)
            @test first(si) < first(bi) < first(ei)
            # The other managed sections are still there.
            @test occursin("## Contributing", readme)
            @test occursin("## Code of conduct", readme)

            # The docs footer gains the logo + org links, keeping the credit.
            mts = read(_p(dir, "docs/src/.vitepress/config.mts"), String)
            @test occursin("epiaware-logo.svg", mts)
            @test occursin(_ORG_SITE, mts)
            @test occursin(_ORG_GITHUB, mts)
            @test occursin("DocumenterVitepress.jl", mts)
            # Referenced through the site base, not root-absolute: a versioned
            # deploy is served under /Package.jl/vX.Y/, where /logo.svg 404s.
            @test occursin("\${baseTemp.base}epiaware-logo.svg", mts)
            @test !occursin("\"/epiaware-logo.svg\"", mts)
        end
    end

    @testset "idempotent, and opting back out removes the branding" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            _set_branding!(dir, true)
            scaffold_update(dir)
            readme_on = read(joinpath(dir, "README.md"), String)
            mts_on = read(_p(dir, "docs/src/.vitepress/config.mts"), String)

            # A second sync writes nothing — the sync is a fixed point with
            # branding on.
            res2 = scaffold_update(dir)
            @test res2.org_branding == :unchanged
            @test read(joinpath(dir, "README.md"), String) == readme_on
            @test read(_p(dir, "docs/src/.vitepress/config.mts"), String) ==
                  mts_on
            @test isfile(_p(dir, _ORG_LOGO_REL))

            # Turning it back off withdraws every trace of the branding.
            _set_branding!(dir, false)
            res3 = scaffold_update(dir)
            @test res3.org_branding == :removed
            @test !isfile(_p(dir, _ORG_LOGO_REL))
            readme_off = read(joinpath(dir, "README.md"), String)
            @test !occursin("EpiAware ecosystem", readme_off)
            @test occursin("## Contributing", readme_off)
            mts_off = read(_p(dir, "docs/src/.vitepress/config.mts"), String)
            @test !occursin("epiaware-logo.svg", mts_off)
            @test occursin("DocumenterVitepress.jl", mts_off)

            # And off is itself a fixed point: nothing left to remove.
            res4 = scaffold_update(dir)
            @test res4.org_branding == :skipped
        end
    end

    @testset "the flag is package-owned: a sync never flips it" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            _set_branding!(dir, true)
            # scaffold_update passes no branding kwarg — it must read the
            # package's committed choice, not revert it to the default. This is
            # the scheduled template-sync's path.
            scaffold_update(dir)
            @test _detect_org_branding(dir)
            @test occursin("const ORG_BRANDING = true", read(_cfg(dir), String))
            # An unforced re-scaffold leaves the package-owned config alone too.
            scaffold(dir)
            @test _detect_org_branding(dir)
            @test occursin("## Part of the EpiAware ecosystem",
                read(joinpath(dir, "README.md"), String))
        end
    end

    @testset "force re-lays the config, and the result is self-consistent" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            _set_branding!(dir, true)
            scaffold_update(dir)
            @test isfile(_p(dir, _ORG_LOGO_REL))

            # `force` re-lays the package-owned files, docs_config.jl included,
            # so it resets the flag to the template default — that is what force
            # means. What must NOT happen is the flag being reset while the
            # branding is applied from the pre-reset value: that leaves a repo
            # with a branded footer, an unbranded README and a flag saying off,
            # whose next sync then strips the branding it never agreed to lose.
            # Every surface must agree with the flag left on disk.
            res = scaffold(dir; force = true)
            @test !_detect_org_branding(dir)
            @test occursin("const ORG_BRANDING = false", read(_cfg(dir), String))
            @test res.org_branding == :removed
            @test !isfile(_p(dir, _ORG_LOGO_REL))
            @test !occursin("EpiAware ecosystem",
                read(joinpath(dir, "README.md"), String))
            mts = read(_p(dir, "docs/src/.vitepress/config.mts"), String)
            @test !occursin("epiaware-logo.svg", mts)

            # And the following sync agrees: nothing left to strip.
            res2 = scaffold_update(dir)
            @test res2.org_branding == :skipped
            @test !_detect_org_branding(dir)
        end
    end

    @testset "a commented-out flag reads as off, not on" begin
        mktempdir() do dir
            mkpath(joinpath(dir, "docs"))
            # Commenting the const out is the obvious way to turn branding off.
            # An unanchored match would read this as still on and brand a repo
            # whose owner had just opted out.
            write(_cfg(dir),
                "# To join the org, uncomment:\n" *
                "# const ORG_BRANDING = true\n")
            @test !_detect_org_branding(dir)
            # A commented-out line above the real one does not win either.
            write(_cfg(dir),
                "# const ORG_BRANDING = true\n" *
                "const ORG_BRANDING = false\n")
            @test !_detect_org_branding(dir)
            # And the live line is still read when it is genuinely set.
            write(_cfg(dir),
                "# const ORG_BRANDING = false\n" *
                "const ORG_BRANDING = true\n")
            @test _detect_org_branding(dir)
        end
    end

    @testset "opting out never deletes a file the kit did not write" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            # Branding is off, but the package has its own file at the org
            # logo's path. It is not the kit's to delete.
            own = _p(dir, _ORG_LOGO_REL)
            mkpath(dirname(own))
            write(own, "<svg><!-- the package's own file --></svg>")
            res = @test_logs (:warn, r"not the logo this kit ships") begin
                scaffold_update(dir)
            end
            @test res.org_branding == :skipped
            @test isfile(own)
            @test occursin("the package's own file", read(own, String))
        end
    end

    @testset "footer message rendering" begin
        # Off: the DocumenterVitepress credit alone, exactly as before #242.
        off = _org_footer_message(false)
        @test occursin("DocumenterVitepress.jl", off)
        @test !occursin("EpiAware", off)
        # On: logo + org links, and the credit is kept.
        on = _org_footer_message(true)
        @test occursin("epiaware-logo.svg", on)
        @test occursin(_ORG_SITE, on)
        @test occursin(_ORG_GITHUB, on)
        @test occursin("DocumenterVitepress.jl", on)
        # Spliced into a backtick template literal in config.mts, so it must
        # carry no backtick of its own, and the `${...}` it does carry is the
        # deliberate base interpolation.
        @test !occursin('`', on)
        @test !occursin('`', off)
    end

    @testset "detection defaults off and tolerates an older config" begin
        mktempdir() do dir
            # No docs_config.jl at all (a package predating the docs seed).
            @test !_detect_org_branding(dir)
            mkpath(joinpath(dir, "docs"))
            # A config predating the key defaults off rather than erroring.
            write(_cfg(dir), "const LIGHT_TUTORIALS = String[]\n")
            @test !_detect_org_branding(dir)
            write(_cfg(dir), "const ORG_BRANDING = true\n")
            @test _detect_org_branding(dir)
            write(_cfg(dir), "const ORG_BRANDING = false\n")
            @test !_detect_org_branding(dir)
        end
    end
end
