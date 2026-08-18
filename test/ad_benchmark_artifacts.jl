# Unit tests for the AD benchmark artefact reader (kit #443): the data path the
# scaffolded `docs/src/benchmarks/ad-comparison.jl` page uses in place of
# measuring every (backend, scenario) pair during the docs build.
#
# The page itself only renders; everything that can go wrong with the input --
# no directory, an empty one, a backend's job that never uploaded, a corrupt
# file -- is decided here, so it is tested here rather than by building docs.

@testsnippet ADArtifactFixtures begin
    using Test
    using EpiAwarePackageTools
    const DB = EpiAwarePackageTools.DocsBuild

    const EXPECTED = [
        "ForwardDiff", "ReverseDiff", "Enzyme forward", "Enzyme reverse",
    ]

    # One backend's artefact, in the contract the benchmark jobs upload.
    function artifact_json(backend, tag, scenarios)
        rows = join(
            [
                """{"name": "$(name)", "time_us": $(t), "bytes_kb": $(b)}"""
                    for (name, t, b) in scenarios
            ], ", "
        )
        return """
        {"backend": "$(backend)", "tag": "$(tag)", "scenarios": [$(rows)]}
        """
    end

    # `touch` cannot set a time, and the loader resolves duplicate scenarios by
    # modification time, so the tests stamp files rather than sleeping between
    # writes and hoping the filesystem's granularity is fine enough.
    function set_mtime(path, t)
        f = Base.Filesystem.open(path, Base.Filesystem.JL_O_RDWR)
        try
            Base.Filesystem.futime(f, t, t)
        finally
            close(f)
        end
        return path
    end

    function write_artifact(dir, backend, tag, scenarios; subdir = nothing)
        into = subdir === nothing ? dir : mkpath(joinpath(dir, subdir))
        path = joinpath(into, "$(tag).json")
        write(path, artifact_json(backend, tag, scenarios))
        return path
    end
end

@testitem "AD artefacts: a complete set" setup = [ADArtifactFixtures] begin
    dir = mktempdir()
    write_artifact(dir, "ForwardDiff", "forwarddiff", [("AR", 10.0, 4.0)])
    write_artifact(dir, "ReverseDiff", "reversediff", [("AR", 20.0, 8.0)])
    write_artifact(
        dir, "Enzyme forward", "enzyme_forward", [("AR", 5.0, 2.0)]
    )
    write_artifact(
        dir, "Enzyme reverse", "enzyme_reverse", [("AR", 2.5, 1.0)]
    )

    a = DB.load_ad_benchmarks(dir, EXPECTED)

    @test a.backends == EXPECTED
    @test isempty(a.missing_backends)
    @test isempty(a.unreadable)
    @test length(a.rows) == 4
    # Registry order, not the alphabetical order the files were read in: the
    # page picks its baseline off the first backend with numbers.
    @test [r.backend for r in a.rows] == EXPECTED
    @test first(a.rows).scenario == "AR"
    @test first(a.rows).time_us == 10.0
    @test first(a.rows).bytes_kb == 4.0
    # Nothing to say when nothing is missing.
    @test DB.ad_benchmark_note(a) == ""
end

@testitem "AD artefacts: one artefact per subdirectory" setup = [
    ADArtifactFixtures,
] begin
    # `actions/download-artifact` with a `pattern:` puts each artefact in a
    # directory named after it, so the reader must walk rather than list.
    dir = mktempdir()
    write_artifact(
        dir, "ForwardDiff", "forwarddiff", [("AR", 10.0, 4.0)];
        subdir = "ad-benchmark-forwarddiff"
    )
    write_artifact(
        dir, "ReverseDiff", "reversediff", [("AR", 20.0, 8.0)];
        subdir = "ad-benchmark-reversediff"
    )

    a = DB.load_ad_benchmarks(dir, EXPECTED)

    @test a.backends == ["ForwardDiff", "ReverseDiff"]
    @test length(a.rows) == 2
end

@testitem "AD artefacts: a partial set renders and is reported" setup = [
    ADArtifactFixtures,
] begin
    # Two of four backends measured: the other two either failed or had not
    # finished. The page must show the two it has, not fail on the two it
    # does not.
    dir = mktempdir()
    write_artifact(
        dir, "ForwardDiff", "forwarddiff",
        [("AR", 10.0, 4.0), ("Renewal", 30.0, 12.0)]
    )
    write_artifact(
        dir, "Enzyme reverse", "enzyme_reverse",
        [("AR", 2.5, 1.0), ("Renewal", 9.0, 3.0)]
    )

    a = DB.load_ad_benchmarks(dir, EXPECTED)

    @test a.backends == ["ForwardDiff", "Enzyme reverse"]
    @test a.missing_backends == ["ReverseDiff", "Enzyme forward"]
    @test length(a.rows) == 4

    note = DB.ad_benchmark_note(a)
    @test occursin("Partial measurements", note)
    @test occursin("ReverseDiff and Enzyme forward", note)
    # The gap is about what got published, not about backend support, and the
    # note has to say so or it reads as a coverage claim. It also must not
    # blame a failed job: a backend the CI matrix names but the registry does
    # not declare publishes nothing either, with nothing having gone wrong.
    @test occursin("No results were published", note)
    @test occursin("registry does not declare", note)
    @test occursin("gradient tests", note)
    @test !occursin("ForwardDiff and", note)
end

@testitem "AD artefacts: no directory, and an empty one" setup = [
    ADArtifactFixtures,
] begin
    # A docs preview raised before the benchmark jobs finished. Not an error:
    # the page renders and says the numbers are not there.
    for dir in (joinpath(mktempdir(), "never-created"), mktempdir())
        a = DB.load_ad_benchmarks(dir, EXPECTED)
        @test isempty(a.rows)
        @test isempty(a.backends)
        @test a.missing_backends == EXPECTED
        note = DB.ad_benchmark_note(a)
        @test occursin("No measurements for this build", note)
        # One statement of the problem, not that plus a partial-set note.
        @test !occursin("Partial measurements", note)
    end
end

@testitem "AD artefacts: unreadable files are skipped, not fatal" setup = [
    ADArtifactFixtures,
] begin
    dir = mktempdir()
    write_artifact(dir, "ForwardDiff", "forwarddiff", [("AR", 10.0, 4.0)])
    write(joinpath(dir, "truncated.json"), "{\"backend\": \"Reverse")
    write(joinpath(dir, "wrong-shape.json"), "[1, 2, 3]")
    write(joinpath(dir, "no-backend.json"), """{"scenarios": []}""")
    # Not JSON at all, and not picked up: only `.json` is read.
    write(joinpath(dir, "notes.txt"), "ignore me")

    a = DB.load_ad_benchmarks(dir, EXPECTED)

    @test a.backends == ["ForwardDiff"]
    @test length(a.rows) == 1
    @test sort(a.unreadable) ==
        ["no-backend.json", "truncated.json", "wrong-shape.json"]

    note = DB.ad_benchmark_note(a)
    @test occursin("truncated.json", note)
    @test occursin("not readable as a benchmark artefact", note)
    # Still says which backends are missing as well.
    @test occursin("Partial measurements", note)
end

@testitem "AD artefacts: unusable scenario entries are dropped" setup = [
    ADArtifactFixtures,
] begin
    # A backend that could not produce a number for a scenario must be absent
    # from that scenario rather than plotted at Inf on a log scale.
    dir = mktempdir()
    write(
        joinpath(dir, "forwarddiff.json"),
        """
        {"backend": "ForwardDiff", "tag": "forwarddiff", "scenarios": [
          {"name": "AR", "time_us": 10.0, "bytes_kb": 4.0},
          {"name": "NoBytes", "time_us": 10.0},
          {"name": "", "time_us": 1.0, "bytes_kb": 1.0},
          {"name": "NotANumber", "time_us": "fast", "bytes_kb": 1.0},
          "not an object"
        ]}
        """
    )

    a = DB.load_ad_benchmarks(dir, EXPECTED)

    @test a.backends == ["ForwardDiff"]
    @test [r.scenario for r in a.rows] == ["AR"]
    # A file that parsed is not "unreadable" just because rows were dropped.
    @test isempty(a.unreadable)
end

@testitem "AD artefacts: a backend outside the registry is kept" setup = [
    ADArtifactFixtures,
] begin
    # A backend renamed in the registry since the artefact was produced. Its
    # numbers still render, after the ones that were asked for, rather than
    # vanishing with no explanation.
    dir = mktempdir()
    write_artifact(dir, "ForwardDiff", "forwarddiff", [("AR", 10.0, 4.0)])
    write_artifact(dir, "Mooncake", "mooncake", [("AR", 3.0, 1.0)])

    a = DB.load_ad_benchmarks(dir, EXPECTED)

    @test a.backends == ["ForwardDiff", "Mooncake"]
    @test [r.backend for r in a.rows] == ["ForwardDiff", "Mooncake"]
    @test "Mooncake" ∉ a.missing_backends
end

@testitem "AD artefacts: one backend split across files" setup = [
    ADArtifactFixtures,
] begin
    # A package may split its scenarios across test items that each write an
    # artefact, so one backend can legitimately arrive in several files. Their
    # scenarios join up rather than one file winning.
    dir = mktempdir()
    write_artifact(dir, "ForwardDiff", "forwarddiff", [("AR", 10.0, 4.0)])
    write_artifact(
        dir, "ForwardDiff", "forwarddiff-1", [("Renewal", 30.0, 12.0)]
    )

    a = DB.load_ad_benchmarks(dir, EXPECTED)

    @test a.backends == ["ForwardDiff"]
    @test sort([r.scenario for r in a.rows]) == ["AR", "Renewal"]
end

@testitem "AD artefacts: a repeated scenario is not counted twice" setup = [
    ADArtifactFixtures,
] begin
    # An older artefact left in the directory must not double-weight a scenario
    # in the geometric means, and the newer measurement is the one that counts.
    # Resolved by modification time, not filename: the `x-1.json` sibling the
    # harness writes sorts *before* `x.json`, `-` preceding `.`.
    dir = mktempdir()
    stale = write_artifact(
        dir, "ForwardDiff", "forwarddiff-1", [("AR", 10.0, 4.0)]
    )
    fresh = write_artifact(
        dir, "ForwardDiff", "forwarddiff", [("AR", 99.0, 42.0)]
    )
    # Stamped explicitly so the ordering does not ride on filesystem timestamp
    # granularity between two writes in the same millisecond.
    set_mtime(stale, time() - 60)
    set_mtime(fresh, time())

    a = DB.load_ad_benchmarks(dir, EXPECTED)

    @test length(a.rows) == 1
    @test only(a.rows).time_us == 99.0
    @test only(a.rows).bytes_kb == 42.0
end

@testitem "AD artefacts: directory resolution and opt-in" setup = [
    ADArtifactFixtures,
] begin
    docs = mktempdir()
    saved = get(ENV, "AD_BENCHMARK_ARTIFACTS_DIR", nothing)
    delete!(ENV, "AD_BENCHMARK_ARTIFACTS_DIR")
    try
        # Not opted in: neither config nor environment, so the page measures
        # live exactly as it did before this existed.
        @test DB.ad_benchmark_artifact_dir(docs, nothing) === nothing
        @test DB.ad_benchmark_artifact_dir(docs, "") === nothing

        # Config alone opts in; a relative path is `docs/`-relative.
        @test DB.ad_benchmark_artifact_dir(docs, "ad-benchmarks") ==
            abspath(joinpath(docs, "ad-benchmarks"))
        elsewhere = joinpath(mktempdir(), "bench")
        @test DB.ad_benchmark_artifact_dir(docs, elsewhere) == elsewhere

        # The environment wins, so CI can name a download location without
        # editing the package's write-once config, and opts in on its own.
        ENV["AD_BENCHMARK_ARTIFACTS_DIR"] = "from-ci"
        @test DB.ad_benchmark_artifact_dir(docs, "ad-benchmarks") ==
            abspath(joinpath(docs, "from-ci"))
        @test DB.ad_benchmark_artifact_dir(docs, nothing) ==
            abspath(joinpath(docs, "from-ci"))
        # An empty environment value is not an opt-in.
        ENV["AD_BENCHMARK_ARTIFACTS_DIR"] = ""
        @test DB.ad_benchmark_artifact_dir(docs, nothing) === nothing
    finally
        if saved === nothing
            delete!(ENV, "AD_BENCHMARK_ARTIFACTS_DIR")
        else
            ENV["AD_BENCHMARK_ARTIFACTS_DIR"] = saved
        end
    end
end

@testitem "AD artefacts: the page's subprocess is told where to look" setup = [
    ADArtifactFixtures,
] begin
    # The benchmark page runs in a subprocess that inherits this environment,
    # so the resolved (absolute) directory is exported rather than passed.
    docs = mktempdir()
    saved = get(ENV, "AD_BENCHMARK_ARTIFACTS_DIR", nothing)
    delete!(ENV, "AD_BENCHMARK_ARTIFACTS_DIR")
    try
        # Not opted in: the variable stays unset, so a page built by an older
        # kit or by a package that never configured this is untouched.
        @test DB._export_ad_benchmark_dir(docs, nothing) === nothing
        @test !haskey(ENV, "AD_BENCHMARK_ARTIFACTS_DIR")

        dir = DB._export_ad_benchmark_dir(docs, "ad-benchmarks")
        @test dir == abspath(joinpath(docs, "ad-benchmarks"))
        @test ENV["AD_BENCHMARK_ARTIFACTS_DIR"] == dir
        @test isabspath(ENV["AD_BENCHMARK_ARTIFACTS_DIR"])
    finally
        if saved === nothing
            delete!(ENV, "AD_BENCHMARK_ARTIFACTS_DIR")
        else
            ENV["AD_BENCHMARK_ARTIFACTS_DIR"] = saved
        end
    end
end
