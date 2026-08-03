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
# `ad-backends.jl` entry is seeded when scaffolded with `ad = true`: the page
# itself is kit-managed; only this registration is package-owned.
const HEAVY_TUTORIALS = String[{{AD_HEAVY_TUTORIALS}}]

# Where tutorial `.jl` sources and rendered `.md` pages live, relative to
# `docs/src`.
const TUTORIALS_SUBDIR = joinpath("getting-started", "tutorials")

# Fast-build stubs (`--skip-notebooks`): `"file.md" => "# Heading"` pairs.
# Preserve the tutorial's `@id` in the heading (e.g. `"# [Title](@id
# my-anchor)"`) so cross-references still resolve in a fast build.
const TUTORIAL_STUBS = Pair{String, String}[{{AD_TUTORIAL_STUBS}}]

# Heavy tutorials that always render from their `TUTORIAL_STUBS` heading and
# never execute, independent of `--skip-notebooks` — the escape hatch for a
# tutorial with its own problem (e.g. a model that never terminates). Leave
# empty; every heavy tutorial without such a problem should execute.
const FORCE_STUB_TUTORIALS = String[]

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

# Whether the build generates the benchmark page (`src/benchmarks.md`): the
# package-owned `docs/benchmarks.md` prose hook plus a summary table, trend
# plot, and per-suite detail rendered from the `benchmarks` branch timeline.
# Defaults to the `benchmarks` scaffold flag; `false` drops the page and its
# `pages.jl` nav entry. The trend plot needs `Plots` in `docs/Project.toml`
# (lazily loaded; degrades to a table-only page with an `@info` note when
# absent).
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
