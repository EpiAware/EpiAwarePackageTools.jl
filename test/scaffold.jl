# Scaffolding into a fresh temp package writes every managed standard file plus
# the package-owned skeletons; `update` re-applies only the managed files and is
# idempotent, never touching package-owned files.

@testitem "scaffold + update (logic)" begin
    using Test
    using Pkg
    using EpiAwarePackageTools
    using EpiAwarePackageTools: SCAFFOLD_TEMPLATES, _templates_dir,
        scaffold_inputs, update, scaffold_update,
        _ad_selected, _bench_selected, _backend_extension_files
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
    function _fake_pkg(
            dir; name = "FakePkg",
            authors = "[\"Ada Lovelace\", \"FakeOrg contributors\"]"
        )
        write(
            joinpath(dir, "Project.toml"),
            "name = \"$name\"\n" *
                "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                "authors = $authors\n"
        )
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
            run(
                pipeline(
                    addenv(
                        `$exe --startup-file=no --history-file=no --project=$env
                     -e "using Pkg; Pkg.instantiate()"`,
                        "JULIA_PKG_PRECOMPILE_AUTO" => "0"
                    );
                    stdout = out, stderr = out
                )
            )
            true
        catch
            false
        end
        ok || println(
            stderr,
            "Pkg.instantiate failed for $env:\n", String(take!(out))
        )
        return ok
    end

    # The templates emitted for a given (`ad`, `benchmarks`) pair. AD/no-AD and
    # benchmark-gated variants writing to the same `dest` collapse to one entry.
    # The bulk of the suite exercises the full standard (ad = true,
    # benchmarks = true); the opt-in benchmark gating (on/off) is covered
    # separately in the `benchmarks_gating` testitem, so tests here scaffold with
    # `benchmarks = true` where they assert the benchmark surface.
    function _selected(ad, benchmarks)
        return [
            t
                for t in SCAFFOLD_TEMPLATES
                if _ad_selected(t, ad) && _bench_selected(t, benchmarks)
        ]
    end

    # The managed / package-owned destination paths for the full standard.
    const MANAGED_DESTS = [t.dest for t in _selected(true, true) if t.managed]
    const OWNED_DESTS = [t.dest for t in _selected(true, true) if !t.managed]

    @testset "scaffold + update" begin
        @testset "scaffold_update is a transitional alias for update (#294)" begin
            # Same generic function, not a wrapper -- so an already-qualified
            # caller (EpiAwarePackageTools.scaffold_update, or an explicit
            # `using EpiAwarePackageTools: scaffold_update`) keeps working
            # unchanged across the rename.
            @test scaffold_update === update
            mktempdir() do dir
                _fake_pkg(dir)
                scaffold(dir)
                res = scaffold_update(dir)
                @test res == update(dir)
            end
        end

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
                for f in (
                        ".github/workflows/test.yaml",
                        ".github/workflows/document.yaml",
                        ".github/dependabot.yml",
                        "test/package/quality.jl",
                        "test/jet/runtests.jl",
                        "test/formatter/runtests.jl",
                        "test/ad/setup.jl",
                        "test/ad/runtests.jl",
                        "benchmark/run.jl",
                        "benchmark/compare.jl",
                    )
                    @test isfile(joinpath(dir, f))
                end
                # CI callers invoke the org reusables; `{{ORG}}` defaults to
                # EpiAware (no Project.toml org field), so the slug is filled.
                test_yaml = read(
                    _dest(dir, ".github/workflows/test.yaml"),
                    String
                )
                @test occursin(
                    "EpiAware/.github/.github/workflows/tests.yml",
                    test_yaml
                )
                @test occursin("downgrade.yml", test_yaml)
                @test !occursin("{{ORG}}", test_yaml)

                # Every managed workflow + dependabot + CODEOWNERS self-identifies
                # with the managed-by header so an adopter never edits it by hand.
                hdr = "MANAGED by EpiAwarePackageTools.scaffold"
                for f in (
                        ".github/workflows/test.yaml",
                        ".github/workflows/ad.yaml",
                        ".github/workflows/document.yaml",
                        ".github/workflows/codecoverage.yaml",
                        ".github/workflows/downstream.yaml",
                        ".github/workflows/pre-commit.yaml",
                        ".github/workflows/TagBot.yaml",
                        ".github/workflows/docpreviewcleanup.yaml",
                        ".github/workflows/cancel-on-close.yaml",
                        ".github/workflows/registrability.yaml",
                        ".github/workflows/release-nudge.yaml",
                        ".github/workflows/try-this-pr.yaml",
                        ".github/workflows/claude.yml",
                        ".github/workflows/claude-code-review.yml",
                        ".github/dependabot.yml", ".github/CODEOWNERS",
                        "codecov.yml", ".pre-commit-config.yaml", "Taskfile.yml",
                    )
                    @test occursin(
                        hdr,
                        read(joinpath(dir, f), String)
                    )
                end
                # The org-standard bot/dev-experience callers are managed and
                # parameterised (no repo-specific literal left hardcoded).
                tpr = read(
                    _dest(dir, ".github/workflows/try-this-pr.yaml"),
                    String
                )
                @test occursin("github.com/EpiAware/FakePkg.jl", tpr)
                @test occursin("using FakePkg", tpr)
                # No kit placeholder remains (GitHub `${{ }}` expressions stay).
                @test !occursin(r"\{\{[A-Z_]+\}\}", tpr)
                coc = read(
                    _dest(dir, ".github/workflows/cancel-on-close.yaml"),
                    String
                )
                @test occursin(
                    "EpiAware/.github/.github/workflows/cancel-on-close.yml", coc
                )
                # The registrability caller invokes the org reusable, pins it
                # by SHA (like the other callers, so Dependabot can bump it),
                # and triggers only on a Project.toml change / dispatch / main.
                reg = read(
                    joinpath(dir, ".github/workflows/registrability.yaml"),
                    String
                )
                @test occursin(
                    "EpiAware/.github/.github/workflows/registrability.yml@",
                    reg
                )
                @test occursin("workflow_dispatch", reg)
                @test occursin("'Project.toml'", reg)
                @test !occursin("{{ORG}}", reg)
                # The release-nudge caller invokes the org reusable, pins
                # it by SHA (like the other callers), runs on a weekly
                # schedule plus `workflow_dispatch`, and leaves no
                # repo-specific placeholder unfilled.
                rn = read(
                    joinpath(dir, ".github/workflows/release-nudge.yaml"),
                    String
                )
                @test occursin(
                    "EpiAware/.github/.github/workflows/release-nudge.yml@",
                    rn
                )
                @test occursin("workflow_dispatch", rn)
                @test occursin(r"cron: '\d+ \d+ \* \* \d+'", rn)
                @test !occursin("{{ORG}}", rn)
                # Coverage hard-fails on upload error (org policy: red on a
                # missing CODECOV_TOKEN as a loud reminder to add it).
                cov_caller = read(
                    _dest(dir, ".github/workflows/codecoverage.yaml"), String
                )
                @test occursin("fail_ci_if_error: true", cov_caller)
                @test !occursin("fail_ci_if_error: false", cov_caller)
            end
        end

        @testset "formatter version is single-sourced (#114)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "FmtPkg")
                scaffold(dir; ad = false)
                ver = EpiAwarePackageTools._RUNIC_VERSION
                prerev = EpiAwarePackageTools._RUNIC_PRE_COMMIT_REV
                # The pre-commit CI caller passes the pinned Runic version to
                # `runic-check.yml`, which greps the local
                # `.pre-commit-config.yaml` for the literal string
                # `Runic@<runic_version>` rather than installing its own.
                pc = read(
                    _dest(dir, ".github/workflows/pre-commit.yaml"),
                    String
                )
                @test occursin("runic_version: '$ver'", pc)
                # No kit placeholder remains (GitHub `${{ }}` expressions stay).
                @test !occursin(r"\{\{[A-Z_]+\}\}", pc)
                # The local pre-commit hook `additional_dependencies` pin, the
                # `runic-pre-commit` hook `rev`, and the isolated formatter
                # env compat pin all agree with the same single sources.
                cfg = read(joinpath(dir, ".pre-commit-config.yaml"), String)
                @test occursin("rev: $prerev", cfg)
                @test occursin("additional_dependencies: ['Runic@$ver']", cfg)
                # The merge-conflict check runs on every commit, not only
                # mid-merge (`--assume-in-merge`), and the diff3 base marker the
                # stock hook misses is forbidden explicitly — the two halves of
                # the gap that let a marker reach CI on #250 (#251).
                @test occursin("--assume-in-merge", cfg)
                @test occursin("forbid-diff3-base-marker", cfg)
                fmt = read(_dest(dir, "test/formatter/Project.toml"), String)
                @test occursin("Runic = \"=$ver\"", fmt)
                @test !occursin("{{", fmt)
            end
        end

        @testset "P0 runnability files present" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # The pre-commit baseline, codecov flags, ad CI caller, and the
                # isolated-env manifests the managed runners need.
                for f in (
                        ".secrets.baseline", "codecov.yml",
                        ".github/workflows/ad.yaml",
                        "test/Project.toml", "test/jet/Project.toml",
                        "test/formatter/Project.toml", "test/ad/Project.toml",
                        "test/ADFixtures/Project.toml",
                        "test/ADFixtures/src/ADFixtures.jl",
                    )
                    @test isfile(joinpath(dir, f))
                end
                # codecov has the unit + ad-* flags; ad caller invokes the reusable.
                cov = read(joinpath(dir, "codecov.yml"), String)
                @test occursin("ad-forwarddiff", cov)
                @test occursin("carryforward", cov)
                # The ad=true codecov gates status until every flag upload lands
                # (unit + seven AD backends = eight), parameterised by backend
                # count.
                @test occursin("after_n_builds: 8", cov)
                @test occursin("wait_for_ci: true", cov)
                @test occursin("target: auto", cov)
                @test !occursin("{{", cov)
                adyaml = read(_dest(dir, ".github/workflows/ad.yaml"), String)
                @test occursin("EpiAware/.github/.github/workflows/ad.yml", adyaml)
                # Docs-only changes skip the heavy 7-backend AD sweep on both
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
                @test occursin(
                    "Wombat = \"00000000-0000-0000-0000-000000000000\"",
                    jetenv
                )
            end
        end

        @testset "main/AD test-env templates are is_kit-aware, like the JET env (#60)" begin
            # `test/Project.toml` (+ `.noad.toml`) and `test/ad/Project.toml`
            # hardcoded an EpiAwarePackageTools `[deps]`/`[sources]` entry with
            # no `is_kit` switch, unlike the JET env (`KIT_DEP_LINE`/
            # `KIT_COMPAT_LINE`). Scaffolding the kit onto itself would then
            # render `EpiAwarePackageTools = "<uuid>"` twice in `[deps]` (once
            # from the hardcoded line, once from `{{PACKAGE}}`) — a duplicate
            # TOML key — and a self-referential `[compat]` bound on the very
            # package the env path-pins. These templates now share the same
            # `is_kit` placeholders as the JET env.
            mktempdir() do dir
                _fake_pkg(dir; name = EpiAwarePackageTools.KIT_NAME)
                scaffold(dir; ad = true)
                for f in ("test/Project.toml", "test/ad/Project.toml")
                    path = joinpath(dir, f)
                    txt = read(path, String)
                    @test !occursin("rev = \"main\"", txt)
                    @test !occursin("{{KIT_DEP_LINE}}", txt)
                    @test !occursin("{{KIT_COMPAT_LINE}}", txt)
                    @test !occursin("{{KIT_COMPAT_SECTION}}", txt)
                    # The kit never bounds itself in its own environments.
                    @test !occursin(
                        "$(EpiAwarePackageTools.KIT_NAME) = " *
                            "\"$(EpiAwarePackageTools.KIT_COMPAT)\"", txt
                    )
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
            # dep, now bounded in `[compat]` rather than git-pinned (#361).
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = true)
                for f in ("test/Project.toml", "test/ad/Project.toml")
                    path = joinpath(dir, f)
                    txt = read(path, String)
                    @test !occursin("rev = \"main\"", txt)
                    @test occursin(
                        "$(EpiAwarePackageTools.KIT_NAME) = " *
                            "\"$(EpiAwarePackageTools.KIT_UUID)\"", txt
                    )
                    @test occursin(
                        "$(EpiAwarePackageTools.KIT_NAME) = " *
                            "\"$(EpiAwarePackageTools.KIT_COMPAT)\"", txt
                    )
                    @test Pkg.TOML.parsefile(path) isa AbstractDict
                end
            end
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false)
                path = _dest(dir, "test/Project.toml")
                txt = read(path, String)
                @test !occursin("rev = \"main\"", txt)
                @test occursin(
                    "$(EpiAwarePackageTools.KIT_NAME) = " *
                        "\"$(EpiAwarePackageTools.KIT_COMPAT)\"", txt
                )
                @test Pkg.TOML.parsefile(path) isa AbstractDict
            end
        end

        @testset "DocumenterVitepress docs setup present + parameterised" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # The standard org docs build (Documenter + DocumenterVitepress).
                for f in (
                        "docs/make.jl", "docs/Project.toml", "docs/pages.jl",
                        "docs/package.json", "docs/versions.js",
                        "docs/src/.vitepress/config.mts",
                        "docs/src/.vitepress/theme/index.ts",
                        "docs/src/.vitepress/theme/style.css",
                        "docs/src/components/VersionPicker.vue",                 # The GitHub-stars navbar widget + its star-count loader.
                        "docs/src/components/StarUs.vue",
                        "docs/src/components/stargazers.data.ts",                 # The authored quickstart, distinct from the README home page.
                        "docs/src/getting-started/index.md",
                    )
                    @test isfile(joinpath(dir, f))
                end
                # The stars widget targets the adopting repo (no owner/repo
                # hardcoded) and its theme + package.json wiring is present.
                star = read(
                    _dest(dir, "docs/src/components/StarUs.vue"),
                    String
                )
                @test occursin("github.com/EpiAware/Wombat.jl", star)
                @test !occursin("{{REPO}}", star)
                data_ts = read(
                    _dest(dir, "docs/src/components/stargazers.data.ts"),
                    String
                )
                @test occursin("EpiAware/Wombat.jl", data_ts)
                theme = read(
                    _dest(dir, "docs/src/.vitepress/theme/index.ts"), String
                )
                @test occursin("StarUs", theme)
                @test occursin(
                    "d3-format",
                    read(_dest(dir, "docs/package.json"), String)
                )
                # The quickstart is authored, package-owned, and substituted
                # (no unresolved placeholders). It does not repeat the install
                # instructions the README-derived home page already carries
                # (#194), and it points at the kit's site rather than a seeded
                # copy of the kit's docs.
                gs = read(
                    _dest(dir, "docs/src/getting-started/index.md"),
                    String
                )
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
                for f in (
                        "docs/src/getting-started/customising.md",
                        "docs/src/getting-started/infrastructure.md",
                    )
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
                # must carry the kit as a dep with a registry bound, or the
                # docs build fails with "package not found" (#115, #361).
                @test occursin(
                    "EpiAwarePackageTools = \"7aaea248", dp
                )
                @test occursin(
                    "EpiAwarePackageTools = " *
                        "\"$(EpiAwarePackageTools.KIT_COMPAT)\"", dp
                )
                @test !occursin("rev = \"main\"", dp)
                # The VitePress config keeps the DocumenterVitepress markers and
                # points social links at the package repo.
                cfg = read(
                    _dest(dir, "docs/src/.vitepress/config.mts"),
                    String
                )
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
            generated = [
                "index.md", "lib/public.md", "lib/internals.md",
                "benchmarks/over-time.md", "release-notes.md",
            ]
            for ad in (true, false)
                mktempdir() do dir
                    _fake_pkg(dir; name = "Wombat")
                    scaffold(dir; ad = ad, benchmarks = true)
                    src = joinpath(dir, "docs", "src")
                    pgs = read(_dest(dir, "docs/pages.jl"), String)
                    targets = [
                        String(m.captures[1])
                            for m in eachmatch(r"\"([^\"]+\.md)\"", pgs)
                    ]
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
                # deploy_url carries an https:// scheme so DocumenterVitepress
                # builds a root base (a scheme-less host is baked into the base
                # and 404s every asset).
                @test occursin(
                    "deploy_url = \"https://wombat.epiaware.org\"", mk
                )
                @test !occursin("deploy_url = nothing", mk)
                @test !occursin("{{", mk)
                txt = read(joinpath(dir, "README.md"), String)
                # Badges link the bare host (no scheme baked into the path).
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
                @test occursin(
                    "deploy_url = \"https://docs.example.org\"", mk
                )
                txt = read(joinpath(dir, "README.md"), String)
                @test occursin("docs.example.org/stable/", txt)
            end
        end

        @testset "managed docs/quality tolerate unseeded config (#163)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # Simulate an adopter predating the build_docs / readme-field
                # migrations: the package-owned config is absent, but update()
                # (managed_only) re-emits the managed make.jl/quality.jl.
                rm(_dest(dir, "docs/docs_config.jl"))
                rm(_dest(dir, "docs/pages.jl"))
                res = update(dir)
                # `docs/pages.jl` self-heals: managed (unlike docs_config.jl,
                # which stays absent -- managed_only skips package-owned
                # templates), so a missing one is written fresh rather than
                # left for a full `scaffold` re-run (#170/#328/#354).
                @test res.pages == :created
                @test isfile(_dest(dir, "docs/pages.jl"))
                # Removed again so the guarded-fallback prelude below still
                # exercises the "both configs absent" path it is named for.
                rm(_dest(dir, "docs/pages.jl"))
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
                write(
                    prelude,
                    "for _f in (\"pages.jl\", \"docs_config.jl\")\n" *
                        "    isfile(joinpath(@__DIR__, _f)) &&\n" *
                        "        include(joinpath(@__DIR__, _f))\n" *
                        "end\n" *
                        "_cfg(sym, default) = isdefined(@__MODULE__, sym) ?\n" *
                        "                     getfield(@__MODULE__, sym) : default\n"
                )
                m = Module()
                Base.include(m, prelude)
                @test Base.invokelatest(
                    getproperty(m, :_cfg), :pages, ["Home" => "index.md"]
                ) ==
                    ["Home" => "index.md"]
                # quality.jl defaults a missing QA_CONFIG.readme field.
                ql = read(_dest(dir, "test/package/quality.jl"), String)
                @test occursin("hasproperty(QA_CONFIG, :readme)", ql)
            end
        end

        @testset "quality.jl runs formatting in the isolated formatter env (#321)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # The formatting testitem must pass the pinned formatter
                # environment through, or Runic resolves from the shared
                # (unpinned) test environment and floats with the CI Julia
                # in use rather than the exact pin (#321).
                ql = read(_dest(dir, "test/package/quality.jl"), String)
                @test occursin("test_formatting(QA_CONFIG.mod; env = env)", ql)
                @test occursin("hasproperty(QA_CONFIG, :formatter_env)", ql)
                cfg = read(_dest(dir, "test/package/qa_config.jl"), String)
                @test occursin(
                    "formatter_env = joinpath(@__DIR__, \"..\", \"formatter\")",
                    cfg
                )

                # An adopter's pre-existing qa_config.jl (package-owned, never
                # re-applied by `update`) can predate the `formatter_env` key.
                # The guard must resolve to `nothing` (today's in-process
                # behaviour) rather than erroring on the missing field — but,
                # unlike a bare `get(...)` default, it must also warn, so a
                # typoed key does not quietly revert to the exact
                # floating-Runic-version failure #321 is about (#188).
                lines = split(ql, "\n")
                i = findfirst(l -> occursin("env = if hasproperty", l), lines)
                j = findfirst(
                    l -> occursin(
                        "test_formatting(QA_CONFIG.mod; env = env)",
                        l
                    ), lines
                )
                prelude = joinpath(dir, "test", "package", "_prelude321.jl")
                write(
                    prelude,
                    "const QA_CONFIG = (; mod = Base)\n" *
                        join(lines[i:(j - 1)], "\n") * "\n"
                )
                m = Module()
                @test_logs (:warn,) match_mode = :any Base.include(m, prelude)
                @test Base.invokelatest(getproperty, m, :env) === nothing
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
                    l -> occursin("getfield(@__MODULE__, sym)", l), lines
                )
                prelude = joinpath(dir, "docs", "_prelude188.jl")
                write(prelude, join(lines[i:j], "\n") * "\n")
                m = Module()
                @test_logs (:warn,) (:warn,) match_mode = :any Base.include(
                    m, prelude
                )
                @test Base.invokelatest(
                    getproperty(m, :_cfg), :pages, ["Home" => "index.md"]
                ) ==
                    ["Home" => "index.md"]
            end
        end

        @testset "update preserves docs_subdomain without re-passing it (#123)" begin
            # A subdomain-hosted package is not reverted to project-pages when a
            # resync (the scheduled template-sync's `update`) omits the kwarg.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; docs_subdomain = true)
                mk = _dest(dir, "docs/make.jl")
                @test occursin(
                    "deploy_url = \"https://wombat.epiaware.org\"",
                    read(mk, String)
                )
                # The common maintenance call: no docs_subdomain kwarg. The
                # scheme form round-trips (read back as a bare host, re-emitted
                # with the scheme), so a resync neither reverts to project-pages
                # nor churns the literal.
                update(dir)
                @test occursin(
                    "deploy_url = \"https://wombat.epiaware.org\"",
                    read(mk, String)
                )
                @test !occursin("deploy_url = nothing", read(mk, String))
                # The README badges stay on the subdomain host too.
                @test occursin(
                    "wombat.epiaware.org/stable/",
                    read(joinpath(dir, "README.md"), String)
                )
            end
            # A project-pages package stays project-pages across a resync.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)  # default: project-pages
                mk = _dest(dir, "docs/make.jl")
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
            # A committed scheme-carrying deploy_url reads back as the bare host
            # (so badges and re-emission stay scheme-free / single-scheme).
            mktempdir() do dir
                mkpath(joinpath(dir, "docs"))
                write(
                    joinpath(dir, "docs", "make.jl"),
                    "build_docs(Foo; " *
                        "deploy_url = \"https://docs.example.org\")\n"
                )
                @test _detect_docs_subdomain(dir) == "docs.example.org"
            end
        end

        @testset "update heals a scheme-less deploy_url (DVP base)" begin
            # An older bare-host `deploy_url` builds a `/<host>/dev/` base that
            # 404s every asset; a resync must rewrite it to the `https://` form
            # that yields a root base.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; docs_subdomain = true)
                mk = _dest(dir, "docs/make.jl")
                # Simulate a repo carrying the old scheme-less literal.
                old = replace(
                    read(mk, String),
                    "deploy_url = \"https://wombat.epiaware.org\"" => "deploy_url = \"wombat.epiaware.org\""
                )
                write(mk, old)
                @test occursin(
                    "deploy_url = \"wombat.epiaware.org\"",
                    read(mk, String)
                )
                update(dir)  # no docs_subdomain kwarg
                @test occursin(
                    "deploy_url = \"https://wombat.epiaware.org\"",
                    read(mk, String)
                )
                @test !occursin(
                    "deploy_url = \"wombat.epiaware.org\",",
                    read(mk, String)
                )
            end
        end

        @testset "recovers the subdomain from a gh-pages CNAME" begin
            using EpiAwarePackageTools: _detect_docs_subdomain, _gh_pages_cname
            _run(dir, cmd) = run(Cmd(cmd; dir = dir))
            mktempdir() do dir
                mkpath(joinpath(dir, "docs"))
                # Project-pages make.jl (`deploy_url = nothing`) in a git repo.
                write(
                    joinpath(dir, "docs", "make.jl"),
                    "build_docs(Foo; deploy_url = nothing)\n"
                )
                _run(dir, `git init -q -b main`)
                _run(dir, `git config user.email t@t.t`)
                _run(dir, `git config user.name t`)
                _run(dir, `git add -A`)
                _run(dir, `git commit -qm init`)
                # No gh-pages CNAME yet -> genuine project-pages, unchanged.
                @test _gh_pages_cname(dir) === nothing
                @test _detect_docs_subdomain(dir) === nothing
                # A Pages custom domain set out of band writes a gh-pages CNAME.
                _run(dir, `git checkout -q --orphan gh-pages`)
                _run(dir, `git reset -q`)
                write(joinpath(dir, "CNAME"), "wombat.example.org\n")
                _run(dir, `git add CNAME`)
                _run(dir, `git commit -qm cname`)
                # `_gh_pages_cname` reads `git show gh-pages:CNAME` and
                # `_detect_docs_subdomain` reads docs/make.jl off disk, so
                # neither needs a particular branch checked out.
                # deploy_url is still `nothing`, but the CNAME now heals the
                # subdomain so the drifted base does not ship a CSS-less site.
                @test _gh_pages_cname(dir) == "wombat.example.org"
                @test _detect_docs_subdomain(dir) == "wombat.example.org"
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
                scaffold(
                    dir; doi = "10.5281/zenodo.18474651",
                    zenodo_badge = "862539324"
                )
                @test _detect_doi(dir) ==
                    ("10.5281/zenodo.18474651", "862539324")
            end
        end

        @testset "update preserves an adopter's DOI badge (#161)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(
                    dir; doi = "10.5281/zenodo.18474651",
                    zenodo_badge = "862539324"
                )
                txt = read(joinpath(dir, "README.md"), String)
                @test occursin("zenodo.org/badge/862539324.svg", txt)
                # A bare update (as the scheduled template-sync runs) must not
                # strip the DOI badge.
                update(dir)
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
                    "\"https://epiawarepackagetools.epiaware.org\""
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
                # Both worktree layouts: the sibling `worktree-*` glob and the
                # nested `worktrees/<name>/` convention these repos actually use
                # (#247), so a live worktree is never one `git add -A` from being
                # committed.
                @test occursin("worktree-*", txt)
                @test occursin(r"(?m)^worktrees/\s*$", txt)
                # Generated docs pages: the release-notes page is generic; the
                # tutorial markdown path tracks docs_config.jl's TUTORIALS_SUBDIR
                # (the template default until the package customises it).
                @test occursin("docs/src/release-notes.md", txt)
                @test occursin(
                    "docs/src/getting-started/tutorials/*.md", txt
                )
                # The benchmark-history page's Plots.jl chart (#114) is also
                # generated by docs/make.jl and must not be committed. It is
                # written beside that page (`joinpath(dirname(dest),
                # "overall_trend.png")`), so moving the page under
                # `docs/src/benchmarks/` moved the chart with it (#299/#305).
                @test occursin(
                    "docs/src/benchmarks/overall_trend.png", txt
                )
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
                write(
                    cfg,
                    replace(
                        read(cfg, String),
                        "const TUTORIALS_SUBDIR = " *
                            "joinpath(\"getting-started\", \"tutorials\")" => "const TUTORIALS_SUBDIR = \"how-to/walkthroughs\""
                    )
                )
                update(dir)
                txt = read(joinpath(dir, ".gitignore"), String)
                @test occursin("docs/src/how-to/walkthroughs/*.md", txt)
                @test !occursin(
                    "docs/src/getting-started/tutorials/*.md", txt
                )
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
                write(
                    joinpath(dir, ".gitignore"),
                    "# MANAGED by EpiAwarePackageTools.scaffold — do not edit by hand.\n" *
                        "Manifest.toml\n" *
                        "docs/src/release-notes.md\n" *
                        "docs/src/getting-started/tutorials/*.md\n" *
                        "# Keep the bundled tutorial data (redistributed with the docs).\n" *
                        keep * "\n"
                )
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

        @testset ".git-blame-ignore-revs is seeded with a managed header only" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                res = scaffold(dir)
                @test res.git_blame_ignore === :created
                path = joinpath(dir, ".git-blame-ignore-revs")
                @test isfile(path)
                txt = read(path, String)
                @test occursin("MANAGED by EpiAwarePackageTools.scaffold", txt)
                @test occursin("blame.ignoreRevsFile", txt)
                @test occursin("# managed:start", txt)
                @test occursin("# managed:end", txt)
                # No SHA is seeded — that is package-owned, added on the repo's
                # own reformat commit.
                @test !occursin(r"^[0-9a-f]{40}$"m, txt)
            end
        end

        @testset ".git-blame-ignore-revs SHA list survives update" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                path = joinpath(dir, ".git-blame-ignore-revs")
                # A repo appends its own reformat SHA below the managed block.
                sha = "a"^40
                write(path, read(path, String) * sha * "\n")
                res2 = update(dir)
                @test res2.git_blame_ignore === :refreshed
                txt = read(path, String)
                @test occursin(sha, txt)
                @test occursin("MANAGED by EpiAwarePackageTools.scaffold", txt)
                # A further no-op update changes nothing (idempotent with a
                # package-owned SHA list present).
                before = read(path, String)
                res3 = update(dir)
                @test res3.git_blame_ignore === :refreshed
                @test read(path, String) == before
            end
        end

        @testset "AGENTS.md points at the docs, CLAUDE.md at AGENTS.md" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                res = scaffold(dir)
                @test res.agents === :created
                txt = read(joinpath(dir, "AGENTS.md"), String)
                @test occursin("MANAGED by EpiAwarePackageTools.scaffold", txt)
                @test occursin("<!-- epiaware-standards:start", txt)
                @test occursin("<!-- epiaware-standards:end -->", txt)
                # Both files land in an agent's context whole on every
                # session, so the block spends one line on saying it is
                # managed rather than a separate comment block. Asserted
                # against the preamble above the package heading, not the
                # whole file, so adding a standards link stays free.
                preamble = first(split(txt, "\n# "))
                @test count(==('\n'), preamble) <= 1
                @test !occursin("<!--\nMANAGED by", txt)
                # The block points at the standards docs rather than
                # restating them, so a second copy cannot drift (#370).
                @test occursin("Package standards", txt)
                @test occursin(
                    "epiawarepackagetools.epiaware.org/stable/standards", txt
                )
                @test occursin("epiaware.org/approaches", txt)
                # Substituted, so it names the package and its own docs.
                @test occursin("# Wombat", txt)
                # CLAUDE.md is a pointer at AGENTS.md, nothing more.
                claude = read(joinpath(dir, "CLAUDE.md"), String)
                @test occursin("[AGENTS.md](AGENTS.md)", claude)
                @test !occursin("Package standards", claude)
                # A one-line pointer, so the wrapper around it stays smaller
                # than the line it wraps.
                @test count(==('\n'), claude) <= 4
                # The standards themselves are NOT copied in.
                @test !occursin("Comment the reason, not the action.", txt)
            end
        end

        @testset "AGENTS.md package-owned tail survives update" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                path = joinpath(dir, "AGENTS.md")
                notes = "## Wombat notes\n\nThe kernel cache is not thread-safe."
                write(path, read(path, String) * "\n" * notes * "\n")
                res = update(dir)
                @test res.agents === :refreshed
                @test occursin(notes, read(path, String))
                # Idempotent with a tail present.
                before = read(path, String)
                update(dir)
                @test read(path, String) == before
            end
        end

        @testset "AGENTS.md a package already had is kept below the block" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                own = "# Wombat\n\nRun the slow suite with `task test-ad`.\n"
                write(joinpath(dir, "AGENTS.md"), own)
                res = update(dir)
                @test res.agents === :injected
                txt = read(joinpath(dir, "AGENTS.md"), String)
                @test occursin(own, txt)
                @test occursin("<!-- epiaware-standards:start", txt)
                # Idempotent once the markers exist.
                before = txt
                update(dir)
                @test read(joinpath(dir, "AGENTS.md"), String) == before
            end
        end

        @testset "the older multi-line agent header is retired on sync" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                path = joinpath(dir, "AGENTS.md")
                # What an adopter scaffolded before this change carries: a
                # bare start marker followed by the five-line header comment.
                # The marker is matched on its prefix, so the whole region is
                # rewritten rather than the old header surviving below a new
                # marker.
                legacy = string(
                    "<!-- epiaware-standards:start -->\n",
                    "<!--\n",
                    "MANAGED by EpiAwarePackageTools.scaffold — do not edit ",
                    "by hand.\n",
                    "Edit it in the kit's `templates/AGENTS.md`. ",
                    "Package-specific notes\n",
                    "go after the closing marker; they are preserved across ",
                    "updates.\n",
                    "-->\n\n# Wombat\n",
                    "<!-- epiaware-standards:end -->\n",
                    "\n## Wombat notes\n"
                )
                write(path, legacy)
                @test update(dir).agents === :refreshed
                txt = read(path, String)
                @test !occursin("<!--\nMANAGED by", txt)
                @test !occursin("do not edit by hand", txt)
                @test occursin("## Wombat notes", txt)
            end
        end

        @testset "AGENTS.md stale block is overwritten" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                path = joinpath(dir, "AGENTS.md")
                stale = replace(
                    read(path, String),
                    "Package standards" => "Stale wording."
                )
                write(path, stale)
                res = update(dir)
                @test res.agents === :refreshed
                txt = read(path, String)
                @test occursin("Package standards", txt)
                @test !occursin("Stale wording.", txt)
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

        @testset "test envs bound EpiAwarePackageTools in [compat]" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; benchmarks = true)
                # Every env that depends on the kit must resolve it. The kit is
                # registered, so that is an ordinary registry bound rather than
                # a git `[sources]` pin (#361).
                bound = "EpiAwarePackageTools = " *
                    "\"$(EpiAwarePackageTools.KIT_COMPAT)\""
                for f in (
                        "test/Project.toml", "test/ad/Project.toml",
                        "test/jet/Project.toml", "benchmark/Project.toml",
                    )
                    txt = read(joinpath(dir, f), String)
                    @test occursin(bound, txt)
                    @test !occursin(
                        r"(?m)^EpiAwarePackageTools = \{url = ", txt
                    )
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
                for f in (
                        "test/runtests.jl", "test/package/qa_config.jl",
                        "test/ad/scenarios.jl", "benchmark/benchmarks.jl",
                    )
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
                _fake_pkg(
                    dir; name = "Wombat",
                    authors = "[\"Ada Lovelace <ada@x.org>\", \"Wombat team\"]"
                )
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
                # `replaceActorsForAssignable` on the update path (#122). The
                # action skips the `--assignee` flag when empty.
                act = read(
                    _dest(
                        dir,
                        ".github/actions/increment-version/action.yaml"
                    ), String
                )
                @test occursin("default: ''", act)
                @test !occursin("default: 'EpiAware'", act)
                @test !occursin("{{ASSIGNEE_DEFAULT}}", act)
                @test !occursin("{{REVIEWER}}", act)
                @test occursin("ASSIGNEE_ARGS", act)
                # A pre-release/build suffix is stripped (release what the
                # number says) rather than incremented, so an unregistered
                # package at `X.Y.Z-DEV` does not get a maiden bump that skips
                # `X.Y.Z` (#255). Parsing off the suffix-free base also stops
                # `$(( PATCH + 1 ))` coercing a "0-DEV" patch field to 1.
                @test occursin(
                    "BASE_VERSION=\"\${CURRENT_VERSION%%[-+]*}\"",
                    act
                )
                @test occursin("suffix stripped, no increment", act)
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
                claude = read(
                    _dest(dir, ".github/workflows/claude.yml"),
                    String
                )
                @test occursin("github.actor == 'octocat'", claude)
                @test !occursin("{{REVIEWER}}", claude)
                review = read(
                    _dest(dir, ".github/workflows/claude-code-review.yml"),
                    String
                )
                @test occursin("user.login == 'octocat'", review)
                # The version-bump assignee default is the handle (a real user
                # GitHub can assign), not empty.
                act = read(
                    _dest(
                        dir,
                        ".github/actions/increment-version/action.yaml"
                    ), String
                )
                @test occursin("default: 'octocat'", act)
            end
        end

        @testset "input overrides win over Project.toml + defaults" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(
                    dir; org = "MyOrg", holder = "The Holder",
                    reviewer = "octocat"
                )
                lic = read(joinpath(dir, "LICENSE"), String)
                @test occursin("The Holder", lic)
                test_yaml = read(
                    _dest(dir, ".github/workflows/test.yaml"),
                    String
                )
                @test occursin(
                    "MyOrg/.github/.github/workflows/tests.yml",
                    test_yaml
                )
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
                owned = _dest(dir, "test/package/qa_config.jl")
                managed = _dest(dir, "test/package/quality.jl")
                owned_marker = "# PACKAGE EDIT — keep me\n"
                write(owned, owned_marker * read(owned, String))
                write(managed, "# drifted\n")

                res = update(dir; benchmarks = true)
                # Only managed files are touched; all of them already existed, so
                # they are `updated`, none `created`, none `preserved`.
                @test isempty(res.created)
                @test Set(res.updated) ==
                    Set(_dest(dir, d) for d in MANAGED_DESTS)
                @test isempty(res.preserved)

                # The managed file's drift was overwritten back to the template.
                @test occursin("Quality: Aqua", read(managed, String))
                # The package-owned file's edit was preserved (update skips it).
                @test occursin(owned_marker, read(owned, String))
                # No package-owned file appears in the update manifest at all.
                for d in OWNED_DESTS
                    @test _dest(dir, d) ∉ res.updated
                end

                # Idempotent: a second update produces no content change.
                before = Dict(
                    f => read(joinpath(dir, f), String)
                        for f in MANAGED_DESTS
                )
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

                codeowners = _dest(dir, ".github/CODEOWNERS")
                dependabot = _dest(dir, ".github/dependabot.yml")
                action = _dest(
                    dir,
                    ".github/actions/increment-version/action.yaml"
                )

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
                joinpath(tempdir(), "no-such-scaffold-target-xyz")
            )
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
                for f in (
                        ".github/workflows/ad.yaml",
                        "test/ad/setup.jl", "test/ad/runtests.jl",
                        "test/ad/run_selected.jl",
                        "test/ad/scenarios.jl", "test/ad/Project.toml",
                        "test/ADFixtures/Project.toml",
                        "test/ADFixtures/src/ADFixtures.jl",
                    )
                    @test !isfile(joinpath(dir, f))
                end
                @test !isdir(_dest(dir, "test/ad"))
                @test !isdir(_dest(dir, "test/ADFixtures"))
                # The non-AD infra is still written.
                for f in (
                        "Taskfile.yml", "codecov.yml", "test/Project.toml",
                        ".github/workflows/test.yaml", "test/package/quality.jl",
                    )
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
                @test !isfile(
                    _dest(
                        dir,
                        "docs/src/getting-started/tutorials/ad-backends.jl"
                    )
                )
                # Nor the AD-comparison benchmark page split out of it
                # (#299/#305, now under docs/src/benchmarks/).
                @test !isfile(
                    _dest(
                        dir,
                        "docs/src/benchmarks/ad-comparison.jl"
                    )
                )
                cfg = read(_dest(dir, "docs/docs_config.jl"), String)
                @test occursin("const HEAVY_TUTORIALS = String[]", cfg)
                @test occursin("const HEAVY_BENCHMARKS = String[]", cfg)
                @test !occursin("\"ad-backends.jl\"", cfg)
                @test !occursin("\"ad-backends.md\"", cfg)
                @test !occursin("\"ad-comparison.jl\"", cfg)
                @test !occursin("\"ad-comparison.md\"", cfg)
                pgs = read(_dest(dir, "docs/pages.jl"), String)
                @test !occursin("ad-backends.md", pgs)
                @test !occursin("ad-comparison", pgs)
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
                for f in (
                        ".github/workflows/ad.yaml", "test/ad/setup.jl",
                        "test/ad/run_selected.jl",
                        "test/ad/scenarios.jl", "test/ADFixtures/src/ADFixtures.jl",
                    )
                    @test isfile(joinpath(dir, f))
                end
                cov = read(joinpath(dir, "codecov.yml"), String)
                @test occursin("ad-forwarddiff", cov)
            end
        end

        @testset "ad = true force-rewrites run_selected.jl on update() (#384)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Selectra")
                scaffold(dir)  # default ad = true
                runner = _dest(dir, "test/ad/run_selected.jl")
                @test occursin("run_selected", read(runner, String))
                write(runner, "# drifted, hand-edited\n")
                res = update(dir)
                @test runner in res.updated
                txt = read(runner, String)
                @test occursin("MANAGED by EpiAwarePackageTools.scaffold", txt)
                @test occursin("EpiAwarePackageTools.run_selected", txt)
                @test occursin("--backend", txt)
                @test occursin("--scenario", txt)
            end
        end

        @testset "ext is flagged under `unit` only (#180)" begin
            # AD jobs run without the weakdeps loaded, so an `ext` path under
            # an `ad-*` flag reports 0% and drags the aggregate down; the
            # unit job (which loads them) may claim extension coverage. The
            # two Enzyme AD jobs are the exception, but they name the Enzyme
            # extension file rather than the directory (#416), so a package
            # with no Enzyme extension claims no `ext` path under any AD flag.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = true)
                cov = read(joinpath(dir, "codecov.yml"), String)
                @test count("      - ext", cov) == 1
                unit = split(cov, "  unit:")[2]
                @test occursin("- ext", split(unit, "carryforward")[1])
            end

            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false)
                cov = read(joinpath(dir, "codecov.yml"), String)
                @test count("      - ext", cov) == 1
                unit = split(cov, "  unit:")[2]
                @test occursin("- ext", split(unit, "carryforward")[1])
            end
        end

        @testset "the AD-backends tutorial is retired" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # Neither the page nor any trace of its registration.
                @test !isfile(
                    _dest(
                        dir,
                        "docs/src/getting-started/tutorials/ad-backends.jl"
                    )
                )
                cfg = read(_dest(dir, "docs/docs_config.jl"), String)
                # No Literate registration and no stub for it. The string
                # "ad-backends" does still appear, as the anchor the
                # AD-comparison stub carries, so match the registration.
                @test !occursin("ad-backends.jl", cfg)
                @test !occursin("\"ad-backends.md\" =>", cfg)
                @test occursin("const HEAVY_TUTORIALS = String[]", cfg)
                @test occursin("const TUTORIAL_STUBS = Pair{String, String}[]", cfg)
                pgs = read(_dest(dir, "docs/pages.jl"), String)
                @test !occursin("getting-started/tutorials/ad-backends", pgs)
                @test !occursin("\"Tutorials\"", pgs)
            end
            # An adopter carrying the page and its registration has the page
            # deleted, and is told to drop the registration `update` cannot
            # reach (docs_config.jl is package-owned).
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                tut = _dest(
                    dir,
                    "docs/src/getting-started/tutorials/ad-backends.jl"
                )
                mkpath(dirname(tut))
                write(tut, "# stale managed page\n")
                write(
                    joinpath(dirname(tut), "ad-backends.md"),
                    "# stale rendered page\n"
                )
                cfg = _dest(dir, "docs/docs_config.jl")
                write(
                    cfg,
                    replace(
                        read(cfg, String),
                        "const HEAVY_TUTORIALS = String[]" =>
                            "const HEAVY_TUTORIALS = String[\"ad-backends.jl\"]"
                    )
                )
                local res
                @test_logs (:warn, r"ad-backends"i) match_mode = :any begin
                    res = update(dir)
                end
                @test !isfile(tut)
                @test !isfile(joinpath(dirname(tut), "ad-backends.md"))
                @test any(w -> occursin("ad-backends", w), res.warnings)
                @test any(w -> occursin("HEAVY_TUTORIALS", w), res.warnings)
            end
        end

        @testset "ad = true ships the AD-comparison benchmark page (#299/#305)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                tut = _dest(dir, "docs/src/benchmarks/ad-comparison.jl")
                @test isfile(tut)
                txt = read(tut, String)
                # Managed, substituted, and anchored for cross-references.
                @test occursin("MANAGED by EpiAwarePackageTools.scaffold", txt)
                @test occursin("@id ad-comparison", txt)
                @test occursin("using Wombat", txt)
                @test !occursin("{{", txt)
                # Carries the retired tutorial's anchor, so the @ref links
                # package pages across the org already hold keep resolving.
                @test occursin("@id ad-backends", txt)
                # The benchmark computation itself.
                @test occursin("benchmark_differentiation", txt)
                # DIT 0.11 needs Chairmarks loaded explicitly for
                # `benchmark_differentiation`/`run_benchmark!` to resolve.
                @test occursin("using Chairmarks", txt)
                # The substituted script is valid Julia (Literate executes it
                # in the docs build): parse it whole and require no error or
                # incomplete trailing expression.
                parsed = Meta.parseall(txt)
                @test parsed isa Expr
                @test !any(
                    ex -> ex isa Expr && ex.head in (:error, :incomplete),
                    parsed.args
                )

                # The summary table is emitted through the wrapper, never as
                # a bare DataFrame (#305).
                @test occursin("markdown_table(summary_table)", txt)
                @test !occursin(r"(?m)^summary_table$", txt)

                # ...and the wrapper behaves: a DataFrame is `showable` as
                # `text/html`, and Literate and DocumenterVitepress both take
                # that branch first, so returning one drops DataFrames' own
                # styled `<table>` into the page as raw HTML, outside
                # VitePress's table styling. `MarkdownTable` is showable ONLY
                # as `text/markdown`, so both writers emit a plain pipe table
                # that VitePress renders natively. Evaluate the substituted
                # definitions in a sandbox against a stand-in frame, so the
                # kit's own tests need no DataFrames dependency.
                helper_start = first(
                    findfirst("struct MarkdownTable", txt)
                )
                helper_stop = first(
                    findfirst(
                        "backend_entries = ADFixtures.backends()", txt
                    )
                ) - 1
                helpers = txt[helper_start:helper_stop]
                mock = """
                struct MockFrame
                    cols::Vector{String}
                    rows::Vector{Vector{Any}}
                end
                Base.names(d::MockFrame) = d.cols
                Base.eachrow(d::MockFrame) =
                    [Dict{String, Any}(zip(d.cols, r)) for r in d.rows]
                """
                sandbox = Module(:ADComparisonSandbox)
                Core.eval(sandbox, Meta.parseall(mock * "\n" * helpers))
                # Probe from inside the sandbox: the definitions above land
                # in a newer world age than this test body, so `showable`
                # and `show` called from here would not see them.
                probe = Core.eval(
                    sandbox,
                    quote
                        tbl = markdown_table(
                            MockFrame(
                                ["Backend", "Relative time"],
                                [
                                    Any["ForwardDiff", 1.0],
                                    Any["Enzyme reverse", 3.39],
                                ]
                            )
                        )
                        (
                            html = showable(MIME("text/html"), tbl),
                            png = showable(MIME("image/png"), tbl),
                            md = showable(MIME("text/markdown"), tbl),
                            text = sprint(show, MIME("text/markdown"), tbl),
                        )
                    end
                )
                @test !probe.html
                @test !probe.png
                @test probe.md
                @test occursin("| Backend | Relative time |", probe.text)
                @test occursin("|:---|---:|", probe.text)
                @test occursin("| ForwardDiff | 1.0 |", probe.text)
                @test occursin("| Enzyme reverse | 3.39 |", probe.text)
                # No DataFrames chrome: no `N×M DataFrame` caption, no `Row`
                # index column, no column-type row, no inline styles.
                @test !occursin("DataFrame", probe.text)
                @test !occursin("style =", probe.text)
                # A `|` in a cell is escaped, so a registry backend name
                # carrying one cannot split the row into extra columns.
                piped = Core.eval(
                    sandbox,
                    quote
                        t = markdown_table(
                            MockFrame(
                                ["Backend"], [Any["Enzyme|reverse"]]
                            )
                        )
                        sprint(show, MIME("text/markdown"), t)
                    end
                )
                @test occursin("| Enzyme\\|reverse |", piped)

                # Registered in the package-owned docs seeds: its own
                # `docs/src/benchmarks/` Literate pipeline (heavy + stub,
                # not HEAVY_TUTORIALS/TUTORIAL_STUBS) and the top-level
                # Benchmarks nav (not Tutorials -- the whole point of the
                # split, #305).
                cfg = read(_dest(dir, "docs/docs_config.jl"), String)
                @test occursin("\"ad-comparison.jl\"", cfg)
                # The stub carries both anchors: `ad-comparison` for this
                # page and `ad-backends` for the retired tutorial, whose
                # cross-references must keep resolving in a fast build.
                @test occursin(
                    "\"ad-comparison.md\" => \"# [AD backend " *
                        "comparison](@id ad-comparison)\\n\\n## " *
                        "[Choosing a backend](@id ad-backends)\"", cfg
                )
                @test occursin(
                    "HEAVY_BENCHMARKS = String[\n    " *
                        "\"ad-comparison.jl\"", cfg
                )
                pgs = read(_dest(dir, "docs/pages.jl"), String)
                @test occursin("benchmarks/ad-comparison.md", pgs)
                @test occursin("\"Benchmarks\"", pgs)
                @test !occursin("{{", pgs)
            end
        end

        # Nests the performance-over-time and AD-comparison pages under one
        # "Benchmarks" entry when both suites are on (#299/#305).
        @testset "Benchmarks nav nests both suites when both are on" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; benchmarks = true)
                pgs = read(_dest(dir, "docs/pages.jl"), String)
                @test occursin(
                    "\"Performance over time\" => \"benchmarks/over-time.md\"",
                    pgs
                )
                @test occursin(
                    "\"AD comparison\" =>\n            " *
                        "\"benchmarks/ad-comparison.md\"", pgs
                )
                @test !occursin("{{", pgs)
            end
        end

        @testset "Benchmarks nav is a lone AD-comparison dropdown (#305)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; benchmarks = false)
                pgs = read(_dest(dir, "docs/pages.jl"), String)
                # Scope to the substituted `pages` array itself, not the
                # header comment above it (which mentions "benchmarks.md" as
                # prose describing the benchmarks=true case).
                arr = pgs[findfirst("pages = [", pgs)[1]:end]
                # Always a dropdown group, even with a single page (#305):
                # "its own header drop down", not a bare flat link.
                @test occursin(
                    "\"Benchmarks\" => [\n        \"AD comparison\" =>\n" *
                        "            \"benchmarks/ad-comparison.md\",\n    ]",
                    arr
                )
                @test !occursin("benchmarks/over-time.md", arr)
                @test !occursin("Performance over time", arr)
            end
        end

        @testset "Benchmarks nav is absent with neither ad nor benchmarks" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false, benchmarks = false)
                pgs = read(_dest(dir, "docs/pages.jl"), String)
                arr = pgs[findfirst("pages = [", pgs)[1]:end]
                @test !occursin("\"Benchmarks\"", arr)
            end
        end

        @testset "Benchmarks nav is a lone performance-over-time dropdown (#305)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false, benchmarks = true)
                pgs = read(_dest(dir, "docs/pages.jl"), String)
                arr = pgs[findfirst("pages = [", pgs)[1]:end]
                @test occursin(
                    "\"Benchmarks\" => [\n        \"Performance over time\"" *
                        " => \"benchmarks/over-time.md\",\n    ]", arr
                )
                @test !occursin("ad-comparison", arr)
            end
        end

        @testset "update() refreshes the managed AD comparison page" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                tut = _dest(dir, "docs/src/benchmarks/ad-comparison.jl")
                # A drifted page body is re-applied from the kit (that is the
                # point: the page stays kit-current; declarations live in the
                # package-owned ADFixtures registry instead).
                write(tut, "# drifted by hand\n")
                res = update(dir)
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
                # A bare update() force-overwrites the managed driver.
                write(setup, "# hand-edited, no marker\n")
                res = update(dir)
                @test setup in res.updated
                @test occursin("test_working_backend", read(setup, String))
                # Marking the driver package-owned makes update() preserve it.
                owned = "# $(_AD_SETUP_OWNED_MARKER): keep this driver\n" *
                    "@testsnippet ADHelpers begin\n    # legacy driver\nend\n"
                write(setup, owned)
                @test _detect_ad_setup_owned(dir)
                res2 = update(dir)
                @test setup in res2.preserved
                @test read(setup, String) == owned
                # scaffold(force = true) still re-lays the managed driver.
                scaffold(dir; force = true)
                @test occursin("test_working_backend", read(setup, String))
            end
        end

        @testset "update warns before clobbering a diverged, unmarked ad setup.jl" begin
            # A managed test/ad/setup.jl that diverges from the fresh render
            # but carries no ownership marker is a strong signal it was
            # customised and the marker was simply never added — the exact
            # footgun that nearly broke CensoredDistributions' AD CI:
            # update silently overwrote a heavily customised,
            # unmarked driver. It still overwrites (managed files always
            # resync), but now warns rather than proceeding silently.
            mktempdir() do dir
                _fake_pkg(dir; name = "Numeric2")
                scaffold(dir)
                setup = _dest(dir, "test/ad/setup.jl")
                write(setup, "# hand-edited, no marker\n")
                local res
                @test_logs (:warn, r"test/ad/setup\.jl.*no.*marker"i) match_mode = :any begin
                    res = update(dir)
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
                res = update(dir)
                @test isempty(res.warnings)
            end
        end

        @testset "update warns when Project.toml carries a comment" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Numeric3b")
                scaffold(dir)
                proj = joinpath(dir, "Project.toml")
                write(
                    proj,
                    replace(
                        read(proj, String),
                        "[workspace]" => "# pinned for a reason\n[workspace]"
                    )
                )
                res = update(dir)
                @test any(
                    w -> occursin("Project.toml", w) && occursin("comment", w),
                    res.warnings
                )
            end
            # A clean, never-commented Project.toml raises nothing.
            mktempdir() do dir
                _fake_pkg(dir; name = "Numeric3c")
                scaffold(dir)
                @test isempty(update(dir).warnings)
            end
        end

        @testset "update warns when docs_config.jl lacks HEAVY_BENCHMARKS (#305)" begin
            # An `ad = true` adopter who synced before the ad-comparison.jl
            # split (#299/#305) has no HEAVY_BENCHMARKS/BENCHMARK_STUBS
            # consts at all (they did not exist yet). `update` cannot add the missing registration itself
            # (docs_config.jl is package-owned), so it should warn that the
            # new managed page it just wrote is never rendered rather than
            # leaving the gap undiscovered.
            mktempdir() do dir
                _fake_pkg(dir; name = "PreSplit")
                scaffold(dir)
                cfg = _dest(dir, "docs/docs_config.jl")
                txt = read(cfg, String)
                txt = replace(
                    txt,
                    "const HEAVY_BENCHMARKS = String[\n" *
                        "    \"ad-comparison.jl\",\n]" => "const HEAVY_BENCHMARKS = String[]"
                )
                # Matched by regex rather than by the literal seeded text:
                # the stub heading carries two anchors now (ad-comparison and
                # the retired tutorial's ad-backends), so pinning the exact
                # string here would make this fixture track the wording.
                txt = replace(
                    txt,
                    r"const BENCHMARK_STUBS = Pair\{String, String\}\[.*?\]"s =>
                        "const BENCHMARK_STUBS = Pair{String, String}[]"
                )
                write(cfg, txt)
                local res
                @test_logs (:warn, r"ad-comparison\.jl"i) match_mode = :any begin
                    res = update(dir)
                end
                @test !isempty(res.warnings)
                @test any(w -> occursin("ad-comparison.jl", w), res.warnings)
                @test any(w -> occursin("HEAVY_BENCHMARKS", w), res.warnings)
                # The managed ad-comparison.jl page is still written — the
                # warning flags a docs-build gap, not a template omission.
                @test isfile(
                    _dest(
                        dir,
                        "docs/src/benchmarks/ad-comparison.jl"
                    )
                )
            end
            # A fresh scaffold registers both entries, so no warning fires.
            mktempdir() do dir
                _fake_pkg(dir; name = "FreshSplit")
                scaffold(dir)
                res = update(dir)
                @test isempty(res.warnings)
            end
            # `ad = false` never expects the registration, so no warning.
            mktempdir() do dir
                _fake_pkg(dir; name = "NoAD")
                scaffold(dir; ad = false)
                res = update(dir; ad = false)
                @test isempty(res.warnings)
            end
        end

        @testset "update warns when a managed AD backend has no test item" begin
            # A backend added to `_AD_BACKENDS` after a package scaffolded
            # reaches its managed ad.yaml matrix, codecov flags and README
            # badge row on the next sync, but not the package-owned
            # `test/ad/scenarios.jl` seed. The job then runs zero tests,
            # reports green, and uploads an empty coverage flag (#415).

            # The seed writes one `tags = [.., :<tag>]` item per backend, so
            # retagging that list drops exactly that backend's items, as an
            # adopter scaffolded before the backend existed would have.
            # `count` leaves the file's trailing commented example alone.
            function _drop_backend(dir, tag; count = typemax(Int))
                scen = _dest(dir, "test/ad/scenarios.jl")
                txt = read(scen, String)
                write(
                    scen,
                    replace(
                        txt, ":$(tag)]" => ":placeholder_other]"; count = count
                    )
                )
                return scen
            end
            mktempdir() do dir
                _fake_pkg(dir; name = "PreBackend")
                scaffold(dir)
                _drop_backend(dir, "reversediff_compiled")
                local res
                pat = r"reversediff_compiled"
                @test_logs (:warn, pat) match_mode = :any begin
                    res = update(dir)
                end
                @test any(
                    w -> occursin(":reversediff_compiled", w), res.warnings
                )
                @test any(w -> occursin("kit#415", w), res.warnings)
            end
            # The same boundary the other way round. Dropping `:reversediff`
            # while the `:reversediff_compiled` items remain must still warn,
            # or a tag that merely prefixes another looks covered by it.
            mktempdir() do dir
                _fake_pkg(dir; name = "PrefixBackend")
                scaffold(dir)
                _drop_backend(dir, "reversediff")
                res = update(dir)
                @test any(w -> occursin(r":reversediff\b", w), res.warnings)
                @test !any(
                    w -> occursin(":reversediff_compiled", w), res.warnings
                )
            end
            # A commented-out item is not an item. The seed ships a commented
            # `:forwarddiff` example below the live items, so dropping only
            # the live one must still warn.
            mktempdir() do dir
                _fake_pkg(dir; name = "CommentedBackend")
                scaffold(dir)
                _drop_backend(dir, "forwarddiff"; count = 1)
                res = update(dir)
                @test occursin(
                    ":forwarddiff",
                    read(_dest(dir, "test/ad/scenarios.jl"), String)
                )
                @test any(w -> occursin(":forwarddiff", w), res.warnings)
            end
            # A freshly scaffolded package seeds an item per managed backend.
            mktempdir() do dir
                _fake_pkg(dir; name = "FreshBackends")
                scaffold(dir)
                @test isempty(update(dir).warnings)
            end
            # `ad = false` ships no ad.yaml matrix, so there is no gap.
            mktempdir() do dir
                _fake_pkg(dir; name = "NoADBackends")
                scaffold(dir; ad = false)
                @test isempty(update(dir; ad = false).warnings)
            end
        end

        @testset "update warns when package-owned prose names a retired tool" begin
            # A sync converges the managed files and says nothing about the
            # package's own docs, so prose describing the old standard
            # survives every sync with nothing reporting it (#328). The
            # observed case: EpiAwareADTools took the kit's Runic migration
            # and kept telling contributors to run JuliaFormatter.
            mktempdir() do dir
                _fake_pkg(dir; name = "StaleProse")
                scaffold(dir)
                page = _dest(dir, "docs/src/getting-started/index.md")
                mkpath(dirname(page))
                write(
                    page,
                    "# Getting started\n\nFormat with JuliaFormatter " *
                        "before opening a pull request.\n"
                )
                local res
                @test_logs (:warn, r"JuliaFormatter"i) match_mode = :any begin
                    res = update(dir)
                end
                @test any(w -> occursin("JuliaFormatter", w), res.warnings)
                @test any(w -> occursin("Runic", w), res.warnings)
                @test any(
                    w -> occursin("getting-started", w), res.warnings
                )
                # It reports only. The wording is the package's, so the file
                # is left exactly as it was.
                @test occursin("JuliaFormatter", read(page, String))
            end
            # A retired path should not still be documented either, so every
            # RETIRED_PATHS entry gets a prose check without being listed
            # twice.
            mktempdir() do dir
                _fake_pkg(dir; name = "StalePath")
                scaffold(dir)
                write(
                    _dest(dir, "CONTRIBUTING.md"),
                    "Formatting settings live in `.JuliaFormatter.toml`.\n"
                )
                res = update(dir)
                @test any(
                    w -> occursin(".JuliaFormatter.toml", w), res.warnings
                )
                # One mention, one complaint. `.JuliaFormatter.toml` matches
                # both the retired path and the retired tool name inside it,
                # and naming it twice reads as two problems.
                @test sum(
                    length(findall("CONTRIBUTING.md still mentions", w))
                        for w in res.warnings
                ) == 1
            end
            # A changelog records what the package used to do, so naming a
            # retired tool there is correct. `docs/src/release-notes.md` is
            # generated by the docs build and is this kit's NEWS.md successor,
            # so it is excluded on the same grounds.
            mktempdir() do dir
                _fake_pkg(dir; name = "ChangelogProse")
                scaffold(dir)
                for rel in (
                        "NEWS.md", "docs/src/release-notes.md",
                        "docs/src/CHANGELOG.md",
                    )
                    path = _dest(dir, rel)
                    mkpath(dirname(path))
                    write(path, "Moved off JuliaFormatter in v2.\n")
                end
                @test isempty(update(dir).warnings)
            end
            # A package with no docs/src at all is scanned without error.
            mktempdir() do dir
                _fake_pkg(dir; name = "NoDocsProse")
                scaffold(dir)
                rm(_dest(dir, "docs/src"); recursive = true)
                write(
                    _dest(dir, "CONTRIBUTING.md"),
                    "Run JuliaFormatter before pushing.\n"
                )
                res = update(dir)
                @test any(w -> occursin("JuliaFormatter", w), res.warnings)
            end
            # A page naming a retired tool to explain the retirement is not
            # drift, so the marker opts it out.
            mktempdir() do dir
                _fake_pkg(dir; name = "ExplainsProse")
                scaffold(dir)
                write(
                    _dest(dir, "CONTRIBUTING.md"),
                    "<!-- EPIAWARE_PROSE_OK -->\n\nWe moved off " *
                        "JuliaFormatter in v2.\n"
                )
                @test isempty(update(dir).warnings)
            end
            # A freshly scaffolded package's own prose is clean.
            mktempdir() do dir
                _fake_pkg(dir; name = "FreshProse")
                scaffold(dir)
                @test isempty(update(dir).warnings)
            end
        end

        @testset "update warns when docs/Project.toml keeps a dropped AD dep" begin
            # `docs/Project.toml` is package-owned and write-once, so dropping
            # AlgebraOfGraphics from `_ad_docs_deps` only lands on a fresh
            # scaffold. An adopter who synced before the AD-comparison split
            # keeps it, and with it the DimensionalData/FlexiChains resolver
            # conflict it was removed to fix (kit#283), now with nothing in
            # the build using it.
            mktempdir() do dir
                _fake_pkg(dir; name = "StaleDeps")
                scaffold(dir)
                proj = _dest(dir, "docs/Project.toml")
                txt = read(proj, String)
                @test !occursin("AlgebraOfGraphics", txt)
                # Reinstate the dep the way a pre-split adopter still carries
                # it, in both [deps] and [compat].
                txt = replace(
                    txt,
                    "[deps]" =>
                        "[deps]\nAlgebraOfGraphics = " *
                        "\"cbdf2221-f076-402e-a563-3d30da359d67\""
                )
                txt = replace(txt, "[compat]" => "[compat]\nAlgebraOfGraphics = \"0.13\"")
                write(proj, txt)
                local res
                @test_logs (:warn, r"AlgebraOfGraphics"i) match_mode = :any begin
                    res = update(dir)
                end
                @test any(w -> occursin("AlgebraOfGraphics", w), res.warnings)
                @test any(w -> occursin("docs/Project.toml", w), res.warnings)
                # The dep is not removed for them: docs/Project.toml is
                # package-owned, so the warning is the whole remedy.
                @test occursin("AlgebraOfGraphics", read(proj, String))
            end
            # A fresh scaffold never carries the dep, so no warning fires.
            mktempdir() do dir
                _fake_pkg(dir; name = "FreshDeps")
                scaffold(dir)
                @test isempty(update(dir).warnings)
            end
            # `ad = false` has no AD docs env to be stale.
            mktempdir() do dir
                _fake_pkg(dir; name = "NoADDeps")
                scaffold(dir; ad = false)
                @test isempty(update(dir; ad = false).warnings)
            end
            # The other direction: a dep the managed AD pages load is absent,
            # because docs/Project.toml is write-once and the kit added it
            # after this package was scaffolded.
            mktempdir() do dir
                _fake_pkg(dir; name = "MissingDeps")
                scaffold(dir)
                proj = joinpath(dir, "docs", "Project.toml")
                write(
                    proj,
                    replace(
                        read(proj, String), r"Chairmarks = \"[^\"]*\"\n" => ""
                    )
                )
                @test_logs (:warn, r"missing Chairmarks"i) match_mode = :any begin
                    global res = update(dir)
                end
                @test any(w -> occursin("Chairmarks", w), res.warnings)
                # Package-owned, so the warning is the whole remedy here too.
                @test !occursin("Chairmarks", read(proj, String))
            end
        end

        @testset "update warns when a bespoke pages.jl lacks Benchmarks nav entries (#305)" begin
            # `docs/pages.jl` is now MANAGED: `update` regenerates a fresh
            # `BENCHMARKS_NAV` in full on every sync, so this gap only survives
            # in a bespoke, preserved `pages.jl` -- one with no
            # `_MANAGED_PAGES_MARKER` header, exactly what every adopter's
            # `pages.jl` looked like before #170/#328/#354 landed. Two ways it
            # can be stale: an `ad = true` adopter who forked before the
            # ad-comparison.jl split has no nav entry pointing at the new page
            # at all, and a `benchmarks = true` adopter who forked before #305
            # still has the pre-#305 nav pointing at a path the build no
            # longer writes.
            using EpiAwarePackageTools: _MANAGED_PAGES_MARKER
            # Strip the managed marker line, turning a freshly scaffolded
            # `pages.jl` into the bespoke, pre-redesign shape this test needs.
            _unmark(txt) = replace(txt, "# " * _MANAGED_PAGES_MARKER * "\n" => "")
            mktempdir() do dir
                _fake_pkg(dir; name = "PreSplitNav")
                scaffold(dir)
                pages = _dest(dir, "docs/pages.jl")
                txt = read(pages, String)
                @test occursin(
                    "\"Benchmarks\" => [\n        \"AD comparison\" =>\n" *
                        "            \"benchmarks/ad-comparison.md\",\n    ]",
                    txt
                )
                txt = replace(
                    txt,
                    ",\n    \"Benchmarks\" => [\n        \"AD comparison\" " *
                        "=>\n            \"benchmarks/ad-comparison.md\",\n    ]" => ""
                )
                write(pages, _unmark(txt))
                local res
                @test_logs (:warn, r"pages\.jl"i) match_mode = :any begin
                    res = update(dir)
                end
                # Bespoke, so preserved verbatim -- not silently regenerated.
                @test res.pages == :preserved
                @test read(pages, String) == _unmark(txt)
                @test !isempty(res.warnings)
                @test any(res.warnings) do w
                    occursin("pages.jl", w) && occursin("ad-comparison", w)
                end
            end
            # A `benchmarks = true` adopter's stale pre-#305 flat entry
            # (pointing at the path the build no longer writes) also warns,
            # even with `ad = false` so no AD entry is expected at all.
            mktempdir() do dir
                _fake_pkg(dir; name = "PreSplitHistoryNav")
                scaffold(dir; ad = false, benchmarks = true)
                pages = _dest(dir, "docs/pages.jl")
                txt = read(pages, String)
                txt = replace(
                    txt,
                    "\"Benchmarks\" => [\n        \"Performance over time\"" *
                        " => \"benchmarks/over-time.md\",\n    ]" => "\"Benchmarks\" => \"benchmarks.md\""
                )
                write(pages, _unmark(txt))
                local res
                @test_logs (:warn, r"pages\.jl"i) match_mode = :any begin
                    res = update(dir; ad = false, benchmarks = true)
                end
                @test res.pages == :preserved
                @test !isempty(res.warnings)
                @test any(res.warnings) do w
                    occursin("pages.jl", w) &&
                        occursin("over-time.md", w)
                end
            end
            # A fresh (still managed) scaffold self-heals instead of warning,
            # even after the same hand-edit: `update` just regenerates it.
            # Covered for all four (ad, benchmarks) combinations -- this is
            # exactly the class of gap (#305 built on top of #299) that has
            # already bitten this branch once when only one combination was
            # exercised.
            for (ad, benchmarks) in (
                    (true, false), (false, true), (true, true), (
                        false, false,
                    ),
                )
                mktempdir() do dir
                    _fake_pkg(
                        dir;
                        name = "Fresh$(ad)$(benchmarks)Nav"
                    )
                    scaffold(dir; ad = ad, benchmarks = benchmarks)
                    res = update(dir; ad = ad, benchmarks = benchmarks)
                    @test isempty(res.warnings)
                    @test res.pages in (:unchanged, :refreshed)
                end
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
                    dir, ".github/workflows/test.yaml", unmarked_render
                )
                write(wf, "# hand-edited, no marker\n")
                res = update(dir)
                @test wf in res.updated
                @test occursin("jobs:", read(wf, String))
                # Marking it makes update() preserve it verbatim.
                owned = "# $(_MANAGED_OVERRIDE_MARKER): package-owned CI\n" *
                    "name: Test\non: [push]\n"
                write(wf, owned)
                @test _detect_managed_override(
                    dir, ".github/workflows/test.yaml", unmarked_render
                )
                res2 = update(dir)
                @test wf in res2.preserved
                @test wf ∉ res2.updated
                @test read(wf, String) == owned
                # A marked, diverged file is a deliberate opt-out: no warning.
                @test isempty(res2.warnings)
                # The match is case-sensitive, as documented: a mis-cased
                # marker is not an opt-out and the file resyncs as usual.
                write(wf, "# epiaware_managed_override\nname: Test\n")
                @test !_detect_managed_override(
                    dir, ".github/workflows/test.yaml", unmarked_render
                )
                @test wf in update(dir).updated
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
                    dir, "test/ad/setup.jl", unmarked_render
                )
                res = update(dir)
                @test setup in res.preserved
                @test read(setup, String) == legacy
                # The generic marker is accepted on the same file.
                generic = "# $(_MANAGED_OVERRIDE_MARKER): kept driver\n"
                write(setup, generic)
                res2 = update(dir)
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
                        _MANAGED_OVERRIDE_MARKER, read(path, String)
                    )
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
                    dir, ".github/workflows/test.yaml", marked
                )
                @test EpiAwarePackageTools._detect_managed_override(
                    dir, ".github/workflows/test.yaml", "name: Test\n"
                )
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
                update(dir; repo = "FakeOrg/Regions.jl")
                # The managed blocks come back despite the marker.
                @test occursin(
                    EpiAwarePackageTools.GITIGNORE_START, read(gi, String)
                )
                body = read(readme, String)
                @test occursin(EpiAwarePackageTools.BADGES_START, body)
                @test occursin(
                    EpiAwarePackageTools.STANDARD_SECTIONS_START, body
                )
            end
        end

        @testset "no divergence warning for stale managed files (#224)" begin
            # A managed file that diverges from a fresh render is the *normal*
            # state right before a routine update (the adopter is
            # simply on an older kit version), so divergence alone cannot
            # distinguish "customised" from "stale". Only test/ad/setup.jl —
            # where a clobber breaks every AD CI job — warns.
            mktempdir() do dir
                _fake_pkg(dir; name = "Stale")
                scaffold(dir)
                wf = _dest(dir, ".github/workflows/test.yaml")
                write(wf, "# an older template version\nname: Test\n")
                res = update(dir)
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
                adyaml = read(
                    _dest(dir, ".github/workflows/ad.yaml"),
                    String
                )
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
                scenarios = read(
                    _dest(dir, "test/ad/scenarios.jl"),
                    String
                )
                @test count(r"(?m)^@testitem", scenarios) == n
            end

            @testset "reversediff compiled family tag (#386)" begin
                mktempdir() do dir
                    _fake_pkg(dir; name = "NumericRD")
                    scaffold(dir)
                    scenarios = read(
                        _dest(dir, "test/ad/scenarios.jl"), String
                    )
                    # The compiled variant carries only its own tag: no
                    # bare `:reversediff` family tag, since that would
                    # collide with the tape entry's own standalone tag and
                    # filtering by `:reversediff` would silently also
                    # select the compiled backend.
                    @test occursin(
                        "tags = [:ad, :reversediff_compiled]", scenarios
                    )
                    @test !occursin(
                        "tags = [:ad, :reversediff, :reversediff_compiled]",
                        scenarios
                    )
                    # The tape entry is unaffected.
                    @test occursin("tags = [:ad, :reversediff]", scenarios)
                end
            end

            @testset "enzyme codecov flags name the Enzyme ext (#386/#416)" begin
                # The Enzyme jobs are the only AD jobs that load one of the
                # package's extensions, so they are the only AD flags that
                # may claim anything under `ext/`. They claim the Enzyme
                # extension file, not the directory: a directory claim
                # charges them for every OTHER extension too, which is #180
                # one level down (#416).
                mktempdir() do dir
                    _fake_pkg(dir; name = "NumericEnzyme")
                    proj = joinpath(dir, "Project.toml")
                    write(
                        proj,
                        read(proj, String) *
                            "\n[weakdeps]\n" *
                            "Enzyme = \"7da242da-08ed-463a-9acd-ee780be4f1d9\"\n" *
                            "Plots = \"91a5bcdd-55d7-5caf-9e0b-520d859cae80\"\n" *
                            "\n[extensions]\n" *
                            "NumericEnzymeEnzymeExt = \"Enzyme\"\n" *
                            "NumericEnzymePlotsExt = \"Plots\"\n"
                    )
                    scaffold(dir)
                    cov = read(joinpath(dir, "codecov.yml"), String)
                    blocks = split(cov, r"(?=^  ad-)"m)
                    tested = String[]
                    for block in blocks
                        m = match(r"^  (ad-\S+):", block)
                        m === nothing && continue
                        flag = m.captures[1]
                        push!(tested, flag)
                        enzyme = flag in
                            ("ad-enzyme-forward", "ad-enzyme-reverse")
                        @test occursin(
                            "ext/NumericEnzymeEnzymeExt.jl", block
                        ) == enzyme
                        # Never the bare directory, and never the unrelated
                        # extension, under any AD flag.
                        @test !occursin("      - ext\n", block)
                        @test !occursin("NumericEnzymePlotsExt", block)
                    end
                    @test "ad-enzyme-forward" in tested
                    @test "ad-enzyme-reverse" in tested
                    # `unit` still claims the whole directory: that job loads
                    # every weakdep.
                    unit = split(cov, "  unit:")[2]
                    @test occursin("- ext", split(unit, "carryforward")[1])
                end
                # An extension triggered by Enzyme plus another weakdep still
                # matches, and a package with no Enzyme extension claims none.
                mktempdir() do dir
                    _fake_pkg(dir; name = "NumericMulti")
                    proj = joinpath(dir, "Project.toml")
                    write(
                        proj,
                        read(proj, String) *
                            "\n[weakdeps]\n" *
                            "Enzyme = \"7da242da-08ed-463a-9acd-ee780be4f1d9\"\n" *
                            "ChainRulesCore = \"d360d2e6-b24c-11e9-a2a3-2a2ae2dbcce4\"\n" *
                            "\n[extensions]\n" *
                            "NumericMultiRulesExt = [\"ChainRulesCore\", \"Enzyme\"]\n"
                    )
                    scaffold(dir)
                    cov = read(joinpath(dir, "codecov.yml"), String)
                    fwd = split(cov, "  ad-enzyme-forward:")[2]
                    @test occursin(
                        "ext/NumericMultiRulesExt.jl",
                        split(fwd, "carryforward")[1]
                    )
                end
                mktempdir() do dir
                    _fake_pkg(dir; name = "NumericNoExt")
                    scaffold(dir)
                    cov = read(joinpath(dir, "codecov.yml"), String)
                    for block in split(cov, r"(?=^  ad-)"m)
                        occursin(r"^  ad-", block) || continue
                        @test !occursin("- ext", block)
                    end
                end
                # Reading the `[extensions]` table must degrade to "no
                # extension paths" rather than throwing. The unparseable case
                # is the real one: an unsubstituted template still holding
                # `{{PLACEHOLDER}}` tokens is not valid TOML.
                mktempdir() do dir
                    @test _backend_extension_files(dir, "Enzyme") == String[]
                    proj = joinpath(dir, "Project.toml")
                    write(proj, "name = \"{{PACKAGE}}\"\nuuid = {{UUID}}\n")
                    @test _backend_extension_files(dir, "Enzyme") == String[]
                    write(proj, "name = \"Gadget\"\n")
                    @test _backend_extension_files(dir, "Enzyme") == String[]
                    # `extensions` present but not a table at all.
                    write(proj, "name = \"Gadget\"\nextensions = \"nope\"\n")
                    @test _backend_extension_files(dir, "Enzyme") == String[]
                    # A bare-string trigger is matched, not dropped, and a
                    # non-Enzyme backend never claims anything.
                    write(
                        proj,
                        "name = \"Gadget\"\n\n[extensions]\n" *
                            "GadgetEnzymeExt = \"Enzyme\"\n"
                    )
                    @test _backend_extension_files(dir, "Enzyme") ==
                        ["ext/GadgetEnzymeExt.jl"]
                    @test _backend_extension_files(dir, "ForwardDiff") ==
                        String[]
                end
            end

            @testset "round-trip: adding a 7th backend" begin
                n = length(EpiAwarePackageTools._AD_BACKENDS)
                push!(
                    EpiAwarePackageTools._AD_BACKENDS,
                    (
                        alt = "FakeAD", header = "FakeAD", slug = "ad-fakead",
                        tag = "fakead", pkg = "FakeADPkg",
                    )
                )
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
                            String
                        )
                        @test count("\"tag\":", adyaml) == n7
                        @test occursin("\"fakead\"", adyaml)

                        setup = read(
                            _dest(dir, "test/ad/setup.jl"),
                            String
                        )
                        @test occursin("FakeADPkg", setup)

                        scenarios = read(
                            _dest(dir, "test/ad/scenarios.jl"), String
                        )
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
                        _dest(dir, ".github/workflows/ad.yaml"), String
                    )
                    @test count("\"tag\":", adyaml) == n

                    push!(
                        EpiAwarePackageTools._AD_BACKENDS,
                        (
                            alt = "FakeAD", header = "FakeAD",
                            slug = "ad-fakead", tag = "fakead",
                            pkg = "FakeADPkg",
                        )
                    )
                    try
                        update(dir)
                        adyaml2 = read(
                            _dest(dir, ".github/workflows/ad.yaml"),
                            String
                        )
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
                # Compared as whole native paths, not by `/`-bearing substring:
                # the manifest holds platform-separated paths, so an
                # `occursin("test/ad/", p)` here would simply never match on
                # Windows and the assertion would pass whatever the manifest
                # said.
                @test _dest(dir, ".github/workflows/ad.yaml") ∉ res.updated
                ad_dir = _dest(dir, "test/ad")
                @test !any(p -> startswith(p, ad_dir), res.updated)
                # The no-AD codecov is re-applied (not the AD-flagged one).
                @test !occursin(
                    "ad-forwarddiff",
                    read(joinpath(dir, "codecov.yml"), String)
                )
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
                    _dest(dir, "test/ADFixtures/src/ADFixtures.jl"), String
                )
                scenarios = read(_dest(dir, "test/ad/scenarios.jl"), String)
                # Every backend `test/ad/scenarios.jl` calls
                # `test_working_backend(...)` for must have a matching seeded
                # `backends()` entry, or a fresh scaffold errors
                # (`ArgumentError: Collection is empty...`) on that backend
                # out of the box (#217). Before this the seed only ever
                # registered ForwardDiff.
                backend_calls = [
                    String(m.captures[1])
                        for m in eachmatch(
                            r"test_working_backend\(\"([^\"]+)\"\)", scenarios
                        )
                ]
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
                    _dest(dir, "test/ADFixtures/Project.toml"), String
                )
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
                edited = replace(
                    read(readme, String),
                    "Intro paragraph." => "Edited intro."
                )
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
                        "workflows/ad.yaml/badge.svg?branch=main)]", txt
                )
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
                # Seeded in the slot #292 puts it in: after Getting started,
                # before the Documentation section.
                @test occursin("## Related packages", txt)
                @test findfirst("## Getting started", txt)[1] <
                    findfirst("## Related packages", txt)[1] <
                    findfirst("## Where to learn more", txt)[1]
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
                        "/blob/main/CITATION.cff)", txt
                )
                @test occursin("CODE_OF_CONDUCT.md", txt)
                # Parameterised, no hardcoded owner/repo.
                @test occursin("EpiAware/Fresh.jl", txt)
                @test occursin(
                    "EpiAware/.github/blob/main/CODE_OF_CONDUCT.md",
                    txt
                )
                # ad = false and no DOI passed: no version-DOI line.
                @test !occursin("doi.org", txt)

                # The managed `## How to cite` heading satisfies the citation
                # group of STANDARD_README_SECTIONS, so the scaffolded README
                # passes the kit's own README-sections quality check out of the
                # box, with no hand-authored License/Supporting section (#201).
                headings = EpiAwarePackageTools._readme_headings(txt)
                @test EpiAwarePackageTools._has_section(
                    headings,
                    EpiAwarePackageTools.STANDARD_README_SECTIONS[end]
                )

                # A second update refreshes the block in place, idempotently.
                before = read(joinpath(dir, "README.md"), String)
                ures = update(dir; ad = false)
                @test ures.standard_sections === :refreshed
                @test read(joinpath(dir, "README.md"), String) == before
                @test count("<!-- standard-sections:start -->", before) == 1

                # An edit outside the markers survives the refresh.
                edited = replace(before, "## Why Fresh?" => "## Why Fresh?!")
                write(
                    joinpath(dir, "README.md"),
                    edited * "\n\n## Extra package section\n"
                )
                update(dir; ad = false)
                final = read(joinpath(dir, "README.md"), String)
                @test occursin("## Why Fresh?!", final)
                @test occursin("## Extra package section", final)
                @test count("<!-- standard-sections:start -->", final) == 1
            end
        end

        @testset "standard-sections DOI line follows a persisted DOI" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Fresh")
                scaffold(
                    dir; ad = false, doi = "10.5281/zenodo.18474651",
                    zenodo_badge = "1046740844"
                )
                txt = read(joinpath(dir, "README.md"), String)
                # The How-to-cite section references the version DOI, recovered
                # from the README DOI badge on the next sync.
                @test occursin("https://doi.org/10.5281/zenodo.18474651", txt)
                update(dir; ad = false)  # no doi re-passed -> read back
                @test occursin(
                    "https://doi.org/10.5281/zenodo.18474651",
                    read(joinpath(dir, "README.md"), String)
                )
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
                res = update(dir; ad = false)
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
                    scaffold(
                        d2; ad = false, doi = "10.5281/zenodo.18474651",
                        zenodo_badge = "1046740844"
                    )
                    ctxt = read(joinpath(d2, "CITATION.cff"), String)
                    @test occursin("doi: \"10.5281/zenodo.18474651\"", ctxt)
                    @test !occursin("XXXXXXX", ctxt)
                end

                # A hand-edited CITATION.cff survives update untouched. `update`
                # seeds a missing file (#322, tested separately below) but still
                # never rewrites one that already exists.
                custom = txt * "\nversion: 1.2.3\n"
                write(cff, custom)
                ures = update(dir; ad = false)
                @test ures.citation === :preserved
                @test read(cff, String) == custom

                # A second scaffold preserves it too.
                sres = scaffold(dir; ad = false)
                @test sres.citation === :preserved
                @test read(cff, String) == custom
            end
        end

        @testset "update seeds a missing CITATION.cff (#322)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "PreCitation")
                scaffold(dir; ad = false)
                cff = joinpath(dir, "CITATION.cff")
                @test isfile(cff)
                # Simulate a package that adopted the template before CITATION
                # seeding existed (#67): the managed "How to cite" section
                # `update` re-renders on every sync links to CITATION.cff
                # unconditionally, so without this, `update` could never make
                # that link resolve -- a permanent 404 once the README reaches
                # a linkchecked docs build.
                rm(cff)
                res = update(dir; ad = false)
                @test res.citation === :created
                @test isfile(cff)
                txt = read(cff, String)
                @test occursin("title: \"PreCitation.jl\"", txt)

                # Write-once still holds: a second update never rewrites the
                # file it just created.
                custom = txt * "\nversion: 1.2.3\n"
                write(cff, custom)
                res2 = update(dir; ad = false)
                @test res2.citation === :preserved
                @test read(cff, String) == custom
            end
        end

        @testset "LICENSE is package-owned and write-once" begin
            mktempdir() do dir
                _fake_pkg(
                    dir; name = "Wombat",
                    authors = "[\"Ada Lovelace\"]"
                )
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
                _fake_pkg(
                    dir; name = "Wombat",
                    authors = "[\"Ada Lovelace\"]"
                )
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
                res = scaffold_generate(
                    dir, "GenPkg"; authors = ["Ada"],
                    license = "Apache-2.0"
                )
                @test res.license === :created
                @test occursin(
                    "Apache License",
                    read(joinpath(dir, "LICENSE"), String)
                )
            end
        end

        @testset "update preserves a Dependabot-bumped reusable ref" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                caller = _dest(dir, ".github/workflows/test.yaml")
                # Simulate Dependabot bumping the reusable SHA in the live
                # caller (the case that used to fail self-drift).
                bumped = replace(
                    read(caller, String),
                    r"(tests\.yml@)\S+" =>
                        s"\1deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
                )
                write(caller, bumped)
                update(dir)
                after = read(caller, String)
                # update keeps the bumped ref (never reverts Dependabot) ...
                @test occursin(
                    "tests.yml@deadbeefdeadbeefdeadbeefdeadbeefdeadbeef", after
                )
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
                overridden = replace(
                    before,
                    r"(?m)^      julia_versions: .*$" => "      julia_versions: '[\"1.11\", \"1\"]'",
                    r"(?m)^      julia_version: .*$" => "      julia_version: '1.12'"
                )
                @test overridden != before
                write(caller, overridden)
                update(dir)
                after = read(caller, String)
                # The `with:` overrides survive the resync ...
                @test occursin("julia_versions: '[\"1.11\", \"1\"]'", after)
                @test occursin("julia_version: '1.12'", after)
                # ... the rest of the caller is still managed and re-applied,
                # and a second update is idempotent on the preserved inputs.
                update(dir)
                @test read(caller, String) == after
            end
        end

        @testset "update preserves a with: input on release-nudge.yaml" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                caller = _dest(dir, ".github/workflows/release-nudge.yaml")
                before = read(caller, String)
                # Unlike test.yaml/ad.yaml, this caller renders with no
                # `with:` block at all, so a package customising e.g.
                # `stale_days` adds one from scratch, directly between
                # `uses:` and `secrets:` (the exact shape #73 protects on
                # the other callers). Guards against a caller job with no
                # `secrets:` block ever again silently dropping this
                # override by falling outside `_CALLER_JOB`'s match.
                @test !occursin("with:", before)
                overridden = replace(
                    before,
                    r"(uses: \S+/release-nudge\.yml@\S+\r?\n)" =>
                        SubstitutionString(
                        "\\1    with:\n      stale_days: 30\n"
                    )
                )
                @test overridden != before
                write(caller, overridden)
                update(dir)
                after = read(caller, String)
                # The override survives the resync ...
                @test occursin("stale_days: 30", after)
                # ... and the rest of the caller (the SHA pin, the
                # trailing `secrets: inherit`) is still managed.
                @test occursin(
                    "EpiAware/.github/.github/workflows/release-nudge.yml@",
                    after
                )
                @test occursin("secrets: inherit", after)
                # A second update is idempotent on the preserved input.
                update(dir)
                @test read(caller, String) == after
            end
        end

        @testset "update preserves a Dependabot-bumped action pin (#215)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # A managed workflow that directly pins third-party actions (not
                # only the org reusables). Dependabot's github-actions ecosystem
                # bumps these pins in the live repo just like a reusable SHA.
                wf = _dest(dir, ".github/workflows/claude.yml")
                before = read(wf, String)
                @test occursin("actions/checkout@v7", before)
                # Simulate Dependabot bumping the third-party pin in the live
                # workflow (the case #215 reports being reverted on resync).
                bumped = replace(
                    before,
                    r"(uses:\s*actions/checkout@)\S+" => s"\1v99"
                )
                @test bumped != before
                write(wf, bumped)
                update(dir)
                after = read(wf, String)
                # update keeps the bumped pin (never reverts Dependabot,
                # regardless of the branch the resync runs on) ...
                @test occursin("actions/checkout@v99", after)
                @test !occursin("actions/checkout@v7", after)
                # ... and a second update is idempotent on the pin.
                update(dir)
                @test read(wf, String) == after
            end
        end

        @testset "update merges a package key into a managed with: block (#183)" begin
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
                overridden = replace(
                    before,
                    r"([ \t]+)(julia_version:[^\r\n]*\r?\n)" =>
                        s"\1\2\1coverage_directories: 'src,ext'\n"
                )
                @test overridden != before
                write(caller, overridden)
                update(dir)
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
                update(dir)
                @test read(caller, String) == after
            end
        end

        @testset "update preserves a comment documenting a merged with: key (#212)" begin
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
                    "      # this suite). Re-added by hand (#88).\n"
                )
                ad_overridden = replace(
                    ad_before,
                    r"([ \t]+)(backends:[^\r\n]*\r?\n)" =>
                        SubstitutionString(
                        "\\1\\2" * guard_comment *
                            "\\1coverage_directories: 'src,ext'\n"
                    )
                )
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
                    "      # lines too. Re-added by hand (#88).\n"
                )
                cov_overridden = replace(
                    cov_before,
                    r"([ \t]+)(julia_version:[^\r\n]*\r?\n)" =>
                        SubstitutionString(
                        "\\1\\2" * pkg_comment *
                            "\\1coverage_directories: 'src,ext'\n"
                    )
                )
                @test cov_overridden != cov_before
                write(cov_caller, cov_overridden)

                update(dir)
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
                update(dir)
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
                "extra_matrix:\n        - x\n        - y", merged
            )
            @test occursin("backends:", merged)
            @test _merge_with_blocks(seed, merged) == merged
        end

        @testset "update preserves the downstreams list (#234)" begin
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
                owned = replace(
                    before, "downstreams: '[]'" =>
                        "downstreams: " * entry
                )
                # Also drift the managed part of the file, to prove the resync
                # still repairs everything except the owned input.
                owned = replace(owned, "name: Downstream" => "name: Bogus")
                write(wf, owned)
                res = update(dir)
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
                # ... and a second update is idempotent on the list.
                update(dir)
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
                update(dir)
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

        @testset "_detect_license recovers a supported GPL licence" begin
            using EpiAwarePackageTools: _detect_license, _license_badge
            # A GPL adopter (a port of GPL'd code, whose licence is inherited
            # rather than the kit's to change) keeps its badge instead of
            # having it reset to the default.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                readme = "# Wombat\n\n" *
                    _license_badge("GPL-2.0-or-later") * "\n"
                write(joinpath(dir, "README.md"), readme)
                @test _detect_license(dir) == "GPL-2.0-or-later"
            end
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                open(joinpath(dir, "Project.toml"), "a") do io
                    write(io, "license = \"GPL-2.0-or-later\"\n")
                end
                @test _detect_license(dir) == "GPL-2.0-or-later"
            end
        end

        @testset "_detect_license canonicalises the spelling it finds" begin
            using EpiAwarePackageTools: _detect_license
            # SPDX identifiers are case-insensitive, so a declaration in
            # another case is the same licence and resolves to the canonical
            # spelling the badge and the bundled text are keyed on.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                open(joinpath(dir, "Project.toml"), "a") do io
                    write(io, "license = \"gpl-2.0-OR-later\"\n")
                end
                @test _detect_license(dir) == "GPL-2.0-or-later"
            end
        end

        @testset "_detect_license ignores an unsupported licence" begin
            using EpiAwarePackageTools: _detect_license
            # Detection is restricted to the supported set: a badge label or
            # Project.toml field naming anything else cannot introduce a
            # licence the kit does not support.
            for label in ("GPL-3.0-only", "not a licence")
                mktempdir() do dir
                    _fake_pkg(dir; name = "Wombat")
                    write(
                        joinpath(dir, "README.md"),
                        "# Wombat\n\n[![License: $label]" *
                            "(https://img.shields.io/badge/License-x-green" *
                            ".svg)](https://example.com)\n"
                    )
                    @test _detect_license(dir) === nothing
                end
                mktempdir() do dir
                    _fake_pkg(dir; name = "Wombat")
                    open(joinpath(dir, "Project.toml"), "a") do io
                        write(io, "license = \"$label\"\n")
                    end
                    @test _detect_license(dir) === nothing
                end
            end
        end

        @testset "scaffold_inputs accepts only the supported licences" begin
            using EpiAwarePackageTools: scaffold_inputs, SUPPORTED_LICENSES
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                for good in SUPPORTED_LICENSES
                    @test scaffold_inputs(dir; license = good).LICENSE == good
                end
            end
            # A committed licence file does not widen the set: an id the kit
            # does not support is rejected whether or not the text is there.
            for bad in ("", "GPL-3.0-only", "not a licence")
                mktempdir() do dir
                    _fake_pkg(dir; name = "Wombat")
                    @test_throws ErrorException scaffold_inputs(
                        dir; license = bad
                    )
                    write(joinpath(dir, "LICENSE"), "licence text...\n")
                    @test_throws ErrorException scaffold_inputs(
                        dir; license = bad
                    )
                end
            end
        end

        @testset "scaffold license = GPL-2.0-or-later writes GPL text" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                res = scaffold(dir; license = "GPL-2.0-or-later", ad = false)
                @test res.license === :created
                txt = read(joinpath(dir, "LICENSE"), String)
                @test occursin("GNU GENERAL PUBLIC LICENSE", txt)
                @test occursin("Version 2, June 1991", txt)
                @test occursin("any later version", txt)
                @test !occursin("{{", txt)
                readme = read(joinpath(dir, "README.md"), String)
                @test occursin("License: GPL-2.0-or-later", readme)
            end
        end

        @testset "a COPYING repo is not given a second licence file" begin
            # `COPYING` is the GNU convention, so a GPL adopter's licence text
            # is already there and the kit must leave it alone.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                write(joinpath(dir, "COPYING"), "GPL licence text...\n")
                res = scaffold(dir; license = "GPL-2.0-or-later", ad = false)
                @test res.license === :preserved
                @test !isfile(joinpath(dir, "LICENSE"))
                @test read(joinpath(dir, "COPYING"), String) ==
                    "GPL licence text...\n"
            end
        end

        @testset "update keeps a GPL badge across a sync" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                write(joinpath(dir, "LICENSE"), "GPL licence text...\n")
                open(joinpath(dir, "Project.toml"), "a") do io
                    write(io, "license = \"GPL-2.0-or-later\"\n")
                end
                scaffold(dir; ad = false)
                readme = read(joinpath(dir, "README.md"), String)
                @test occursin("License: GPL-2.0-or-later", readme)
                # A bare resync (as the scheduled template-sync runs, with no
                # `license` kwarg) must not flip the badge to MIT.
                update(dir; ad = false)
                readme2 = read(joinpath(dir, "README.md"), String)
                @test occursin("License: GPL-2.0-or-later", readme2)
                @test !occursin("License: MIT", readme2)
            end
        end

        @testset "update preserves a non-MIT licence badge (#235)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; license = "Apache-2.0", ad = false)
                # A bare update (as the scheduled template-sync runs,
                # with no `license` kwarg) must not flip the badge to MIT.
                update(dir; ad = false)
                txt = read(joinpath(dir, "README.md"), String)
                @test occursin("License: Apache-2.0", txt)
                @test !occursin("License: MIT", txt)
                # An explicit licence still overrides the detected one.
                update(dir; ad = false, license = "MIT")
                txt2 = read(joinpath(dir, "README.md"), String)
                @test occursin("License: MIT", txt2)
            end
            # An MIT package is unaffected (no spurious preservation).
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat2")
                scaffold(dir; ad = false)
                update(dir; ad = false)
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
                res = update(dir)
                @test mk in res.updated
                @test occursin("build_docs", read(mk, String))
                # Marking the file package-owned (#224) keeps it: the answer to
                # the docs-migration opt-out #237 asks for.
                marked = "# $(_MANAGED_OVERRIDE_MARKER): bespoke docs build\n" *
                    bespoke
                write(mk, marked)
                res2 = update(dir)
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

        @testset "update removes retired managed paths (#185)" begin
            using EpiAwarePackageTools: RETIRED_PATHS
            # The kit retires managed files (the `benchmark/comment/` env went
            # with #126/#157). An adopter kept the dead env because
            # `update` only ever wrote files, never removed them.
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
                reported = vcat(
                    res.created, res.updated, res.preserved,
                    res.removed
                )
                @test !isempty(reported)
                @test all(p -> p == normpath(p), reported)
            end
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; benchmarks = true)
                stale = _dest(dir, "benchmark/comment")
                mkpath(stale)
                write(joinpath(stale, "Project.toml"), "name = \"asv_comment\"\n")
                res = update(dir; benchmarks = true)
                @test !ispath(stale)
                @test stale in res.removed
                # Nothing to remove on the next sync: idempotent, and a package
                # with no retired path reports none.
                res2 = update(dir; benchmarks = true)
                @test isempty(res2.removed)
            end
        end

        @testset "managed files are writable after update (#187)" begin
            # A `Pkg.add`ed kit lives in the read-only depot; copying a template
            # verbatim used to preserve mode 444, so pre-commit hooks failed
            # with a PermissionError on the emitted file.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                # Simulate the read-only depot: mark an emitted managed file
                # read-only, then resync it as a `Pkg.add`ed kit would.
                fmt = joinpath(dir, ".pre-commit-config.yaml")
                chmod(fmt, 0o444)
                update(dir)
                for f in (
                        ".pre-commit-config.yaml", ".gitattributes",
                        ".github/workflows/test.yaml", "Taskfile.yml",
                    )
                    path = joinpath(dir, f)
                    @test isfile(path)
                    @test filemode(path) & 0o200 != 0
                end
            end
        end

        @testset "reusable-workflow seed refs are single-sourced (#186)" begin
            using EpiAwarePackageTools: _REUSABLE_SEED_REFS, _seed_ref,
                _downgrade_compat_job, _templates_dir
            # Every bundled caller pins the seed recorded for the workflow it
            # wraps, so the templates and `_REUSABLE_SEED_REFS` cannot drift
            # apart (#186). The seeds are per workflow rather than one shared
            # commit (#425): a shared seed is by construction wrong for any
            # workflow that post-dates it, which is how three callers came to
            # carry their own newer ref anyway.
            #
            # Every ref is a full SHA, `downstream.yaml`'s included (#425).
            # A floating `@main` ref is moved by nothing — Dependabot cannot
            # bump a branch ref and freshening leaves it alone — so an
            # org-side edit reaches every adopter untested.
            wf = joinpath(_templates_dir(), ".github", "workflows")
            seen = String[]
            for f in readdir(wf; join = true)
                for m in eachmatch(
                        r"/\.github/\.github/workflows/([^@\s]+)@(\S+)",
                        read(f, String)
                    )
                    workflow = String(m.captures[1])
                    @test String(m.captures[2]) == _seed_ref(workflow)
                    push!(seen, workflow)
                end
            end
            @test !isempty(seen)
            # The opt-in downgrade-compat job is rendered, not templated, and
            # is seeded from the same table.
            @test occursin(
                "downgrade.yml@" * _seed_ref("downgrade.yml"),
                _downgrade_compat_job("FakeOrg", true)
            )
            # No stale entry: every seed recorded is one a caller wraps.
            @test issetequal(
                union(seen, ["downgrade.yml"]), keys(_REUSABLE_SEED_REFS)
            )
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
                update(dir)
                @test occursin("timeout_minutes: 120", read(doc, String))
            end
        end

        @testset "update preserves a with: block documented by comments (#117)" begin
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
                overridden = replace(
                    before,
                    r"(uses: \S+/tests\.yml@\S+\r?\n)" =>
                        s"""\1    # Floor is Julia 1.11 (Turing 0.45 needs it).
                            # Test the floor and the latest release.
                        """
                )
                overridden = replace(
                    overridden,
                    r"(?m)^      julia_versions: .*$" => "      julia_versions: '[\"1.11\", \"1\", \"pre\"]'"
                )
                @test overridden != before
                write(caller, overridden)
                update(dir)
                after = read(caller, String)
                # Both the override and its rationale comment survive the resync.
                @test occursin(
                    "julia_versions: '[\"1.11\", \"1\", \"pre\"]'",
                    after
                )
                @test occursin("Floor is Julia 1.11", after)
                # Idempotent on the preserved block.
                update(dir)
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
                update(dir; ad = false)
                @test !occursin("downgrade-compat:", read(tf, String))
                # Idempotent.
                after = read(tf, String)
                update(dir; ad = false)
                @test read(tf, String) == after
                # The sync workflow bakes the opt-out into its own update call.
                sync = read(
                    _dest(dir, ".github/workflows/template-sync.yaml"),
                    String
                )
                @test occursin("downgrade_compat = false", sync)
            end
        end

        @testset "scaffold_update warns before dropping a caller repointed at a local reusable workflow (#325)" begin
            # The regression #325 reports: a package repoints a managed
            # caller job at a repo-local copy of the reusable workflow (so
            # it can pass an input the shared reusable does not expose,
            # e.g. `downgrade-compat` → `./.github/workflows/downgrade.yaml`
            # with `projects: '., test'`). `_CALLER_JOB` keys only the
            # org's shared-reusable shape, so `_preserve_caller_with_inputs`
            # cannot see the job and the next resync silently reverts it,
            # dropping the input with no trace in the sync output. Option 2
            # from the issue: still revert (no change to preservation
            # behaviour — the caller cannot be kept without teaching
            # `_CALLER_JOB` to key local paths too), but warn so the loss is
            # visible.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false)
                caller = _dest(dir, ".github/workflows/test.yaml")
                before = read(caller, String)
                @test occursin(
                    "uses: EpiAware/.github/.github/workflows/downgrade.yml",
                    before
                )
                localised = replace(
                    before,
                    r"uses: EpiAware/\.github/\.github/workflows/downgrade\.yml@\S+" => "uses: ./.github/workflows/downgrade.yaml",
                    r"(?m)^(      )julia_version: '1'$" => s"\1projects: '., test'"
                )
                @test occursin(
                    "uses: ./.github/workflows/downgrade.yaml", localised
                )
                @test occursin("projects: '., test'", localised)
                write(caller, localised)
                # `downgrade_compat = true` explicitly, matching what the
                # scheduled `template-sync.yaml` actually bakes in and
                # calls (see the "scheduled sync is managed" testset
                # below) — the real regression's trigger, rather than
                # `_detect_downgrade_compat`'s own `occursin("downgrade.yml",
                # ...)` heuristic, which a `downgrade.yaml`-named local
                # file (deliberately not `.yml`, to prove path/extension
                # do not matter to this warning) does not satisfy.
                local res
                @test_logs (
                    :warn,
                    r"downgrade-compat.*local reusable workflow"is,
                ) match_mode = :any begin
                    res = scaffold_update(dir; ad = false, downgrade_compat = true)
                end
                # The loss is now visible ...
                @test !isempty(res.warnings)
                @test any(
                    w -> occursin(".github/workflows/test.yaml", w) &&
                        occursin("downgrade-compat", w), res.warnings
                )
                # ... but the job still reverts: no change to what gets
                # emitted, only new diagnostic output.
                after = read(caller, String)
                @test occursin(
                    "uses: EpiAware/.github/.github/workflows/downgrade.yml",
                    after
                )
                @test !occursin("projects:", after)
                @test caller in res.updated
            end
            # A local caller with no `with:` block (nothing package-owned
            # to lose) does not warn.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat2")
                scaffold(dir; ad = false)
                caller = _dest(dir, ".github/workflows/test.yaml")
                before = read(caller, String)
                localised = replace(
                    before,
                    r"(?m)^  downgrade-compat:\n    uses: EpiAware/\.github/\.github/workflows/downgrade\.yml@\S+\n    with:\n      julia_version: '1'\n    secrets: inherit  # pragma: allowlist secret$" => "  downgrade-compat:\n    uses: ./.github/workflows/downgrade.yaml\n    secrets: inherit  # pragma: allowlist secret"
                )
                @test occursin(
                    "uses: ./.github/workflows/downgrade.yaml", localised
                )
                @test !occursin("with:", localised) ||
                    !occursin(
                    r"uses: \./\.github/workflows/downgrade\.yaml\n    with:",
                    localised
                )
                write(caller, localised)
                res = scaffold_update(dir; ad = false)
                @test isempty(res.warnings)
            end
            # A normal org-reusable caller repointed via `_preserve_caller_with_inputs`
            # (the #73 case) is unaffected: it is preserved, not reverted,
            # and does not spuriously trigger this warning.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat3")
                scaffold(dir; ad = false)
                caller = _dest(dir, ".github/workflows/test.yaml")
                before = read(caller, String)
                overridden = replace(
                    before,
                    r"(?m)^      julia_version: .*$" => "      julia_version: '1.12'"
                )
                write(caller, overridden)
                res = scaffold_update(dir; ad = false)
                @test isempty(res.warnings)
                @test occursin("julia_version: '1.12'", read(caller, String))
            end
            # A repo-local *composite action* step (`uses:
            # ./.github/actions/<name>`, e.g. `auto-version-increment.yaml`'s
            # `increment-version` call), a routine, unrelated shape that
            # also has a `with:` block, must not be mistaken for a
            # local-reusable-workflow caller job.
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat4")
                res = scaffold(dir; ad = false)
                @test isempty(res.warnings)
                res2 = scaffold_update(dir; ad = false)
                @test isempty(res2.warnings)
            end
        end

        @testset "scheduled sync is managed; community health not shipped" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false)
                @test isfile(
                    _dest(dir, ".github/workflows/template-sync.yaml")
                )
                # The org-level community health files come from
                # EpiAware/.github org-wide, so the kit must not ship them
                # (shipping them would shadow the org defaults and drift).
                for f in (
                        ".github/ISSUE_TEMPLATE/bug_report.md",
                        ".github/ISSUE_TEMPLATE/feature_request.md",
                        ".github/ISSUE_TEMPLATE/scientific_improvement.md",
                        ".github/ISSUE_TEMPLATE/config.yml",
                        ".github/PULL_REQUEST_TEMPLATE.md",
                        "CONTRIBUTING.md", "CODE_OF_CONDUCT.md", "SUPPORT.md",
                    )
                    @test !ispath(joinpath(dir, f))
                end
                # The sync workflow re-applies the standard with the package's
                # own `org` + `ad` + `benchmarks` + `downgrade_compat` values
                # and is fully substituted (fresh package keeps
                # downgrade-compat).
                sync = read(
                    _dest(dir, ".github/workflows/template-sync.yaml"),
                    String
                )
                @test occursin(
                    "update(\".\"; org = \"EpiAware\", ad = false, " *
                        "benchmarks = false, " *
                        "downgrade_compat = true, " *
                        "unregistered_sources = false, " *
                        "freshen_reusable_refs = true)", sync
                )
                # The kit placeholders are resolved (GitHub Actions `${{ }}`
                # expressions legitimately remain).
                @test !occursin("{{ORG}}", sync)
                @test !occursin("{{AD}}", sync)
                @test !occursin("{{BENCHMARKS}}", sync)
                @test !occursin("{{DOWNGRADE_COMPAT}}", sync)
                @test !occursin("{{SYNC_INSTALL}}", sync)
                # It is managed: an update re-applies it.
                res = update(dir; ad = false)
                @test _dest(dir, ".github/workflows/template-sync.yaml") in
                    res.updated
            end
        end

        @testset "a package outside EpiAware keeps its org on a sync" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false, org = "epiforecasts")
                readme = read(joinpath(dir, "README.md"), String)
                @test occursin("epiforecasts/Wombat.jl", readme)
                @test !occursin("EpiAware/Wombat.jl", readme)
                # A bare `update(".")` would leave `org` on the kit default
                # and rewrite every repo URL back to EpiAware on each weekly
                # run, so the sync states the owner it was scaffolded with.
                sync = read(
                    _dest(dir, ".github/workflows/template-sync.yaml"),
                    String
                )
                @test occursin(
                    "update(\".\"; org = \"epiforecasts\", ad = false,", sync
                )
                # The local re-apply the drift issue prints names it too, so
                # following those steps does not revert the owner either.
                @test occursin("update(\".\"; org = \"epiforecasts\",\n", sync)
                # Running what the sync runs leaves the owner untouched.
                update(dir; org = "epiforecasts", ad = false)
                @test read(joinpath(dir, "README.md"), String) == readme
            end
        end

        @testset "sync never pushes to a branch it did not open (#215)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false)
                sync = read(
                    joinpath(dir, ".github/workflows/template-sync.yaml"),
                    String
                )
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
                    "if: github.event_name != 'pull_request'", sync
                )
                # The scheduled/manual path is unchanged: it re-applies the
                # standard and opens (or refreshes) its own PR, a branch it owns.
                @test occursin("update", sync)
                @test occursin("peter-evans/create-pull-request", sync)
                @test occursin("branch: chore/template-sync", sync)
                # The PR is opened with an App token when one is configured so
                # the sync can push workflow-file drift (the default token is
                # forbidden from touching `.github/workflows/`), falling back to
                # `GITHUB_TOKEN` for non-workflow drift when no App is set.
                @test occursin("actions/create-github-app-token", sync)
                @test occursin(
                    "steps.app-token.outputs.token || secrets.GITHUB_TOKEN",
                    sync
                )
                # The minted token is capped to exactly what the sync PR step
                # needs, regardless of what else the App may hold at install.
                @test occursin("permission-contents: write", sync)
                @test occursin("permission-pull-requests: write", sync)
                @test occursin("permission-workflows: write", sync)
            end
        end

        @testset "a failed sync opens one tracking issue (#352)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; ad = false)
                sync = read(
                    joinpath(dir, ".github/workflows/template-sync.yaml"),
                    String
                )
                # A scheduled run has no audience: a red X on the Actions tab
                # recurs every week until someone happens to look. The failing
                # run must tell the maintainer instead, via an issue on their
                # own repo, so `issues: write` has to be granted. Anchored, so
                # the comment explaining the grant cannot stand in for the
                # grant itself and leave every `gh issue` call 403-ing.
                @test occursin(r"^  issues: write$"m, sync)
                # Exactly one issue: the failure step reuses the open
                # `template-sync` issue and edits it, and only creates one when
                # no open issue carries that label. A create-per-run would bury
                # the repo in duplicates of the same weekly failure.
                @test occursin("gh issue edit", sync)
                @test occursin("gh issue create", sync)
                @test occursin("--label template-sync", sync)
                # The step runs only when something failed, and never on the
                # pull-request no-op leg (which cannot fail, and whose token
                # could not open an issue anyway).
                @test occursin(
                    "failure() && github.event_name != 'pull_request'", sync
                )
                # The two routes out are both named: fix the drift here, or ask
                # the kit for the flexibility. Silently pinning/patching the
                # managed file locally is the thing the issue must steer away
                # from, since the next sync reverts it.
                @test occursin(
                    "github.com/EpiAware/EpiAwarePackageTools.jl", sync
                )
                @test occursin("issues/new", sync)
                # The remediation must re-apply the same standard the sync
                # itself applies, so it carries this package's own options. A
                # bare `update(".")` defaults `ad` to true, so on an
                # `ad = false` package the documented fix would seed AD infra
                # the package does not want and leave it still drifted.
                @test occursin("update(\".\"; org = \"EpiAware\",", sync)
                @test occursin("ad = false, benchmarks = false,", sync)
                @test !occursin("update(\".\")'", sync)
                # A clean run closes the issue again, so a stale tracker never
                # outlives the drift it reported.
                @test occursin("gh issue close", sync)
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

        @testset "benchmark CI workflows present, no comment env" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; benchmarks = true)
                for f in (
                        ".github/workflows/benchmark.yaml",
                        ".github/workflows/benchmark-history.yaml",
                    )
                    @test isfile(joinpath(dir, f))
                end
                # The unwired asv_comment env is not scaffolded (#126): the PR
                # comment comes from the BenchmarkTools `benchmark/compare.jl`
                # path, and the history workflow renders via benchpkg directly.
                @test !ispath(_dest(dir, "benchmark/comment"))
                bench = read(
                    _dest(dir, ".github/workflows/benchmark.yaml"),
                    String
                )
                # `pull_request` (not `pull_request_target`): the comparison
                # runs the PR's own code, keeping the comment-posting token
                # scoped to same-repo PRs (#821 gap 1).
                @test occursin("on:\n  pull_request:", bench)
                @test !occursin("pull_request_target:", bench)
                # Triggers on every path that affects performance: sources, the
                # extensions, the benchmark suite, and the AD fixtures.
                for p in (
                        "'src/**'", "'ext/**'", "'benchmark/**'",
                        "'test/ADFixtures/**'",
                    )
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
                    String
                )
                @test occursin(
                    "--url=\"https://github.com/\${{ github.repository }}\"",
                    hist
                )
                @test occursin("revs=\${GITHUB_SHA}", hist)
                @test !occursin(r"\{\{[A-Z_]+\}\}", hist)
            end
        end

        @testset "version automation workflows + action present" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; reviewer = "octocat")
                for f in (
                        ".github/workflows/auto-version-increment.yaml",
                        ".github/workflows/version-on-demand.yaml",
                        ".github/actions/increment-version/action.yaml",
                    )
                    @test isfile(joinpath(dir, f))
                end
                act = read(
                    _dest(dir, ".github/actions/increment-version/action.yaml"),
                    String
                )
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
                for f in (
                        "docs/run_literate_tutorial.jl", "docs/docs_config.jl",
                        "docs/release_notes_header.jl",
                    )
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
                # The release-notes header is parameterised on the repo and
                # introduces the fetched GitHub releases, not a changelog file.
                rh = read(_dest(dir, "docs/release_notes_header.jl"), String)
                @test occursin("EpiAware/Wombat.jl", rh)
                @test !occursin("{{", rh)
                @test !occursin("NEWS", rh)
                @test occursin("EpiAware/Wombat.jl/releases", rh)
                # The generated page is in the nav, so the releases are
                # reachable from the site rather than only by URL.
                @test occursin(
                    "\"Release notes\" => \"release-notes.md\"",
                    read(_dest(dir, "docs/pages.jl"), String)
                )
                # The benchmark-history page: a package-owned prose hook, a nav
                # entry, and the managed make.jl generation + config flag.
                @test isfile(_dest(dir, "docs/benchmarks.md"))
                bh = read(_dest(dir, "docs/benchmarks.md"), String)
                @test occursin("Wombat", bh)
                @test !occursin("{{", bh)
                @test occursin(
                    "benchmarks/over-time.md", read(
                        _dest(dir, "docs/pages.jl"), String
                    )
                )
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

        @testset "benchmarks_notes.md round-trips update (#202)" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir; benchmarks = true)
                notes = _dest(dir, "docs/benchmarks_notes.md")
                edit = "\n## Known-broken\n\n`slow_path` skipped: see #123.\n"
                write(notes, read(notes, String) * edit)
                update(dir; benchmarks = true)
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
                @test !occursin(
                    "Plots =",
                    read(_dest(dir, "docs/Project.toml"), String)
                )
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
                # The path-pinned package under test carries no compat bound;
                # the kit, being registered, does (#361). Matched on the
                # section header, not the bare word: the file's own header
                # comment mentions `[compat]` too.
                compat = tp[first(findfirst(r"(?m)^\[compat\]", tp)):end]
                compat = split(compat, "[sources]")[1]
                @test !occursin("Wombat", compat)
                @test occursin(
                    "EpiAwarePackageTools = " *
                        "\"$(EpiAwarePackageTools.KIT_COMPAT)\"", compat
                )
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
                # `[sources]` (the path pin on the package under test), which
                # only exists on Julia >= 1.11. On the LTS (1.10) `[sources]`
                # is ignored, so these envs cannot resolve their local pins at
                # all. The TOML round-trip above still runs on every version.
                if VERSION >= v"1.11"
                    # The ADFixtures registry skeleton carries no
                    # EpiAwarePackageTools dependency at all, so instantiating it
                    # exercises nothing beyond the generated package + registry
                    # deps already primed by the kit's own test run.
                    for env in ("test/ADFixtures",)
                        @test _env_instantiates(joinpath(dir, env))
                    end

                    # The remaining envs bound EpiAwarePackageTools in
                    # `[compat]` at the kit's current minor (#361), which the
                    # registry only carries once that minor is released. Point
                    # each at the local kit checkout with a `[sources]` path
                    # entry instead — the same switch a maintainer developing
                    # the kit alongside a package makes — so the rest of every
                    # env is proven to resolve hermetically, with no network
                    # fetch and no dependency on the release having landed.
                    # A path-sourced kit still has to satisfy the bound, so
                    # this also proves `KIT_COMPAT` admits the kit's own
                    # version.
                    #
                    # Forward-slash the absolute path: a backslashed Windows
                    # path (`C:\...`) in a TOML basic string is an invalid
                    # escape sequence, and Julia/Pkg resolve forward slashes on
                    # every platform.
                    kit_root = replace(
                        pkgdir(EpiAwarePackageTools), '\\' => '/'
                    )
                    kit_path = "EpiAwarePackageTools = {path = \"" *
                        kit_root * "\"}"
                    for env in ("test", "test/jet", "docs")
                        proj = joinpath(dir, env, "Project.toml")
                        txt = read(proj, String)
                        # Every one of these envs already has a `[sources]`
                        # table (the path pin on the package under test), so
                        # the entry goes under the existing header.
                        @test occursin(r"(?m)^\[sources\]", txt)
                        patched = replace(
                            txt, r"(?m)^\[sources\]" =>
                                "[sources]\n" * kit_path; count = 1
                        )
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
                # Managed: `update` re-applies it (not merely preserved).
                res = update(dir)
                @test _dest(dir, ".github/workflows/Register.yml") in
                    res.updated
            end
        end

        @testset "no NEWS.md is seeded, and an existing one is left alone" begin
            mktempdir() do dir
                _fake_pkg(dir; name = "Wombat")
                scaffold(dir)
                news = joinpath(dir, "NEWS.md")
                # Release notes live on the GitHub release, so there is no
                # changelog file to seed.
                @test !isfile(news)
                # A repo that already has one keeps it: the kit no longer
                # writes, reads, or removes it.
                write(news, "## v1.0.0\n\nFirst release.\n")
                res = update(dir)
                @test news ∉ res.updated
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
                        "# Wombat <img src=\"docs/src/assets/logo.svg\"", txt
                    )
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
                    write(
                        _dest(dir, "docs/src/assets/logo.svg"),
                        "<svg></svg>\n"
                    )
                    write(
                        joinpath(dir, "README.md"),
                        "# Wombat <img src=\"docs/src/assets/logo.svg\" " *
                            "width=\"50\">\n\nbody\n"
                    )
                    res = update(dir)
                    @test res.logo === :preserved
                    txt = read(joinpath(dir, "README.md"), String)
                    @test occursin("width=\"50\"", txt)
                end
            end
        end
    end # @testset "scaffold + update"
end # @testitem "scaffold + update (logic)"

@testitem "Julia 1.11 floor in the managed standard (#246)" begin
    using Test
    using EpiAwarePackageTools
    using EpiAwarePackageTools: _JULIA_FLOOR, _JULIA_COMPAT,
        _JULIA_COMPAT_SOURCES, _JULIA_TEST_VERSIONS,
        _JULIA_TEST_VERSIONS_SOURCES, _julia_test_versions,
        _julia_compat_below_floor, _julia_versions_below_floor, update

    function _fake_pkg(dir; name = "Wombat", julia = nothing)
        compat = julia === nothing ? "" : "\n[compat]\njulia = \"$(julia)\"\n"
        write(
            joinpath(dir, "Project.toml"),
            "name = \"$name\"\n" *
                "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                "authors = [\"Ada Lovelace\"]\n" * compat
        )
        return dir
    end
    _p(dir, rel) = joinpath(dir, split(rel, '/')...)

    @testset "the floor is 1.11 (where [sources] starts working)" begin
        # `[sources]` is a Pkg 1.11 feature, silently ignored on 1.10. That is
        # the whole reason for the floor, so pin it rather than let it drift.
        @test _JULIA_FLOOR == v"1.11"
        # The default no longer imposes that floor on a consuming package: the
        # kit is registered, so the standard pins nothing by git (#410/#361).
        @test _JULIA_COMPAT == "1.10, 1.11, 1.12"
        # A package that does still pin something unregistered keeps it.
        @test _JULIA_COMPAT_SOURCES == "1.11, 1.12"
        # And the same split for the CI matrix: the standard tests lts, unless
        # the package's own git `[sources]` pins would be ignored there.
        @test _JULIA_TEST_VERSIONS == "'[\"1\", \"lts\", \"pre\"]'"
        @test _JULIA_TEST_VERSIONS_SOURCES == "'[\"1\", \"pre\"]'"
        @test _julia_test_versions(false) == _JULIA_TEST_VERSIONS
        @test _julia_test_versions(true) == _JULIA_TEST_VERSIONS_SOURCES
    end

    @testset "the test caller keeps the lts leg" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            wf = read(_p(dir, ".github/workflows/test.yaml"), String)
            # The lts (1.10) leg runs `Pkg.test`, which develops the package
            # under test itself, so `[sources]` being a Pkg 1.11 feature costs
            # it nothing. The environments that do need the pin honoured are
            # separate jobs on the current release, not legs of this matrix
            # (#410).
            #
            # Asserted against the `julia_versions:` line itself, not the whole
            # file: the block's own comment mentions the lts leg, and a naive
            # `occursin("lts", wf)` would match that comment rather than the
            # matrix — passing or failing for the wrong reason.
            lines = split(wf, '\n')
            vline = only(filter(l -> occursin("julia_versions:", l), lines))
            @test occursin("[\"1\", \"lts\", \"pre\"]", vline)
            # And no placeholder survives into the emitted workflow.
            @test !occursin("{{JULIA_TEST_VERSIONS}}", wf)
        end
    end

    @testset "a package holding to the floor is seeded without lts" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; unregistered_sources = true)
            wf = read(_p(dir, ".github/workflows/test.yaml"), String)
            lines = split(wf, '\n')
            vline = only(filter(l -> occursin("julia_versions:", l), lines))
            # Its git `[sources]` pins are silently ignored on 1.10, so the leg
            # would resolve a registry instead. Seeding it would contradict the
            # warning `_julia_versions_below_floor` raises for exactly that leg.
            @test occursin("[\"1\", \"pre\"]", vline)
            @test !occursin("lts", vline)
        end
    end

    @testset "the downgrade caller is pinned above the floor" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; downgrade_compat = true)
            wf = read(_p(dir, ".github/workflows/test.yaml"), String)
            @test occursin("downgrade-compat:", wf)
            # downgrade.yml's own default is '1.10', which the managed test env
            # cannot resolve on, so the job must be given a version above the
            # floor. The current release, not the floor itself: the
            # standard's test env cannot resolve on 1.11 (JET ships nothing for
            # 1.11 past 0.9.20, and that needs JuliaSyntax 0.4, which the pinned
            # Runic 1.7.0 rules out), so pinning the job to the floor would
            # only go red on a conflict unrelated to the package.
            @test occursin("julia_version: '1'", wf)
            @test !occursin("julia_version: '1.10'", wf)
        end
    end

    @testset "the JET bound is one every leg of the matrix can resolve" begin
        for ad in (true, false)
            mktempdir() do dir
                _fake_pkg(dir)
                scaffold(dir; ad = ad)
                compat = read(_p(dir, "test/Project.toml"), String)
                # JET publishes nothing past 0.9.18 for Julia 1.10, so a bound
                # starting at 0.10 makes the seeded lts leg unresolvable and
                # the matrix a lie. The bound reaches back to 0.9 in both the
                # AD and no-AD variants, which had drifted apart.
                #
                # This costs the downgrade job nothing: `julia-downgrade-compat`
                # resolves `projects: '.'` — the root Project.toml — so the
                # test environment's bounds are never floor-resolved.
                @test occursin("JET = \"0.9, 0.10\"", compat)
            end
        end
    end

    @testset "a generated package is seeded below the floor by default" begin
        mktempdir() do dir
            scaffold_generate(dir, "Fresh"; authors = ["Ada Lovelace"])
            proj = read(joinpath(dir, "Project.toml"), String)
            # 1.10 LTS is not dropped for a reason internal to the kit's own
            # release process (#410).
            @test occursin("julia = \"1.10, 1.11, 1.12\"", proj)
        end
        # Unless the package declares it pins something unregistered.
        mktempdir() do dir
            scaffold_generate(
                dir, "Fresh"; authors = ["Ada Lovelace"],
                unregistered_sources = true
            )
            proj = read(joinpath(dir, "Project.toml"), String)
            @test occursin("julia = \"1.11, 1.12\"", proj)
            @test !occursin("1.10", proj)
        end
    end

    @testset "claiming 1.10 is only warned about under the opt-out" begin
        # The default: the standard needs nothing above 1.10, so a package
        # claiming it is claiming support the standard can deliver (#410).
        mktempdir() do dir
            _fake_pkg(dir; julia = "1.10, 1.11, 1.12")
            res = scaffold(dir)
            @test !any(w -> occursin("#246", w), res.warnings)
        end
        # With unregistered `[sources]` pins of its own, 1.10 really is broken.
        mktempdir() do dir
            _fake_pkg(dir; julia = "1.10, 1.11, 1.12")
            res = scaffold(dir; unregistered_sources = true)
            @test any(
                w -> occursin("1.11", w) && occursin("sources", w),
                res.warnings
            )
            # The kit does not rewrite the package-owned compat itself.
            @test occursin(
                "julia = \"1.10, 1.11, 1.12\"",
                read(joinpath(dir, "Project.toml"), String)
            )
        end
        # A package already at the floor is not nagged.
        mktempdir() do dir
            _fake_pkg(dir; julia = "1.11, 1.12")
            res = scaffold(dir; unregistered_sources = true)
            @test !any(w -> occursin("#246", w), res.warnings)
        end
        # Nor is one with no julia compat at all (nothing claimed).
        mktempdir() do dir
            _fake_pkg(dir)
            res = scaffold(dir; unregistered_sources = true)
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
            write(
                caller,
                replace(
                    before,
                    r"(?m)^      julia_versions: .*$" =>
                        "      # Pin the floor explicitly (Turing needs it).\n" *
                        "      julia_versions: '[\"1.11\", \"1\", \"pre\"]'"
                )
            )
            res = update(dir)
            after = read(caller, String)
            @test occursin("julia_versions: '[\"1.11\", \"1\", \"pre\"]'", after)
            @test occursin("Pin the floor explicitly", after)
            # An override at or above the floor draws no warning.
            @test !any(w -> occursin("below the", w), res.warnings)
            # Idempotent on the preserved override.
            update(dir)
            @test read(caller, String) == after
        end
    end

    @testset "an override that reaches below the floor is warned" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            caller = _p(dir, ".github/workflows/test.yaml")
            # Putting the lts leg back is allowed — the kit does not fight the
            # package — but under `unregistered_sources` it silently tests
            # something stale, so it must be said.
            write(
                caller,
                replace(
                    read(caller, String),
                    r"(?m)^      julia_versions: .*$" => "      julia_versions: '[\"1\", \"lts\", \"pre\"]'"
                )
            )
            res = update(dir; unregistered_sources = true)
            @test occursin(
                "julia_versions: '[\"1\", \"lts\", \"pre\"]'",
                read(caller, String)
            )
            @test any(
                w -> occursin("lts", w) && occursin("stale", w),
                res.warnings
            )
            # Without the opt-out the kit says nothing: an lts leg is the
            # package's own call once nothing managed is git-pinned (#410).
            @test !any(w -> occursin("#246", w), update(dir).warnings)
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
            write(
                cov,
                replace(
                    read(cov, String),
                    r"(?m)^      julia_version: .*$" => "      julia_version: '1.10'"
                )
            )
            res = update(dir)
            after = read(cov, String)
            # The kit reclaims its managed value ...
            @test occursin("julia_version: '1'", after)
            @test !occursin("julia_version: '1.10'", after)
            # ... and the downgrade caller's same-named key is still the
            # package's to override, in the same run.
            caller = _p(dir, ".github/workflows/test.yaml")
            write(
                caller,
                replace(
                    read(caller, String),
                    r"(?m)^      julia_version: .*$" => "      julia_version: '1.12'"
                )
            )
            update(dir)
            @test occursin(
                "julia_version: '1.12'",
                read(caller, String)
            )
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
            write(
                own,
                "jobs:\n  x:\n    with:\n      julia_version: '1.10'\n"
            )
            res = update(dir; unregistered_sources = true)
            @test any(
                w -> occursin("nightly.yaml", w) && occursin("1.10", w),
                res.warnings
            )
        end
    end

    @testset "an inline comment is not read as a version" begin
        # A note explaining which leg was dropped must not warn about a leg that
        # is not there.
        @test _julia_versions_below_floor(
            "      julia_versions: '[\"1\", \"pre\"]'  # was [\"1\",\"lts\"]\n"
        ) ==
            String[]
    end

    @testset "_julia_versions_below_floor names the offending legs" begin
        @test _julia_versions_below_floor(
            "      julia_versions: '[\"1\", \"pre\"]'\n"
        ) == String[]
        @test _julia_versions_below_floor(
            "      julia_versions: '[\"1\", \"lts\", \"pre\"]'\n"
        ) == ["lts"]
        @test _julia_versions_below_floor(
            "      julia_versions: '[\"1.10\", \"1\"]'\n"
        ) == ["1.10"]
        @test _julia_versions_below_floor(
            "      julia_versions: '[\"1.11\", \"1.12\"]'\n"
        ) == String[]
        # The downgrade caller's singular key is read too.
        @test _julia_versions_below_floor(
            "      julia_version: '1.10'\n"
        ) == ["1.10"]
        @test _julia_versions_below_floor(
            "      julia_version: '1.11'\n"
        ) == String[]
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

@testitem "the kit is depended on as a registered package (#361)" begin
    using Test
    using Pkg
    using EpiAwarePackageTools
    using EpiAwarePackageTools: KIT_NAME, KIT_COMPAT,
        _detect_unregistered_sources, _kit_git_pin_gap, _SOURCES_ENVS, update

    function _fake_pkg(dir; name = "Wombat")
        write(
            joinpath(dir, "Project.toml"),
            "name = \"$name\"\n" *
                "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                "authors = [\"Ada Lovelace\"]\n"
        )
        return dir
    end
    _p(dir, rel) = joinpath(dir, split(rel, '/')...)

    # A `[sources]` entry pinning `name` by git, appended to an env.
    function _git_pin!(path, name; url = "https://example.invalid/$name.jl")
        pin = "$name = {url = \"$url\", rev = \"main\"}"
        text = read(path, String)
        text = if occursin(r"(?m)^\[sources\]", text)
            replace(text, r"(?m)^\[sources\]" => "[sources]\n$pin"; count = 1)
        else
            text * "\n[sources]\n$pin\n"
        end
        return write(path, text)
    end

    @testset "the managed bound admits the kit's own version" begin
        # The bound reaches back a minor so an adopter can resolve it before
        # this one is registered, which is what lets the ecosystem move off
        # its git pins ahead of a release rather than after. Two properties
        # matter, and both are asserted rather than trusted.
        proj = Pkg.TOML.parsefile(
            joinpath(pkgdir(EpiAwarePackageTools), "Project.toml")
        )
        v = VersionNumber(proj["version"])
        # It admits what the templates are written against.
        @test v in Pkg.Types.semver_spec(KIT_COMPAT)
        # And its newest minor is this one, so a release that moves `version`
        # has to move this too and the bound cannot silently lag behind.
        @test endswith(KIT_COMPAT, "$(v.major).$(v.minor)")
    end

    @testset "every managed env bounds the kit instead of git-pinning it" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; ad = true, benchmarks = true)
            for rel in _SOURCES_ENVS
                path = _p(dir, rel)
                isfile(path) || continue
                parsed = Pkg.TOML.parsefile(path)
                # No git pin anywhere, on the kit or otherwise.
                for (_, spec) in get(parsed, "sources", Dict{String, Any}())
                    @test !(spec isa AbstractDict && haskey(spec, "url"))
                end
                # And where the kit is a dep, it is bounded.
                if haskey(get(parsed, "deps", Dict{String, Any}()), KIT_NAME)
                    @test get(
                        get(parsed, "compat", Dict{String, Any}()),
                        KIT_NAME, nothing
                    ) == KIT_COMPAT
                end
            end
            # A freshly scaffolded package therefore draws no pin warning, and
            # is not read as needing the floor.
            @test _kit_git_pin_gap(dir) === nothing
            @test !_detect_unregistered_sources(dir)
        end
    end

    @testset "a leftover kit pin is warned about, or fixed if managed" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; ad = true)
            # `test/jet/Project.toml` is MANAGED, `test/Project.toml` is not.
            _git_pin!(_p(dir, "test/jet/Project.toml"), KIT_NAME)
            _git_pin!(_p(dir, "test/Project.toml"), KIT_NAME)
            res = update(dir)
            # The kit fixes what it owns ...
            @test !occursin(
                "rev = \"main\"", read(_p(dir, "test/jet/Project.toml"), String)
            )
            # ... and names what it cannot, with the bound to write instead.
            warning = only(filter(w -> occursin(KIT_NAME, w), res.warnings))
            @test occursin("test/Project.toml", warning)
            @test !occursin("test/jet/Project.toml", warning)
            @test occursin("$(KIT_NAME) = \"$(KIT_COMPAT)\"", warning)
            @test occursin("#361", warning)
            # A pin on the kit is not itself a reason to hold the floor: the
            # fix is to drop the pin, not to raise the package's compat.
            @test !_detect_unregistered_sources(dir)
        end
    end

    @testset "a package on the registry stays silent" begin
        mktempdir() do dir
            _fake_pkg(dir)
            res = scaffold(dir; ad = true)
            @test !any(w -> occursin(KIT_NAME, w), res.warnings)
            @test !any(w -> occursin("#361", w), update(dir).warnings)
        end
    end

    @testset "a genuine unregistered pin is detected and preserved" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            @test !_detect_unregistered_sources(dir)
            # An ecosystem sibling awaiting registration, pinned by the package
            # itself. `[sources]` is honoured only from 1.11, so the floor is
            # real for this package and a resync must not reset it.
            _git_pin!(_p(dir, "Project.toml"), "Sibling")
            @test _detect_unregistered_sources(dir)
            write(
                _p(dir, ".github/workflows/nightly.yaml"),
                "jobs:\n  x:\n    with:\n      julia_version: '1.10'\n"
            )
            res = update(dir)
            @test any(
                w -> occursin("nightly.yaml", w) && occursin("1.10", w),
                res.warnings
            )
            # An explicit `false` still wins over the detection.
            @test !any(
                w -> occursin("nightly.yaml", w),
                update(dir; unregistered_sources = false).warnings
            )
        end
    end

    @testset "a path pin is not an unregistered pin" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; ad = true)
            # Every managed env path-pins the package under test. Counting
            # those would put the whole fleet on the floor for nothing.
            @test occursin(
                "{path =", read(_p(dir, "test/Project.toml"), String)
            )
            @test !_detect_unregistered_sources(dir)
        end
    end
end

@testitem "undeclared stdlib test deps are flagged (#263)" begin
    using Test
    using EpiAwarePackageTools
    using EpiAwarePackageTools: _undeclared_test_stdlibs, _used_module_names,
        _declared_deps, _julia_stdlibs,
        _manifest_packages, update
    _p(dir, rel) = joinpath(dir, split(rel, '/')...)
    # A minimal resolved test manifest naming `pkgs` — the availability oracle
    # the scan reads (a real Manifest lists the full transitive set). Only the
    # `[[deps.Name]]` headers matter to `_manifest_packages`.
    _manifest(pkgs) = "manifest_format = \"2.0\"\n\n" *
        join(["[[deps.$n]]" for n in pkgs], "\n") * "\n"

    @testset "_julia_stdlibs reads the running Julia's stdlib set" begin
        libs = _julia_stdlibs()
        # A few load-bearing stdlibs are always present; JLL wrappers never are.
        @test "LinearAlgebra" in libs
        @test "Statistics" in libs
        @test "Test" in libs
        @test !any(endswith("_jll"), libs)
    end

    @testset "_used_module_names parses the using/import forms" begin
        src = """
        using Test
        using LinearAlgebra: dot
        using Statistics, Random
        import Printf as PF
        using Base.Threads
        # using Serialization
        using LibGit2  # trailing comment
        """
        names = _used_module_names(src)
        for n in (
                "Test", "LinearAlgebra", "Statistics", "Random", "Printf",
                "Base", "LibGit2",
            )
            @test n in names
        end
        # A commented-out line is not a use.
        @test !("Serialization" in names)
    end

    @testset "_declared_deps reads [deps], tolerates placeholders" begin
        mktempdir() do dir
            f = joinpath(dir, "Project.toml")
            write(f, "[deps]\nA = \"x\"\nB = \"y\"\n[compat]\nA = \"1\"\n")
            @test _declared_deps(f) == Set(["A", "B"])
            # A raw (unsubstituted) template is not valid TOML; skip it.
            write(f, "[deps]\n{{PACKAGE}} = \"{{UUID}}\"\nReal = \"z\"\n")
            @test _declared_deps(f) == Set(["Real"])
            @test _declared_deps(joinpath(dir, "nope.toml")) == Set{String}()
        end
    end

    @testset "_manifest_packages reads header names (both formats)" begin
        mktempdir() do dir
            f = joinpath(dir, "Manifest.toml")
            write(
                f,
                "manifest_format = \"2.0\"\n\n[[deps.Aqua]]\n" *
                    "uuid = \"x\"\n\n[[deps.Random]]\nuuid = \"y\"\n"
            )
            @test _manifest_packages(f) == Set(["Aqua", "Random"])
            # Format 1 headers (`[[Name]]`) parse too.
            write(f, "[[LinearAlgebra]]\nuuid = \"z\"\n")
            @test _manifest_packages(f) == Set(["LinearAlgebra"])
            @test _manifest_packages(joinpath(dir, "no.toml")) == Set{String}()
        end
    end

    @testset "the scan names only stdlibs absent from the resolved env" begin
        mktempdir() do dir
            mkpath(joinpath(dir, "test"))
            write(
                joinpath(dir, "Project.toml"),
                "name = \"Foo\"\n[deps]\n" *
                    "Distributions = \"31c24e10-a181-5473-b8eb-7969acd0382f\"\n"
            )
            write(
                _p(dir, "test/Project.toml"),
                "[deps]\nTest = \"8dfed614-e22c-5e08-85e1-65c5234f0b40\"\n"
            )
            # Resolved env: Test + Distributions, and Random pulled in
            # transitively by Distributions — but NOT LinearAlgebra/Statistics/
            # Printf. So Random must not be flagged though it is in no `[deps]`.
            write(
                _p(dir, "test/Manifest.toml"),
                _manifest(["Test", "Distributions", "Random"])
            )
            write(
                _p(dir, "test/runtests.jl"), """
                using Test
                using LinearAlgebra: dot
                using Statistics
                using Random          # transitive via Distributions -> available
                import Printf as PF
                using SomeThirdParty  # not a stdlib -> never flagged
                # using Serialization # commented -> not a use
                """
            )
            @test _undeclared_test_stdlibs(dir) ==
                ["LinearAlgebra", "Printf", "Statistics"]
        end
    end

    @testset "a transitively-available stdlib is not warned (#263 review)" begin
        # The narrow case a69e flagged: a stdlib reachable only through a
        # third-party main dep (never in any `[deps]` line) is available and
        # must not be flagged. Reading only `[deps]` used to warn it.
        mktempdir() do dir
            mkpath(joinpath(dir, "test"))
            write(
                joinpath(dir, "Project.toml"),
                "name = \"Foo\"\n[deps]\n" *
                    "Distributions = \"31c24e10-a181-5473-b8eb-7969acd0382f\"\n"
            )
            write(_p(dir, "test/Project.toml"), "[deps]\n")
            write(
                _p(dir, "test/Manifest.toml"),
                _manifest(["Distributions", "Random"])
            )
            write(_p(dir, "test/runtests.jl"), "using Random\n")
            @test _undeclared_test_stdlibs(dir) == String[]
        end
    end

    @testset "a stdlib in test/Project.toml [deps] is not flagged" begin
        mktempdir() do dir
            mkpath(joinpath(dir, "test"))
            write(
                _p(dir, "test/Project.toml"),
                "[deps]\nLinearAlgebra = " *
                    "\"37e2e46d-f89d-539d-b4ee-838fcccc9c8e\"\n"
            )
            # Manifest present (so the scan runs) but without LinearAlgebra;
            # the direct `[deps]` entry is what keeps it off the list.
            write(_p(dir, "test/Manifest.toml"), _manifest(["Test"]))
            write(_p(dir, "test/runtests.jl"), "using LinearAlgebra\n")
            @test _undeclared_test_stdlibs(dir) == String[]
        end
    end

    @testset "no manifest / no test dir means no warning" begin
        # Without a resolved manifest, transitive availability is unknowable, so
        # the scan stays silent rather than false-flag (a bare CI checkout).
        mktempdir() do dir
            mkpath(joinpath(dir, "test"))
            write(_p(dir, "test/Project.toml"), "[deps]\n")
            write(_p(dir, "test/runtests.jl"), "using LinearAlgebra\n")
            @test _undeclared_test_stdlibs(dir) == String[]
        end
        # No test/ directory at all: nothing to scan.
        mktempdir() do dir
            @test _undeclared_test_stdlibs(dir) == String[]
        end
    end

    @testset "update warns on an adopter's undeclared stdlib" begin
        mktempdir() do dir
            write(
                joinpath(dir, "Project.toml"),
                "name = \"Wombat\"\n" *
                    "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                    "authors = [\"Ada Lovelace\"]\n"
            )
            scaffold(dir)
            # A freshly scaffolded package uses no undeclared stdlib (and has no
            # manifest yet either) — no warning.
            res = update(dir)
            @test !any(w -> occursin("#263", w), res.warnings)
            # A contributor adds `using LinearAlgebra` without declaring it, in
            # an instantiated env (manifest present) that does not resolve it.
            write(
                _p(dir, "test/renewal_tests.jl"),
                "using LinearAlgebra: dot\n"
            )
            write(
                _p(dir, "test/Manifest.toml"),
                _manifest(["Test", "Aqua", "JET"])
            )
            res2 = update(dir)
            hit = filter(w -> occursin("#263", w), res2.warnings)
            @test length(hit) == 1
            @test occursin("LinearAlgebra", only(hit))
            # The kit never edits the package-owned test/Project.toml.
            @test !occursin(
                "LinearAlgebra",
                read(_p(dir, "test/Project.toml"), String)
            )
        end
    end
end

@testitem "opt-in EpiAware org branding (#242)" begin
    using Test
    using EpiAwarePackageTools
    using EpiAwarePackageTools: _detect_org_branding, _org_footer_message,
        _ORG_LOGO_REL, _ORG_SITE, _ORG_GITHUB,
        update

    function _fake_pkg(dir; name = "Wombat")
        write(
            joinpath(dir, "Project.toml"),
            "name = \"$name\"\n" *
                "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                "authors = [\"Ada Lovelace\"]\n"
        )
        return dir
    end
    _p(dir, rel) = joinpath(dir, split(rel, '/')...)
    _cfg(dir) = joinpath(dir, "docs", "docs_config.jl")
    # Flip the package-owned opt-in, the one line an adopter writes.
    function _set_branding!(dir, on::Bool)
        cfg = _cfg(dir)
        text = read(cfg, String)
        write(
            cfg,
            replace(text, r"const ORG_BRANDING = (true|false)" => "const ORG_BRANDING = $(on)")
        )
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
            res = update(dir)
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
            update(dir)
            readme_on = read(joinpath(dir, "README.md"), String)
            mts_on = read(_p(dir, "docs/src/.vitepress/config.mts"), String)

            # A second sync writes nothing — the sync is a fixed point with
            # branding on.
            res2 = update(dir)
            @test res2.org_branding == :unchanged
            @test read(joinpath(dir, "README.md"), String) == readme_on
            @test read(_p(dir, "docs/src/.vitepress/config.mts"), String) ==
                mts_on
            @test isfile(_p(dir, _ORG_LOGO_REL))

            # Turning it back off withdraws every trace of the branding.
            _set_branding!(dir, false)
            res3 = update(dir)
            @test res3.org_branding == :removed
            @test !isfile(_p(dir, _ORG_LOGO_REL))
            readme_off = read(joinpath(dir, "README.md"), String)
            @test !occursin("EpiAware ecosystem", readme_off)
            @test occursin("## Contributing", readme_off)
            mts_off = read(_p(dir, "docs/src/.vitepress/config.mts"), String)
            @test !occursin("epiaware-logo.svg", mts_off)
            @test occursin("DocumenterVitepress.jl", mts_off)

            # And off is itself a fixed point: nothing left to remove.
            res4 = update(dir)
            @test res4.org_branding == :skipped
        end
    end

    @testset "the flag is package-owned: a sync never flips it" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            _set_branding!(dir, true)
            # update passes no branding kwarg — it must read the
            # package's committed choice, not revert it to the default. This is
            # the scheduled template-sync's path.
            update(dir)
            @test _detect_org_branding(dir)
            @test occursin("const ORG_BRANDING = true", read(_cfg(dir), String))
            # An unforced re-scaffold leaves the package-owned config alone too.
            scaffold(dir)
            @test _detect_org_branding(dir)
            @test occursin(
                "## Part of the EpiAware ecosystem",
                read(joinpath(dir, "README.md"), String)
            )
        end
    end

    @testset "force re-lays the config, and the result is self-consistent" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            _set_branding!(dir, true)
            update(dir)
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
            @test !occursin(
                "EpiAware ecosystem",
                read(joinpath(dir, "README.md"), String)
            )
            mts = read(_p(dir, "docs/src/.vitepress/config.mts"), String)
            @test !occursin("epiaware-logo.svg", mts)

            # And the following sync agrees: nothing left to strip.
            res2 = update(dir)
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
            write(
                _cfg(dir),
                "# To join the org, uncomment:\n" *
                    "# const ORG_BRANDING = true\n"
            )
            @test !_detect_org_branding(dir)
            # A commented-out line above the real one does not win either.
            write(
                _cfg(dir),
                "# const ORG_BRANDING = true\n" *
                    "const ORG_BRANDING = false\n"
            )
            @test !_detect_org_branding(dir)
            # And the live line is still read when it is genuinely set.
            write(
                _cfg(dir),
                "# const ORG_BRANDING = false\n" *
                    "const ORG_BRANDING = true\n"
            )
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
                update(dir)
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

@testitem "dependabot groups bumps into one PR per ecosystem (#249)" begin
    using Test
    using EpiAwarePackageTools
    _dest(dir, rel) = joinpath(dir, split(rel, '/')...)

    mktempdir() do dir
        write(
            joinpath(dir, "Project.toml"),
            "name = \"Wombat\"\n" *
                "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                "authors = [\"Ada Lovelace\"]\n"
        )
        scaffold(dir)
        dep = read(_dest(dir, ".github/dependabot.yml"), String)
        # EVERY entry carries a `groups:` block with a wildcard pattern, so a
        # run's bumps land in one grouped PR each rather than a PR per workflow
        # file / per package — the storm Sam hit (#249). Asserted against the
        # entry count rather than a hardcoded number, so adding an ecosystem
        # entry cannot quietly add an *ungrouped* one: the invariant is
        # "grouped, one per entry", not "there are exactly N entries".
        entries = count("package-ecosystem:", dep)
        @test entries == 3
        @test count("groups:", dep) == entries
        @test count("patterns:", dep) == entries
        @test count("- \"*\"", dep) == entries
        @test occursin("      github-actions:\n", dep)
        @test occursin("      julia:\n", dep)
        # The isolated test environments (`test/jet`, `test/formatter`, and
        # with `ad = true` also `test/ad` / `test/ADFixtures`) are not
        # `[workspace]` members, so the `directory: "/"` julia entry never sees
        # them and their pins drift from `test/Project.toml`'s. A separate
        # entry over `/test/*` watches them, in its own group so a JET or
        # Runic minor — a breaking bump under 0.x semver — is reviewed
        # on its own rather than bundled with the workspace updates. A glob
        # because which of those directories exist is per-package.
        @test occursin("      julia-isolated:\n", dep)
        @test occursin("- \"/test/*\"", dep)
        # Every entry runs daily (#312). The grouping above is what makes that
        # affordable: a grouped PR is refreshed in place, so the shorter
        # interval buys faster updates rather than more open PRs. Asserted
        # here, on the same scaffold, because the two settings only make
        # sense together — daily and ungrouped is the storm #249 fixed.
        @test count("interval: \"daily\"", dep) == entries
        @test !occursin("interval: \"weekly\"", dep)
        # No placeholder survives into the emitted config.
        @test !occursin("{{", dep)
    end
end

@testitem "extensions get a docs nav group and seeded pages (#319)" begin
    using Test
    using Markdown
    using EpiAwarePackageTools
    using EpiAwarePackageTools: _package_extensions, _extensions_nav,
        _extension_stem, _extension_slug
    _dest(dir, rel) = joinpath(dir, split(rel, '/')...)

    # The stem drops the two affixes that carry no information, so the nav and
    # the page name read as the feature rather than as a module name.
    @test _extension_stem("WombatPlotsExt", "Wombat") == "Plots"
    @test _extension_stem("WombatComposedDistributionsExt", "Wombat") ==
        "ComposedDistributions"
    # An extension named exactly `<Package>Ext` keeps its full name rather
    # than stemming to nothing.
    @test _extension_stem("WombatExt", "Wombat") == "WombatExt"
    @test _extension_slug("ComposedDistributions") == "composed-distributions"

    mktempdir() do dir
        write(
            joinpath(dir, "Project.toml"),
            "name = \"Wombat\"\n" *
                "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                "authors = [\"Ada Lovelace\"]\n" *
                "\n[weakdeps]\n" *
                "Plots = \"91a5bcdd-55d7-5caf-9e0b-520d859cae80\"\n" *
                "DataFrames = \"a93c6f00-e57d-5684-b7b6-d8193f3e46c0\"\n" *
                "\n[extensions]\n" *
                "WombatPlotsExt = \"Plots\"\n" *
                "WombatTablesExt = [\"DataFrames\", \"Plots\"]\n"
        )

        # Detected from Project.toml, with no opt-in kwarg: an extension is a
        # fact about the package, not a CI choice.
        pages = _package_extensions(dir)
        @test length(pages) == 2
        # Labelled by the weakdep(s) that trigger the extension, sorted so the
        # nav order does not depend on TOML table order.
        @test [p.title for p in pages] == ["DataFrames + Plots", "Plots"]
        @test [p.slug for p in pages] == ["tables", "plots"]

        nav = _extensions_nav(dir)
        @test occursin("\"Extensions\" => [", nav)
        @test occursin("\"Plots\" => \"extensions/plots.md\"", nav)
        @test occursin(
            "\"DataFrames + Plots\" => \"extensions/tables.md\"",
            nav
        )

        scaffold(dir)
        pages_jl = read(_dest(dir, "docs/pages.jl"), String)
        @test occursin("\"Extensions\" => [", pages_jl)
        @test occursin("extensions/plots.md", pages_jl)
        @test occursin("extensions/tables.md", pages_jl)
        @test !occursin("{{", pages_jl)
        # The nav tree still evaluates: a malformed substitution would take
        # every adopter's docs build down at `include("pages.jl")`.
        nav_pages = include(_dest(dir, "docs/pages.jl"))
        @test any(e -> e isa Pair && e.first == "Extensions", nav_pages)

        # Every entry resolves to a seeded page.
        plots_md = _dest(dir, "docs/src/extensions/plots.md")
        @test isfile(plots_md)
        @test isfile(_dest(dir, "docs/src/extensions/tables.md"))
        page = read(plots_md, String)
        @test occursin("(@id extension-plots)", page)
        @test occursin("WombatPlotsExt", page)
        # The seeded page must contain no LIVE Documenter block. An extension
        # module exists only once its weakdeps load, so a live `@autodocs`
        # over `Base.get_extension` evaluates to `nothing` and kills the build
        # with a `MethodError` that `warnonly = [:autodocs_block]` does not
        # catch — for every freshly-scaffolded package. Asserted against the
        # parsed page, not the source text: Documenter parses with the
        # `Markdown` stdlib, which has no CommonMark HTML-block handling, so
        # an `@autodocs` fence wrapped in `<!-- -->` is still live to it (the
        # parser quirk behind #301/#304). The outer ````markdown fence is what
        # makes it inert.
        parsed = Markdown.parse(page)
        blocks = [el for el in parsed.content if el isa Markdown.Code]
        @test !isempty(blocks)
        @test !any(b -> startswith(b.language, "@"), blocks)
        @test any(
            b -> b.language == "markdown" &&
                occursin("```@autodocs", b.code), blocks
        )
        # The public-API block ships commented out: an extension module only
        # exists once its weakdeps load, so a live `@autodocs` over
        # `Base.get_extension` would red every freshly-scaffolded docs build.
        @test occursin(
            "Modules = [Base.get_extension(Wombat, " *
                ":WombatPlotsExt)]", page
        )

        # The pages are package-owned: authored scope prose survives a sync.
        authored = "# Plots extension\n\nAuthored prose.\n"
        write(plots_md, authored)
        EpiAwarePackageTools.update(dir)
        @test read(plots_md, String) == authored
        # ... and a re-scaffold, which does reach the package-owned seeds:
        # write-once means the authored page is preserved, not re-seeded.
        scaffold(dir)
        @test read(plots_md, String) == authored
        # `force` is the documented way back to the seeded page, as for every
        # other package-owned file.
        scaffold(dir; force = true)
        @test occursin("(@id extension-plots)", read(plots_md, String))
    end
end

@testitem "a package with no extensions gets no Extensions nav (#319)" begin
    using Test
    using EpiAwarePackageTools
    using EpiAwarePackageTools: _package_extensions, _extensions_nav
    _dest(dir, rel) = joinpath(dir, split(rel, '/')...)

    mktempdir() do dir
        write(
            joinpath(dir, "Project.toml"),
            "name = \"Wombat\"\n" *
                "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                "authors = [\"Ada Lovelace\"]\n"
        )
        @test isempty(_package_extensions(dir))
        @test _extensions_nav(dir) == ""

        scaffold(dir)
        pages_jl = read(_dest(dir, "docs/pages.jl"), String)
        @test !occursin(
            "Extensions", pages_jl[
                (something(findfirst("pages = [", pages_jl)).start):end,
            ]
        )
        @test !isdir(_dest(dir, "docs/src/extensions"))
    end
end

@testitem "coverage task actually instruments the test run (#315)" begin
    using Test
    using EpiAwarePackageTools
    _dest(dir, rel) = joinpath(dir, split(rel, '/')...)

    function _fake_pkg(dir; name = "Wombat")
        write(
            joinpath(dir, "Project.toml"),
            "name = \"$name\"\n" *
                "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                "authors = [\"Ada Lovelace\"]\n"
        )
        return dir
    end

    # `Pkg.test()` spawns its own child process for the actual test run, so an
    # outer `--code-coverage=user` on the driving `julia` process never reaches
    # it; only `Pkg.test(coverage=true, ...)` controls the child's
    # instrumentation. `coverage-ad` runs `runtests.jl` directly (no spawned
    # child), so its own `--code-coverage=user` is legitimate and left alone —
    # assertions below are scoped to the `coverage:` task's own recipe.
    function _check_coverage_recipe(dir)
        tf = read(_dest(dir, "Taskfile.yml"), String)
        cov_recipe = split(tf, "coverage-ad:")[1]
        @test occursin(
            "Pkg.test(coverage=true, test_args=[\"skip_quality\"])",
            cov_recipe
        )
        @test !occursin("--code-coverage=user", cov_recipe)
        # The post-processing step used to `Pkg.add("Coverage")` into
        # `--project=test`, dirtying the adopter's tracked `test/Project.toml`
        # (adds the dep, reorders entries) on every routine coverage run. A
        # shared environment keeps that dependency out of the tracked project
        # files.
        @test occursin("julia --project=@coverage -e", cov_recipe)
        @test !occursin(
            "julia --project=test -e 'using Pkg; Pkg.add(\"Coverage\")",
            cov_recipe
        )
    end

    @testset "ad = true (Taskfile.yml)" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; ad = true)
            _check_coverage_recipe(dir)
        end
    end

    @testset "ad = false (Taskfile.noad.yml)" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; ad = false)
            _check_coverage_recipe(dir)
        end
    end
end

@testitem "extension slugs and the manifest hold up at the edges (#319)" begin
    using Test
    using EpiAwarePackageTools
    using EpiAwarePackageTools: _package_extensions
    _dest(dir, rel) = joinpath(dir, split(rel, '/')...)

    @testset "two extensions stemming alike keep separate pages" begin
        mktempdir() do dir
            # `WombatPlotsExt` loses the package prefix, `PlotsExt` never had
            # one: both stem to `Plots`. Left unresolved, two nav entries would
            # point at one page and one extension would be documented under the
            # other's label.
            write(
                joinpath(dir, "Project.toml"),
                "name = \"Wombat\"\n" *
                    "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                    "authors = [\"Ada Lovelace\"]\n" *
                    "\n[weakdeps]\n" *
                    "Plots = \"91a5bcdd-55d7-5caf-9e0b-520d859cae80\"\n" *
                    "DataFrames = \"a93c6f00-e57d-5684-b7b6-d8193f3e46c0\"\n" *
                    "\n[extensions]\n" *
                    "WombatPlotsExt = \"Plots\"\n" *
                    "PlotsExt = \"DataFrames\"\n"
            )
            pages = _package_extensions(dir)
            @test length(pages) == 2
            @test length(unique(p.slug for p in pages)) == 2

            # Uniqueness is enforced, not assumed: a fallback slug can itself
            # land on one that was free in the first pass, since
            # `WombatPlotsExtExt` stems to the `PlotsExt` a bare `PlotsExt`
            # slugs to.
            three = joinpath(dir, "three")
            mkpath(three)
            write(
                joinpath(three, "Project.toml"),
                "name = \"Wombat\"\n" *
                    "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                    "authors = [\"Ada Lovelace\"]\n" *
                    "\n[weakdeps]\n" *
                    "Plots = \"91a5bcdd-55d7-5caf-9e0b-520d859cae80\"\n" *
                    "DataFrames = \"a93c6f00-e57d-5684-b7b6-d8193f3e46c0\"\n" *
                    "Random = \"9a3f8284-a2c9-5f02-9a11-845980a1fd5c\"\n" *
                    "\n[extensions]\n" *
                    "WombatPlotsExt = \"Plots\"\n" *
                    "PlotsExt = \"DataFrames\"\n" *
                    "WombatPlotsExtExt = \"Random\"\n"
            )
            trio = _package_extensions(three)
            @test length(trio) == 3
            @test length(unique(p.slug for p in trio)) == 3
            @test all(!isempty(p.slug) for p in trio)

            scaffold(dir)
            # Every nav entry resolves to a page of its own.
            pgs = read(_dest(dir, "docs/pages.jl"), String)
            for p in pages
                @test occursin("extensions/" * p.slug * ".md", pgs)
                @test isfile(
                    _dest(
                        dir,
                        "docs/src/extensions/" * p.slug * ".md"
                    )
                )
                # The page documents its own extension, not its twin's.
                @test occursin(
                    p.name,
                    read(
                        _dest(dir, "docs/src/extensions/" * p.slug * ".md"),
                        String
                    )
                )
            end
        end
    end

    @testset "declaring an extension later is picked up automatically (#170/#328/#354)" begin
        mktempdir() do dir
            write(
                joinpath(dir, "Project.toml"),
                "name = \"Wombat\"\n" *
                    "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                    "authors = [\"Ada Lovelace\"]\n"
            )
            res = scaffold(dir)
            # No extensions: nothing to seed, nothing to warn about, and the
            # manifest still reports the pair.
            @test isempty(res.extension_pages.created)
            @test isempty(res.extension_pages.preserved)
            @test !any(w -> occursin("extensions/", w), res.warnings)

            # The package declares an extension after adopting the kit. A
            # re-scaffold seeds the page (absent, so write-once writes it)
            # and regenerates the managed `pages.jl`, which links it
            # automatically -- before #170/#328/#354, `pages.jl` was
            # write-once too, so this needed a warning plus a hand-pasted nav
            # entry (see the git history of this test).
            proj = joinpath(dir, "Project.toml")
            write(
                proj,
                read(proj, String) *
                    "\n[weakdeps]\n" *
                    "Plots = \"91a5bcdd-55d7-5caf-9e0b-520d859cae80\"\n" *
                    "\n[extensions]\n" *
                    "WombatPlotsExt = \"Plots\"\n"
            )
            res2 = scaffold(dir)
            @test length(res2.extension_pages.created) == 1
            @test isfile(_dest(dir, "docs/src/extensions/plots.md"))
            @test res2.pages == :refreshed
            pgs2 = read(_dest(dir, "docs/pages.jl"), String)
            @test occursin("\"Plots\" => \"extensions/plots.md\"", pgs2)
            # Already linked by the regeneration above, so nothing to warn
            # about.
            @test !any(w -> occursin("extensions/plots.md", w), res2.warnings)

            # A further re-scaffold changes nothing of substance: the page is
            # preserved (write-once), and the nav entry survives being
            # regenerated again.
            res3 = scaffold(dir)
            @test !any(w -> occursin("extensions/plots.md", w), res3.warnings)
            @test length(res3.extension_pages.preserved) == 1
            @test isempty(res3.extension_pages.created)
            @test occursin(
                "\"Plots\" => \"extensions/plots.md\"",
                read(_dest(dir, "docs/pages.jl"), String)
            )
        end
    end

    @testset "update stays silent when there is no page to be unreachable" begin
        mktempdir() do dir
            write(
                joinpath(dir, "Project.toml"),
                "name = \"Wombat\"\n" *
                    "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                    "authors = [\"Ada Lovelace\"]\n"
            )
            scaffold(dir)
            # A package that adopted the kit before it seeded extension pages,
            # then declared an extension: `update` seeds no page, so there is
            # no file to be unreachable. Warning here would claim a page is
            # "built but unreachable" when none was ever written, and the nav
            # entry it asks for would be stripped at build time anyway — on
            # every routine sync of the packages this feature targets.
            proj = joinpath(dir, "Project.toml")
            write(
                proj,
                read(proj, String) *
                    "\n[weakdeps]\n" *
                    "Plots = \"91a5bcdd-55d7-5caf-9e0b-520d859cae80\"\n" *
                    "\n[extensions]\n" *
                    "WombatPlotsExt = \"Plots\"\n"
            )
            res = EpiAwarePackageTools.update(dir)
            @test !isfile(_dest(dir, "docs/src/extensions/plots.md"))
            @test !any(w -> occursin("extensions/", w), res.warnings)
            # `update` seeds no package-owned pages, and says so.
            @test isempty(res.extension_pages.created)
            @test isempty(res.extension_pages.preserved)
        end
    end
end

@testitem "scaffolded output is Runic-clean (#344)" begin
    using Test
    using EpiAwarePackageTools
    using EpiAwarePackageTools: SCAFFOLD_TEMPLATES, _templates_dir
    using Runic

    # `templates/` itself is excluded from formatting (#363): several of its
    # `.jl` files carry a `{{PLACEHOLDER}}` in `using`/`import` position and
    # are hard parse errors until substituted, so Runic (AST-based) cannot
    # check the raw tree. Before Runic that gap was silent churn — a managed
    # file could land in a downstream repo already unclean, and that repo had
    # no way to fix it (JuliaFormatter.format just reformatted it locally on
    # every run). Under Runic an unclean managed file is a hard `--check`
    # failure in the adopter's own CI, which the adopter cannot fix (the file
    # is regenerated by `update`) and did not cause. So the guard runs here
    # instead: substitute every template through the real `scaffold` path,
    # across every combination of the flags that change which templates are
    # selected and what gets substituted into them, and Runic-check the
    # result. Every combination must already be `.jl`-clean.
    #
    # Checking the emitted tree rather than `templates/` is also the stricter
    # test, not just the only workable one. What an adopter's own formatter
    # job sees is the substituted file, and substitution can change the tree
    # Runic formats, so a raw template being clean neither implies nor is
    # implied by the emitted file being clean.
    #
    # `[extensions]` is part of the sweep because it is the one nav fragment
    # driven by the target's Project.toml rather than by a kwarg, and its
    # entries are the last thing in the Extensions group -- the position
    # Runic's trailing comma lands on (#413).

    # Where each destination came from, so a failure names the file to edit
    # rather than a path in a temp dir. `docs/pages.jl` is applied by
    # `_apply_pages` rather than copied, so it is not a table entry (#170).
    dest_to_src = Dict{String, String}(
        t.dest => t.src for t in SCAFFOLD_TEMPLATES if endswith(t.src, ".jl")
    )
    dest_to_src["docs/pages.jl"] = "docs/pages.jl"

    # Every `.jl` under `templates/` has to reach the sweep, or the guard is
    # silently partial: a template gated on a flag combination not swept, or
    # never wired into the scaffold at all, would go unchecked here and
    # unchecked everywhere (#420). Hold the two sets equal instead of
    # trusting the walk to have covered them.
    templates_root = _templates_dir()
    template_jl = Set{String}()
    for (root, _, files) in walkdir(templates_root), f in files
        endswith(f, ".jl") || continue
        push!(
            template_jl,
            join(splitpath(relpath(joinpath(root, f), templates_root)), '/')
        )
    end
    @test !isempty(template_jl)
    # Reported as two differences rather than one set equality, so a failure
    # prints the file that moved rather than both whole sets.
    @test setdiff(template_jl, Set(values(dest_to_src))) == Set{String}()
    @test setdiff(Set(values(dest_to_src)), template_jl) == Set{String}()

    # Destinations reached by at least one combination of the sweep, as posix
    # relative paths to compare against the template set.
    covered = Set{String}()

    for ad in (true, false), benchmarks in (true, false),
            extensions in (true, false)

        mktempdir() do dir
            ext_toml = extensions ?
                "\n[weakdeps]\n" *
                "Plots = \"91a5bcdd-55d7-5caf-9e0b-520d859cae80\"\n" *
                "Zed = \"00000000-0000-0000-0000-00000000000f\"\n" *
                "\n[extensions]\n" *
                "FakePkgPlotsExt = \"Plots\"\n" *
                "FakePkgZedExt = \"Zed\"\n" : ""
            write(
                joinpath(dir, "Project.toml"),
                "name = \"FakePkg\"\n" *
                    "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                    "authors = [\"Ada Lovelace\"]\n" * ext_toml
            )
            scaffold(dir; ad = ad, benchmarks = benchmarks)
            pages = read(joinpath(dir, "docs", "pages.jl"), String)
            # Guard against the sweep going vacuous: the Extensions group has
            # to actually be there for its formatting to mean anything.
            @test occursin("\"Extensions\" => [", pages) == extensions
            emitted = Tuple{String, String}[]
            for (root, _, files) in walkdir(dir), f in files
                endswith(f, ".jl") || continue
                path = joinpath(root, f)
                rel = join(splitpath(relpath(path, dir)), '/')
                push!(covered, rel)
                push!(emitted, (rel, path))
            end
            code = Runic.main(["--check", "--diff", dir])
            # The diff is against a temp dir nobody can edit, so on failure
            # re-check per file and report the templates behind it. Only on
            # failure: the whole-tree pass is one walk, this is one Runic run
            # per emitted file. The exit code is still asserted below, so a
            # non-zero run no single file reproduces (a parse error, say)
            # cannot pass as an empty list.
            unclean = code == 0 ? String[] :
                sort(
                    [
                        "templates/" * get(dest_to_src, rel, rel)
                        for (rel, path) in emitted
                        if Runic.main(["--check", path]) != 0
                    ]
                )
            @test isempty(unclean)
            @test code == 0
        end
    end

    # No `.jl` template escaped the sweep above. Compared on destinations,
    # since a template is free to be written somewhere other than its own
    # path (the AD/no-AD pairs do exactly that).
    @test setdiff(Set(keys(dest_to_src)), covered) == Set{String}()
end

# Freshening moves a managed caller's reusable-workflow ref forwards to the
# newest commit that touched the workflow it wraps, and does nothing else: a
# ref that is already current or ahead, one that floats on a branch, and one
# the resolver cannot speak to are all left exactly as committed (#425).
@testitem "reusable-workflow refs are freshened forwards only (#425)" begin
    using Test
    # `Base.CoreLogging`, not the `Logging` stdlib: `Logging` is not a
    # declared dep of the managed test environment, and declaring one
    # here would push it to every adopter for the sake of a test.
    using Base.CoreLogging: NullLogger, with_logger
    using EpiAwarePackageTools
    using EpiAwarePackageTools: scaffold, update, ReusableRefSource,
        _REUSABLE_SEED_REFS

    _dest(dir, rel) = joinpath(dir, split(rel, '/')...)

    function _fake_pkg(dir)
        write(
            joinpath(dir, "Project.toml"),
            "name = \"FakePkg\"\n" *
                "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                "authors = [\"Ada Lovelace\"]\n"
        )
        return dir
    end

    # A stubbed resolver, so the policy is exercised with no network. `latest`
    # answers from `refs`, falling back to the workflow's own seed so every
    # caller the test is not about resolves to what it already pins and stays
    # quiet; `nothing` in `refs` models an unresolvable workflow. `is_newer`
    # answers from `ahead`, keyed by the (committed, candidate) pair, and
    # `nothing` (the default) models a pair that cannot be compared. Both
    # record their calls, so a test can assert none were made.
    function _stub_source(refs::Dict, ahead::Dict = Dict())
        calls = String[]
        latest = function (_org, workflow)
            push!(calls, "latest:" * workflow)
            return haskey(refs, workflow) ? refs[workflow] :
                get(_REUSABLE_SEED_REFS, workflow, nothing)
        end
        is_newer = function (_org, current, candidate)
            push!(calls, "is_newer:" * current * ":" * candidate)
            return get(ahead, (current, candidate), nothing)
        end
        return ReusableRefSource(latest, is_newer), calls
    end

    committed = "a"^40
    newest = "b"^40

    # Pin `test.yaml`'s `tests.yml` caller at `ref`, as Dependabot or an
    # earlier adoption would have left it.
    function _pin_tests_caller(dir, ref)
        caller = _dest(dir, ".github/workflows/test.yaml")
        write(
            caller,
            replace(
                read(caller, String),
                r"(tests\.yml@)\S+" => SubstitutionString("\\1" * ref)
            )
        )
        return caller
    end

    @testset "a ref behind the workflow's newest commit is advanced" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            caller = _pin_tests_caller(dir, committed)
            source, calls = _stub_source(
                Dict("tests.yml" => newest), Dict((committed, newest) => true)
            )
            res = with_logger(NullLogger()) do
                update(dir; freshen_reusable_refs = true, ref_source = source)
            end
            @test occursin("tests.yml@" * newest, read(caller, String))
            @test isempty(res.warnings)
            @test "is_newer:" * committed * ":" * newest in calls
            # Idempotent: a second run has nothing left to move.
            after = read(caller, String)
            source2, _ = _stub_source(
                Dict("tests.yml" => newest), Dict((committed, newest) => true)
            )
            with_logger(NullLogger()) do
                update(dir; freshen_reusable_refs = true, ref_source = source2)
            end
            @test read(caller, String) == after
        end
    end

    @testset "a ref already at the newest commit is left alone" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            caller = _dest(dir, ".github/workflows/test.yaml")
            before = read(caller, String)
            source, calls = _stub_source(Dict())
            res = with_logger(NullLogger()) do
                update(dir; freshen_reusable_refs = true, ref_source = source)
            end
            @test read(caller, String) == before
            @test isempty(res.warnings)
            # Nothing to compare when the candidate is what is already there.
            @test !any(startswith(c, "is_newer:") for c in calls)
        end
    end

    @testset "a ref ahead of the newest commit is never rewound" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            # The Dependabot case: it bumps to the `.github` head, which is a
            # descendant of the newest commit touching any one workflow. A
            # freshener that took the newest per-file commit unconditionally
            # would revert every such bump.
            caller = _pin_tests_caller(dir, committed)
            source, _ = _stub_source(
                Dict("tests.yml" => newest), Dict((committed, newest) => false)
            )
            res = with_logger(NullLogger()) do
                update(dir; freshen_reusable_refs = true, ref_source = source)
            end
            @test occursin("tests.yml@" * committed, read(caller, String))
            @test isempty(res.warnings)
        end
    end

    @testset "an unresolvable workflow keeps its committed ref" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            caller = _pin_tests_caller(dir, committed)
            before = read(caller, String)
            # Offline, unauthenticated, rate-limited or simply absent
            # upstream: all reach `update` as an unresolved candidate.
            source, _ = _stub_source(Dict("tests.yml" => nothing))
            res = with_logger(NullLogger()) do
                update(dir; freshen_reusable_refs = true, ref_source = source)
            end
            @test read(caller, String) == before
            @test any(
                occursin("could not resolve", w) && occursin("tests.yml", w)
                    for w in res.warnings
            )
        end
    end

    @testset "an uncomparable ref keeps its committed ref" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            # A SHA the org repository does not know (e.g. taken from a fork)
            # cannot be shown to be older, so it is not moved.
            caller = _pin_tests_caller(dir, committed)
            source, _ = _stub_source(Dict("tests.yml" => newest))
            res = with_logger(NullLogger()) do
                update(dir; freshen_reusable_refs = true, ref_source = source)
            end
            @test occursin("tests.yml@" * committed, read(caller, String))
            @test any(occursin("could not compare", w) for w in res.warnings)
        end
    end

    @testset "a branch or tag ref is never resolved or replaced" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            caller = _pin_tests_caller(dir, "main")
            source, calls = _stub_source(Dict("tests.yml" => newest))
            res = with_logger(NullLogger()) do
                update(dir; freshen_reusable_refs = true, ref_source = source)
            end
            @test occursin("tests.yml@main", read(caller, String))
            @test isempty(res.warnings)
            @test !("latest:tests.yml" in calls)
        end
    end

    @testset "update makes no network call by default" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            caller = _pin_tests_caller(dir, committed)
            before = read(caller, String)
            source, calls = _stub_source(
                Dict("tests.yml" => newest), Dict((committed, newest) => true)
            )
            update(dir; ref_source = source)
            @test read(caller, String) == before
            @test isempty(calls)
        end
    end
end
