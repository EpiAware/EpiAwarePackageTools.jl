# Focused tests for the managed `docs/pages.jl` base + `docs_config.jl`
# extension points (#170/#328/#354): regeneration/idempotence, each
# extension point splicing into the right slot with absence a no-op,
# migration-safety (a bespoke file preserved + warned about, a managed one
# refreshed), and the self-healing this whole redesign exists for (a stale
# `BENCHMARKS_NAV`/orphaned AD tutorial fixed by `update`, not only by a
# fresh `scaffold`).

@testitem "managed docs/pages.jl base + docs_config.jl extension points (#170/#328/#354)" begin
    using Test
    using EpiAwarePackageTools
    using EpiAwarePackageTools: _MANAGED_PAGES_MARKER, update
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

    @testset "regenerated on update, and idempotent" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            pgs = _dest(dir, "docs/pages.jl")
            before = read(pgs, String)
            @test occursin(_MANAGED_PAGES_MARKER, before)
            res = update(dir)
            @test res.pages == :unchanged
            @test read(pgs, String) == before

            # A hand-edit to a MANAGED file is reverted on the next sync,
            # exactly like any other managed template.
            write(
                pgs,
                replace(
                    before,
                    "\"Home\" => \"index.md\"" => "\"Homepage\" => \"index.md\""
                )
            )
            res2 = update(dir)
            @test res2.pages == :refreshed
            @test read(pgs, String) == before
        end
    end

    @testset "PACKAGE_TUTORIALS splices after Overview, absence is a no-op" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; ad = false)
            cfg = _dest(dir, "docs/docs_config.jl")
            fresh = read(_dest(dir, "docs/pages.jl"), String)
            @test !occursin("Fitting a Wombat", fresh)
            write(
                cfg,
                read(cfg, String) *
                    "\nconst PACKAGE_TUTORIALS = [\n" *
                    "    \"Fitting a Wombat\" => " *
                    "\"getting-started/tutorials/fitting.md\"\n]\n"
            )
            res = update(dir; ad = false)
            @test res.pages == :refreshed
            pgs = read(_dest(dir, "docs/pages.jl"), String)
            @test occursin(
                "\"Overview\" => \"getting-started/index.md\",\n" *
                    "        \"Fitting a Wombat\" => " *
                    "\"getting-started/tutorials/fitting.md\"\n    ],", pgs
            )
        end
    end

    @testset "GETTING_STARTED_FAQ splices right after Overview" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; ad = false)
            cfg = _dest(dir, "docs/docs_config.jl")
            write(
                cfg,
                read(cfg, String) *
                    "\nconst GETTING_STARTED_FAQ = \"getting-started/faq.md\"\n"
            )
            update(dir; ad = false)
            pgs = read(_dest(dir, "docs/pages.jl"), String)
            @test occursin(
                "\"Overview\" => \"getting-started/index.md\",\n" *
                    "        \"FAQ\" => \"getting-started/faq.md\"\n    ],", pgs
            )
        end
    end

    @testset "PACKAGE_SECTIONS adds whole top-level groups, in slot" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; ad = false, benchmarks = false)
            fresh = read(_dest(dir, "docs/pages.jl"), String)
            @test !occursin("\"Tools\"", fresh)
            cfg = _dest(dir, "docs/docs_config.jl")
            write(
                cfg,
                read(cfg, String) *
                    "\nconst PACKAGE_SECTIONS = [\n" *
                    "    \"Tools\" => [\n" *
                    "        \"Charter\" => \"tools/index.md\",\n" *
                    "        \"Widget\" => \"tools/widget.md\"\n" *
                    "    ]\n]\n"
            )
            update(dir; ad = false, benchmarks = false)
            pgs = read(_dest(dir, "docs/pages.jl"), String)
            @test occursin(
                "\"Tools\" => [\n        \"Charter\" => \"tools/index.md\"," *
                    "\n        \"Widget\" => \"tools/widget.md\",\n    ]", pgs
            )
            # After API reference (Extensions/Benchmarks are the base's own
            # slots in between), before Release notes.
            api_at = first(findfirst("\"API reference\"", pgs))
            tools_at = first(findfirst("\"Tools\"", pgs))
            rel_at = first(findfirst("\"Release notes\"", pgs))
            @test api_at < tools_at < rel_at
        end
    end

    @testset "DEVELOPMENT_EXTEND_PAGE gates the whole Development group" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            @test !occursin(
                "\"Development\"",
                read(_dest(dir, "docs/pages.jl"), String)
            )
            cfg = _dest(dir, "docs/docs_config.jl")
            write(
                cfg,
                read(cfg, String) *
                    "\nconst DEVELOPMENT_EXTEND_PAGE = \"Adding a workaround\" " *
                    "=> \"developer/adding-a-tool.md\"\n"
            )
            update(dir)
            pgs = read(_dest(dir, "docs/pages.jl"), String)
            @test occursin(
                "\"Development\" => [\n" *
                    "        \"Overview\" => \"developer/index.md\",\n" *
                    "        \"Contributing\" => \"developer/contributing.md\",\n" *
                    "        \"Adding a workaround\" => " *
                    "\"developer/adding-a-tool.md\",\n" *
                    "        \"Release process\" => " *
                    "\"developer/release-process.md\",\n" *
                    "        \"Developer FAQ\" => \"developer/faq.md\",\n    ]",
                pgs
            )
        end
    end

    @testset "an AD-enabled package's nav links the AD tutorial (no orphan)" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; ad = true)
            pgs = read(_dest(dir, "docs/pages.jl"), String)
            @test occursin(
                "getting-started/tutorials/ad-backends.md", pgs
            )
            @test isfile(
                _dest(
                    dir,
                    "docs/src/getting-started/tutorials/ad-backends.jl"
                )
            )
            # Still linked after a resync, not just at first scaffold.
            update(dir; ad = true)
            @test occursin(
                "getting-started/tutorials/ad-backends.md",
                read(_dest(dir, "docs/pages.jl"), String)
            )
        end
    end

    @testset "Benchmarks nav self-heals on update, not only scaffold (#305)" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; benchmarks = true)
            pgs = _dest(dir, "docs/pages.jl")
            fresh = read(pgs, String)
            # Simulate a MANAGED pages.jl (marker present) that has drifted
            # from what `_benchmarks_nav` currently renders -- e.g. a package
            # synced with an older kit version.
            stale = replace(
                fresh,
                r"\"Benchmarks\" => \[.*?\]"s => "\"Benchmarks\" => \"benchmarks.md\""
            )
            @test stale != fresh
            write(pgs, stale)
            res = update(dir; benchmarks = true)
            @test res.pages == :refreshed
            @test read(pgs, String) == fresh
            @test isempty(filter(w -> occursin("pages.jl", w), res.warnings))
        end
    end

    @testset "a bespoke pages.jl is preserved; warning names the lost groups" begin
        mktempdir() do dir
            _fake_pkg(dir; name = "EpiAwareADTools")
            scaffold(dir)
            # A realistic bespoke file predating this redesign: no
            # `_MANAGED_PAGES_MARKER`, and a "Tools" group (real content, in
            # the shape EpiAwareADTools.jl's actual pages.jl carries) the
            # generated base has no slot for without `PACKAGE_SECTIONS`.
            # "Development" here has no `DEVELOPMENT_EXTEND_PAGE` set yet
            # either, so it is also unreproduced.
            bespoke = """
            # PACKAGE-OWNED — scaffold writes this once and never overwrites it.
            pages = [
                "Home" => "index.md",
                "Getting started" => [
                    "Overview" => "getting-started/index.md",
                    "Installation" => "getting-started/installation.md",
                    "FAQ" => "getting-started/faq.md"
                ],
                "Tools" => [
                    "Charter and status" => "tools/index.md",
                    "Tape-strip: primal" => "tools/tape-strip.md"
                ],
                "API reference" => [
                    "Public API" => "lib/public.md",
                    "Internal API" => "lib/internals.md"
                ],
                "Development" => [
                    "Overview" => "developer/index.md",
                    "Contributing" => "developer/contributing.md",
                    "Adding a workaround" => "developer/adding-a-tool.md",
                    "Release process" => "developer/release-process.md",
                    "Developer FAQ" => "developer/faq.md"
                ]
            ]
            """
            pgs = _dest(dir, "docs/pages.jl")
            write(pgs, bespoke)
            res = update(dir)
            @test res.pages == :preserved
            # Untouched, byte for byte.
            @test read(pgs, String) == bespoke
            w = only(filter(m -> occursin("pages.jl", m), res.warnings))
            @test occursin("Tools", w)
            @test occursin("Development", w)
            @test occursin("PACKAGE_SECTIONS", w)
            @test occursin("docs_config.jl", w)
            # "Getting started"/"API reference" (reproduced by the base
            # regardless of extension points) are not named as at risk.
            @test !occursin("\"Getting started\"", w)
            @test !occursin("\"API reference\"", w)

            # A further sync leaves it preserved too -- `force` does not
            # reach it either, unlike every other package-owned skeleton.
            res2 = scaffold(dir; force = true)
            @test res2.pages == :preserved
            @test read(pgs, String) == bespoke
        end
    end
end
