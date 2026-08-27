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
# Which files are searched is scoped by the managed `JuliaTestItems.toml` at
# the repo root. That matters more here than for most packages: the kit keeps
# dozens of dev worktrees under `worktrees/`, and `templates/` holds `.jl`
# files carrying `{{PLACEHOLDER}}` tokens that are not valid Julia until
# substituted.
#
# Filters:
#   skip_quality  — skip the QA testset (fast local iteration)
#   quality_only  — run only the QA testset

using TestItemRunner

if "skip_quality" in ARGS
    @run_package_tests filter = ti -> !(:quality in ti.tags)
elseif "quality_only" in ARGS
    @run_package_tests filter = ti -> :quality in ti.tags
else
    @run_package_tests
end
