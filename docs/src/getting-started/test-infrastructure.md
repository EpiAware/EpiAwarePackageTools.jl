# [Test infrastructure](@id test-infrastructure)

The kit scaffolds a complete test setup so every adopting package runs the same
checks the same way.
This page describes what it writes, how the pieces fit together, and how to run
and configure them.
See [Infrastructure and template sync](@ref infrastructure) for the
managed-versus-package-owned split that governs which of these files a sync
rewrites, and [Package standards](@ref standards) for the standards these checks
hold a package to (and the ones no check covers).

## The test tree

`scaffold` lays down a `test/` tree with a clear split between the standard
harness and your own tests.

- `test/runtests.jl` (package-owned) is the entry point.
  It discovers `@testitem`s with TestItemRunner and runs them.
- `test/package/quality.jl` (managed) holds the standard quality testset.
- `test/package/qa_config.jl` (package-owned) supplies the package-specific
  inputs the quality testset needs.
- `test/jet/` and `test/formatter/` (managed runners, package-owned config) are
  isolated environments for the JET and JuliaFormatter checks.
- `test/Project.toml` (package-owned) is the test environment, seeded with the
  dependencies the shared helpers need.

Your package's own unit tests live alongside these as further `@testitem`s
anywhere under `test/`.

## TestItemRunner and `@testitem`

Tests are written as `@testitem` blocks rather than a nested tree of `include`d
files.
Each item is an isolated unit that TestItemRunner discovers by walking the test
directory, so there is no central file listing every test to keep up to date.
Items carry tags, and the runner selects which to run by filtering on those
tags.

`test/runtests.jl` uses this to expose a few run modes through test arguments.

- No argument runs every item except the AD-tagged ones (see
  [AD tooling](@ref ad-tooling)).
- `skip_quality` skips the `:quality`-tagged items for fast local iteration.
- `quality_only` runs only the quality testset.
- `readme_only` runs only `:readme`-tagged items.

Discovery is restricted to the package's own test tree, so a nested worktree or
a sibling directory sharing a path prefix is never globbed in.

## The quality testset

`test/package/quality.jl` routes every generic quality check through the shared
`EpiAwarePackageTools` helpers, so a package gets the whole set without
reimplementing any of it.
Each check is a `:quality`-tagged `@testitem`.

- Aqua ([`test_aqua`](@ref)) for method ambiguities, unbound type parameters,
  stale dependencies, and other common package defects.
- ExplicitImports ([`test_explicit_imports`](@ref)) so every used name is
  explicitly imported rather than pulled in implicitly.
- Import centralisation ([`test_import_centralisation`](@ref)) so `using` and
  `import` statements sit in the module file rather than scattered across
  sources.
- Docstring format ([`test_docstring_format`](@ref)) for the standard docstring
  conventions.
- README sections ([`test_readme_sections`](@ref)) so the standard README
  structure stays intact.
- Doctests ([`test_doctest`](@ref)) so the examples in docstrings still run.
- Formatting ([`test_formatting`](@ref)) so the source matches the pinned
  formatter.
- Linting with JET ([`test_linting`](@ref)) for static analysis.
- Extension ambiguities ([`test_ext_ambiguities`](@ref)) for packages that ship
  extensions.

The check logic is managed and stays in `quality.jl`.
Everything a check needs that is specific to your package lives in the
package-owned `qa_config.jl` as a `QA_CONFIG` named tuple, so you tune the
checks without editing the managed file.
`QA_CONFIG` carries the module under test, the JET and formatter environment
paths, per-check Aqua relaxations, ExplicitImports ignore lists, docstring
cross-reference ignores, the README requirements, and the list of extensions to
ambiguity-check.

## Opt-in README wording checks

Three further README checks ship with the kit but are not part of the managed
quality testset.
They encode the overview-page design standard, which most adopting READMEs do
not meet yet, so switching them on for every caller at once would red the whole
ecosystem.
A package opts in by calling them from its own tests.

- Placeholders ([`test_readme_placeholders`](@ref)) fails when a README still
  carries the scaffold's unfilled placeholder text.
  The patterns come from the seeded skeleton itself, so a placeholder added to
  the scaffold is checked for without a change here.
- Prose ([`test_readme_prose`](@ref)) fails on the banned-word list
  ([`BANNED_README_WORDS`](@ref)) and on sentences over a configurable length.
  Only prose is read: code fences, tables, inline code, and link URLs are
  skipped, so a banned word in an identifier or a URL is not a failure.
- Why-section bullets ([`test_readme_bullets`](@ref)) fails on a bullet that
  opens with a bold label and a colon (a feature inventory rather than a reason
  to use the package), on a bullet count outside 3-6, and on a bullet running to
  more than one sentence.

```julia
@testitem "README wording" tags=[:readme] begin
    using EpiAwarePackageTools
    root = pkgdir(MyPackage)
    test_readme_placeholders(root)
    test_readme_prose(root)
    test_readme_bullets(root)
end
```

## Eager option validation

Any function that accepts a set of named options — keyword arguments, a
scenario or backend registry, a set of sweep axes — should validate them
eagerly and, on an unrecognised name, raise an error that names every
offending key and lists the valid set.
An option name that is silently ignored is a latent bug: a caller believes
they set a value when they did not, and the mistake only surfaces (if at
all) as a wrong result far from its cause.
The worst case is a sweep axis, where a mistyped name can send a whole run
down the wrong path and only become visible deep inside it.

The reference implementation is `scaffold`'s own licence check
(`EpiAwarePackageTools.SUPPORTED_LICENSES`, checked by the internal
`_validate_license`):

```julia
license in SUPPORTED_LICENSES || error(
    "unsupported license $(repr(license)); choose one of " *
    join(repr.(SUPPORTED_LICENSES), ", "))
```

Follow the same shape for every option-accepting entry point: name the
offending value with `repr`, list the valid set the same way, and, where a
plausible-looking option is deliberately excluded, explain why in a
parenthetical (e.g. `` `:legacy_mode` is intentionally excluded; use
`:mode` instead` ``).

[`test_option_validation`](@ref) enforces this by fuzzing a validating
function: it feeds `f` a run of random names outside the valid set and
asserts each call raises an error naming the offending value and listing
every valid entry, so a package inherits the check by pointing it at each
option-accepting entry point rather than auditing by hand.

```julia
test_option_validation(k -> configure(; Dict(k => true)...), VALID_KEYS)
```

Wire this into your own quality testset (or any `@testitem`) once per
option-accepting entry point; it is not part of the generic checks in
`test/package/quality.jl` above, since each entry point needs its own
wrapper.

## Isolated JET and formatter environments

JET and JuliaFormatter each pin their own version of JuliaSyntax, and those pins
clash with each other and with the main test dependencies.
The kit therefore runs each in its own environment under `test/jet/` and
`test/formatter/`, invoked as a subprocess by the quality testset.

The formatter check reports any file under `src`, `test`, `docs`, or `benchmark`
that is not formatted, without modifying it.
The style is Blue, set by the managed `.JuliaFormatter.toml` at the package root,
which every path that runs JuliaFormatter reads.
Blue and the JuliaFormatter default are the styles upstream keeps stable, so a
version bump does not rewrite files;
sciml and YAS instead make a package choose between pinning a version forever
and accepting output changes when their bugs are fixed.
The JET runner fails on any static-analysis report by default.
A package whose public surface is DynamicPPL `@model` functions can drop a
package-owned `test/jet/jet_config.jl` defining a `JET_REPORT_FILTER` predicate
to suppress the spurious reports the tilde macro produces;
`dynamicppl_model_filter` is the ready-made filter for that case.

## Running the tests

From a Julia session, `Pkg.test()` runs the full suite.
The scaffolded `Taskfile.yml` wraps the common modes.

- `task test` runs the full suite including quality and AD gradient tests.
- `task test-fast` skips the quality checks for development.
- `task test-quality` runs only the quality checks.
- `task test-jet` and `task test-formatting` run those checks in their isolated
  environments.

The formatter gate also runs in CI through the managed `pre-commit.yaml`
workflow, pinned to the same formatter version as the local pre-commit hook and
the isolated formatter environment so a local format and CI never disagree.
