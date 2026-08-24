# PACKAGE-OWNED — scaffold writes this once and never overwrites it.
#
# Main test entry. Discovers `@testitem`s (the managed QA testset under
# `test/package/` plus the package's own unit tests) with TestItemRunner.
# `:ad`-tagged items live under `test/ad/` with their own environment and
# run in dedicated per-backend CI, so are excluded here (test/ad/runtests.jl).
#
# Which files are searched is scoped by the managed `JuliaTestItems.toml` at
# the package root, so a nested worktree checked out under the repo cannot
# inject test items or shadow a same-named `@testsnippet`.
#
# Filters:
#   skip_quality  — skip the QA testset (fast local iteration)
#   quality_only  — run only the QA testset
#   readme_only   — run only `:readme`-tagged items (README/tutorial tests)

using TestItemRunner

if "skip_quality" in ARGS
    @run_package_tests filter = ti -> !(:quality in ti.tags) && !(:ad in ti.tags)
elseif "quality_only" in ARGS
    @run_package_tests filter = ti -> :quality in ti.tags
elseif "readme_only" in ARGS
    @run_package_tests filter = ti -> :readme in ti.tags
else
    @run_package_tests filter = ti -> !(:ad in ti.tags)
end
