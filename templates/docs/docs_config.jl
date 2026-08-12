# PACKAGE-OWNED — scaffold writes this once and never overwrites it.
#
# Package-specific configuration read by the managed `make.jl`: the
# Literate.jl tutorial pipeline, README/index link rewrites, and linkcheck
# ignore list. Defaults below build a site with no tutorials, so a fresh
# package needs no edits here; fill these in as the docs grow.

# Tutorial source `.jl` files (Literate scripts) under `TUTORIALS_SUBDIR`.
# Light tutorials emit `@example` blocks Documenter runs in-process; keep
# cheap tutorials here.
const LIGHT_TUTORIALS = String[]

# Heavy tutorials (live MCMC fits, multi-backend AD, plotting) each run once
# in a fresh subprocess so native/memory state cannot accumulate. The
# kit-managed AD-comparison page is registered in `HEAVY_BENCHMARKS` below
# instead, so this list starts empty and is yours to fill.
const HEAVY_TUTORIALS = String[]

# Where tutorial `.jl` sources and rendered `.md` pages live, relative to
# `docs/src`.
const TUTORIALS_SUBDIR = joinpath("getting-started", "tutorials")

# Fast-build stubs (`--skip-notebooks`): `"file.md" => "# Heading"` pairs.
# Preserve the tutorial's `@id` in the heading (e.g. `"# [Title](@id
# my-anchor)"`) so cross-references still resolve in a fast build.
const TUTORIAL_STUBS = Pair{String, String}[]

# Heavy tutorials that always render from their `TUTORIAL_STUBS` heading and
# never execute, independent of `--skip-notebooks` — the escape hatch for a
# tutorial with its own problem (e.g. a model that never terminates). Leave
# empty; every heavy tutorial without such a problem should execute. Shared
# with the `docs/src/benchmarks/` pipeline below, so `ad-comparison.jl` is
# parked by naming it here too.
const FORCE_STUB_TUTORIALS = String[]

# Heavy tutorials that build against their own environment instead of the
# shared `docs/` one, as `"file.jl" => "environment/dir"` pairs. The directory
# is relative to `docs/` unless absolute. The escape hatch for a dependency
# that cannot co-resolve with the rest of the docs environment, e.g. one
# capping a shared dependency below the version this package's own extension
# needs; everything else belongs in `docs/Project.toml`.
#
# The environment is package-owned: the kit never writes it, exactly as it
# never writes `docs/Project.toml`. Create the directory with a
# `Project.toml` declaring the tutorial's dependencies plus `Literate` (the
# tutorial runs in a subprocess resolving against that environment alone),
# and a `[sources]` entry pointing at the package root so `using` this
# package resolves. It is instantiated before the tutorial runs, and a
# missing or incomplete one fails the build rather than quietly stubbing the
# page. Shared with the `docs/src/benchmarks/` pipeline below, matched by
# source file name.
#
# One environment per tutorial that needs one, under `environments/` (so
# `"environments/my-tutorial"` here, `docs/environments/my-tutorial/` on
# disk). Each resolves on its own manifest, so two tutorials wanting
# incompatible versions simply get one environment each. The managed
# Dependabot config watches that path and nowhere else: an environment
# elsewhere still builds, but its dependencies are never updated.
const TUTORIAL_ENVIRONMENTS = Pair{String, String}[]

# The `docs/src/benchmarks/` Literate pipeline: its own heavy list and stubs,
# mirroring `HEAVY_TUTORIALS`/`TUTORIAL_STUBS` above but rooted at
# `docs/src/benchmarks`, so a benchmark report gets its own top-level
# "Benchmarks" nav group rather than reading as a how-to under Tutorials. The
# `ad-comparison.jl` entry is seeded when scaffolded with `ad = true`: the
# page itself is kit-managed; only this registration is package-owned.
const HEAVY_BENCHMARKS = String[{{AD_HEAVY_BENCHMARKS}}]

# Fast-build stubs for `HEAVY_BENCHMARKS`, same convention as
# `TUTORIAL_STUBS`.
const BENCHMARK_STUBS = Pair{String, String}[{{AD_BENCHMARK_STUBS}}]

# Whether this package advertises itself as part of the EpiAware ecosystem: a
# "Part of the EpiAware ecosystem" README section, and the EpiAware logo + org
# links in the docs footer. Opt-in, off by default (the kit also scaffolds
# non-org packages). Set `true` in an EpiAware org package.
const ORG_BRANDING = false

# Regexes for URLs to skip during the (full-build) linkcheck, e.g. a page
# published by a separate workflow that is not yet live.
const LINKCHECK_IGNORE = Regex[]

# README -> index.md link rewrites: `from => to` pairs applied line by line,
# e.g. rewriting an absolute docs URL to an in-site `@ref`.
const INDEX_REWRITES = Pair{String, String}[]

# Whether README ```julia blocks become runnable `@example readme` blocks on
# the home page. Keep `true` for real, runnable examples; set `false` when
# they are illustrative (placeholder names) and must not execute.
const README_EXECUTE = true

# README headings whose whole section (heading + body, to the next heading of
# the same or higher level) is dropped from the home page. The managed badge
# block is always stripped via its `<!-- badges:start/end -->` markers; this
# list is the package-owned hook for omitting any other named section. Leave
# empty to keep the whole README.
const INDEX_STRIP_SECTIONS = String[]

# Whether the build generates the benchmark page
# (`src/benchmarks/over-time.md`): the package-owned `docs/benchmarks.md`
# prose hook plus a summary table, trend plot, and one section per suite,
# rendered from the `benchmarks` branch timeline. Defaults to the
# `benchmarks` scaffold flag; `false` drops the page and its `pages.jl` nav
# entry. The trend plot needs `Plots` in `docs/Project.toml` (lazily loaded;
# degrades to a table-only page with an `@info` note when absent).
const BENCHMARK_PAGE = {{BENCHMARK_PAGE}}

# Headline benchmark suites to keep on the performance-history page. A suite
# is the first `/`-segment of a benchmark's name (e.g. "AD gradients" in
# "AD gradients/Convolved Normal+Normal/ForwardDiff"). Empty keeps every
# suite; name a few when the full list makes the page too long.
const HISTORY_SUITES = String[]

# How many of the most-recent revisions (columns) to show in the overall
# summary and history ratio table. The published `table.md` can carry every
# benchmarked release; this caps the rendered table (and trend plot) so it
# stays readable. Columns are relabelled with commit dates.
const HISTORY_COMMITS = 5

# Ratio (median benchmark value at the most recent shown revision, over its
# value at the oldest shown revision) at or above which a suite's `Status`
# flags "⚠ reg". 1.1 == a 10% increase counts as a regression; raise for a
# noisier suite, lower for a stricter one. Must be > 1.0, or a suite with no
# change (or an improvement) would flag.
const HISTORY_REGRESSION_THRESHOLD = 1.1

# --- docs/pages.jl extension points (#170/#328/#354) ------------------------
#
# `docs/pages.jl` is MANAGED: `scaffold`/`update` regenerate it in full on
# every run, owning group labels, ordering and placement. Add nav content
# here instead of editing `pages.jl` directly — a direct edit is overwritten
# on the next sync. All four constants are optional and default to
# empty/absent, so a `docs_config.jl` written before one existed keeps
# working untouched.

# The package's own Getting-started tutorials, as `"Title" => "page.md"`
# pairs (relative to `docs/src`), listed right after Overview (and the
# optional FAQ below) in the generated nav — one placement for the whole
# ecosystem rather than a per-repo choice (#354). These are the only tutorials
# in the nav; the kit itself writes no tutorial page.
const PACKAGE_TUTORIALS = Pair{String, String}[]

# Whole extra top-level nav groups the package owns (e.g. "Tools", "Guide",
# a developer reference distinct from the Development skeleton below), as
# `"Title" => content` pairs where `content` is anything a nav entry may
# hold: a single page path, or a nested vector of `"Title" => content` pairs.
# Spliced in after "Benchmarks" and before "Development", in list order.
const PACKAGE_SECTIONS = Pair{String, Any}[]

# The one package-specific leaf in the managed "Development" group's fixed
# skeleton (Overview, Contributing, this leaf, Release process, Developer
# FAQ) — e.g. `"Adding a workaround" => "developer/adding-a-tool.md"`. The
# group appears only when this is set: a package with nothing of its own to
# document under Development gets no group, rather than a skeleton of pages
# about no package-specific extension point. Leave `nothing` to opt out; the
# four fixed pages (`developer/index.md`, `developer/contributing.md`,
# `developer/release-process.md`, `developer/faq.md`) are then the package's
# own to write, at those exact paths.
const DEVELOPMENT_EXTEND_PAGE = nothing

# An optional Getting-started FAQ page, listed right after Overview, e.g.
# `"getting-started/faq.md"`. Leave `nothing` to omit it.
const GETTING_STARTED_FAQ = nothing
