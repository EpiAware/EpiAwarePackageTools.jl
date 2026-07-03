# `setup_checklist` prints only (no `gh`/API calls), so it is exercised by
# capturing its `io` output into an `IOBuffer` and checking the rendered text.

@testitem "setup_checklist" begin
    using Test
    using EpiAwarePackageTools

    @testset "resolves package/repo from Project.toml" begin
        mktempdir() do dir
            write(joinpath(dir, "Project.toml"),
                "name = \"FakePkg\"\n" *
                "uuid = \"00000000-0000-0000-0000-000000000000\"\n" *
                "authors = [\"Ada Lovelace\"]\n")
            buf = IOBuffer()
            result = setup_checklist(dir; io = buf)
            @test result === nothing
            text = String(take!(buf))
            @test occursin("FakePkg", text)
            @test occursin("EpiAware/FakePkg.jl", text)
            # Every checklist step renders as a markdown task-list item.
            @test occursin("Codecov", text)
            @test occursin("CODECOV_TOKEN", text)
            @test occursin("GitHub Pages", text)
            @test occursin("main", text)
            @test occursin("/register", text)
            @test occursin("Register", text)
            # A ready-to-paste tracking-issue body follows the checklist.
            @test occursin("Manual setup for FakePkg", text)
            @test occursin("- [ ] Enable FakePkg on Codecov", text)
            # Every step actually names the target package (not just the
            # title/heading) — regression check for the package name being
            # resolved but never interpolated into the step text.
            @test occursin("GitHub Pages for FakePkg's", text)
            @test occursin("Protect FakePkg's `main` branch", text)
            # No `gh`/API dependency: nothing in the output shells out.
            @test !occursin("gh api", text)
            @test !occursin("gh issue create --title", text)
        end
    end

    @testset "explicit package/repo/org override with no Project.toml" begin
        mktempdir() do dir
            buf = IOBuffer()
            setup_checklist(dir; package = "OtherPkg",
                repo = "SomeOrg/OtherPkg.jl", io = buf)
            text = String(take!(buf))
            @test occursin("OtherPkg", text)
            @test occursin("SomeOrg/OtherPkg.jl", text)
        end
    end

    @testset "falls back to placeholders with nothing resolved" begin
        mktempdir() do dir
            buf = IOBuffer()
            setup_checklist(dir; io = buf)
            text = String(take!(buf))
            @test occursin("<package>", text)
            @test occursin("<org>/<package>.jl", text)
        end
    end

    @testset "default target_dir/io do not throw" begin
        # Smoke test: the zero-argument call used from a package root prints
        # to stdout without erroring, whatever the current directory is.
        mktemp() do path, io
            redirect_stdout(io) do
                @test setup_checklist() === nothing
            end
        end
    end
end
