# Drive the AD harness over a tiny synthetic registry. The scenarios are plain
# differentiable functions with a ForwardDiff reference, so the test exercises
# the harness logic (working/partial backends, broken bookkeeping) without
# pulling in any package-specific distributions.

@testitem "AD harness" begin
    using Test
    using EpiAwarePackageTools
    using ADTypes: AutoForwardDiff, AutoReverseDiff
    using DifferentiationInterface: DifferentiationInterface, Constant
    import DifferentiationInterfaceTest as DIT
    import ForwardDiff, ReverseDiff

    # A registry exposing the `ADRegistry` contract as a module-like object.
    # `scenarios`, `backends`, etc. are closures captured in a NamedTuple, which
    # the harness reaches via property access just like a module.
    function build_registry()
        # Two simple gradient scenarios; the second uses a data context.
        f1(θ) = sum(abs2, θ)
        f2(θ, c) = sum(abs2, θ .- c)
        ref(f, θ, ctx) = DifferentiationInterface.gradient(
            f, AutoForwardDiff(), θ, ctx...
        )

        function make_scenarios(; with_reference = true)
            θ1 = [1.0, 2.0, 3.0]
            θ2 = [0.5, -0.5]
            c = Constant([0.1, 0.2])
            s1 = DIT.Scenario{:gradient, :out}(
                f1, θ1; name = "sum_squares",
                res1 = with_reference ? ref(f1, θ1, ()) : nothing
            )
            s2 = DIT.Scenario{:gradient, :out}(
                f2, θ2, c; name = "centred",
                res1 = with_reference ? ref(f2, θ2, (c,)) : nothing
            )
            return [s1, s2]
        end

        return (
            scenarios = make_scenarios,
            backends = () -> [
                (name = "ForwardDiff", backend = AutoForwardDiff()),
                (
                    name = "ReverseDiff",
                    backend = AutoReverseDiff(compile = false),
                ),
            ],
            broken_scenario_names = () -> String[],
            backend_broken_scenarios = () -> Dict{String, Set{String}}(),
            backend_skip_scenarios = () -> Dict{String, Set{String}}(),
        )
    end

    reg = build_registry()

    @testset "ADRegistry is an abstract marker" begin
        @test ADRegistry isa Type && isabstracttype(ADRegistry)
    end

    @testset "check_broken records coverage" begin
        scens = reg.scenarios(with_reference = true)
        # Both scenarios are differentiable by ForwardDiff and match the
        # reference, so each records as a passing test.
        check_broken(scens, AutoForwardDiff())
    end

    @testset "test_working_backend over a clean backend" begin
        test_working_backend(reg, "ForwardDiff")
        test_working_backend(reg, "ReverseDiff")
    end

    @testset "test_partial_backend marks supported scenarios" begin
        test_partial_backend(reg, "ReverseDiff")
    end

    @testset "broken bookkeeping marks a scenario broken" begin
        # Mark one scenario globally broken: it should now be routed through
        # check_broken (where it still passes, so it is not a failure) and the
        # other through test_differentiation. Both paths must complete cleanly.
        broken_reg = merge(
            reg,
            (broken_scenario_names = () -> ["centred"],)
        )
        test_working_backend(broken_reg, "ForwardDiff")
    end

    @testset "ad_backend_support_table renders declarations" begin
        # No declarations: every backend supports the full set.
        tbl = ad_backend_support_table(reg)
        @test occursin(
            "| Backend | Scenarios | Declared broken | Skipped |",
            tbl
        )
        @test occursin("| ForwardDiff | 2/2 | none | none |", tbl)
        @test occursin("| ReverseDiff | 2/2 | none | none |", tbl)

        # Globally broken + per-backend broken + per-backend skip
        # declarations all land in the right row, and the coverage count
        # excludes the union (a name both broken and skipped counts once).
        declared = merge(
            reg,
            (
                broken_scenario_names = () -> ["centred"],
                backend_broken_scenarios = () -> Dict(
                    "ReverseDiff" => Set(["sum_squares"])
                ),
                backend_skip_scenarios = () -> Dict(
                    "ReverseDiff" => Set(["centred"])
                ),
            )
        )
        tbl2 = ad_backend_support_table(declared)
        @test occursin("| ForwardDiff | 1/2 | centred | none |", tbl2)
        @test occursin(
            "| ReverseDiff | 0/2 | centred, sum_squares | centred |", tbl2
        )

        # A registry with none of the optional accessors renders all-none,
        # mirroring the harness's missing-accessor defaults.
        minimal = (scenarios = reg.scenarios, backends = reg.backends)
        tbl3 = ad_backend_support_table(minimal)
        @test occursin("| ForwardDiff | 2/2 | none | none |", tbl3)
    end

    @testset "run_selected" begin
        @testset "filters and classifies PASS/MISMATCH/ERROR" begin
            # A tiny registry covering all three outcomes: a scenario whose
            # gradient matches its reference (PASS), one whose declared
            # reference is deliberately wrong (MISMATCH), and one whose
            # function always throws (ERROR).
            θ = [1.0, 2.0, 3.0]
            f_ok(θ) = sum(abs2, θ)
            # Plain evaluation on a `Float64` vector succeeds (so scenario
            # construction, which probes `f(x)` eagerly, does not itself
            # throw), but `Float64.(θ)` cannot accept a `Dual`/`TrackedReal`,
            # so differentiating this always throws — an AD-unsafe function.
            f_err(θ) = sum(abs2, Float64.(θ))
            wrong_ref = zeros(length(θ))
            true_ref = DifferentiationInterface.gradient(
                f_ok, AutoForwardDiff(), θ
            )
            s_ok = DIT.Scenario{:gradient, :out}(
                f_ok, θ; name = "ok", res1 = true_ref
            )
            s_mismatch = DIT.Scenario{:gradient, :out}(
                f_ok, θ; name = "mismatch", res1 = wrong_ref
            )
            s_error = DIT.Scenario{:gradient, :out}(
                f_err, θ; name = "erroring", res1 = nothing
            )
            run_reg = (
                scenarios = (; with_reference = true) -> [
                    s_ok, s_mismatch, s_error,
                ],
                backends = () -> [
                    (name = "ForwardDiff", backend = AutoForwardDiff()),
                    (
                        name = "ReverseDiff",
                        backend = AutoReverseDiff(compile = false),
                    ),
                ],
            )

            # Scenario and backend filters both narrow the run.
            filtered = run_selected(
                run_reg; scenarios = ["ok"], backends = ["forward"],
                verbose = false
            )
            @test length(filtered) == 1
            @test only(filtered).scenario == "ok"
            @test only(filtered).status == :pass

            results = run_selected(run_reg; verbose = false)
            @test length(results) == 6
            byname(scen, back) = only(
                filter(
                    r -> r.scenario == scen && r.backend == back, results
                )
            )
            @test byname("ok", "ForwardDiff").status == :pass
            @test byname("ok", "ReverseDiff").status == :pass
            @test byname("mismatch", "ForwardDiff").status == :mismatch
            err = byname("erroring", "ForwardDiff")
            @test err.status == :error
            @test startswith(err.detail, "ERROR: ")
            # ReverseDiff's tracked type is equally unconvertible to Float64.
            @test byname("erroring", "ReverseDiff").status == :error
        end

        @testset "errors when a filter matches nothing" begin
            @test_throws ErrorException run_selected(
                reg; scenarios = ["nope"], verbose = false
            )
            @test_throws ErrorException run_selected(
                reg; backends = ["nope"], verbose = false
            )
        end

        @testset "honours per-backend skip without attempting the call" begin
            # The skip set must short-circuit before the gradient call, not
            # merely catch a failure from attempting it — skips exist for
            # combinations that can crash the process outright.
            skip_reg = merge(
                reg,
                (
                    backend_skip_scenarios = () -> Dict(
                        "ForwardDiff" => Set(["centred"])
                    ),
                )
            )
            results = run_selected(skip_reg; verbose = false)
            is_skip(r) = r.scenario == "centred" && r.backend == "ForwardDiff"
            skipped = only(filter(is_skip, results))
            @test skipped.status == :skipped
            others = filter(!is_skip, results)
            @test all(r -> r.status == :pass, others)
        end
    end

    @testset "optional bookkeeping accessors default to empty" begin
        # A registry that owns no broken/skipped scenarios may omit all three
        # bookkeeping accessors; the harness must treat them as empty rather
        # than erroring on the missing property. This mirrors a package whose
        # AD fixtures only define `scenarios` and `backends` (e.g. CD `main`).
        minimal_reg = (
            scenarios = reg.scenarios,
            backends = reg.backends,
        )
        @test EpiAwarePackageTools._global_broken(minimal_reg) == String[]
        @test EpiAwarePackageTools._per_backend_broken(minimal_reg) ==
            Dict{String, Set{String}}()
        @test EpiAwarePackageTools._per_backend_skip(minimal_reg) ==
            Dict{String, Set{String}}()
        test_working_backend(minimal_reg, "ForwardDiff")
        test_partial_backend(minimal_reg, "ReverseDiff")
    end
end

# The producer side of the AD benchmark artefact: `benchmark_backend`
# runs in its own CI leg, separate from and uninstrumented relative to the
# per-backend correctness job `test_working_backend` runs in, and writes the
# artefact the docs page reads. These tests pin the contract the page joins
# on, that broken/skipped scenarios are excluded the same way correctness
# excludes them, and that `test_working_backend` itself never benchmarks.
@testitem "AD benchmark artefact" begin
    using Test
    using EpiAwarePackageTools
    using ADTypes: AutoForwardDiff
    using DifferentiationInterface: DifferentiationInterface
    import DifferentiationInterfaceTest as DIT
    import ForwardDiff, Chairmarks
    const EPT = EpiAwarePackageTools

    f1(θ) = sum(abs2, θ)
    ref(f, θ) = DifferentiationInterface.gradient(f, AutoForwardDiff(), θ)

    # Two scenarios so a broken declaration can remove one and leave the other.
    function registry(; broken = String[])
        θ = [1.0, 2.0, 3.0]
        return (
            scenarios = (; with_reference = true) -> [
                DIT.Scenario{:gradient, :out}(
                    f1, θ; name = "sum_squares",
                    res1 = with_reference ? ref(f1, θ) : nothing
                ),
                DIT.Scenario{:gradient, :out}(
                    f1, θ; name = "second",
                    res1 = with_reference ? ref(f1, θ) : nothing
                ),
            ],
            backends = () -> [
                (name = "ForwardDiff", backend = AutoForwardDiff()),
            ],
            broken_scenario_names = () -> broken,
        )
    end

    @testset "test_working_backend never benchmarks" begin
        # Regression guard for the producer split: the correctness call must
        # write nothing, however tempting an env-var opt-in would be, because
        # it runs under `--code-coverage=user` in CI and a timing taken there
        # would measure the instrumentation, not the backend.
        dir = mktempdir()
        test_working_backend(registry(), "ForwardDiff")
        @test isempty(readdir(dir))
    end

    @testset "the artefact round-trips into the docs loader" begin
        dir = mktempdir()
        path = joinpath(dir, "ad-bench-forwarddiff.json")
        written = benchmark_backend(
            registry(), "ForwardDiff", path; tag = "forwarddiff"
        )
        @test written.path == path
        @test written.scenarios == 2
        @test isfile(path)

        # The strongest check available: the file this writes is read by the
        # very loader the docs page uses, and lands as usable rows. If the two
        # sides ever disagree about the contract, this fails.
        a = EPT.DocsBuild.load_ad_benchmarks(dir, ["ForwardDiff"])
        @test a.backends == ["ForwardDiff"]
        @test isempty(a.missing_backends)
        @test isempty(a.unreadable)
        @test sort([r.scenario for r in a.rows]) == ["second", "sum_squares"]
        @test all(r -> r.backend == "ForwardDiff", a.rows)
        # Real measurements: positive, finite, and not the same object twice.
        @test all(r -> r.time_us > 0 && isfinite(r.time_us), a.rows)
        @test all(r -> r.bytes_kb >= 0 && isfinite(r.bytes_kb), a.rows)
        # No note to render, since every declared backend published.
        @test EPT.DocsBuild.ad_benchmark_note(a) == ""

        # `backend` is the registry label, which is what the page joins on,
        # and `tag` is informational.
        txt = read(path, String)
        @test occursin("\"backend\": \"ForwardDiff\"", txt)
        @test occursin("\"tag\": \"forwarddiff\"", txt)
        # Only gradient rows: DIT also measures `value_and_gradient`, which
        # would otherwise double every scenario.
        @test length(a.rows) == 2
    end

    @testset "the tag defaults to the artefact's basename" begin
        dir = mktempdir()
        path = joinpath(dir, "enzyme_forward.json")
        benchmark_backend(registry(), "ForwardDiff", path)
        @test occursin("\"tag\": \"enzyme_forward\"", read(path, String))
    end

    @testset "declared-broken scenarios are absent from the artefact" begin
        # The artefact is built from the same filtered list correctness runs,
        # so an excluded pair is simply not there — which is the rule the
        # page's coverage column already assumes.
        dir = mktempdir()
        path = joinpath(dir, "forwarddiff.json")
        benchmark_backend(registry(broken = ["second"]), "ForwardDiff", path)
        a = EPT.DocsBuild.load_ad_benchmarks(dir, ["ForwardDiff"])
        @test [r.scenario for r in a.rows] == ["sum_squares"]
    end

    @testset "a second call does not overwrite the first" begin
        # A registry split across categories, say, benchmarked by two calls
        # sharing a path. Losing the first writer's rows here would show up as
        # a silently short published table, so the second takes a numbered
        # sibling and the loader joins them.
        dir = mktempdir()
        path = joinpath(dir, "forwarddiff.json")
        benchmark_backend(registry(broken = ["second"]), "ForwardDiff", path)
        benchmark_backend(
            registry(broken = ["sum_squares"]), "ForwardDiff", path
        )
        @test isfile(path)
        @test isfile(joinpath(dir, "forwarddiff-1.json"))

        a = EPT.DocsBuild.load_ad_benchmarks(dir, ["ForwardDiff"])
        @test sort([r.scenario for r in a.rows]) == ["second", "sum_squares"]
    end

    @testset "names are escaped, so the JSON stays parseable" begin
        # Backend and scenario names are free text from the registry.
        @test EPT._json_escape("plain") == "plain"
        @test EPT._json_escape("say \"hi\"") == "say \\\"hi\\\""
        @test EPT._json_escape("back\\slash") == "back\\\\slash"
        @test EPT._json_escape("line\nbreak") == "line\\nbreak"
        @test EPT._json_escape("tab\there") == "tab\\there"
        @test EPT._json_escape("bell\a") == "bell\\u0007"

        # And end to end: a scenario whose name carries a quote still produces
        # a file the loader can read, with the name intact.
        dir = mktempdir()
        path = joinpath(dir, "quoted.json")
        θ = [1.0, 2.0]
        quoted = (
            scenarios = (; with_reference = true) -> [
                DIT.Scenario{:gradient, :out}(
                    f1, θ; name = "quote\"and\\slash",
                    res1 = with_reference ? ref(f1, θ) : nothing
                ),
            ],
            backends = () -> [
                (name = "ForwardDiff", backend = AutoForwardDiff()),
            ],
        )
        benchmark_backend(quoted, "ForwardDiff", path)
        a = EPT.DocsBuild.load_ad_benchmarks(dir, ["ForwardDiff"])
        @test [r.scenario for r in a.rows] == ["quote\"and\\slash"]
    end
end
