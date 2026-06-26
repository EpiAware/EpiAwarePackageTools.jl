# Drive the AD harness over a tiny synthetic registry. The scenarios are plain
# differentiable functions with a ForwardDiff reference, so the test exercises
# the harness logic (working/partial backends, broken bookkeeping) without
# pulling in any package-specific distributions.

@testset "AD harness" begin
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
            f, AutoForwardDiff(), θ, ctx...)

        function make_scenarios(; with_reference = true)
            θ1 = [1.0, 2.0, 3.0]
            θ2 = [0.5, -0.5]
            c = Constant([0.1, 0.2])
            s1 = DIT.Scenario{:gradient, :out}(
                f1, θ1; name = "sum_squares",
                res1 = with_reference ? ref(f1, θ1, ()) : nothing)
            s2 = DIT.Scenario{:gradient, :out}(
                f2, θ2, c; name = "centred",
                res1 = with_reference ? ref(f2, θ2, (c,)) : nothing)
            return [s1, s2]
        end

        return (
            scenarios = make_scenarios,
            backends = () -> [
                (name = "ForwardDiff", backend = AutoForwardDiff()),
                (name = "ReverseDiff",
                    backend = AutoReverseDiff(compile = false))
            ],
            broken_scenario_names = () -> String[],
            backend_broken_scenarios = () -> Dict{String, Set{String}}(),
            backend_skip_scenarios = () -> Dict{String, Set{String}}()
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
        # check_broken (where it still passes, so it is NOT a failure) and the
        # other through test_differentiation. Both paths must complete cleanly.
        broken_reg = merge(reg,
            (broken_scenario_names = () -> ["centred"],))
        test_working_backend(broken_reg, "ForwardDiff")
    end

    @testset "optional bookkeeping accessors default to empty" begin
        # A registry that owns no broken/skipped scenarios may omit all three
        # bookkeeping accessors; the harness must treat them as empty rather
        # than erroring on the missing property. This mirrors a package whose
        # AD fixtures only define `scenarios` and `backends` (e.g. CD `main`).
        minimal_reg = (
            scenarios = reg.scenarios,
            backends = reg.backends
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
