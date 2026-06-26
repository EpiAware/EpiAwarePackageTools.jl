# EpiAwareTestUtils.jl

Shared, package-agnostic test utilities for
[EpiAware](https://github.com/EpiAware) Julia packages.

The package collects the test scaffolding that EpiAware packages would
otherwise each copy: standard quality checks over a target module, and an
AD-gradient harness that checks a package's AD backends against a ForwardDiff
reference. Package-specific fixtures stay in each package; this package supplies
only the reusable run logic.

The kit has four parts: package-quality helpers, an AD-gradient harness, a
benchmark-reporting submodule, and a [`scaffold`](@ref) that drops the standard
dev configuration into a package.

## Package-quality helpers

Run the standard checks over a target module:

```julia
using EpiAwareTestUtils

test_aqua(MyPackage)
test_explicit_imports(MyPackage; ignore = (:SomeInternal,))
test_jet(MyPackage; env = joinpath(@__DIR__, "jet"))
test_docstring_format(MyPackage; crossref_ignore = (:pdf, :cdf))
test_doctest(MyPackage)
test_formatting(MyPackage)            # or test_formatting([src, test, docs])
test_linting(MyPackage; env = joinpath(@__DIR__, "jet"))
```

For an extension's in-process method-ambiguity check (which Aqua cannot see, as
it runs with no extensions loaded), load the trigger package then call:

```julia
import SomeTrigger
test_ext_ambiguities(MyPackage, :MyPackageSomeTriggerExt;
    prefixes = ("MyPackage", "SomeTrigger"))
```

## Adopting the standard config

[`scaffold`](@ref) copies the standard `Taskfile.yml`,
`.pre-commit-config.yaml`, and `.JuliaFormatter.toml` into a package:

```julia
using EpiAwareTestUtils

# writes the templates; pass force = true to overwrite existing files
scaffold(pkgdir(MyPackage))
```

## AD-gradient harness

A package supplies an AD-fixture registry satisfying the [`ADRegistry`](@ref)
contract; the harness runs the working scenarios and marks the rest broken:

```julia
using EpiAwareTestUtils

test_working_backend(MyPackageADFixtures, "ReverseDiff")
test_partial_backend(MyPackageADFixtures, "Enzyme forward")
```

See the [API](@ref) page for the full reference.
