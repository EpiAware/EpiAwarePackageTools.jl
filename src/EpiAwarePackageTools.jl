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
    works on any registry satisfying the [`ADRegistry`](@ref) contract, and
    [`ad_backend_support_table`](@ref) renders that registry's broken/skip
    declarations as the support table the scaffolded AD-backends docs page
    shows.

A [`scaffold`](@ref) helper writes the shipped standard configuration and test
infrastructure into a package — root dev config, CI caller workflows +
dependabot, and the QA/AD/benchmark test-infra drivers that call these
helpers — so a package adopts the whole kit at once. [`scaffold_generate`](@ref) does the
same for a brand-new package, laying down its `Project.toml` and source module
first. [`scaffold_update`](@ref) re-applies the managed standard files (the scheduled
template-sync entry point), leaving package-owned tests, AD scenarios, and QA
config values untouched.

[`setup_checklist`](@ref) prints the handful of manual, dashboard-only setup
steps `scaffold`/`scaffold_generate` cannot do for us (Codecov, GitHub Pages, branch
protection, the first registry registration), plus a ready-to-paste tracking
issue body.

The AD harness + AD CI are opt-in: `scaffold`/`scaffold_generate`/`scaffold_update` take an
`ad::Bool` keyword (default `true`). A numerical package keeps `ad = true`; a
tooling/non-numerical package passes `ad = false` to scaffold none of the AD
infrastructure. The kit manages its own repo with `ad = false`.

A [`Benchmarks`](@ref EpiAwarePackageTools.Benchmarks) submodule supplies the
generic benchmark-reporting harness: turning AirspeedVelocity or BenchmarkTools
result data into a legible Markdown PR comment. A package keeps its own
benchmark definitions and calls into this module to run and report them.

A [`DocsBuild`](@ref EpiAwarePackageTools.DocsBuild) submodule supplies the
generic documentation-build machinery: [`build_docs`](@ref) runs the standard
Documenter + DocumenterVitepress build (README→index, release notes, benchmark
page, API split, Literate tutorials) for a package module, so the managed
`docs/make.jl` is a thin caller.

Package-specific fixtures (the actual distributions, models, or interface
checklists a package wants to exercise) stay in that package. This module only
supplies the reusable scaffolding.
"""
module EpiAwarePackageTools

# All genuine module-scope `using`/`import` statements live here, in one
# place, rather than scattered across the `include`d files below (they all
# run in this module's namespace, so this is behaviour-preserving). Heavy
# deps that are only needed at call time (e.g. Aqua, JET, Documenter) are
# NOT here: they are resolved lazily via `_require_pkg`/`Base.require`
# inside the functions that use them, so they stay out of the kit's hard
# dependency set (see `_require_pkg` below).
using Test: @testset, @test, @test_skip, @test_broken, detect_ambiguities
using Markdown: Markdown
using DocStringExtensions: @template, DOCSTRING, EXPORTS, IMPORTS, TYPEDEF,
                           TYPEDFIELDS, TYPEDSIGNATURES
import Dates
import UUIDs

# Resolve a heavy dependency at call time via `Base.require`, rather than
# making it a hard dependency of the kit: a package only needs it in the
# environment that actually runs the check (e.g. JET only in the test env,
# Documenter only in the docs env). Every lazy-load site across the kit
# (quality/QA wrappers, the AD harness, the Benchmarks and DocsBuild
# submodules) shares this one helper instead of repeating the
# `Base.require(Base.PkgId(Base.UUID(...), ...))` boilerplate each time (#58).
#
# The loaded module's methods live in a world age newer than the caller, so
# every call into it must go through `Base.invokelatest` — that rationale is
# documented once here rather than restated at each of the 15 call sites.
function _require_pkg(uuid::AbstractString, name::AbstractString)
    Base.require(Base.PkgId(Base.UUID(uuid), name))
end

# Register the standard EpiAware docstring conventions before any docstrings are
# defined, so the kit applies its own `@template` standard to itself, using the
# same docstrings template it ships to adopting packages (see
# src/docstrings.jl).
include("docstrings.jl")

include("quality.jl")
include("qa.jl")
include("scaffold.jl")
include("setup_checklist.jl")
include("ad_harness.jl")
include("benchmarks.jl")
include("docs_build.jl")

export test_aqua, test_jet, test_explicit_imports, test_import_centralisation
export dynamicppl_model_filter
export test_docstring_format, test_ext_ambiguities, test_doctest,
       test_formatting, test_linting
export test_readme_sections, readme_qa_config, STANDARD_README_SECTIONS
export on_surface_ambiguities, raw_ambiguity_count
export scaffold, scaffold_update, scaffold_generate, scaffold_inputs, setup_checklist
export ADRegistry, check_broken, test_working_backend, test_partial_backend
export ad_backend_support_table
export build_docs, default_docs_pages

using .DocsBuild: build_docs, default_docs_pages

end # module EpiAwarePackageTools
