# The Claude workflows are opt-in: a fresh scaffold writes neither, and
# `claude_review = true` writes both. `update` detects an adopter's state from
# the committed workflows so a resync preserves an opt-in.

@testitem "claude_review opt-in gating" begin
    using Test
    using EpiAwarePackageTools
    using EpiAwarePackageTools: _detect_claude_review, update,
        SCAFFOLD_TEMPLATES, _template_selected

    function _fake_pkg(dir)
        write(
            joinpath(dir, "Project.toml"),
            "name = \"FakePkg\"\n" *
                "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                "authors = [\"Ada Lovelace\"]\n"
        )
        return dir
    end

    wf(dir, f) = joinpath(dir, ".github", "workflows", f)
    const CLAUDE_FILES = ["claude.yml", "claude-code-review.yml"]

    @testset "the default writes neither workflow" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            for f in CLAUDE_FILES
                @test !isfile(wf(dir, f))
            end
            @test !_detect_claude_review(dir)
        end
    end

    @testset "claude_review = true writes both" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; claude_review = true)
            for f in CLAUDE_FILES
                @test isfile(wf(dir, f))
            end
            @test _detect_claude_review(dir)
        end
    end

    @testset "update preserves the state it detects" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir; claude_review = true)
            update(dir)
            for f in CLAUDE_FILES
                @test isfile(wf(dir, f))
            end
        end
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            update(dir)
            for f in CLAUDE_FILES
                @test !isfile(wf(dir, f))
            end
        end
    end

    @testset "update can switch the workflows on" begin
        mktempdir() do dir
            _fake_pkg(dir)
            scaffold(dir)
            update(dir; claude_review = true)
            for f in CLAUDE_FILES
                @test isfile(wf(dir, f))
            end
        end
    end

    @testset "a template's `when` is checked against every flag" begin
        t = first(
            t for t in SCAFFOLD_TEMPLATES if t.dest == "benchmark/run.jl"
        )
        @test t.when == (benchmarks = true,)
        flags(; kw...) = merge(
            (ad = true, benchmarks = true, claude_review = true), (; kw...)
        )
        @test _template_selected(t, flags())
        @test !_template_selected(t, flags(benchmarks = false))
        @test _template_selected(t, flags(ad = false))
    end
end
