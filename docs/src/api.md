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

The `EpiAwareTestUtils.Benchmarks` submodule turns benchmark result data into a
Markdown PR comment.

```@docs
EpiAwareTestUtils.Benchmarks.flatten_asv
EpiAwareTestUtils.Benchmarks.asv_comment
EpiAwareTestUtils.Benchmarks.compare_comment
EpiAwareTestUtils.Benchmarks.run_suite
EpiAwareTestUtils.Benchmarks.fmt_time
EpiAwareTestUtils.Benchmarks.fmt_ratio
```
