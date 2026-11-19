# The Claude workflows need an API key or OAuth token secret, so they are
# opt-in: a fresh scaffold writes neither, `claude_review = true` writes both,
# and `update` detects the committed state so a resync keeps an opt-in and does
# not restore workflows a package deleted.

@testitem "claude_review opt-in gating + idempotence" begin
    using Test
    using EpiAwarePackageTools
    using EpiAwarePackageTools: _detect_claude_review, update, scaffold_generate

    function _fake_pkg(dir; name = "FakePkg")
        write(
            joinpath(dir, "Project.toml"),
            "name = \"$name\"\n" *
                "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                "authors = [\"Ada Lovelace\"]\n"
        )
        return dir
    end

    wf(dir, f) = joinpath(dir, ".github", "workflows", f)
    FILES = ["claude.yml", "claude-code-review.yml"]

    mktempdir() do dir
        _fake_pkg(dir)
        scaffold(dir)
        @test !any(f -> isfile(wf(dir, f)), FILES)
        @test !_detect_claude_review(dir)
        # The template-sync call carries the flag.
        sync = read(wf(dir, "template-sync.yaml"), String)
        @test occursin("claude_review = false", sync)
        # A resync keeps the opt-out.
        update(dir)
        @test !any(f -> isfile(wf(dir, f)), FILES)
    end

    mktempdir() do dir
        _fake_pkg(dir)
        scaffold(dir; claude_review = true)
        @test all(f -> isfile(wf(dir, f)), FILES)
        @test _detect_claude_review(dir)
        @test occursin(
            "claude_review = true", read(wf(dir, "template-sync.yaml"), String)
        )
        # A resync with no kwarg preserves the opt-in.
        update(dir)
        @test all(f -> isfile(wf(dir, f)), FILES)
        # Deleting both workflows is honoured by the next sync.
        foreach(f -> rm(wf(dir, f)), FILES)
        update(dir)
        @test !any(f -> isfile(wf(dir, f)), FILES)
        # An explicit flag still overrides detection.
        update(dir; claude_review = true)
        @test all(f -> isfile(wf(dir, f)), FILES)
    end

    mktempdir() do dir
        scaffold_generate(dir, "Wombat"; authors = ["Ada Lovelace"])
        @test !isfile(wf(dir, "claude.yml"))
    end
end
