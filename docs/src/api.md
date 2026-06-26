# [API](@id API)

## Package-quality helpers

```@docs
test_aqua
test_explicit_imports
test_jet
test_docstring_format
test_ext_ambiguities
on_surface_ambiguities
raw_ambiguity_count
test_doctest
test_formatting
test_linting
```

## Scaffolding

```@docs
scaffold
update
scaffold_inputs
```

## AD-gradient harness

```@docs
ADRegistry
check_broken
test_working_backend
test_partial_backend
```

## Benchmarks

The `EpiAwarePackageTools.Benchmarks` submodule turns benchmark result data into a
Markdown PR comment.

```@docs
EpiAwarePackageTools.Benchmarks.flatten_asv
EpiAwarePackageTools.Benchmarks.asv_comment
EpiAwarePackageTools.Benchmarks.compare_comment
EpiAwarePackageTools.Benchmarks.run_suite
EpiAwarePackageTools.Benchmarks.fmt_time
EpiAwarePackageTools.Benchmarks.fmt_ratio
```
