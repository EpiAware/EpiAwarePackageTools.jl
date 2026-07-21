# [Extension design](@id extension-design)

This kit is the single shared implementation of package hygiene, docstring-shape enforcement, executable documentation, and the AD/benchmark test harnesses across EpiAware packages.
An adopting package satisfies a published contract rather than growing its own copy of the checking logic, so the logic does not drift between packages.
This page states the design rule that keeps a new variant addable without editing the kit's own source, and records where the kit does not yet meet that bar itself.

## The litmus test

A component of this kit is extension-by-dispatch when a new variant can be added by defining a type (or a module, or a value) and one or two methods on it, without editing the existing component's source.
The generic runner dispatches on the contract the caller's object satisfies, not on which package supplied it.
A component fails the test when adding a variant requires editing an `if`/`elseif` chain, a lookup table, or a case list inside the kit itself.

Apply this test when reviewing a change to a shared helper: does the change add a method satisfying an existing contract, or does it add a branch to existing code?
The former is exactly what the design expects; the latter is a deviation, and should either be justified and recorded below, or redesigned as a contract instead.

## Worked example: the AD-harness contract

[`ADRegistry`](@ref) is the clearest instance of the rule.
A package supplies its own AD fixtures by satisfying the published contract — defining `scenarios`, `backends`, and (only if it has them) the optional broken/skip bookkeeping accessors — without touching `src/ad_harness.jl`.

```julia
# A downstream package's fixture module. It satisfies the published
# contract purely by defining the methods the harness calls; no edit
# to the harness itself is required.
module MyFixtures
    # required: the two methods every registry must respond to
    scenarios(; with_reference = true, kwargs...) = [ ... ]
    backends() = [(; name = "reverse", backend = my_backend)]
    # optional accessors (broken_scenario_names, backend_broken_scenarios,
    # backend_skip_scenarios) are omitted here -> the harness treats each
    # missing one as "none"
end

# The generic runner dispatches on the contract, not on MyFixtures:
test_working_backend(MyFixtures, "reverse")
```

Adding a new fixture package needs a module and its methods only.
`test_working_backend`/`test_partial_backend`/`check_broken` are unchanged by that addition, and would be unchanged by the next one too.

The same shape holds elsewhere in the kit: [`test_jet`](@ref)'s `report_filter` is a predicate the caller supplies (see [`dynamicppl_model_filter`](@ref) for a worked instance) rather than a package name the harness recognises by branching on it, and the `QA_CONFIG` a package's `qa_config.jl` supplies is read generically by `quality.jl`, not matched against a per-package case.

## Known deviations

Two places in the kit do not meet the litmus test today.
Recording them here is more useful than an aspirational claim that every component already does; each is a candidate for a future redesign, not a hidden inconsistency.

- **Formatter style selection** (`_formatter_style` in `src/qa.jl`) maps a style name (`"sciml"`, `"blue"`, `"yas"`, `"default"`) to a JuliaFormatter style constructor through an `if`/`elseif` chain.
  Supporting a new JuliaFormatter style needs a new branch in that function, not a method a caller defines.
  This is a narrow deviation in practice — the valid styles are fixed by JuliaFormatter itself, not by anything an EpiAware package would define — but it is a lookup table inside the kit, not a dispatch contract.
- **Licence selection** (`SUPPORTED_LICENSES`/`_validate_license` in `src/scaffold.jl`, backed by a bundled `templates/LICENSE.<spdx>` file per entry) resolves a licence identifier to a bundled template file by string lookup.
  Adding a supported licence needs a new tuple entry and a new bundled template file in the kit's own `templates/` directory, not a method on a caller-supplied type.
  As with the formatter styles, the valid set is fixed by what the kit ships, not by what an adopting package wants to add, so the deviation is bounded — but by the letter of the litmus test above, it is still one.
