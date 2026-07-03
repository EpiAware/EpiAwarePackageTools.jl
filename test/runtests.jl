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

using TestItemRunner

const TEST_ROOT = normpath(@__DIR__) * Base.Filesystem.path_separator
in_this_package(ti) = startswith(normpath(ti.filename), TEST_ROOT)

if "skip_quality" in ARGS
    @run_package_tests filter = ti -> in_this_package(ti) &&
                                      !(:quality in ti.tags)
elseif "quality_only" in ARGS
    @run_package_tests filter = ti -> in_this_package(ti) &&
                                      :quality in ti.tags
else
    @run_package_tests filter = in_this_package
end
