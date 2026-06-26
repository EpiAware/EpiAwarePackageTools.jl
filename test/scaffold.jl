# Scaffolding a fresh temp directory should write all standard templates; a
# second pass should skip the existing files unless forced.

@testset "scaffold" begin
    expected = ("Taskfile.yml", ".pre-commit-config.yaml",
        ".JuliaFormatter.toml")

    mktempdir() do dir
        res = scaffold(dir)

        @testset "writes every template" begin
            @test length(res.written) == length(expected)
            @test isempty(res.skipped)
            for name in expected
                @test isfile(joinpath(dir, name))
            end
        end

        @testset "copies expected content" begin
            fmt = read(joinpath(dir, ".JuliaFormatter.toml"), String)
            @test occursin("sciml", fmt)
            pc = read(joinpath(dir, ".pre-commit-config.yaml"), String)
            @test occursin("JuliaFormatter.jl", pc)
            tf = read(joinpath(dir, "Taskfile.yml"), String)
            @test occursin("version: '3'", tf)
        end

        @testset "skips existing without force" begin
            res2 = scaffold(dir)
            @test isempty(res2.written)
            @test length(res2.skipped) == length(expected)
        end

        @testset "overwrites with force" begin
            res3 = scaffold(dir; force = true)
            @test length(res3.written) == length(expected)
            @test isempty(res3.skipped)
        end
    end

    @testset "errors on missing target" begin
        @test_throws ErrorException scaffold(
            joinpath(tempdir(), "no-such-scaffold-target-xyz"))
    end
end
