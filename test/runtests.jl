# PACKAGE-OWNED — the kit's own test entry.
#
# Discovers `@testitem`s with TestItemRunner: the managed QA testset under
# `test/package/` (which runs the standard QA checks over EpiAwarePackageTools
# itself, dogfooding the kit) plus the kit's own logic unit tests
# (`scaffold.jl`, `qa.jl`, `ad_harness.jl`, `benchmarks.jl`), which exercise the
# helpers the kit ships rather than re-running them on the package.
#
# The kit ships an AD harness but is itself a tooling package with no
# differentiable code, so it scaffolds/manages itself with `ad = false`: there
# is no `test/ad/` real-backend matrix here. The AD harness logic is unit-tested
# in `ad_harness.jl` with the light backends (ForwardDiff, ReverseDiff) only;
# heavy backends (Enzyme, Mooncake) are kept out of the kit's required CI.
#
# Filters:
#   skip_quality  — skip the QA testset (fast local iteration)
#   quality_only  — run only the QA testset

using EpiAwarePackageTools: run_package_tests

# `run_package_tests` roots discovery at this package's own `test/` tree so the
# kit's ~40 dev worktrees under `worktrees/` are never scanned and cannot inject
# test items or shadow a same-named `@testsnippet` (kit #191). Drop-in for
# TestItemRunner's `@run_package_tests`.

if "skip_quality" in ARGS
    run_package_tests(@__DIR__; filter = ti -> !(:quality in ti.tags))
elseif "quality_only" in ARGS
    run_package_tests(@__DIR__; filter = ti -> :quality in ti.tags)
else
    run_package_tests(@__DIR__)
end
