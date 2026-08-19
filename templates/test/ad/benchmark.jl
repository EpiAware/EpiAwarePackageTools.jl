#!/usr/bin/env julia
# MANAGED by EpiAwarePackageTools.scaffold — do not edit by hand.
#
# AD benchmark producer entry: writes the per-backend JSON artefact the
# scaffolded `docs/src/benchmarks/ad-comparison.jl` page renders, so the page
# does not measure every (backend, scenario) pair itself during the docs build.
#
# Runs as its own CI leg, separate from the per-backend gradient job
# `runtests.jl` runs in: that job runs `--code-coverage=user`, so a timing
# taken there would measure the coverage instrumentation, not the backend.
#
#   julia --project=test/ad test/ad/benchmark.jl "<backend name>" <out-path>
#
# `<backend name>` is a registry label from `ADFixtures.backends()` (e.g.
# "Enzyme reverse"), not the CI matrix's underscored tag; the managed workflow
# passes the matching `name` from the same backend entry the tag comes from.

using ADTypes
using DifferentiationInterface
import DifferentiationInterfaceTest as DIT
using EpiAwarePackageTools
using ADFixtures
using {{AD_BACKEND_PACKAGES}}
using Chairmarks

length(ARGS) == 2 || error(
    "usage: julia --project=test/ad test/ad/benchmark.jl " *
        "<backend name> <out-path>"
)

written = EpiAwarePackageTools.benchmark_backend(ADFixtures, ARGS[1], ARGS[2])
println(
    "wrote AD benchmark artefact: ", written.path,
    " (", written.scenarios, " scenarios)"
)
