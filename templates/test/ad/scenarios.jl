# PACKAGE-OWNED — scaffold writes this once and never overwrites it.
#
# Per-backend AD gradient test items. Each backend is its own `@testitem`,
# tagged so the per-backend CI can select it with a tag filter (e.g. `julia
# test/ad/runtests.jl enzyme_reverse`). Harness wiring lives in the managed
# `setup.jl`; the SCENARIOS come from the package's own `ADFixtures`
# registry. This starter seed covers every backend the kit knows about; add
# or trim backends and categories to match the package afterwards.

{{AD_SCENARIO_TESTITEMS}}

# Add latent (or other) scenario groups as the package needs, e.g.:
# @testitem "ForwardDiff gradients (latent)" tags=[:ad, :forwarddiff] setup=[ADHelpers] begin
#     test_working_backend("ForwardDiff"; category = :latent)
# end
