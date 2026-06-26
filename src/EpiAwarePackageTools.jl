"""
    EpiAwarePackageTools

Shared, package-agnostic test utilities for EpiAware Julia packages.

The helpers here are deliberately generic: they take a target module or a
backend/scenario registry and run a standard check over it, so each EpiAware
package can reuse one implementation rather than copying the same boilerplate.

Two groups are provided.

  - Package-quality wrappers ([`test_aqua`](@ref), [`test_jet`](@ref),
    [`test_explicit_imports`](@ref)) run Aqua, JET, and ExplicitImports over a
    target module. Aqua and ExplicitImports run in-process; JET runs in an
    isolated environment to avoid version clashes. Further QA helpers cover
    docstring conventions ([`test_docstring_format`](@ref)), per-extension
    method ambiguities ([`test_ext_ambiguities`](@ref)), doctests
    ([`test_doctest`](@ref)), and formatting/linting ([`test_formatting`](@ref),
    [`test_linting`](@ref)).
  - An AD-gradient harness ([`check_broken`](@ref),
    [`test_working_backend`](@ref), [`test_partial_backend`](@ref)) checks a
    package's reverse/forward AD backends against a ForwardDiff reference. It
    works on any registry satisfying the [`ADRegistry`](@ref) contract.

A [`scaffold`](@ref) helper writes the shipped standard configuration AND test
infrastructure into a package — root dev config, CI caller workflows +
dependabot, and the QA/AD/benchmark test-infra drivers that call these
helpers — so a package adopts the whole kit at once. [`generate`](@ref) does the
same for a brand-new package, laying down its `Project.toml` and source module
first. [`update`](@ref) re-applies the managed standard files (the scheduled
template-sync entry point), leaving package-owned tests, AD scenarios, and QA
config values untouched.

The AD harness + AD CI are OPT-IN: `scaffold`/`generate`/`update` take an
`ad::Bool` keyword (default `true`). A numerical package keeps `ad = true`; a
tooling/non-numerical package passes `ad = false` to scaffold none of the AD
infrastructure. The kit manages its OWN repo with `ad = false`.

A [`Benchmarks`](@ref EpiAwarePackageTools.Benchmarks) submodule supplies the
generic benchmark-reporting harness: turning AirspeedVelocity or BenchmarkTools
result data into a legible Markdown PR comment. A package keeps its own
benchmark definitions and calls into this module to run and report them.

Package-specific fixtures (the actual distributions, models, or interface
checklists a package wants to exercise) stay in that package. This module only
supplies the reusable scaffolding.
"""
module EpiAwarePackageTools

include("quality.jl")
include("qa.jl")
include("scaffold.jl")
include("ad_harness.jl")
include("benchmarks.jl")

export test_aqua, test_jet, test_explicit_imports
export test_docstring_format, test_ext_ambiguities, test_doctest,
       test_formatting, test_linting
export test_readme_sections, STANDARD_README_SECTIONS
export on_surface_ambiguities, raw_ambiguity_count
export scaffold, update, generate, scaffold_inputs
export ADRegistry, check_broken, test_working_backend, test_partial_backend

end # module EpiAwarePackageTools
