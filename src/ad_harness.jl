# Generic AD-gradient harness scaffolding.
#
# This is the package-agnostic core of an AD test suite: given a set of
# gradient scenarios (each carrying a ForwardDiff reference) and a list of
# backends, it drives `DifferentiationInterfaceTest.test_differentiation` over
# the working scenarios for a backend and marks the rest broken. The scenarios
# themselves (the package's distributions / models) stay in the package; this
# module only owns the run logic that every package would otherwise copy.
#
# The harness talks to a package's fixtures through the `ADRegistry` contract
# below, so it has no dependency on any particular package's types.

using Test: @testset, @test, @test_broken

"""
    ADRegistry

The contract a package's AD-fixture module must satisfy to drive the harness.

A registry `reg` is any object (commonly a package's `ADFixtures` module)
responding to:

  - `scenarios(reg; with_reference = true, kwargs...)` returning a vector of
    scenarios. Each scenario `s` exposes `s.name::String`, `s.f`, `s.x`,
    `s.contexts` (a tuple, possibly empty), and `s.res1` (the ForwardDiff
    reference gradient, or `nothing`). This matches a
    `DifferentiationInterfaceTest` scenario. Extra keyword arguments (e.g. a
    package's own scenario-group selector) are forwarded from the runners'
    `scenario_kwargs`.
  - `backends(reg)` returning a vector of named-tuples `(; name, backend)`,
    where `backend` is an `ADTypes` backend.

The remaining bookkeeping accessors are optional: a registry that owns no broken
or skipped scenarios may omit them, and the harness treats the missing accessor
as "none". Define them only when a package actually has such scenarios.

  - `broken_scenario_names(reg)` (optional) returning a collection of scenario
    names broken on every backend. Default: empty.
  - `backend_broken_scenarios(reg)` (optional) returning a
    `Dict{String, Set{String}}` of per-backend broken scenario names. Default:
    empty.
  - `backend_skip_scenarios(reg)` (optional) returning a
    `Dict{String, Set{String}}` of per-backend scenario names too unstable to
    run at all. Default: empty.

A package may implement these as plain functions taking the registry, or (the
common case) expose them as zero-argument functions on a module and pass the
module as `reg`; the harness calls `reg.f(...)` either way via property access.

This is a documentation-only marker; the harness duck-types on the methods
above.
"""
abstract type ADRegistry end

# Internal: resolve a registry method, supporting both a module exposing the
# zero/one-arg functions as properties and a struct with methods of the same
# name. We call through `getproperty` so a module registry works directly.
function _scenarios(reg; with_reference = true, scenario_kwargs = (;))
    return reg.scenarios(; with_reference = with_reference, scenario_kwargs...)
end
_backends(reg) = reg.backends()

# True when `reg` exposes a callable `name` accessor. A module registry exposes
# its functions as properties; a struct registry would carry them as fields.
function _has_accessor(reg, name::Symbol)
    reg isa Module ? isdefined(reg, name) : hasproperty(reg, name)
end

# The broken/skip bookkeeping accessors are optional (see `ADRegistry`): a
# registry that defines none of them is treated as having no broken or skipped
# scenarios, so a package without such scenarios need not define empty stubs.
function _global_broken(reg)
    _has_accessor(reg, :broken_scenario_names) ?
    reg.broken_scenario_names() : String[]
end
function _per_backend_broken(reg)
    _has_accessor(reg, :backend_broken_scenarios) ?
    reg.backend_broken_scenarios() : Dict{String, Set{String}}()
end
function _per_backend_skip(reg)
    _has_accessor(reg, :backend_skip_scenarios) ?
    reg.backend_skip_scenarios() : Dict{String, Set{String}}()
end

_entry(reg, name) = only(filter(e -> e.name == name, _backends(reg)))

"""
    check_broken(scenarios_list, backend; rtol = 5e-2, atol = 1e-6)

Run each scenario through plain `DifferentiationInterface.gradient` and record
whether it matches its reference.

A scenario passes (`@test true`) when the gradient is a finite vector matching
`scen.res1` within tolerance, and is marked `@test_broken` otherwise. This lets
a partial backend record the coverage it does have without an all-or-nothing
result. `DifferentiationInterface` must be loaded by the caller.
"""
function check_broken(scenarios_list, backend; rtol = 5e-2, atol = 1e-6)
    DI = Base.require(Base.PkgId(
        Base.UUID("a0c0ee7d-e4b9-4e03-894e-1c5f64a51d63"),
        "DifferentiationInterface"))
    for scen in scenarios_list
        ok = try
            g = Base.invokelatest(
                DI.gradient, scen.f, backend, scen.x, scen.contexts...)
            ref = scen.res1
            g isa AbstractVector && all(isfinite, g) && ref !== nothing &&
                isapprox(g, ref; rtol = rtol, atol = atol)
        catch
            false
        end
        ok ? (@test ok) : (@test_broken ok)
    end
    return nothing
end

"""
    test_working_backend(reg, name; rtol = 5e-2, atol = 1e-6,
        scenario_intact = false)

Hard-test a working backend on the scenarios it supports.

Looks up the backend named `name` in `reg`, runs
`DifferentiationInterfaceTest.test_differentiation` (correctness only) over the
scenarios not listed as globally or per-backend broken and not in the backend's
skip set, then runs the broken scenarios through [`check_broken`] so they record
as `@test_broken`.

`scenario_intact` is forwarded to `test_differentiation`; it defaults to `false`
because a scenario carrying a `Missing`-bearing context trips DIT's default
post-run equality check (comparing a `missing`-containing vector with `==`
errors in a boolean context), while the gradients themselves stay correct.

`scenario_kwargs` is a `NamedTuple` of extra keyword arguments forwarded to the
registry's `scenarios` call, e.g. a package's own scenario-group selector
(`scenario_kwargs = (; category = :latent)`).

`DifferentiationInterface` and `DifferentiationInterfaceTest` must be loaded.
"""
function test_working_backend(reg, name::AbstractString;
        rtol = 5e-2, atol = 1e-6, scenario_intact::Bool = false,
        scenario_kwargs = (;))
    DIT = Base.require(Base.PkgId(
        Base.UUID("a82114a7-5aa3-49a8-9643-716bb13727a3"),
        "DifferentiationInterfaceTest"))
    backend = _entry(reg, name).backend
    all_scenarios = _scenarios(
        reg; with_reference = true, scenario_kwargs = scenario_kwargs)
    global_broken = Set(_global_broken(reg))
    per_backend = get(_per_backend_broken(reg), name, Set{String}())
    skip = get(_per_backend_skip(reg), name, Set{String}())
    runnable = filter(s -> !(s.name in skip), all_scenarios)
    ok = filter(
        s -> !(s.name in global_broken) && !(s.name in per_backend), runnable)
    broken_scens = filter(
        s -> s.name in global_broken || s.name in per_backend, runnable)
    Base.invokelatest(
        DIT.test_differentiation,
        [backend], ok;
        correctness = true,
        type_stability = :none,
        logging = false,
        scenario_intact = scenario_intact,
        rtol = rtol,
        atol = atol
    )
    check_broken(broken_scens, backend; rtol = rtol, atol = atol)
    return nothing
end

"""
    test_partial_backend(reg, name; rtol = 5e-2, atol = 1e-6)

Test a partially-supported backend by running every scenario through
[`check_broken`].

Each scenario the backend supports passes; the rest are marked `@test_broken`.
Use this for a backend that cannot run the full `test_differentiation` sweep
without crashing.
"""
function test_partial_backend(reg, name::AbstractString;
        rtol = 5e-2, atol = 1e-6, scenario_kwargs = (;))
    backend = _entry(reg, name).backend
    scens = _scenarios(
        reg; with_reference = true, scenario_kwargs = scenario_kwargs)
    check_broken(scens, backend; rtol = rtol, atol = atol)
    return nothing
end
