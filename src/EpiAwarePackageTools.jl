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
    [`test_linting`](@ref)). README structure and wording have their own set:
    [`test_readme_sections`](@ref) for the standard section structure, plus
    [`test_readme_placeholders`](@ref), [`test_readme_prose`](@ref), and
    [`test_readme_bullets`](@ref), which are opt-in (a package calls them from
    its own tests; the scaffolded quality testset does not).
  - An AD-gradient harness ([`check_broken`](@ref),
    [`test_working_backend`](@ref), [`test_partial_backend`](@ref)) checks a
    package's reverse/forward AD backends against a ForwardDiff reference. It
    works on any registry satisfying the [`ADRegistry`](@ref) contract, and
    [`ad_backend_support_table`](@ref) renders that registry's broken/skip
    declarations as a support table for a package that wants one in its own
    docs. [`run_selected`](@ref) runs a named subset of scenarios against a
    named subset of backends for fast diagnosis, and backs the scaffolded
    `test/ad/run_selected.jl` driver.

A [`scaffold`](@ref) helper writes the shipped standard configuration and test
infrastructure into a package — root dev config, CI caller workflows +
dependabot, and the QA/AD/benchmark test-infra drivers that call these
helpers — so a package adopts the whole kit at once. [`scaffold_generate`](@ref) does the
same for a brand-new package, laying down its `Project.toml` and source module
first. [`update`](@ref) re-applies the managed standard files (the scheduled
template-sync entry point), leaving package-owned tests, AD scenarios, and QA
config values untouched.

[`setup_checklist`](@ref) prints the handful of manual, dashboard-only setup
steps `scaffold`/`scaffold_generate` cannot do for us (Codecov, GitHub Pages,
the `DOCUMENTER_KEY` deploy key, branch protection, the first registry
registration), plus a ready-to-paste tracking issue body.

The AD harness + AD CI are opt-in: `scaffold`/`scaffold_generate`/`update` take an
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

# All genuine module-scope `using`/`import` statements live here (the
# `include`d files below run in this namespace, so this is
# behaviour-preserving). Heavy call-time-only deps (Aqua, JET, Documenter)
# are NOT here — see `_require_pkg` below.
using Test: @testset, @test, @test_skip, @test_broken, detect_ambiguities
using Markdown: Markdown
using DocStringExtensions: @template, DOCSTRING, EXPORTS, IMPORTS, TYPEDEF,
    TYPEDFIELDS, TYPEDSIGNATURES
import Dates
import Random
import UUIDs
# `Pkg.TOML` parses a target's Project.toml where a line scan will not do —
# the `[extensions]` table's values are strings or arrays of strings (see
# `_package_extensions`). Pkg is already a hard dependency of the kit.
import Pkg
# `Test` (the module) is needed for the test-runner machinery in
# `run_tests.jl` (`Test.push_testset`/`get_testset`/`record`/`finish`); the
# selective `using Test: ...` above only pulls in the assertion macros.
import Test

# Resolve a heavy dependency at call time via `Base.require`, rather than
# making it a hard dependency: a package only needs it in the environment
# that actually runs the check (e.g. JET only in the test env). Shared by
# every lazy-load site across the kit instead of repeating the
# `Base.require(Base.PkgId(...))` boilerplate (#58).
#
# The loaded module's methods live in a world age newer than the caller, so
# every call must go through `Base.invokelatest` — documented once here
# rather than restated at each call site.
function _require_pkg(uuid::AbstractString, name::AbstractString)
    return Base.require(Base.PkgId(Base.UUID(uuid), name))
end

# Register the standard EpiAware docstring conventions before any
# docstrings are defined, so the kit applies its own @template standard to
# itself (see src/docstrings.jl).
include("docstrings.jl")

include("quality.jl")
include("qa.jl")
include("scaffold.jl")
include("run_tests.jl")
include("setup_checklist.jl")
include("ad_harness.jl")
include("benchmarks.jl")
include("docs_build.jl")

export test_aqua, test_jet, test_explicit_imports, test_import_centralisation
export dynamicppl_model_filter
export test_docstring_format, test_ext_ambiguities, test_doctest,
    test_formatting, test_linting
export test_readme_sections, STANDARD_README_SECTIONS, MANAGED_README_SECTIONS
export STALE_README_HEADINGS, BANNED_README_WORDS
export test_readme_placeholders, test_readme_prose, test_readme_bullets
export on_surface_ambiguities, raw_ambiguity_count
export test_option_validation
export scaffold, scaffold_generate, scaffold_inputs, setup_checklist

# `update` is `public`, not `export`ed (#294): a scaffolded `docs/make.jl`
# does `using EpiAwarePackageTools` alongside `using <ThePackage>`, so a
# bare `export`ed `update` could collide with a package's own `update`
# export and leave the name unbound in `Main` (#173). `public` avoids this
# — a `public`-not-`export`ed name is never brought into scope by a bare
# `using`. `scaffold_update` remains a `public` alias
# (`const scaffold_update = update` in scaffold.jl) for existing callers.
#
# `public` is a Julia >= 1.11 parse feature, so the declaration is built from
# a string rather than written literally: a bare `public ...` line is a parse
# error on lts (1.10), which the package supports. On 1.10 the names are
# simply neither `export`ed nor `public`, which is the same visibility a
# `using` sees either way.
if VERSION >= v"1.11"
    Core.eval(@__MODULE__, Meta.parse("public update, scaffold_update"))
end
export ADRegistry, check_broken, test_working_backend, test_partial_backend
export ad_backend_support_table
export run_selected
export build_docs

using .DocsBuild: build_docs

end # module EpiAwarePackageTools
