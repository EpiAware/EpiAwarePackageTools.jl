# PACKAGE-OWNED — scaffold writes this once and never overwrites it.
#
# Main test entry. Discovers `@testitem`s (the managed QA testset under
# `test/package/` plus the package's own unit tests) with TestItemRunner. The
# `:ad`-tagged items live under `test/ad/` with their own environment and run in
# dedicated per-backend CI, so they are excluded here (see test/ad/runtests.jl).
#
# Filters:
#   skip_quality  — skip the QA testset (fast local iteration)
#   quality_only  — run only the QA testset
#   readme_only   — run only `:readme`-tagged items (README/tutorial tests)

using TestItemRunner

# Restrict discovery to this package's test tree so a nested worktree's items
# are not globbed in. Trailing separator guards against sibling dirs sharing a
# string prefix.
#
# `@run_package_tests` walks the WHOLE package root (TestItemRunner.jl's
# `run_tests`, hardcoded via `dirname(@__FILE__)/..`), not just `test/`, and it
# registers every `@testsnippet` it finds by NAME with no path scoping at all —
# `in_this_package`/`filter` only decide which `@testitem`s RUN, never which
# `@testsnippet`s get registered (kit #191). A stale worktree ANYWHERE under
# the package root (not just under test/) that carries an old copy of a test
# file can silently shadow the current file's same-named snippet, with no
# error at the collision site. Keep every nested worktree (a manual `git
# worktree add`, this repo's own agent-tooling worktrees, etc.) fully OUTSIDE
# the package root — a sibling directory, never a subdirectory of it — until
# TestItemRunner exposes a way to scope `@testsnippet` discovery itself.
const TEST_ROOT = normpath(@__DIR__) * Base.Filesystem.path_separator
in_this_package(ti) = startswith(normpath(ti.filename), TEST_ROOT)

if "skip_quality" in ARGS
    @run_package_tests filter = ti -> in_this_package(ti) &&
                                      !(:quality in ti.tags) &&
                                      !(:ad in ti.tags)
elseif "quality_only" in ARGS
    @run_package_tests filter = ti -> in_this_package(ti) &&
                                      :quality in ti.tags
elseif "readme_only" in ARGS
    @run_package_tests filter = ti -> in_this_package(ti) &&
                                      :readme in ti.tags
else
    @run_package_tests filter = ti -> in_this_package(ti) &&
                                      !(:ad in ti.tags)
end
