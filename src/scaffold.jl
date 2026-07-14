# Scaffolder for the standard EpiAware package tooling. Writes/updates the
# shipped standard configuration and test infrastructure into a package so it
# adopts (and stays in sync with) the kit in one call. The templates live in
# `templates/` at this package's root and are the single source of truth.
#
# Each template is either managed (the standard infra: re-applied on scaffold_update,
# overwritten to remove drift) or package-owned (a starting skeleton written
# once and never touched again — the package's unit tests, AD scenarios, and
# QA config values live here). `scaffold` adopts; `scaffold_update` re-applies only the
# managed files. Both return a manifest distinguishing what was created,
# updated, preserved, or removed (a managed file the kit has retired).
#
# No person, org, or repository name is baked into a template. Every such value
# is a `{{PLACEHOLDER}}` filled from `scaffold`/`scaffold_update` inputs, which default
# to reading the target package's `Project.toml` (name, authors) and a sensible
# org default. A caller can override any of them by keyword.

# A template entry. `src` is the path under `templates/`; `dest` the path under
# the target package root (usually equal). `managed = true` means standard
# infra (overwritten on scaffold_update); `false` a package-owned skeleton (write once).
# `substitute = true` runs placeholder substitution on copy.
#
# `ad` selects whether a template is emitted for the AD-enabled or AD-disabled
# standard, so a numerical package opts into the AD CI caller + AD test infra
# while a tooling/non-numerical package opts out:
#
#   - `:always`    — emitted regardless of the `ad` flag.
#   - `:ad_only`   — emitted only when `ad = true` (the AD CI caller, the
#                    `test/ad` and `test/ADFixtures` harness, and the AD-flavoured
#                    variant of a file that differs by AD content).
#   - `:noad_only` — emitted only when `ad = false` (the no-AD-flavoured variant
#                    of a file that differs by AD content, e.g. a `codecov.yml`
#                    without the per-backend flags).
#
# A file whose content depends on AD ships as a pair (`:ad_only` + `:noad_only`)
# writing to the same `dest`; exactly one is emitted for a given `ad` value.
#
# `bench` gates a template on the `benchmarks` flag, mirroring `ad` (benchmarks
# are opt-in: a package with a real performance suite opts in, everything else
# skips the benchmark CI, suite skeleton, and docs page):
#
#   - `:always`     — emitted regardless of the `benchmarks` flag.
#   - `:bench_only` — emitted only when `benchmarks = true` (the benchmark CI
#                     callers, the `benchmark/` suite + compare script, and the
#                     package-owned benchmark docs prose hook).
struct Template
    src::String
    dest::String
    managed::Bool
    substitute::Bool
    ad::Symbol
    bench::Symbol
end

# Convenience constructor: most templates are AD- and benchmark-agnostic.
function Template(src, dest, managed, substitute)
    Template(src, dest, managed, substitute, :always, :always)
end

# AD-flavoured templates specify only `ad`; still benchmark-agnostic.
function Template(src, dest, managed, substitute, ad::Symbol)
    Template(src, dest, managed, substitute, ad, :always)
end

# The standard template set. Order is informational only.
const SCAFFOLD_TEMPLATES = Template[
    # --- root dev config (managed) ---
    # Taskfile + codecov differ by AD content, so each ships as an
    # AD/no-AD pair writing to the same destination.
    Template("Taskfile.yml", "Taskfile.yml", true, false, :ad_only),
    Template("Taskfile.noad.yml", "Taskfile.yml", true, false, :noad_only),
    # Substituted for the single-source `{{JULIAFORMATTER_VERSION}}` hook `rev`.
    Template(".pre-commit-config.yaml", ".pre-commit-config.yaml", true, true),
    Template(".JuliaFormatter.toml", ".JuliaFormatter.toml", true, false),
    Template(".gitattributes", ".gitattributes", true, false),
    # NOTE: `.gitignore` is not in this list. It is managed between markers
    # (see `_apply_gitignore`) so a package's own ignore-rule additions below
    # the managed block survive `scaffold_update`, rather than being copied verbatim
    # and clobbered on the next sync (#65).
    Template(".secrets.baseline", ".secrets.baseline", true, false),
    Template("codecov.yml", "codecov.yml", true, true, :ad_only),
    Template("codecov.noad.yml", "codecov.yml", true, false, :noad_only),
    # NOTE: `LICENSE` is not a managed template. It is written once from the
    # `license` input (see `_apply_license`) and never overwritten by `scaffold_update`,
    # so a package that deliberately changes its licence is not silently
    # reverted on a sync. See the `license` field of `scaffold_inputs`.

    # --- CI caller workflows + dependabot (managed) ---
    Template(".github/dependabot.yml", ".github/dependabot.yml", true, true),
    # CODEOWNERS is managed and parameterised by the `reviewer` handle
    # (`* @{{REVIEWER}}`). GitHub serves no org-default CODEOWNERS, so it is
    # repo-specific, but the content is fully derived from the handle so it is
    # re-applied like any other managed file.
    Template(".github/CODEOWNERS", ".github/CODEOWNERS", true, true),
    Template(".github/workflows/test.yaml",
        ".github/workflows/test.yaml", true, true),
    # The AD CI caller is opt-in: only scaffolded when `ad = true`.
    Template(".github/workflows/ad.yaml",
        ".github/workflows/ad.yaml", true, true, :ad_only),
    Template(".github/workflows/document.yaml",
        ".github/workflows/document.yaml", true, true),
    Template(".github/workflows/pre-commit.yaml",
        ".github/workflows/pre-commit.yaml", true, true),
    Template(".github/workflows/codecoverage.yaml",
        ".github/workflows/codecoverage.yaml", true, true),
    Template(".github/workflows/docpreviewcleanup.yaml",
        ".github/workflows/docpreviewcleanup.yaml", true, true),
    Template(".github/workflows/TagBot.yaml",
        ".github/workflows/TagBot.yaml", true, true),
    # Triggers Julia General Registry registration: a `/register` issue/PR
    # comment or a manual `workflow_dispatch` both post the
    # `@JuliaRegistrator register` comment on `main`'s HEAD commit (gated on
    # the actor having write access). No `{{PLACEHOLDER}}`s — every value it
    # needs comes from the GitHub Actions context, so it ships unsubstituted.
    Template(".github/workflows/Register.yml",
        ".github/workflows/Register.yml", true, false),
    Template(".github/workflows/downstream.yaml",
        ".github/workflows/downstream.yaml", true, true),
    # Registration-safety caller (thin caller of the EpiAware/.github
    # reusable): fails when a dependency is unregistrable (unregistered or
    # compat-unsatisfiable) so a version cannot be published unregistrable
    # (the ConvolvedDistributions 0.2.0 failure), and warns when an org
    # reverse-dep's compat is stranded by the version under test.
    Template(".github/workflows/registrability.yaml",
        ".github/workflows/registrability.yaml", true, true),
    # Cancel a PR's in-flight runs on close/merge (thin caller of the
    # EpiAware/.github reusable), freeing runners that concurrency groups miss.
    Template(".github/workflows/cancel-on-close.yaml",
        ".github/workflows/cancel-on-close.yaml", true, true),
    # The generic org "Try this PR!" helper: comments install instructions for
    # the PR branch. Parameterised by repo slug + package name.
    Template(".github/workflows/try-this-pr.yaml",
        ".github/workflows/try-this-pr.yaml", true, true),
    # The Claude Code review bot integration (org-standard; the OAuth token is a
    # per-repo secret). Gated on the `reviewer` handle so only that user's
    # comments/PRs trigger it.
    Template(".github/workflows/claude.yml",
        ".github/workflows/claude.yml", true, true),
    Template(".github/workflows/claude-code-review.yml",
        ".github/workflows/claude-code-review.yml", true, true),
    # Scheduled template-sync: re-applies the managed standard on a schedule
    # (and on Dependabot updates) and opens a PR / refreshes the branch when the
    # committed infra has drifted from the kit. The auto-refresh half of the
    # dogfooding loop (the `self-drift` check guards it the rest of the time).
    Template(".github/workflows/template-sync.yaml",
        ".github/workflows/template-sync.yaml", true, true),

    # --- benchmark CI (managed, opt-in via `benchmarks = true`) ---
    # The PR base-vs-head comparison comment (`benchmark.yaml`) and the
    # persistent history timeline (`benchmark-history.yaml`), reproducing the
    # CensoredDistributions.jl benchmark CI. `benchmark.yaml` builds its PR
    # comment from `benchmark/compare.jl` (the BenchmarkTools `compare_comment`
    # path); `benchmark-history.yaml` renders the timeline with
    # AirspeedVelocity's `benchpkgtable`/`benchpkgplot`.
    Template(".github/workflows/benchmark.yaml",
        ".github/workflows/benchmark.yaml", true, true, :always, :bench_only),
    Template(".github/workflows/benchmark-history.yaml",
        ".github/workflows/benchmark-history.yaml", true, true, :always,
        :bench_only),

    # --- version automation (managed) ---
    # Auto-increment the patch version on a merge to main when it was not bumped
    # (`auto-version-increment.yaml`), and an on-demand `/version major|minor|
    # patch` PR comment command (`version-on-demand.yaml`), both driven by the
    # bundled `increment-version` composite action.
    Template(".github/workflows/auto-version-increment.yaml",
        ".github/workflows/auto-version-increment.yaml", true, false),
    Template(".github/workflows/version-on-demand.yaml",
        ".github/workflows/version-on-demand.yaml", true, false),
    Template(".github/actions/increment-version/action.yaml",
        ".github/actions/increment-version/action.yaml", true, true),

    # NOTE: the org-level community health files (ISSUE_TEMPLATE/, the
    # PULL_REQUEST_TEMPLATE, CONTRIBUTING/CODE_OF_CONDUCT/SUPPORT) are not
    # scaffolded. GitHub serves them org-wide from EpiAware/.github to any repo
    # that lacks its own copy, so shipping them here would only shadow the org
    # defaults and cause drift. Only the repo-specific CODEOWNERS is seeded
    # below (GitHub has no org-default CODEOWNERS).

    # --- shipped test infrastructure (managed) ---
    Template("test/package/quality.jl",
        "test/package/quality.jl", true, false),
    Template("test/jet/runtests.jl", "test/jet/runtests.jl", true, true),
    Template("test/jet/Project.toml", "test/jet/Project.toml", true, true),
    Template("test/formatter/runtests.jl",
        "test/formatter/runtests.jl", true, false),
    # Substituted for the single-source `{{JULIAFORMATTER_VERSION}}` compat pin.
    Template("test/formatter/Project.toml",
        "test/formatter/Project.toml", true, true),
    # The AD harness drivers are opt-in (managed, but only when `ad = true`).
    Template("test/ad/setup.jl", "test/ad/setup.jl", true, true, :ad_only),
    Template("test/ad/runtests.jl", "test/ad/runtests.jl", true, false,
        :ad_only),
    # The benchmark suite drivers are opt-in (managed, only when
    # `benchmarks = true`).
    Template("benchmark/run.jl", "benchmark/run.jl", true, false, :always,
        :bench_only),
    Template("benchmark/compare.jl", "benchmark/compare.jl", true, false,
        :always, :bench_only),

    # --- documentation: Documenter + DocumenterVitepress (managed) ---
    # The standard org docs build (mirrors CensoredDistributions.jl). `make.jl`
    # (the build logic), the VitePress site config/theme/components, the node
    # deps, and the version stub are managed; `Project.toml` (doc deps) and
    # `pages.jl` (the nav tree) are package-owned so a package extends them.
    Template("docs/make.jl", "docs/make.jl", true, true),
    # The per-subprocess heavy-tutorial runner `make.jl` shells out to.
    Template("docs/run_literate_tutorial.jl",
        "docs/run_literate_tutorial.jl", true, false),
    Template("docs/package.json", "docs/package.json", true, false),
    Template("docs/versions.js", "docs/versions.js", true, false),
    Template("docs/src/.vitepress/config.mts",
        "docs/src/.vitepress/config.mts", true, true),
    Template("docs/src/.vitepress/theme/index.ts",
        "docs/src/.vitepress/theme/index.ts", true, false),
    Template("docs/src/.vitepress/theme/style.css",
        "docs/src/.vitepress/theme/style.css", true, false),
    Template("docs/src/components/VersionPicker.vue",
        "docs/src/components/VersionPicker.vue", true, false),
    # The GitHub-stars navbar widget (Vue component + its build-time star-count
    # loader). Both carry `{{REPO}}` so the widget targets the adopting repo.
    Template("docs/src/components/StarUs.vue",
        "docs/src/components/StarUs.vue", true, true),
    Template("docs/src/components/stargazers.data.ts",
        "docs/src/components/stargazers.data.ts", true, true),
    # The AD-backends tutorial page (generalised from CensoredDistributions.jl,
    # the org model page). Managed so the page body stays kit-current across
    # syncs; everything package-specific it reports — scenarios, backends, and
    # broken/skip declarations — is read at docs-build time from the
    # package-owned `test/ADFixtures` registry (the `ADRegistry` contract), so
    # a package never edits this file to declare a broken scenario. Its
    # registration (docs_config's Literate pipeline, the pages.jl nav) and the
    # docs-env deps it needs live in the package-owned docs seeds below, filled
    # via the `AD_*` docs fragments (see `_ad_heavy_tutorials` etc.); an
    # adopter that predates those seeds wires them by hand once.
    Template("docs/src/getting-started/tutorials/ad-backends.jl",
        "docs/src/getting-started/tutorials/ad-backends.jl", true, true,
        :ad_only),

    # --- package-owned skeletons (written once, never overwritten) ---
    # The standard DocStringExtensions `@template` conventions. Package-owned
    # because it lives in `src/` and must be `include`d by the package module
    # before its docstrings are defined for the templates to take effect (see
    # CensoredDistributions.jl `src/docstrings.jl`).
    Template("src/docstrings.jl", "src/docstrings.jl", false, false),
    # The hybrid-changelog NEWS.md seed (major-release notes; GitHub Releases
    # cover the rest — see `docs/release_notes_header.jl` /
    # `docs/make.jl`'s release-notes.md step, which reads this file when
    # present). Package-owned so a package's own entries are never touched.
    Template("NEWS.md", "NEWS.md", false, false),
    Template("docs/Project.toml", "docs/Project.toml", false, true),
    # A placeholder logo, seeded once at this exact path so a package can drop
    # in a real logo without any further wiring: `docs/make.jl`'s README ->
    # index.md step already strips an `<img ... assets/logo.svg ...>` tag from
    # the generated docs home page (see `_apply_logo_title` for the managed
    # README title tag). Package-owned like LICENSE — replace the file, never
    # regenerated.
    Template("docs/src/assets/logo.svg",
        "docs/src/assets/logo.svg", false, true),
    # Substituted so the benchmark nav entry (`{{BENCHMARKS_NAV}}`) is present
    # only when `benchmarks = true`; package-owned so a package extends the tree.
    Template("docs/pages.jl", "docs/pages.jl", false, true),
    # The authored quickstart, distinct from the README-derived home page.
    # Package-owned (write-once) so a package grows its own content without a
    # sync reverting it; the nav entry lives in the package-owned `pages.jl`.
    # Docs about the kit (customising the site, infrastructure and template
    # sync) are not seeded here: they describe the kit, not the adopting
    # package, so they live on the kit's own site (#194).
    Template("docs/src/getting-started/index.md",
        "docs/src/getting-started/index.md", false, true),
    # The optional Literate/tutorial + README-rewrite config `make.jl` reads
    # (empty by default), and the release-notes page header (NEWS.md prepend).
    # Substituted so `BENCHMARK_PAGE` defaults to the `benchmarks` flag.
    Template("docs/docs_config.jl", "docs/docs_config.jl", false, true),
    Template("docs/release_notes_header.jl",
        "docs/release_notes_header.jl", false, true),
    # The package-owned prose hook spliced into the generated benchmark page.
    # Opt-in: only written when `benchmarks = true` (no page, no hook otherwise).
    Template("docs/benchmarks.md", "docs/benchmarks.md", false, true, :always,
        :bench_only),
    # The package-owned "Skipped & broken benchmarks" notes hook, spliced
    # near the top of the benchmark page (below the overall trend plot,
    # above the collapsed detail). Same write-once/opt-in lifecycle as the
    # narrative prose hook above.
    Template("docs/benchmarks_notes.md", "docs/benchmarks_notes.md", false,
        true, :always, :bench_only),
    Template("test/runtests.jl", "test/runtests.jl", false, false),
    # The test env differs by AD deps, so it ships as an AD/no-AD pair.
    Template("test/Project.toml", "test/Project.toml", false, true, :ad_only),
    Template("test/Project.noad.toml", "test/Project.toml", false, true,
        :noad_only),
    Template("test/package/qa_config.jl",
        "test/package/qa_config.jl", false, true),
    # The optional JET report filter (e.g. for a DynamicPPL @model package).
    Template("test/jet/jet_config.jl", "test/jet/jet_config.jl", false, false),
    # The benchmark environment, so `--project=benchmark` resolves. Opt-in.
    Template("benchmark/Project.toml", "benchmark/Project.toml", false, true,
        :always, :bench_only),
    # The AD scenarios + registry skeleton are opt-in (only when `ad = true`).
    Template("test/ad/scenarios.jl", "test/ad/scenarios.jl", false, true,
        :ad_only),
    Template("test/ad/Project.toml", "test/ad/Project.toml", false, true,
        :ad_only),
    Template("test/ADFixtures/Project.toml",
        "test/ADFixtures/Project.toml", false, true, :ad_only),
    Template("test/ADFixtures/src/ADFixtures.jl",
        "test/ADFixtures/src/ADFixtures.jl", false, true, :ad_only),
    # The package-owned benchmark suite skeleton (the `SUITE`). Opt-in.
    Template("benchmark/benchmarks.jl", "benchmark/benchmarks.jl", false, true,
        :always, :bench_only)
]

# Managed paths the kit has retired (#185). `scaffold_update` writes the current
# standard but used to leave a dropped one behind, so an adopter kept dead infra
# no workflow invokes: `benchmark/comment/` (the unwired `asv_comment` env) went
# with #126/#157 and survived on every package that had already adopted it.
# Retiring is one-way: a path listed here is removed on sync and never written
# again, so it must not be (or contain) a live template destination — enforced
# by the scaffold tests. An entry may be a file or a directory.
const RETIRED_PATHS = String[
    "benchmark/comment"
]

# Remove the retired managed paths from `target_dir`, returning those actually
# deleted. Only paths the kit itself once shipped are listed, so this never
# reaches package-owned content.
function _remove_retired(target_dir::AbstractString)
    removed = String[]
    for rel in RETIRED_PATHS
        path = joinpath(target_dir, rel)
        ispath(path) || continue
        rm(path; recursive = true, force = true)
        push!(removed, path)
    end
    return removed
end

# The default org used to derive `{{ORG}}`/`{{REPO}}` when a caller does not
# pass them. This is the only org default in the kit; it is overridable.
const DEFAULT_ORG = "EpiAware"

# The single source of truth for the pinned JuliaFormatter version (#114). It
# feeds three managed files via `{{JULIAFORMATTER_VERSION}}`: the
# `.pre-commit-config.yaml` hook `rev`, the `test/formatter/Project.toml` exact
# compat pin, and the `juliaformatter_version` input the `pre-commit.yaml`
# caller passes to the shared `format-check.yml`. Without that input the shared
# workflow installs its own (older) default, so CI reformats code the pinned
# local formatter left intact and the check fails; pinning all three from here
# keeps the local hook, the isolated formatter env, and CI on one version.
const _JULIAFORMATTER_VERSION = "2.10.1"

# The seed reusable-workflow ref for the opt-in `downgrade-compat` caller job
# built by `_downgrade_compat_job` (#121). Dependabot bumps the live pin in each
# adopting repo, and `_preserve_reusable_refs` keeps that bumped ref across
# `scaffold_update`, so this seed is only what a first scaffold commits. Kept in step
# with the `test` job's pin in `templates/.github/workflows/test.yaml`.
const _DOWNGRADE_SEED_REF = "6fcdcde033ec670ac3832b239427fd2ded591bbc"  # pragma: allowlist secret

# The seed reusable-workflow ref for the registrability caller
# (`templates/.github/workflows/registrability.yaml`). It pins a NEWER
# EpiAware/.github commit than `_DOWNGRADE_SEED_REF` because
# `registrability.yml` post-dates the shared seed (added in EpiAware/.github
# #31), so the caller cannot pin the older seed and still resolve the
# reusable. The two refs converge once that PR merges and Dependabot bumps the
# pins across adopters. UPDATE this to the squash-merge SHA of
# EpiAware/.github#31 once it lands (the current value is that PR's branch
# head, which resolves pre-merge but may be garbage-collected after a
# squash-merge deletes the branch).
const _REGISTRABILITY_SEED_REF = "0c1b4ec28e30933f3ea50513d0aca40592cf512f"  # pragma: allowlist secret

# The kit's own name + UUID, used to source it into the managed JET env for an
# adopting package. When the adopting package is the kit (it dogfoods itself),
# these are omitted so the env does not depend on / source itself twice.
const KIT_NAME = "EpiAwarePackageTools"
const KIT_UUID = "7aaea248-0d11-4a0d-a7dc-86da30abb951"

# The SPDX licence identifiers a package may select, each backed by a bundled
# `templates/LICENSE.<spdx>` file carrying `{{YEAR}}`/`{{HOLDER}}` placeholders.
const SUPPORTED_LICENSES = ("MIT", "Apache-2.0")
const DEFAULT_LICENSE = "MIT"

# Absolute path to the bundled `templates/` directory.
function _templates_dir()
    dir = pkgdir(EpiAwarePackageTools)
    dir === nothing && error("could not locate EpiAwarePackageTools package dir")
    return joinpath(dir, "templates")
end

# Read a scalar `key = "..."` from a Project.toml line; `nothing` if absent.
function _project_string(proj::AbstractString, key::AbstractString)
    isfile(proj) || return nothing
    pat = Regex("^\\s*" * key * "\\s*=\\s*\"([^\"]+)\"")
    for line in eachline(proj)
        m = match(pat, line)
        m === nothing || return m.captures[1]
    end
    return nothing
end

# Read the `authors = [...]` array from Project.toml as a vector of strings, or
# an empty vector if absent. Handles the common single-line array form
# `authors = ["A <a@x>", "B"]`.
function _project_authors(proj::AbstractString)
    isfile(proj) || return String[]
    txt = read(proj, String)
    m = match(r"authors\s*=\s*\[(.*?)\]"s, txt)
    m === nothing && return String[]
    inner = m.captures[1]
    inner === nothing && return String[]
    return [String(something(x.captures[1], ""))
            for x in eachmatch(r"\"([^\"]*)\"", inner)]
end

# Strip a trailing `<email>` from an author entry, leaving the display name.
_author_name(a::AbstractString) = strip(replace(a, r"<[^>]*>" => ""))

"""
    _logo_initial(pkg)

The single glyph shown on the placeholder logo
(`templates/docs/src/assets/logo.svg`): the package's first letter,
uppercased, or `"?"` when the package name is unknown (a
`scaffold_generate`d/`scaffold`ed target always has one, but this keeps
`scaffold_inputs` total). Purely cosmetic — replacing the placeholder
SVG with a real logo makes this irrelevant.
"""
function _logo_initial(pkg::Union{Nothing, AbstractString})
    (pkg === nothing || isempty(pkg)) && return "?"
    return uppercase(string(first(pkg)))
end

# The template default for the tutorial subdir (see `templates/docs/
# docs_config.jl`), used when a target has no `docs_config.jl` yet.
const _DEFAULT_TUTORIALS_SUBDIR = "getting-started/tutorials"

"""
    _tutorials_subdir(target_dir)

Read `TUTORIALS_SUBDIR` from the package-owned `docs/docs_config.jl`:
the subdir (relative to `docs/src`) holding the Literate tutorial
sources and their rendered `.md` pages.

The managed `.gitignore` ignores those rendered pages, so the ignore
must track whatever path the package configures rather than hardcode
one. The const is written as a quoted string or a
`joinpath("a", "b")` of quoted segments; every quoted segment is
joined with `/` (the gitignore separator). Falls back to the template
default when the config is absent (e.g. at first scaffold) or omits
the const.
"""
function _tutorials_subdir(target_dir::AbstractString)
    cfg = joinpath(target_dir, "docs", "docs_config.jl")
    isfile(cfg) || return _DEFAULT_TUTORIALS_SUBDIR
    m = match(r"const\s+TUTORIALS_SUBDIR\s*=\s*([^\n]+)", read(cfg, String))
    m === nothing && return _DEFAULT_TUTORIALS_SUBDIR
    rhs = String(something(m.captures[1]))
    segs = [String(something(x.captures[1], ""))
            for x in eachmatch(r"\"([^\"]*)\"", rhs)]
    isempty(segs) && return _DEFAULT_TUTORIALS_SUBDIR
    return join(segs, "/")
end

"""
    _detect_reviewer(target_dir)

Recover a persisted reviewer handle from an already-scaffolded repo so
a resync (`scaffold_update` with no `reviewer` kwarg) keeps it instead of
reverting to the org placeholder (#72).

CODEOWNERS and the Dependabot `reviewers` block are managed
(re-emitted on every sync), and the scheduled template-sync never
re-passes `reviewer`, so the handle must be read back from the
destination — exactly as `_preserve_reusable_refs` reads existing
reusable-workflow refs to stay idempotent against Dependabot SHA
bumps. Reads the active (uncommented) CODEOWNERS owner line the kit
renders from the handle and returns its first `@handle` (the leading
`@` stripped, an `org/team` slug kept whole), or `nothing` when
CODEOWNERS is absent or carries only the commented placeholder (so a
never-configured repo stays unconfigured).
"""
function _detect_reviewer(target_dir::AbstractString)
    co = joinpath(target_dir, ".github", "CODEOWNERS")
    isfile(co) || return nothing
    for line in eachline(co)
        s = strip(line)
        (isempty(s) || startswith(s, "#")) && continue
        m = match(r"@(\S+)", s)
        m === nothing && continue
        return String(something(m.captures[1]))
    end
    return nothing
end

"""
    _detect_docs_subdomain(target_dir)

Recover the docs-hosting choice from an already-scaffolded repo so a
resync (`scaffold_update` with no `docs_subdomain` kwarg) keeps it instead of
silently reverting a subdomain-hosted package to project-pages (#123).

The managed `docs/make.jl` carries the resolved `deploy_url` literal,
which is the source of truth: a quoted host means the custom-subdomain
path, a bare `nothing` means project-pages. Returns the host string,
`nothing` (explicit project-pages), or `:missing` when `docs/make.jl`
is absent or carries no `deploy_url` (a never-scaffolded target, so
the caller falls back to the scaffold default). Mirrors
`_detect_reviewer`/`_detect_benchmarks`: the destination is read back
so a scheduled sync — which never re-passes `docs_subdomain` — stays
idempotent, and a package that has drifted to the wrong base self-heals
on the next `scaffold_update`.
"""
function _detect_docs_subdomain(target_dir::AbstractString)
    mk = joinpath(target_dir, "docs", "make.jl")
    isfile(mk) || return :missing
    m = match(r"deploy_url\s*=\s*(nothing|\"([^\"]*)\")", read(mk, String))
    m === nothing && return :missing
    m.captures[2] === nothing && return nothing  # `deploy_url = nothing`
    host = String(something(m.captures[2]))
    return isempty(host) ? nothing : host
end

"""
    _detect_doi(target_dir)

Recover a persisted Zenodo DOI and badge id from an already-scaffolded
repo so a resync (`scaffold_update` with no `doi`/`zenodo_badge` kwargs) keeps an
adopter's DOI badge instead of stripping it (#161).

The README "License & DOI" badge cell is fully managed and re-rendered
on every sync, but `doi`/`zenodo_badge` default to `nothing` and the
scheduled template-sync never re-passes them, so the values must be read
back from the destination — exactly as `_detect_reviewer` recovers the
code-owner handle. Reads the managed DOI badge the kit renders
(`[![DOI](https://zenodo.org/badge/<id>.svg)](https://doi.org/<doi>)`)
back from the existing README and returns the `(doi, zenodo_badge)`
pair, or `(nothing, nothing)` when the README is absent or carries no
DOI badge (so a never-configured repo stays unconfigured).
"""
function _detect_doi(target_dir::AbstractString)
    readme = joinpath(target_dir, "README.md")
    isfile(readme) || return (nothing, nothing)
    m = match(
        r"\[!\[DOI\]\(https://zenodo\.org/badge/([^)]+?)\.svg\)\]\(https://doi\.org/([^)]+?)\)",
        read(readme, String))
    m === nothing && return (nothing, nothing)
    return (String(something(m.captures[2])), String(something(m.captures[1])))
end

"""
    scaffold_inputs(target_dir; package = nothing, authors = nothing,
        holder = nothing, org = $(repr(DEFAULT_ORG)), repo = nothing,
        reviewer = nothing, year = <current year>,
        license = $(repr(DEFAULT_LICENSE))) -> NamedTuple

Resolve the placeholder substitution values for [`scaffold`](@ref) /
[`scaffold_update`](@ref).

Every value defaults from the target `Project.toml` (or a sensible org default)
and is overridable by keyword, so no person, org, or repository name is baked
into a template:

  - `package` — the package name (`{{PACKAGE}}`); default the `Project.toml`
    `name`. The package UUID (`{{UUID}}`) is read from `Project.toml` `uuid`.
  - `authors` — `{{AUTHORS}}`; default the joined `Project.toml` `authors`.
  - `holder` — copyright holder (`{{HOLDER}}`); default `authors`.
  - `org` — GitHub org (`{{ORG}}`); default `$(repr(DEFAULT_ORG))`.
  - `repo` — `owner/name` slug (`{{REPO}}`); default `"{org}/{package}.jl"`.
  - `reviewer` — the GitHub handle (`{{REVIEWER}}`) that drives every place a
    real reviewer/code-owner is needed: the `.github/CODEOWNERS` rule
    (`* @{{REVIEWER}}`), the Dependabot `reviewers`, the version-bump assignee,
    and the Claude bot's actor gate. A username or `org/team` slug — GitHub
    cannot assign a bare org. When omitted (`nothing`), no owner is written
    (CODEOWNERS ships a commented placeholder, Dependabot gets no `reviewers`)
    so a bare org is never hardcoded.
  - `year` — copyright year (`{{YEAR}}`); default the current year.
  - `license` — the SPDX licence identifier (one of
    `$(join(SUPPORTED_LICENSES, ", "))`) selecting which `LICENSE` text
    [`scaffold`](@ref) writes; default `$(repr(DEFAULT_LICENSE))`. This is a
    scaffold-time choice, not a substitution placeholder, and the `LICENSE` is
    written once and never overwritten by [`scaffold_update`](@ref) so a deliberate
    licence is never reverted.
  - `doi` / `zenodo_badge` — an optional Zenodo DOI and badge id; when both are
    given a DOI badge is added to the README "License & DOI" cell (mirroring
    CensoredDistributions.jl). Both default to `nothing`, in which case any DOI
    badge already committed to the README is recovered and preserved (`#161`),
    so a bare `scaffold_update`/template-sync keeps an adopter's DOI instead of stripping
    it. Passing either explicitly supplies or overrides the DOI on demand.
  - `docs_timeout` — an optional docs-build job timeout in minutes for the
    managed `document.yaml` Documenter caller. Default `nothing`, which renders
    no `with:` block so the reusable `documentation.yml`'s own default (45 min)
    applies; pass a positive integer to cap a slow docs build. A package-owned
    `with:` block hand-added to `document.yaml` is preserved across `scaffold_update()`
    (see `_preserve_caller_with_inputs`), so a set timeout survives a resync.

Returns a `NamedTuple` of `placeholder => value` pairs (plus `LICENSE`, the
resolved SPDX identifier).
"""
function scaffold_inputs(target_dir::AbstractString;
        package::Union{Nothing, AbstractString} = nothing,
        authors::Union{Nothing, AbstractString} = nothing,
        holder::Union{Nothing, AbstractString} = nothing,
        org::AbstractString = DEFAULT_ORG,
        repo::Union{Nothing, AbstractString} = nothing,
        reviewer::Union{Nothing, AbstractString} = nothing,
        year::Union{Nothing, Integer} = nothing,
        license::AbstractString = DEFAULT_LICENSE,
        docs_subdomain::Union{Nothing, Bool, AbstractString} = nothing,
        doi::Union{Nothing, AbstractString} = nothing,
        zenodo_badge::Union{Nothing, AbstractString} = nothing,
        docs_timeout::Union{Nothing, Integer} = nothing)
    license in SUPPORTED_LICENSES || error(
        "unsupported license $(repr(license)); choose one of " *
        join(repr.(SUPPORTED_LICENSES), ", "))
    proj = joinpath(target_dir, "Project.toml")
    pkg = package === nothing ? _project_string(proj, "name") : package
    auth_vec = _project_authors(proj)
    auth = authors === nothing ?
           (isempty(auth_vec) ? nothing : join(_author_name.(auth_vec), ", ")) :
           authors
    hold = holder === nothing ? auth : holder
    rp = repo === nothing ?
         (pkg === nothing ? nothing : string(org, "/", pkg, ".jl")) : repo
    # The `reviewer` handle drives every place a real reviewer/code-owner is
    # needed: the CODEOWNERS line, the Dependabot `reviewers`, the version
    # bump's assignee, and the Claude bot's actor gate. A GitHub username (or an
    # `org/team` slug) is required — GitHub cannot assign a bare org, so when no
    # handle is given those owners are left empty (with a note) rather than
    # producing PRs that error with "can't assign <org> as a reviewer".
    # When no `reviewer` is passed, recover any handle a previous scaffold/scaffold_update
    # persisted in the destination, so a scheduled resync stays idempotent rather
    # than reverting CODEOWNERS / Dependabot reviewers / the assignee to the org
    # placeholder (#72). An explicit `reviewer = ""` still omits owners.
    resolved_reviewer = reviewer === nothing ? _detect_reviewer(target_dir) :
                        reviewer
    has_reviewer = resolved_reviewer !== nothing && !isempty(resolved_reviewer)
    rev = resolved_reviewer === nothing ? org : resolved_reviewer
    # The CODEOWNERS rule (active when a handle is given; otherwise a commented
    # placeholder so a bare org is never written as a code owner).
    codeowners_line = has_reviewer ? string("* @", resolved_reviewer) :
                      string("# * @", org, "/maintainers  # set the `reviewer` ",
        "input to a GitHub handle to enable")
    # The per-entry Dependabot `reviewers:` block (empty when no handle). The
    # template carries the 4-space indent before the following `commit-message:`
    # key, so this fragment only supplies the reviewers lines themselves.
    dependabot_reviewers = has_reviewer ?
                           string("    reviewers:\n      - \"", resolved_reviewer,
        "\"\n") : ""
    # The increment-version composite action's `assignee` default. It must be a
    # user/bot handle (or empty), never the bare org: GitHub rejects assigning
    # an org, and the update-existing-PR path fails hard with
    # `replaceActorsForAssignable` (#122). So it mirrors CODEOWNERS/Dependabot —
    # the handle when one is set, empty otherwise (the action then skips the
    # `--assignee` flag) — rather than falling back to `{{REVIEWER}}`, which is
    # the org placeholder when no reviewer was given.
    assignee_default = has_reviewer ? resolved_reviewer : ""
    yr = year === nothing ? Dates.year(Dates.now()) : year
    uuid = _project_string(proj, "uuid")
    # A fresh UUID for the seeded ADFixtures registry skeleton (a new path
    # package). Generated once per call; the author keeps it thereafter.
    adfix_uuid = string(UUIDs.uuid4())
    # How the docs site is hosted. The default (`docs_subdomain = nothing`) is
    # a GitHub project-pages deploy: `deploy_url = nothing`, so
    # DocumenterVitepress derives the VitePress base from the repo name and the
    # site renders at `epiaware.org/<Repo>.jl/` with no DNS to wire. Opting into
    # a custom subdomain (`docs_subdomain = true` for the conventional
    # `<pkg>.epiaware.org`, or a string for a bespoke host) sets `deploy_url` to
    # that host, which then needs a DNS record and the repo's GitHub Pages
    # custom domain (see the `docs_subdomain` note in `scaffold`).
    # `DOCS_DEPLOY_URL` is the `deploy_url` Julia literal substituted into
    # `docs/make.jl`; `DOCS_URL` is the bare host(+path) for the README badges.
    #
    # When no explicit `docs_subdomain` is passed, recover the choice the repo
    # already committed (its `docs/make.jl` `deploy_url`) so a resync keeps a
    # subdomain-hosted package instead of silently reverting it to project-pages
    # and serving a CSS-less site (#123) — the same read-back-the-destination
    # idempotency `_detect_reviewer`/`_detect_benchmarks` provide. Only a
    # never-scaffolded target (`:missing`) falls back to the scaffold default:
    # the kit dogfoods its DNS-wired custom subdomain
    # (`epiawarepackagetools.epiaware.org`), so it defaults to the subdomain and
    # every other package to project-pages.
    ds = if docs_subdomain !== nothing
        docs_subdomain
    else
        detected = _detect_docs_subdomain(target_dir)
        detected === :missing ? (pkg == KIT_NAME ? true : nothing) : detected
    end
    docs_sub = _resolve_docs_subdomain(ds, pkg)
    docs_deploy_url = _docs_deploy_url(docs_sub)
    docs_url = _docs_url(rp, docs_sub)
    # When neither `doi` nor `zenodo_badge` is passed, recover any Zenodo DOI a
    # previous scaffold/scaffold_update persisted in the README badge block, so a
    # scheduled resync keeps an adopter's DOI badge instead of stripping it
    # (#161) — the same read-back-the-destination idempotency `_detect_reviewer`
    # provides. Passing either explicitly skips detection, so a caller can still
    # supply or override a DOI on demand.
    resolved_doi, resolved_zenodo = if doi === nothing && zenodo_badge === nothing
        _detect_doi(target_dir)
    else
        (doi, zenodo_badge)
    end
    # The managed JET env depends on EpiAwarePackageTools (for its report
    # filter). The kit dogfoods itself, so when the adopting package is the kit
    # the `{{PACKAGE}}` dep/source already cover it — adding a second
    # EpiAwarePackageTools dep (and a git source clashing with the path source)
    # would make a duplicate/invalid env. These placeholders emit the kit dep +
    # git source for every other package, and nothing for the kit itself.
    is_kit = pkg == KIT_NAME
    kit_dep = is_kit ? "" : string(KIT_NAME, " = \"", KIT_UUID, "\"\n")
    kit_source = is_kit ? "" :
                 string(
        "\n# Until EpiAwarePackageTools is registered, it is pinned by git so\n",
        "# the env resolves out of the box. Switch to a local path to\n",
        "# develop the kit alongside this package.\n",
        KIT_NAME, " = {url = \"https://github.com/", org, "/",
        KIT_NAME, ".jl\", rev = \"main\"}")
    # How the scheduled template-sync workflow loads the kit before calling
    # `scaffold_update(".")`. The kit dogfoods itself, so when the adopting package is
    # the kit it syncs from its own checked-out project; every other package
    # pulls the kit's newest `main` into a throwaway env so a sync vendors the
    # latest standard. Kept here (not in the template) because it depends on the
    # same `is_kit` split as the JET kit source line.
    sync_install = is_kit ?
                   "Pkg.activate(\".\"); Pkg.instantiate()" :
                   string("Pkg.activate(; temp = true); Pkg.add(url = ",
        "\"https://github.com/", org, "/", KIT_NAME,
        ".jl\", rev = \"main\")")
    # The managed `.gitignore` tracks the package's tutorial subdir, and the
    # ad=true `codecov.yml` gate holds the status notification until all flag
    # uploads (unit + one per AD backend) are in.
    tutorials_subdir = _tutorials_subdir(target_dir)
    ad_build_count = string(length(_AD_BACKENDS) + 1)
    return (PACKAGE = pkg, UUID = uuid, ADFIXTURES_UUID = adfix_uuid,
        AUTHORS = auth, HOLDER = hold, ORG = org, REPO = rp,
        REVIEWER = rev, YEAR = string(yr), LICENSE = license,
        DOCS_DEPLOY_URL = docs_deploy_url, DOCS_URL = docs_url,
        DOCS_TIMEOUT_WITH = _docs_timeout_with(docs_timeout),
        DOI = resolved_doi, ZENODO_BADGE = resolved_zenodo,
        TUTORIALS_SUBDIR = tutorials_subdir, AD_BUILD_COUNT = ad_build_count,
        AD_CODECOV_FLAGS = _ad_codecov_flags(),
        AD_BACKENDS_JSON = _ad_backends_json(),
        AD_COV_TABLE = _ad_cov_table(rp),
        AD_BACKEND_PACKAGES = _ad_backend_packages(),
        AD_BACKEND_ENTRIES = _ad_backend_entries(),
        AD_SCENARIO_TESTITEMS = _ad_scenario_testitems(),
        CODEOWNERS_LINE = codeowners_line,
        DEPENDABOT_REVIEWERS = dependabot_reviewers,
        ASSIGNEE_DEFAULT = assignee_default,
        KIT_DEP_LINE = kit_dep,
        KIT_SOURCE_LINE = kit_source, SYNC_INSTALL = sync_install,
        JULIAFORMATTER_VERSION = _JULIAFORMATTER_VERSION,
        LOGO_INITIAL = _logo_initial(pkg))
end

# Apply placeholder substitution to `content`. A template may use any subset of
# the placeholders; each used placeholder must resolve to a non-nothing value.
function _substitute(content::AbstractString, inputs::NamedTuple,
        from::AbstractString)
    for (key, val) in pairs(inputs)
        token = "{{" * string(key) * "}}"
        occursin(token, content) || continue
        val === nothing && error(
            "template $from uses $token but no value resolved; pass it to " *
            "scaffold/scaffold_update or set the target Project.toml")
        content = replace(content, token => val)
    end
    return content
end

# A reusable-workflow `uses:` line in a managed CI caller, capturing the prefix
# up to and including the `@`, the workflow filename, and the pinned ref. The
# EpiAware/.github reusables are pinned by ref (a SHA), which Dependabot bumps in
# each adopting repo. See `_preserve_reusable_refs`.
const _REUSABLE_USES = r"(uses:\s*\S+/\.github/\.github/workflows/([^@\s]+)@)(\S+)"

"""
    _preserve_reusable_refs(content, dest)

Keep the destination's existing reusable-workflow refs when
re-emitting a managed CI caller.

Dependabot owns the EpiAware/.github reusable SHAs in every adopting
repo, so a template that hard-pinned one SHA would report drift (and
fail self-drift / churn the scheduled sync) every time Dependabot
moved the live pin. When the destination already pins a ref for the
same reusable workflow, that ref wins and only the rest of the caller
body is re-applied from the template; on first adoption (no
destination yet) the template's seed ref is used. This makes `scaffold_update`
idempotent against Dependabot's bumps.
"""
function _preserve_reusable_refs(content::AbstractString, dest::AbstractString)
    occursin(_REUSABLE_USES, content) || return content
    isfile(dest) || return content
    existing = Dict{String, String}()
    for line in eachline(dest)
        m = match(_REUSABLE_USES, line)
        m === nothing && continue
        # `something` strips the `Union{Nothing, SubString}` the capture API
        # returns; the three groups always match when `m` is non-nothing.
        existing[String(something(m.captures[2]))] = String(something(m.captures[3]))
    end
    isempty(existing) && return content
    return replace(content,
        _REUSABLE_USES => function (s)
            m = match(_REUSABLE_USES, s)
            m === nothing && return String(s)
            prefix = String(something(m.captures[1]))
            workflow = String(something(m.captures[2]))
            seed = String(something(m.captures[3]))
            return prefix * get(existing, workflow, seed)
        end)
end

# A third-party action `uses:` pin in a managed workflow (e.g.
# `actions/checkout@v6`, `julia-actions/cache@v3`), capturing the prefix up to
# the action path, the action path, and the pinned ref. Local `./…` actions
# carry no `@ref` and never match; the org reusable callers do match this shape
# but are skipped in favour of `_preserve_reusable_refs`.
const _ACTION_USES = r"(uses:[ \t]*)([A-Za-z0-9][A-Za-z0-9._/-]*)@(\S+)"

"""
    _preserve_action_pins(content, dest)

Keep the destination's existing third-party action pins when re-emitting a
managed workflow.

Dependabot owns the github-actions pins in every adopting repo (the managed
`dependabot.yml` enables the github-actions ecosystem), so a template that
hard-pins `actions/checkout@v6` would revert a Dependabot bump on every resync.
When template-sync re-applies on a branch it did not open (a Dependabot PR),
that revert rides along silently into the merge (#215). When the destination
already pins a version for an action, that pin wins and only the rest of the
workflow is re-applied from the template; on first adoption (no destination yet)
the template's seed pin is used. Mirrors `_preserve_reusable_refs`, which does
the same for the org reusable-workflow callers (those lines are left to it).
"""
function _preserve_action_pins(content::AbstractString, dest::AbstractString)
    occursin(_ACTION_USES, content) || return content
    isfile(dest) || return content
    existing = Dict{String, String}()
    for line in eachline(dest)
        # Reusable-workflow callers are `_preserve_reusable_refs`' job.
        occursin(_REUSABLE_USES, line) && continue
        m = match(_ACTION_USES, line)
        m === nothing && continue
        existing[String(something(m.captures[2]))] = String(something(m.captures[3]))
    end
    isempty(existing) && return content
    return replace(content,
        _ACTION_USES => function (s)
            occursin(_REUSABLE_USES, s) && return String(s)
            m = match(_ACTION_USES, s)
            m === nothing && return String(s)
            prefix = String(something(m.captures[1]))
            action = String(something(m.captures[2]))
            seed = String(something(m.captures[3]))
            return prefix * action * "@" * get(existing, action, seed)
        end)
end

# A managed CI caller job's reusable `uses:` line, any interspersed blank/comment
# lines documenting an override, its optional `with:` block, and the following
# `secrets:` key. Reuses the same workflow-filename capture as `_REUSABLE_USES`
# to key the block; group 3 is the preserved region — the interspersed
# blank/comment lines plus the `with:` block (empty when the job has neither).
# Group 4 (the `with:` line's own indent) is only used internally, via the `\4`
# backreference, to require the block's input lines be indented DEEPER than
# `with:` — which is what stops the match from swallowing the sibling `secrets:`
# line (indented the same as `with:`). The leading `(?:...comment/blank...)*?`
# lets a documented override survive even when a rationale comment sits between
# `uses:` and `with:` (#117): those comment lines fall inside group 3 and are
# re-emitted with the block, rather than breaking the `uses:`→`with:` adjacency
# and silently dropping the override. It is lazy so it consumes only as far as
# the `with:` block / `secrets:` key, never a following job. See
# `_preserve_caller_with_inputs`.
const _CALLER_JOB = r"(uses:[ \t]*\S+/\.github/\.github/workflows/([^@\s]+)@\S+\r?\n)((?:[ \t]*(?:#[^\r\n]*)?\r?\n)*?(?:([ \t]+)with:\r?\n(?:\4[ \t]+\S.*\r?\n?)*)?)([ \t]*secrets:)"

# Keep a package-owned `with:` block on a managed CI caller job across
# `scaffold_update()` (#73). A package can deliberately override a reusable workflow's
# defaults on a managed caller (e.g. a Julia version floor/matrix on
# `test.yaml`'s `test`/`downgrade-compat` jobs) by adding a `with:` block; the
# template itself carries no `with:` block for these jobs, so re-emitting it
# verbatim would silently drop the override on every sync. Mirrors
# `_preserve_reusable_refs`: the destination is the source of truth, so when
# it already carries a `with:` block for a job, that block is kept and only
# the rest of the caller (the `uses:` ref, `secrets:`, etc.) is re-applied
# from the template; on first adoption (no destination yet) the template's
# with-less form is used untouched.
#
# A job whose template renders its own non-empty `with:` block (e.g. `ad.yaml`'s
# `backends:` passthrough, generated from `_AD_BACKENDS`) carries managed values,
# not package overrides, so the two blocks are merged per key (#183): the
# template wins on a key it renders (a `_AD_BACKENDS` change keeps reaching an
# adopted package rather than freezing at whatever was first scaffolded), while
# a key only the package carries (e.g. `coverage_directories`, counting a package
# extension) is kept. Before #183 the template's block replaced the whole of the
# destination's, silently dropping such a key on every sync.

# The lines of a caller's preserved region, split into the leading blank/comment
# lines and the `with:` inputs. `indent` is the `with:` line's indent, or
# `nothing` when the region carries no `with:` block. Each input is
# `key => lines`, keeping any deeper continuation lines with their key so a
# block/list value survives intact. A comment/blank line is buffered and
# attached to the key it *precedes* (a rationale comment documents the key
# below it, by convention — e.g. `# guard comment` / `coverage_directories:
# 'src,ext'`), not the key above; `trailing` catches any such lines left
# over with no following key (dangling at the end of the block). Before
# #212 a comment was attached to the preceding key instead, which silently
# dropped it when that key was seeded (replaced wholesale by the template)
# and duplicated it when the *next* real template key happened to carry the
# same trailing comment.
function _parse_with_block(chunk::AbstractString)
    head = String[]
    inputs = Pair{String, Vector{String}}[]
    indent = nothing
    pending = String[]
    lines = split(chunk, '\n')
    endswith(chunk, "\n") && !isempty(lines) && pop!(lines)
    for line in lines
        if indent === nothing
            m = match(r"^([ \t]+)with:[ \t]*\r?$", line)
            if m === nothing
                push!(head, String(line))
            else
                indent = String(something(m.captures[1]))
            end
            continue
        end
        key = match(r"^[ \t]+([A-Za-z0-9_.-]+):", line)
        if key !== nothing
            name = String(something(key.captures[1]))
            push!(inputs, name => vcat(pending, String[String(line)]))
            empty!(pending)
        elseif occursin(r"^[ \t]*#", line) || isempty(strip(line))
            push!(pending, String(line))  # comment/blank: attach to next key
        elseif !isempty(inputs)
            push!(last(inputs).second, String(line))  # value continuation
        end
    end
    return (head = head, indent = indent, inputs = inputs, trailing = pending)
end

# Render a caller's preserved region back from its parts. `trailing` has no
# default: the sole call site (`_merge_with_blocks`) always supplies it
# explicitly, and a default here would generate an unreachable, uncovered
# 3-arg method (caught by codecov's patch-coverage check on #218).
function _render_with_block(head::Vector{String}, indent::AbstractString,
        inputs::Vector{Pair{String, Vector{String}}},
        trailing::Vector{String})
    lines = copy(head)
    push!(lines, indent * "with:")
    for (_, value) in inputs
        append!(lines, value)
    end
    append!(lines, trailing)
    return join(lines, "\n") * "\n"
end

# Merge the template's `with:` block (`seed`) with the destination's, keeping
# every key the template renders and appending the keys only the package carries.
function _merge_with_blocks(seed::AbstractString, existing::AbstractString)
    s = _parse_with_block(seed)
    e = _parse_with_block(existing)
    e.indent === nothing && return seed
    # The template renders no `with:` for this job, so the whole block is a
    # package override: the destination's region stands, rationale comments
    # included (#73, #117).
    s.indent === nothing && return existing
    seeded = Set(first(p) for p in s.inputs)
    extra = [p for p in e.inputs if !(first(p) in seeded)]
    # A genuinely dangling comment in the destination (no key follows it) is
    # package-owned unmatched content, exactly like an extra key — keep it
    # alongside the seed's own trailing lines (if any) rather than dropping it.
    trailing = isempty(e.trailing) ? s.trailing : vcat(s.trailing, e.trailing)
    isempty(extra) && isempty(e.trailing) && return seed
    return _render_with_block(s.head, s.indent, vcat(s.inputs, extra), trailing)
end

function _preserve_caller_with_inputs(content::AbstractString,
        dest::AbstractString)
    occursin(_CALLER_JOB, content) || return content
    isfile(dest) || return content
    existing = Dict{String, String}()
    for m in eachmatch(_CALLER_JOB, read(dest, String))
        block = String(something(m.captures[3], ""))
        isempty(block) && continue
        existing[String(something(m.captures[2]))] = block
    end
    isempty(existing) && return content
    return replace(content,
        _CALLER_JOB => function (s)
            m = match(_CALLER_JOB, s)
            m === nothing && return String(s)
            prefix = String(something(m.captures[1]))
            workflow = String(something(m.captures[2]))
            seed = String(something(m.captures[3], ""))
            suffix = String(something(m.captures[5]))
            kept = get(existing, workflow, "")
            replacement = isempty(kept) ? seed : _merge_with_blocks(seed, kept)
            return prefix * replacement * suffix
        end)
end

# Make an emitted file writable by its owner (#187). A `Pkg.add`ed kit ships its
# templates in the read-only depot, so `cp` hands the destination mode 444 and
# the adopting repo cannot edit or `pre-commit` its own managed files. A
# `Pkg.develop`ed kit never showed this, which is why it went unnoticed.
function _make_writable(path::AbstractString)
    isfile(path) || return nothing
    mode = filemode(path)
    mode & 0o200 == 0 && chmod(path, mode | 0o200)
    return nothing
end

# The template's text as the kit would render it: placeholders substituted when
# the template takes substitution, verbatim otherwise. The
# destination-preserving passes `_emit` runs (`_preserve_*`) are deliberately
# not applied — they merge the destination's own pins and inputs back in, so
# they say nothing about what the kit's own template contains, which is what
# the callers here ask about (does the template ship the override marker; has
# the committed file diverged from the standard).
function _render(from::AbstractString, substitute::Bool, inputs::NamedTuple)
    text = read(from, String)
    return substitute ? _substitute(text, inputs, from) : text
end

# Copy one template to `to`, substituting placeholders when requested. Managed
# workflows additionally keep any reusable-workflow ref (see
# `_preserve_reusable_refs`) and any third-party action pin (see
# `_preserve_action_pins`) the destination already carries, plus any
# package-owned `with:` input it holds (see `_preserve_caller_with_inputs`), so
# neither a Dependabot bump nor a deliberate caller override is reverted.
function _emit(from::AbstractString, to::AbstractString, substitute::Bool,
        inputs::NamedTuple)
    mkpath(dirname(to))
    # A previous sync from a read-only depot may have left `to` unwritable, so
    # restore the write bit before rewriting it (#187).
    _make_writable(to)
    if substitute
        content = _substitute(read(from, String), inputs, from)
        content = _preserve_reusable_refs(content, to)
        content = _preserve_action_pins(content, to)
        content = _preserve_caller_with_inputs(content, to)
        write(to, content)
    else
        cp(from, to; force = true)
    end
    _make_writable(to)
    return nothing
end

# --- package-owned LICENSE (write-once) -----------------------------------
#
# LICENSE is package-owned: the `license` input selects a bundled
# `templates/LICENSE.<spdx>`, which `scaffold`/`scaffold_generate` write once with
# `{{YEAR}}`/`{{HOLDER}}` filled. `scaffold_update` never touches it, so a package that
# deliberately switches licence is not silently reverted on a sync. This mirrors
# the managed-vs-owned split used for unit tests and AD scenarios.

# Write the selected LICENSE to `target_dir` if absent (write-once). `inputs`
# supplies `LICENSE` (the SPDX id) plus the `{{YEAR}}`/`{{HOLDER}}` values.
# Returns `:created`, `:preserved` (already present), or `:skipped`.
function _apply_license(target_dir::AbstractString, inputs::NamedTuple)
    dest = joinpath(target_dir, "LICENSE")
    isfile(dest) && return :preserved
    spdx::String = String(inputs.LICENSE)::String
    from = joinpath(_templates_dir(), string("LICENSE.", spdx))
    isfile(from) || error("missing bundled LICENSE template for $spdx at $from")
    write(dest, _substitute(read(from, String), inputs, from))
    return :created
end

# --- managed README badge block -------------------------------------------
#
# The README body is package-owned, but the standard badge set is managed: it
# lives between the markers below and is (re)rendered from the placeholder
# inputs on every scaffold/scaffold_update, so an adopting package gets and keeps the
# standard badges automatically. Nothing outside the markers is touched.

const BADGES_START = "<!-- badges:start -->"
const BADGES_END = "<!-- badges:end -->"

# The single source of truth for the kit's per-backend AD infra: the README
# coverage-flag badge table (`_render_badges`), the `codecov.yml` `ad-*` flags
# and `AD_BUILD_COUNT` gate (`scaffold_inputs`), and the `backends` input the
# kit's `ad.yaml` caller passes to the org `ad.yml` reusable workflow (so the
# ACTUAL CI matrix is driven from here too, rather than silently trusting the
# reusable's own default to match). Add, remove, or reorder a backend here and
# every one of those regenerates consistently on the next `scaffold`/`scaffold_update`
# (#821 AD-backend-configurability gap).
#
#   - `alt`: the `cov <alt>` badge alt text.
#   - `header`: the coverage-flag table column heading (matching
#     CensoredDistributions.jl, which labels the tape-based ReverseDiff column
#     explicitly) and the `name` the reusable workflow shows as the AD job's
#     display name.
#   - `slug`: the `ad-*` codecov flag / reusable-workflow `flag`.
#   - `tag`: the `@testitem` tag `test/ad/runtests.jl` filters on to run just
#     this backend (see `test/ad/scenarios.jl`), and the reusable workflow's
#     `tag` (passed as the CLI argument selecting which backend to test).
#   - `pkg`: the Julia package the backend is loaded from (several backends
#     share one package, e.g. Enzyme forward/reverse both come from
#     `Enzyme`), used to derive the scaffolded `test/ad/setup.jl` `using`
#     line without repeating a package name.
const _AD_BACKENDS = [
    (alt = "ForwardDiff", header = "ForwardDiff",
        slug = "ad-forwarddiff", tag = "forwarddiff", pkg = "ForwardDiff"),
    (alt = "ReverseDiff", header = "ReverseDiff (tape)",
        slug = "ad-reversediff", tag = "reversediff", pkg = "ReverseDiff"),
    (alt = "Enzyme forward", header = "Enzyme forward",
        slug = "ad-enzyme-forward", tag = "enzyme_forward", pkg = "Enzyme"),
    (alt = "Enzyme reverse", header = "Enzyme reverse",
        slug = "ad-enzyme-reverse", tag = "enzyme_reverse", pkg = "Enzyme"),
    (alt = "Mooncake reverse", header = "Mooncake reverse",
        slug = "ad-mooncake-reverse", tag = "mooncake_reverse",
        pkg = "Mooncake"),
    (alt = "Mooncake forward", header = "Mooncake forward",
        slug = "ad-mooncake-forward", tag = "mooncake_forward",
        pkg = "Mooncake")
]

# The managed `codecov.yml` `flags:` entries for every AD backend, generated
# from `_AD_BACKENDS` (one `carryforward` flag block per backend, matching the
# `unit` flag already in the template) so the flags list can never drift from
# `AD_BUILD_COUNT` — see `_AD_BACKENDS`.
#
# `src` only: an AD job runs without the package's weakdeps loaded, so no
# extension file executes under an `ad-*` flag. Listing `ext` here made every
# AD upload report the extension at 0%, which dragged the cross-flag aggregate
# down and redded codecov/patch even when the unit suite covered it fully
# (#180). `ext` belongs to the `unit` flag alone (the job that loads them).
function _ad_codecov_flags()
    blocks = [string("  ", b.slug, ":\n", "    paths:\n", "      - src\n",
                  "    carryforward: true") for b in _AD_BACKENDS]
    return join(blocks, "\n")
end

# The `backends` JSON array the kit's `ad.yaml` caller passes to the org
# `ad.yml` reusable workflow, generated from `_AD_BACKENDS`, so the ACTUAL CI
# matrix is pinned to the same single source as the badges/codecov flags
# rather than silently trusting the reusable's own default to match. Emitted
# compact (one line) and wrapped in single quotes by the template, which is
# valid YAML (no characters here need escaping) and avoids any risk of a
# multi-line block scalar being mis-indented by the substitution.
function _ad_backends_json()
    entries = [string(
                   "{\"name\":\"", b.header, "\",\"tag\":\"", b.tag, "\",\"flag\":\"",
                   b.slug, "\"}") for b in _AD_BACKENDS]
    return "[" * join(entries, ",") * "]"
end

# The comma-joined list of Julia packages the scaffolded `test/ad/setup.jl`
# `using` line loads, derived from `_AD_BACKENDS` (deduplicated, first-seen
# order) so adding a backend that needs a new package — or dropping the last
# backend that needed one — can never leave `setup.jl` over- or
# under-loading relative to `_AD_BACKENDS`.
function _ad_backend_packages()
    pkgs = String[]
    for b in _AD_BACKENDS
        b.pkg in pkgs || push!(pkgs, b.pkg)
    end
    return join(pkgs, ", ")
end

# The `ADTypes` constructor call for each `_AD_BACKENDS` tag, matching what
# every real adopter (ConvolvedDistributions, ModifiedDistributions, ...)
# ends up hand-writing in its own `ADFixtures.backends()`.
const _AD_BACKEND_CTORS = Dict(
    "forwarddiff" => "AutoForwardDiff()",
    "reversediff" => "AutoReverseDiff(compile = false)",
    "enzyme_forward" => "AutoEnzyme(mode = Enzyme.set_runtime_activity(Enzyme.Forward))",
    "enzyme_reverse" => "AutoEnzyme(mode = Enzyme.set_runtime_activity(Enzyme.Reverse))",
    "mooncake_reverse" => "AutoMooncake(config = nothing)",
    "mooncake_forward" => "AutoMooncakeForward()")

# The seeded `ADFixtures.backends()` body, one `(; name, backend)` entry per
# `_AD_BACKENDS` entry, so a fresh package's AD registry always matches every
# backend `test/ad/scenarios.jl` emits a testitem for (#217). Before this the
# seed only ever registered ForwardDiff, so a fresh `ad = true` scaffold
# errored (`ArgumentError: Collection is empty...`) on 5 of 6 backends out of
# the box, and every real adopter had to hand-copy the full list from a
# sibling package to get a passing AD suite.
#
# A tag with no known constructor (e.g. a newly added `_AD_BACKENDS` entry
# ahead of this being updated, or a test round-trip backend) gets `nothing`
# with an inline TODO rather than erroring, so `scaffold`/`scaffold_update`
# still succeeds — the same graceful-degradation the other `_AD_BACKENDS`
# generators (`_ad_codecov_flags`, `_ad_backends_json`, ...) already offer,
# since they need no such lookup at all.
function _ad_backend_entries()
    entries = map(_AD_BACKENDS) do b
        ctor = get(_AD_BACKEND_CTORS, b.tag) do
            "nothing  # TODO: add the ADTypes constructor for \"$(b.header)\""
        end
        string("        (name = \"", b.header, "\", backend = ", ctor, ")")
    end
    return join(entries, ",\n")
end

# The family tag shared by a backend's forward/reverse variants (e.g.
# `:enzyme` for `enzyme_forward`/`enzyme_reverse`), or `nothing` when the
# backend's `tag` has no such split (`forwarddiff`, `reversediff`).
function _ad_scenario_family(tag::AbstractString)
    parts = split(tag, '_')
    return length(parts) > 1 ? first(parts) : nothing
end

# The scaffolded `test/ad/scenarios.jl` starter `@testitem` blocks, one per
# `_AD_BACKENDS` entry, so the package-owned starter seed covers every
# backend the kit currently knows about rather than a hand-picked subset
# that silently falls behind as backends are added.
function _ad_scenario_testitems()
    blocks = map(_AD_BACKENDS) do b
        family = _ad_scenario_family(b.tag)
        tags = family === nothing ? "[:ad, :$(b.tag)]" :
               "[:ad, :$(family), :$(b.tag)]"
        string("@testitem \"", b.header, " gradients (marginal)\" tags=",
            tags, " setup=[ADHelpers] begin\n",
            "    test_working_backend(\"", b.header, "\")\n",
            "end")
    end
    return join(blocks, "\n\n")
end

# The per-backend coverage-flag markdown table (header line, separator line,
# badge line), generated from `_AD_BACKENDS` so it can never drift from the
# codecov flags / CI matrix derived from the same source. Shared by the
# managed README badge block (`_render_badges`) and the AD-backends tutorial
# page (`{{AD_COV_TABLE}}`), so the two always show the same table.
function _ad_cov_flag_table(repo::AbstractString)
    cov = "https://codecov.io/gh/" * repo
    headers = "| " * join((b.header for b in _AD_BACKENDS), " | ") * " |"
    sep = "|" * join((":---:" for _ in _AD_BACKENDS), "|") * "|"
    badges = "| " *
             join(
                 ["[![cov $(b.alt)]($cov/graph/badge.svg?flag=$(b.slug))]" *
                  "(https://app.codecov.io/gh/$repo?flags%5B0%5D=" *
                  "$(b.slug))" for b in _AD_BACKENDS],
                 " | ") * " |"
    return (headers, sep, badges)
end

# The `{{AD_COV_TABLE}}` substitution for the AD-backends tutorial page: the
# three table lines joined, or `nothing` when the repo slug is unknown (then
# `_substitute` errors only if the ad-gated tutorial is actually emitted,
# matching every other `{{REPO}}`-bearing template).
_ad_cov_table(repo::Nothing) = nothing
_ad_cov_table(repo::AbstractString) = join(_ad_cov_flag_table(repo), "\n")

# --- the ad=true docs surface -----------------------------------------------
#
# The managed AD-backends tutorial page needs three package-owned docs seeds to
# carry it: `docs/docs_config.jl` must register it with the Literate pipeline
# (heavy tutorial + fast-build stub), `docs/pages.jl` must add its nav entry,
# and `docs/Project.toml` must reach the `ADFixtures` registry by path and
# carry the page's execution deps. Each helper below renders the fragment
# substituted into those seeds — empty for `ad = false` — so a single template
# serves both standards, mirroring the `BENCHMARKS_NAV` pattern.

# The `HEAVY_TUTORIALS` entry: the page executes DIT benchmarks over every
# registry backend plus CairoMakie plotting, exactly the workload the heavy
# (one fresh subprocess per tutorial) pipeline exists for.
function _ad_heavy_tutorials(ad::Bool)
    ad || return ""
    return "\n    \"ad-backends.jl\"\n"
end

# The fast-build stub, preserving the page's `@id` so cross-references still
# resolve under `--skip-notebooks`.
function _ad_tutorial_stubs(ad::Bool)
    ad || return ""
    return "\n    \"ad-backends.md\" => \"# [Automatic differentiation " *
           "backends](@id ad-backends)\"\n"
end

# The Getting started nav entry for the rendered page.
function _ad_tutorials_nav(ad::Bool)
    ad || return ""
    return ",\n        \"Tutorials\" => [\n" *
           "            \"Automatic differentiation backends\" =>\n" *
           "                \"getting-started/tutorials/ad-backends.md\"\n" *
           "        ]"
end

# The docs-env `[deps]` block the page executes against: the seeded
# `ADFixtures` registry (same fresh UUID as the AD test env, path-sourced
# below), DifferentiationInterfaceTest (the benchmark driver), the
# DataFrames/plotting stack, and the stdlibs the page loads.
function _ad_docs_deps(ad::Bool, adfix_uuid::AbstractString)
    ad || return ""
    return string(
        "ADFixtures = \"", adfix_uuid, "\"\n",
        "AlgebraOfGraphics = \"cbdf2221-f076-402e-a563-3d30da359d67\"\n",
        "CairoMakie = \"13f3f980-e62b-5c42-98c6-ff1f3baf88f0\"\n",
        "DataFramesMeta = \"1313f7d8-7da2-5740-9ea0-a2ca25f37964\"\n",
        "DifferentiationInterfaceTest = ",
        "\"a82114a7-5aa3-49a8-9643-716bb13727a3\"\n",
        "Markdown = \"d6f4376e-aef5-505a-96c1-9c027394607a\"\n",
        "Statistics = \"10745b16-79ce-11e8-11f9-7d13ad32a3b2\"\n")
end

# The `[sources]` path pin from the docs env to the registry.
function _ad_docs_sources(ad::Bool)
    ad || return ""
    return "\nADFixtures = {path = \"../test/ADFixtures\"}"
end

# The `[compat]` bounds for the ad-only docs deps (ADFixtures is path-pinned,
# so it carries none). DifferentiationInterfaceTest mirrors the test-env pin.
function _ad_docs_compat(ad::Bool)
    ad || return ""
    return string(
        "AlgebraOfGraphics = \"0.13\"\n",
        "CairoMakie = \"0.15\"\n",
        "DataFramesMeta = \"0.15\"\n",
        "DifferentiationInterfaceTest = \"0.9, 0.10\"\n",
        "Markdown = \"1\"\n",
        "Statistics = \"1\"\n")
end

# The docs-env `[deps]` fragment the benchmark page's combined trend plot
# needs (`EpiAwarePackageTools.DocsBuild._write_overall_trend_plot`): `Plots`
# (GR backend), lazily loaded kit-side so it is only required once a package
# opts into `BENCHMARK_PAGE = true`. Empty for `benchmarks = false`,
# mirroring `_ad_docs_deps`. Without this, the trend plot silently degrades
# to an `@info` note (never fails the docs build), but a freshly scaffolded
# benchmark page would otherwise never render it at all.
function _bench_docs_deps(benchmarks::Bool)
    benchmarks || return ""
    return "Plots = \"91a5bcdd-55d7-5caf-9e0b-520d859cae80\"\n"
end

# The `[compat]` bound for the benchmark-only docs dep.
function _bench_docs_compat(benchmarks::Bool)
    benchmarks || return ""
    return "Plots = \"1\"\n"
end

# The conventional custom-subdomain docs host for a package, e.g.
# `MyPkg` -> `mypkg.epiaware.org`. Only used on the opt-in subdomain path
# (`docs_subdomain = true`); the default project-pages path needs no host.
_docs_host(pkg::AbstractString) = lowercase(pkg) * ".epiaware.org"

# The GitHub Pages domain the org serves project-pages from. A repo without a
# custom domain is reachable at `<this>/<Repo>.jl/`.
const DOCS_PAGES_APEX = "epiaware.org"

"""
    _resolve_docs_subdomain(spec, pkg)

Resolve the `docs_subdomain` input to either `nothing` (project-pages,
the default) or a concrete host string.

`true` selects the conventional `<pkg>.epiaware.org`; a string is
taken verbatim; `nothing`/`false` opt out. The `Bool` and `Nothing`
cases dispatch to their own methods so the `String` conversion only
ever runs on a genuine string input (keeps JET type-stable —
`String(::Bool)` has no method and would otherwise show as a possible
error).
"""
_resolve_docs_subdomain(::Nothing, pkg) = nothing
function _resolve_docs_subdomain(spec::Bool, pkg)
    spec || return nothing
    return pkg === nothing ? nothing : _docs_host(pkg)
end
function _resolve_docs_subdomain(spec, pkg)
    s = String(spec)
    return isempty(s) ? nothing : s
end

# The `deploy_url` Julia literal for `docs/make.jl`. On the default
# project-pages path this is the bare `nothing` (DocumenterVitepress then
# derives the base from the repo name); on the subdomain path it is the quoted
# host. Returned as source text so the template substitutes a real literal.
_docs_deploy_url(sub::Nothing) = "nothing"
_docs_deploy_url(sub::AbstractString) = repr(String(sub))

# The bare host(+path) the docs badges link to. Project-pages packages live at
# `epiaware.org/<Repo>.jl`; a subdomain package at its own host. `nothing` when
# the repo slug is unknown (badges are then skipped upstream).
_docs_url(repo::Nothing, sub) = sub === nothing ? nothing : String(sub)
function _docs_url(repo::AbstractString, sub)
    sub === nothing || return String(sub)
    return DOCS_PAGES_APEX * "/" * last(split(repo, '/'))
end

# The optional `with: timeout_minutes:` override on the managed `document.yaml`
# Documenter caller (#154), spliced via `{{DOCS_TIMEOUT_WITH}}`. Empty by
# default, so the reusable `documentation.yml` applies its own default (45 min);
# a set `docs_timeout` renders the block to cap a slow docs build. A package can
# equally hand-add the block and `_preserve_caller_with_inputs` keeps it across
# `scaffold_update()` (#73), so the scheduled sync — which never re-passes `docs_timeout`
# — never reverts a package-owned timeout.
function _docs_timeout_with(docs_timeout::Union{Nothing, Integer})
    docs_timeout === nothing && return ""
    docs_timeout > 0 || error(
        "docs_timeout must be a positive integer (minutes), got " *
        repr(docs_timeout))
    return string("    with:\n      timeout_minutes: ", docs_timeout, "\n")
end

# A license-badge cell for an SPDX identifier (label, shields colour, and the
# opensource.org URL). Falls back to a plain SPDX label for an id without a
# dedicated entry, so the badge always matches the package's actual licence.
function _license_badge(spdx::AbstractString)
    label = replace(spdx, "-" => "--")  # shields escapes a literal dash as `--`
    url, colour = if spdx == "MIT"
        "https://opensource.org/licenses/MIT", "yellow"
    elseif spdx == "Apache-2.0"
        "https://opensource.org/licenses/Apache-2.0", "blue"
    else
        "https://spdx.org/licenses/$spdx.html", "green"
    end
    return "[![License: $spdx](https://img.shields.io/badge/License-" *
           "$label-$colour.svg)]($url)"
end

# The two juliapkgstats download badges for a package (total + monthly), keyed
# only on the package name. They render once the package is in the General
# registry and are harmless before then. Mirrors CensoredDistributions.jl.
function _downloads_badges(pkg::AbstractString)
    base = "https://img.shields.io/badge/dynamic/json?url=" *
           "http%3A%2F%2Fjuliapkgstats.com%2Fapi%2Fv1%2F"
    page = "https://juliapkgstats.com/pkg/" * pkg
    total = "[![Downloads](" * base * "total_downloads%2F" * pkg *
            "&query=total_requests&label=Downloads)](" * page * ")"
    monthly = "[![Downloads](" * base * "monthly_downloads%2F" * pkg *
              "&query=total_requests&suffix=%2Fmonth&label=Downloads)](" *
              page * ")"
    return total * " " * monthly
end

"""
    _render_badges(repo, pkg; ad, license = DEFAULT_LICENSE,
        docs_url = nothing, doi = nothing, zenodo_badge = nothing)

Render the standard badge block (without the markers) from resolved
inputs.

`repo` is the `owner/name.jl` slug; `pkg` the package name; `ad` adds
the per-backend AD CI + coverage badge table; `license` is the SPDX id
whose badge is shown. `doi`/`zenodo_badge` add a Zenodo DOI badge when
both are given. The layout matches CensoredDistributions.jl: a
five-column header table (Documentation, Build Status, Code Quality,
License & DOI, Downloads) plus the per-backend AD table. No owner/repo
is hardcoded — every URL is built from `repo`/`pkg`.
"""
function _render_badges(repo::AbstractString, pkg::AbstractString; ad::Bool,
        license::AbstractString = DEFAULT_LICENSE,
        docs_url::Union{Nothing, AbstractString} = nothing,
        doi::Union{Nothing, AbstractString} = nothing,
        zenodo_badge::Union{Nothing, AbstractString} = nothing)
    gh = "https://github.com/" * repo
    cov = "https://codecov.io/gh/" * repo
    # Default to the project-pages URL (`epiaware.org/<Repo>.jl`); a subdomain
    # package passes its host explicitly.
    host = docs_url === nothing ? _docs_url(repo, nothing) : docs_url
    docs = "[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)]" *
           "(https://" * host * "/stable/) " *
           "[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)]" *
           "(https://" * host * "/dev/)"
    ci = "[![Test](" * gh * "/actions/workflows/test.yaml/badge.svg" *
         "?branch=main)](" * gh * "/actions/workflows/test.yaml) " *
         "[![codecov](" * cov * "/graph/badge.svg)](" * cov * ")"
    # We ship one aggregate `ad.yaml` (not six per-backend workflows), so the
    # Build Status cell carries a single AD status badge; the per-backend detail
    # lives in the AD coverage-flag table below.
    if ad
        ci *= " [![AD](" * gh * "/actions/workflows/ad.yaml/badge.svg" *
              "?branch=main)](" * gh * "/actions/workflows/ad.yaml)"
    end
    quality = "[![SciML Code Style](https://img.shields.io/static/v1?" *
              "label=code%20style&message=SciML&color=9558b2&" *
              "labelColor=389826)](https://github.com/SciML/SciMLStyle) " *
              "[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/" *
              "Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/" *
              "Aqua.jl) " *
              "[![JET](https://img.shields.io/badge/" *
              "%E2%9C%88%EF%B8%8F%20tested%20with%20-%20JET.jl%20-%20red)]" *
              "(https://github.com/aviatesk/JET.jl)"
    license_doi = _license_badge(license)
    if doi !== nothing && zenodo_badge !== nothing
        license_doi *= " [![DOI](https://zenodo.org/badge/" * zenodo_badge *
                       ".svg)](https://doi.org/" * doi * ")"
    end
    downloads = _downloads_badges(pkg)
    lines = String[
        "| **Documentation** | **Build Status** | **Code Quality** | " * "**License & DOI** | **Downloads** |",
        "|:-----------------:|:----------------:|:----------------:|" * ":-----------------:|:-------------:|",
        "| " * docs * " | " * ci * " | " * quality * " | " * license_doi * " | " * downloads * " |"
    ]
    if ad
        # Per-backend AD coverage flags (one codecov upload per backend from the
        # aggregate ad.yaml matrix). No per-backend *status* badges: only the
        # aggregate ad.yaml exists, so per-backend status URLs would 404 — the
        # single aggregate AD status badge lives in the Build Status cell above.
        # The table itself is shared with the AD-backends tutorial page, so the
        # two always match (see `_ad_cov_flag_table`).
        header_line, sep, cov_line = _ad_cov_flag_table(repo)
        push!(lines, "")
        push!(lines, header_line)
        push!(lines, sep)
        push!(lines, cov_line)
    end
    return join(lines, "\n")
end

# Inject or refresh the managed badge block in a README. If the markers are
# present, the content between them is replaced; otherwise the block is inserted
# just after the first `# ` H1 title (or at the top when there is no title).
# Content outside the markers is never touched. Returns `(action, changed)`
# where action is `:created`/`:injected`/`:refreshed` and `changed` is whether
# the file content changed.
# A starter README body for a package that has none yet, following the standard
# EpiAware section structure (Why / Getting started / Where to learn more). The
# managed standard-sections block (`_apply_standard_sections`) then appends
# Contributing / How to cite / Code of conduct in the order
# `STANDARD_README_SECTIONS` in `quality.jl` requires. Parameterised from the
# repo slug, package name, and docs host. Only seeded when no README exists;
# thereafter this body is package-owned and only the badge block and the managed
# standard sections are refreshed on scaffold_update.
function _seed_readme_body(repo::AbstractString, pkg::AbstractString,
        docs_url::Union{Nothing, AbstractString})
    host = docs_url === nothing ? _docs_url(repo, nothing) : docs_url
    stable = host === nothing ? nothing : "https://" * host * "/stable/"
    docs_link = stable === nothing ? "the documentation" :
                "[documentation](" * stable * ")"
    return string(
        "_One-line description of $pkg._\n\n",
        "## Why $pkg?\n\n",
        "- _List the package's key features here._\n\n",
        "## Getting started\n\n",
        "See $docs_link for a full walkthrough.\n\n",
        "```julia\nusing $pkg\n```\n\n",
        "## Where to learn more\n\n",
        "- [GitHub Discussions](https://github.com/$repo/discussions)\n",
        "- [GitHub Repository](https://github.com/$repo)\n")
end

function _apply_badges(readme::AbstractString, repo, pkg; ad::Bool,
        license::AbstractString = DEFAULT_LICENSE,
        docs_url::Union{Nothing, AbstractString} = nothing,
        doi::Union{Nothing, AbstractString} = nothing,
        zenodo_badge::Union{Nothing, AbstractString} = nothing)
    badges = _render_badges(repo, pkg; ad = ad, license = license,
        docs_url = docs_url, doi = doi, zenodo_badge = zenodo_badge)
    block = BADGES_START * "\n" * badges * "\n" * BADGES_END
    if !isfile(readme)
        body = _seed_readme_body(repo, pkg, docs_url)
        write(readme, "# " * pkg * "\n\n" * block * "\n\n" * body)
        return (:created, true)
    end
    text = read(readme, String)
    si = findfirst(BADGES_START, text)
    ei = findfirst(BADGES_END, text)
    if si !== nothing && ei !== nothing && first(ei) > last(si)
        # Refresh: replace everything between (and including) the markers.
        new = text[1:(first(si) - 1)] * block * text[(last(ei) + 1):end]
        new == text && return (:refreshed, false)
        write(readme, new)
        return (:refreshed, true)
    end
    # Inject after the first H1 title, else at the very top.
    m = match(r"^(#[^\n]*\n)"m, text)
    if m !== nothing && m.offset == 1
        new = text[1:(m.offset + lastindex(m.match) - 1)] *
              "\n" * block * "\n" * text[(m.offset + lastindex(m.match)):end]
    else
        new = block * "\n\n" * text
    end
    write(readme, new)
    return (:injected, true)
end

# --- managed README logo title ---------------------------------------------
#
# Once a package has a `docs/src/assets/logo.svg` (package-owned; see the
# `docs/src/assets/logo.svg` template), the README's `# ` title gets an inline
# `<img>` tag pointing at it, mirroring CensoredDistributions.jl. This is
# managed like the badge block: (re)checked on every scaffold/scaffold_update, but it
# only adds the tag — a title that already references `assets/logo.svg` (in
# whatever form the package customised it to) is left exactly as-is.

const _LOGO_REL = "docs/src/assets/logo.svg"

# The standard inline logo tag for a README title, sized/positioned to match
# CensoredDistributions.jl.
function _logo_img_tag(pkg::AbstractString)
    string(
        "<img src=\"", _LOGO_REL, "\" width=\"150\" alt=\"", pkg,
        " logo\" align=\"right\">")
end

# Add the logo `<img>` tag to the README's `# ` title when `docs/src/assets/
# logo.svg` exists and the title does not already reference it. Returns
# `:injected`, `:preserved`, or `:skipped` (no logo file, or no README title to
# amend).
function _apply_logo_title(target_dir::AbstractString, pkg::AbstractString)
    isfile(joinpath(target_dir, _LOGO_REL)) || return :skipped
    readme = joinpath(target_dir, "README.md")
    isfile(readme) || return :skipped
    text = read(readme, String)
    m = match(r"^#[^\n]*"m, text)
    m === nothing && return :skipped
    title = m.match
    occursin("assets/logo.svg", title) && return :preserved
    write(readme, replace(text, title => title * " " * _logo_img_tag(pkg);
        count = 1))
    return :injected
end

# --- managed README standard sections --------------------------------------
#
# The README body is package-owned, but three standard sections are managed so
# their wording stays consistent across adopters and updates centrally:
# Contributing, How to cite, and Code of conduct. They live between the markers
# below and are re-rendered on every scaffold/scaffold_update, exactly like the badge
# block. The citation *content* stays package-owned in `CITATION.cff` (seeded
# once, never clobbered); the managed "How to cite" section only points at it
# (#67).

# --- opt-in EpiAware org branding (#242) -----------------------------------
#
# An EpiAware package can advertise that it is part of the org's ecosystem: a
# line in the managed README standard sections, and a logo + org links in the
# docs footer. Opt-in and default OFF, because the kit is usable by anyone: a
# third-party adopter must never be handed EpiAware branding, so the flag is
# read from the package-owned `docs/docs_config.jl` (`const ORG_BRANDING`) and
# defaults to `false` when the config is absent or predates the key.
#
# The *flag* is package-owned; the *content* it turns on is managed, so the
# wording, links and logo update centrally on every sync, like the badge block.

# The org's canonical site. The repo's CNAME serves the site from `epiaware.org`
# (`epiaware.github.io` redirects to it), so link the canonical host.
const _ORG_SITE = "https://epiaware.org"
const _ORG_GITHUB = "https://github.com/EpiAware"

# The bundled org logo, distinct from the package's own `docs/src/assets/
# logo.svg`. Copied verbatim from the org site's `assets/img/logo.svg`, so the
# ecosystem shows one mark. Written only when branding is on, and removed again
# when it is turned off, so an opted-out repo carries no EpiAware asset at all.
const _ORG_LOGO_SRC = "docs/epiaware-logo.svg"
# Split into segments so the destination is built with the platform separator
# (a posix string joined onto a Windows root leaves a mixed path).
const _ORG_LOGO_SEGMENTS = ("docs", "src", "assets", "epiaware-logo.svg")
const _ORG_LOGO_REL = join(_ORG_LOGO_SEGMENTS, "/")

"""
    _detect_org_branding(target_dir)

Whether the package opted in to EpiAware org branding, via
`const ORG_BRANDING = true` in the package-owned `docs/docs_config.jl` (#242).

Read from the destination rather than passed as a kwarg, the same
detect-from-the-file idempotency as `_detect_benchmarks`/`_detect_downgrade_compat`:
a `scaffold_update` (or the scheduled template sync, which passes no kwargs)
then preserves the package's choice instead of reverting it. Defaults to
`false` — off — for a package with no config, or one predating the key.
"""
function _detect_org_branding(target_dir::AbstractString)
    cfg = joinpath(target_dir, "docs", "docs_config.jl")
    isfile(cfg) || return false
    m = match(r"const\s+ORG_BRANDING\s*=\s*(true|false)", read(cfg, String))
    m === nothing && return false
    return something(m.captures[1]) == "true"
end

# The README line, rendered into the managed standard-sections block when
# branding is on and omitted entirely when it is off.
function _org_branding_section(pkg::AbstractString)
    return string(
        "## Part of the EpiAware ecosystem\n\n",
        pkg, " is part of [EpiAware](", _ORG_SITE, "), a set of composable ",
        "tools for infectious disease modelling. See the [other packages](",
        _ORG_GITHUB, ") in the ecosystem.\n")
end

# The docs footer message spliced into the managed `config.mts`
# (`{{ORG_FOOTER_MESSAGE}}`). VitePress renders `themeConfig.footer.message` as
# HTML, so branding is a logo + org links prepended to the standard
# DocumenterVitepress credit; with branding off it is the credit alone, exactly
# as before this feature.
#
# The logo is referenced through the site's own `base`, not as a root-absolute
# `/epiaware-logo.svg`: a versioned deploy is served under `/Package.jl/vX.Y/`,
# where a root-absolute path 404s. DocumenterVitepress copies any asset whose
# filename contains "logo" from `assets/` into `public/`, which VitePress then
# serves at the base — hence `${baseTemp.base}epiaware-logo.svg`, resolved in
# `config.mts` where `base` is known.
#
# Spliced into a backtick template literal in `config.mts` — which is what lets
# `${baseTemp.base}` interpolate — so the HTML quotes with `"` throughout and
# must contain no backtick of its own.
const _DOCS_CREDIT = string(
    "Made with <a href=\"https://luxdl.github.io/DocumenterVitepress.jl/dev/\" ",
    "target=\"_blank\"><strong>DocumenterVitepress.jl</strong></a><br>")

function _org_footer_message(org_branding::Bool)
    org_branding || return _DOCS_CREDIT
    return string(
        "<a href=\"", _ORG_SITE, "\" target=\"_blank\">",
        # `\$` so a literal `\${baseTemp.base}` reaches config.mts, where the
        # backtick template literal interpolates the site base.
        "<img src=\"\${baseTemp.base}epiaware-logo.svg\" alt=\"EpiAware\" ",
        "width=\"48\" height=\"48\" style=\"display:inline-block\"></a><br>",
        "Part of the <a href=\"", _ORG_SITE, "\" target=\"_blank\">",
        "<strong>EpiAware</strong></a> ecosystem &middot; ",
        "<a href=\"", _ORG_GITHUB, "\" target=\"_blank\">GitHub</a><br>",
        _DOCS_CREDIT)
end

"""
    _apply_org_branding(target_dir, org_branding)

Write (or remove) the bundled EpiAware org logo asset, following the package's
`ORG_BRANDING` opt-in (#242).

Bundled but deliberately not a `SCAFFOLD_TEMPLATES` entry, like the `LICENSE`
variants: the template table is emitted wholesale, and a third-party adopter
must not be handed an EpiAware logo. Returns `:created`, `:refreshed`,
`:removed`, or `:skipped`.

Managed, so the asset is re-applied when it drifts, and removed when branding
is turned back off — leaving a repo that opts out with no EpiAware asset, and
`scaffold_update` a fixed point either way.
"""
function _apply_org_branding(target_dir::AbstractString, org_branding::Bool)
    dest = joinpath(target_dir, _ORG_LOGO_SEGMENTS...)
    if !org_branding
        isfile(dest) || return :skipped
        rm(dest; force = true)
        return :removed
    end
    from = joinpath(_templates_dir(), _ORG_LOGO_SRC)
    isfile(from) || error("missing bundled org logo at $from")
    content = read(from, String)
    exists = isfile(dest)
    exists && read(dest, String) == content && return :refreshed
    mkpath(dirname(dest))
    write(dest, content)
    return exists ? :refreshed : :created
end

const STANDARD_SECTIONS_START = "<!-- standard-sections:start -->"
const STANDARD_SECTIONS_END = "<!-- standard-sections:end -->"

# The managed-block header written just inside the start marker, so it is part
# of the refreshed region (like the `.gitignore` header) and never duplicated on
# the preserved side of the file.
const _STANDARD_SECTIONS_HEADER = string(
    "<!-- MANAGED by EpiAwarePackageTools.scaffold — do not edit between the\n",
    "     markers. These standard sections are re-rendered on every scaffold_update;\n",
    "     edit the package-owned sections outside them, or CITATION.cff. -->")

# The org Code of Conduct URL, served from the org's shared `.github` repo.
function _coc_url(org::AbstractString)
    "https://github.com/" * org * "/.github/blob/main/CODE_OF_CONDUCT.md"
end

# Render the managed standard sections (Contributing / How to cite / Code of
# conduct) without the markers, parameterised by package/org/repo. `doi` adds a
# version-DOI line to the citation pointer when known (the value persisted in
# the README DOI badge); otherwise the section points only at `CITATION.cff`.
function _render_standard_sections(pkg::AbstractString, org::AbstractString,
        repo::AbstractString; doi::Union{Nothing, AbstractString} = nothing,
        org_branding::Bool = false)
    doi_line = doi === nothing ? "" :
               string("A version-specific DOI is available at ",
        "[https://doi.org/", doi, "](https://doi.org/", doi, ").\n")
    # The org line leads the block when the package opted in (#242), and is
    # absent entirely otherwise, so a third-party adopter's README is untouched.
    branding = org_branding ? _org_branding_section(pkg) * "\n" : ""
    return string(
        branding,
        "## Contributing\n\n",
        "We welcome contributions and new contributors! Please open an issue ",
        "or pull request on [GitHub](https://github.com/", repo, "). This ",
        "package follows [ColPrac](https://github.com/SciML/ColPrac) and the ",
        "[SciML style](https://github.com/SciML/SciMLStyle).\n\n",
        "## How to cite\n\n",
        "If you use ", pkg, " in your work, please cite it. Citation metadata ",
        "lives in [`CITATION.cff`](https://github.com/", repo,
        "/blob/main/CITATION.cff), which GitHub renders as a ",
        "\"Cite this repository\" button on the repository page.\n",
        doi_line,
        "\n",
        "## Code of conduct\n\n",
        "Please note that the ", pkg, " project is released with a ",
        "[Contributor Code of Conduct](", _coc_url(org), "). By contributing, ",
        "you agree to abide by its terms.\n")
end

# Whether `text` already carries one of the managed standard section headings
# (Contributing / Code of conduct / a citation section), used to leave a
# marker-less README that has bespoke prose alone rather than duplicating them.
function _has_managed_section_heading(text::AbstractString)
    return occursin(r"(?mi)^#{2,6}\s+contributing\b", text) ||
           occursin(r"(?mi)^#{2,6}\s+code of conduct\b", text) ||
           occursin(
               r"(?mi)^#{2,6}\s+(how to cite|citation|citing|supporting)\b", text)
end

"""
    _apply_standard_sections(target_dir, inputs)

Inject or refresh the managed README standard-sections block.

Returns `(action, changed)` where action is `:refreshed` (markers present),
`:injected` (appended to a README that carries none of these sections yet), or
`:skipped` (no README, missing inputs, or a marker-less README that already has
a bespoke Contributing/Code-of-conduct/citation section — migrating that to the
managed block is a deliberate, maintainer-signed per-repo wording change, #67).
Mirrors `_apply_badges`/`_apply_gitignore`: only the marked region is rewritten.
"""
function _apply_standard_sections(
        target_dir::AbstractString, inputs::NamedTuple)
    readme = joinpath(target_dir, "README.md")
    isfile(readme) || return (:skipped, false)
    pkg = inputs.PACKAGE
    org = inputs.ORG
    repo = inputs.REPO
    (pkg === nothing || org === nothing || repo === nothing) &&
        return (:skipped, false)
    body = _render_standard_sections(String(pkg), String(org), String(repo);
        doi = inputs.DOI, org_branding = _detect_org_branding(target_dir))
    block = STANDARD_SECTIONS_START * "\n" * _STANDARD_SECTIONS_HEADER *
            "\n\n" * body * STANDARD_SECTIONS_END
    text = read(readme, String)
    si = findfirst(STANDARD_SECTIONS_START, text)
    ei = findlast(STANDARD_SECTIONS_END, text)
    if si !== nothing && ei !== nothing && first(ei) > last(si)
        new = text[1:(first(si) - 1)] * block * text[(last(ei) + 1):end]
        new == text && return (:refreshed, false)
        write(readme, new)
        return (:refreshed, true)
    end
    # No markers. Append the block only when the README carries none of these
    # standard sections yet (a freshly seeded body). A README with bespoke
    # Contributing/citation/CoC prose is left untouched — migrating it to the
    # managed block is a deliberate wording change signed off per repo (#67).
    _has_managed_section_heading(text) && return (:skipped, false)
    endswith(text, "\n") || (text *= "\n")
    write(readme, text * "\n" * block * "\n")
    return (:injected, true)
end

# --- package-owned CITATION.cff --------------------------------------------
#
# A Citation File Format (https://citation-file-format.github.io) seed so GitHub
# renders a "Cite this repository" widget and the managed "How to cite" README
# section has a file to point at. Package-owned and write-once like `LICENSE`:
# scaffold seeds it, `scaffold_update` never rewrites it, so a package's real author
# list, DOI, and version are preserved (#67).

# The CFF `authors:` list from the kit's author display names (comma- or
# `and`-separated), one `- name:` entity entry each — a valid CFF starting point
# the package refines into person `family-names`/`given-names`.
function _cff_authors(authors::Union{Nothing, AbstractString})
    names = authors === nothing ? String[] :
            [String(strip(a))
             for a in split(authors, r",|\band\b") if !isempty(strip(a))]
    isempty(names) && (names = ["Author One", "Author Two"])
    return join(("  - name: \"" * n * "\"" for n in names), "\n")
end

# Render a package-owned CITATION.cff seed. `doi` fills the `doi:` field when
# known (the value persisted in the README DOI badge); otherwise the field is
# omitted entirely (a valid CFF) — add a real `doi:` line once released, rather
# than carrying a placeholder value.
function _render_citation_cff(pkg::AbstractString, repo::AbstractString,
        authors::Union{Nothing, AbstractString},
        doi::Union{Nothing, AbstractString})
    doi_line = doi === nothing ? "" : "doi: \"" * doi * "\"\n"
    return string(
        "cff-version: 1.2.0\n",
        "message: \"If you use this software, please cite it using these ",
        "metadata.\"\n",
        "title: \"", pkg, ".jl\"\n",
        "type: software\n",
        "authors:\n", _cff_authors(authors), "\n",
        "repository-code: \"https://github.com/", repo, "\"\n",
        "url: \"https://github.com/", repo, "\"\n",
        doi_line)
end

# Seed a package-owned CITATION.cff, write-once (like `_apply_license`): returns
# `:preserved` when one already exists, `:skipped` when the inputs are unknown,
# `:created` when freshly written.
function _apply_citation_cff(target_dir::AbstractString, inputs::NamedTuple)
    dest = joinpath(target_dir, "CITATION.cff")
    isfile(dest) && return :preserved
    pkg = inputs.PACKAGE
    repo = inputs.REPO
    (pkg === nothing || repo === nothing) && return :skipped
    write(dest, _render_citation_cff(String(pkg), String(repo),
        inputs.AUTHORS, inputs.DOI))
    return :created
end

# --- managed [workspace] stanza in the root Project.toml -------------------
#
# The root Project.toml is package-owned (the kit never rewrites its deps), but
# the Julia `[workspace]` table that makes the `test` and `docs` sub-projects
# share the root manifest is part of the standard (as in CensoredDistributions.jl
# with `projects = ["test", "docs"]`). It is injected once when absent and left
# alone thereafter, so a package may extend `projects` without it being reverted.

const WORKSPACE_PROJECTS = ["test", "docs"]

# Ensure the root Project.toml declares a `[workspace]` table. Returns
# `:injected` when one was appended, `:preserved` when already present, or
# `:skipped` when there is no Project.toml to amend.
function _apply_workspace(target_dir::AbstractString)
    proj = joinpath(target_dir, "Project.toml")
    isfile(proj) || return :skipped
    text = read(proj, String)
    occursin(r"(?m)^\[workspace\]", text) && return :preserved
    projects = join(("\"" * p * "\"" for p in WORKSPACE_PROJECTS), ", ")
    stanza = "\n[workspace]\nprojects = [" * projects * "]\n"
    endswith(text, "\n") || (text *= "\n")
    write(proj, text * stanza)
    return :injected
end

# --- managed .gitignore block (package additions preserved) ----------------
#
# `.gitignore` used to be a fully-managed template: `scaffold_update` copied it
# verbatim, so a package's own ignore-rule additions (e.g. a keep-rule for
# bundled data the standard rules would otherwise exclude) were silently
# dropped on the next sync (#65). It now follows the same managed-block
# pattern as the README badges: the standard rules live between the markers
# below and are (re)rendered on every scaffold/scaffold_update; anything outside the
# markers — including a legacy `.gitignore` with no markers yet, which is
# treated as a package-owned tail and kept below the freshly-inserted block —
# is left untouched.

const GITIGNORE_START = "# managed:start"
const GITIGNORE_END = "# managed:end"

# Render the managed `.gitignore` body (without markers) from the bundled
# template, substituting placeholders (currently `{{TUTORIALS_SUBDIR}}`).
function _render_gitignore(inputs::NamedTuple)
    from = joinpath(_templates_dir(), ".gitignore")
    isfile(from) || error("missing bundled template .gitignore at $from")
    return _substitute(read(from, String), inputs, from)
end

"""
    _apply_gitignore(target_dir, inputs)

Apply the managed `.gitignore` block to `target_dir`.

Returns `(action, changed)` where action is `:created`, `:injected`
(markers added to an existing file, e.g. on first run of a kit version
with this fix), or `:refreshed` (markers already present; only the
marked region is touched). Mirrors `_apply_badges`.
"""
function _apply_gitignore(target_dir::AbstractString, inputs::NamedTuple)
    path = joinpath(target_dir, ".gitignore")
    body = _render_gitignore(inputs)
    # The explanatory header lives inside the marker pair (the start marker is
    # always the block's first line) so the whole block — header included —
    # is replaced as one unit on refresh. Putting the header before the start
    # marker would leave it sitting in the "preserved" prefix on every
    # subsequent refresh, duplicating it on each `scaffold_update` call.
    block = GITIGNORE_START * "\n" *
            "# MANAGED by EpiAwarePackageTools.scaffold — do not edit by hand.\n" *
            "# Standard ignore rules live between the markers below and are\n" *
            "# replaced on every scaffold_update. Add package-specific rules after the\n" *
            "# closing marker — they are preserved across updates.\n" *
            body * GITIGNORE_END
    if !isfile(path)
        write(path, block * "\n")
        return (:created, true)
    end
    text = read(path, String)
    # `findfirst` for the opening marker (the block we write always puts it
    # first); `findlast` for the closing one, so a closing marker is found
    # correctly even if the package-owned tail happens to mention the marker
    # text (e.g. in a comment) before the real terminator.
    si = findfirst(GITIGNORE_START, text)
    ei = findlast(GITIGNORE_END, text)
    if si !== nothing && ei !== nothing && first(ei) > last(si)
        new = text[1:(first(si) - 1)] * block * text[(last(ei) + 1):end]
        new == text && return (:refreshed, false)
        write(path, new)
        return (:refreshed, true)
    end
    # No markers yet: a legacy fully-managed copy (pre-#65) or a hand-written
    # file. Insert the managed block at the top and keep everything that was
    # already there as the package-owned tail — never drop existing content.
    new = block * "\n\n" * text
    write(path, new)
    return (:injected, true)
end

# Whether a template is emitted for the requested `ad` value: `:always` always,
# `:ad_only` when `ad = true`, `:noad_only` when `ad = false`.
function _ad_selected(t::Template, ad::Bool)
    t.ad === :always && return true
    t.ad === :ad_only && return ad
    t.ad === :noad_only && return !ad
    error("template $(t.src) has unknown ad mode $(t.ad)")
end

# Whether a template is emitted for the requested `benchmarks` value:
# `:always` always, `:bench_only` only when `benchmarks = true`.
function _bench_selected(t::Template, benchmarks::Bool)
    t.bench === :always && return true
    t.bench === :bench_only && return benchmarks
    error("template $(t.src) has unknown bench mode $(t.bench)")
end

"""
    _detect_benchmarks(target_dir)

Whether a repo already has benchmarks enabled, so a resync (`scaffold_update`
with no `benchmarks` kwarg) preserves an adopter's opt-in instead of
reverting to the opt-out default and stripping their benchmark
CI/suite/page (the #72 trap).

The scheduled template-sync bakes `benchmarks = {{BENCHMARKS}}` into
its `scaffold_update` call, but a repo scaffolded before this flag has a
template-sync that re-passes nothing, so the state must also be
recoverable from the destination. The managed benchmark CI workflows
are the marker: present iff benchmarks were enabled. A fresh
(never-scaffolded) target has neither, so it defaults to opt-out —
exactly the intended behaviour for a new package.
"""
function _detect_benchmarks(target_dir::AbstractString)
    wf = joinpath(target_dir, ".github", "workflows")
    return isfile(joinpath(wf, "benchmark.yaml")) ||
           isfile(joinpath(wf, "benchmark-history.yaml"))
end

"""
    _detect_downgrade_compat(target_dir)

Whether a repo keeps the opt-in `downgrade-compat` CI job, so a resync
(`scaffold_update` with no `downgrade_compat` kwarg) preserves a package's
decision to drop it instead of unconditionally reintroducing a job the
package deliberately removed (#121).

A package pinned to a Julia floor (or one adopting an unregistered,
`[sources]`-pinned dependency) can never resolve the
`julia-downgrade-compat` job, so it disables that job in its managed
`.github/workflows/test.yaml`. The current template would regenerate it
on every sync, silently reintroducing a permanently-red job. The
committed `test.yaml`'s `downgrade.yml` caller is the marker: present
iff the job is kept. A fresh (never-scaffolded) target has no
`test.yaml`, so it defaults to keeping the job — the standard for a new
package.
"""
function _detect_downgrade_compat(target_dir::AbstractString)
    tf = joinpath(target_dir, ".github", "workflows", "test.yaml")
    isfile(tf) || return true
    return occursin("downgrade.yml", read(tf, String))
end

# The managed AD-harness driver (`test/ad/setup.jl`) and the opt-out marker a
# package writes into its own copy to keep a package-owned driver (#162).
const _AD_SETUP_DEST = "test/ad/setup.jl"
const _AD_SETUP_OWNED_MARKER = "EPIAWARE_AD_SETUP_OWNED"

"""
    _detect_ad_setup_owned(target_dir)

Whether a package has opted its AD-harness driver (`test/ad/setup.jl`) out
of kit management by marking it package-owned (#162).

`test/ad/setup.jl` is force-managed: `scaffold_update()` overwrites it with the
generic driver that assumes the package's `ADFixtures` registry satisfies the
current `ADRegistry` contract (its `scenarios` accepts a `category` keyword).
A package whose `ADFixtures` predates that contract cannot run the generic
driver (it would `MethodError` on `category=`), so it must keep a package-owned
driver while it migrates. Adding the marker `$(_AD_SETUP_OWNED_MARKER)` to the
committed `test/ad/setup.jl` (in a comment) tells `scaffold_update()` to preserve the
file instead of clobbering it — the same detect-from-the-destination idempotency
as `_detect_downgrade_compat` (#121). A never-scaffolded or unmarked file is
managed as before, so the opt-out is explicit and self-documenting.
"""
function _detect_ad_setup_owned(target_dir::AbstractString)
    f = joinpath(target_dir, _AD_SETUP_DEST)
    isfile(f) || return false
    return occursin(_AD_SETUP_OWNED_MARKER, read(f, String))
end

# The generic ownership marker any managed file may carry to opt out of kit
# management (#224), generalising `test/ad/setup.jl`'s file-specific marker.
const _MANAGED_OVERRIDE_MARKER = "EPIAWARE_MANAGED_OVERRIDE"

"""
    _detect_managed_override(target_dir, dest, rendered)

Whether the template-emitted managed file at `dest` has been marked
package-owned, so `scaffold_update()` preserves it rather than resyncing it
(#224).

Managed files always resync — that is what keeps an adopter on the current
standard. A package that must keep its own version of one (a hand-kept AD
driver mid-migration, a workflow the package genuinely owns) says so in the
file, by putting the marker `$(_MANAGED_OVERRIDE_MARKER)` in a comment. The
committed file is then the marker, the same detect-from-the-destination
idempotency as `_detect_downgrade_compat` (#121), so the opt-out is explicit,
self-documenting, and survives every sync. The match is a plain case-sensitive
`occursin`, so a mis-cased marker does nothing.

This governs whole files emitted from a template (`SCAFFOLD_TEMPLATES`) only.
The marker-delimited regions the kit injects into otherwise package-owned
files (the `.gitignore` managed block, the README badge and standard-sections
blocks, `Project.toml`'s `[workspace]` stanza) are refreshed by their own
appliers (`_apply_gitignore` and friends), which never consult this, so they
cannot be opted out this way.

`rendered` is the freshly rendered template for `dest`, and is required rather
than defaulted: a managed template that itself contained the marker literal (a
workflow comment documenting this feature, say) would otherwise hand every
adopter a self-preserving copy of that file on its next sync, and the kit would
silently stop managing its own file, everywhere, forever. So when the fresh
render carries the marker, the marker means nothing and the file stays managed.
A caller cannot omit the guard by accident. The test suite additionally asserts
that no bundled template renders the marker, so a template that ever adds it
fails the kit's own CI loudly rather than being tacitly absorbed here.

`test/ad/setup.jl` additionally still honours its original marker
`$(_AD_SETUP_OWNED_MARKER)` (#162) via `_detect_ad_setup_owned`, which adopters
carry today; either marker opts that file out.

`scaffold`/`scaffold_generate` (`force = true`) ignore the marker and lay the
managed file down fresh, so a new package always starts managed. The marker
opts a file out of *resyncing*, not out of *retirement*: a path the kit retires
(`RETIRED_PATHS`) is still deleted, marker or not.
"""
function _detect_managed_override(target_dir::AbstractString,
        dest::AbstractString, rendered::AbstractString)
    f = joinpath(target_dir, dest)
    isfile(f) || return false
    occursin(_MANAGED_OVERRIDE_MARKER, rendered) && return false
    occursin(_MANAGED_OVERRIDE_MARKER, read(f, String)) && return true
    return dest == _AD_SETUP_DEST && _detect_ad_setup_owned(target_dir)
end

# The opt-in `downgrade-compat` caller job spliced into `test.yaml` directly
# after the `test` job's `secrets:` line via `{{DOWNGRADE_COMPAT_JOB}}` (#121):
# the job block (preceded by a blank line) when kept, empty when a package opts
# out. The template file keeps the single trailing newline the pre-commit
# end-of-file-fixer requires, so this block carries none of its own — the empty
# opt-out case leaves just that newline, and the kept case ends on its
# `secrets:` line with the file's newline after it. Built with the org already
# interpolated (so no `{{ORG}}` survives into the substituted content) and the
# seed ref `_DOWNGRADE_SEED_REF`, which `_preserve_reusable_refs` overwrites
# with the destination's Dependabot-bumped ref on every `scaffold_update`.
function _downgrade_compat_job(org::AbstractString, keep::Bool)
    keep || return ""
    return string(
        "\n\n  downgrade-compat:\n",
        "    uses: ", org, "/.github/.github/workflows/downgrade.yml@",
        _DOWNGRADE_SEED_REF, "\n",
        "    secrets: inherit  # pragma: allowlist secret")
end

"""
    _detect_benchmark_history_parked(target_dir)

Whether a package has parked `benchmark-history.yaml`'s push/tag triggers, so
a resync (`scaffold_update`) preserves that state instead of re-enabling a permanently
failing `history` run (#153).

AirspeedVelocity/benchpkg installs the package into a temp environment where a
`[sources]` pin does not apply, so an unregistered `[sources]`-pinned dependency
(currently every adopter, via the unregistered kit itself) can never resolve
there and every push/tag-triggered `history` run fails. The fix is to park the
workflow — drop the `push`/`tags` triggers, keeping only `workflow_dispatch` —
until the package is registered. The committed `on:` block is the marker:
parked iff it carries no `push:` trigger. A fresh (never-scaffolded) target has
no file, so it defaults to the full triggers — the standard once a package is
registered, mirroring `_detect_downgrade_compat`.
"""
function _detect_benchmark_history_parked(target_dir::AbstractString)
    f = joinpath(target_dir, ".github", "workflows", "benchmark-history.yaml")
    isfile(f) || return false
    return !occursin(r"(?m)^  push:", read(f, String))
end

# The `benchmark-history.yaml` `on:` trigger block spliced via
# `{{BENCHMARK_HISTORY_TRIGGERS}}` (#153): the full push/tags/dispatch triggers
# by default, or a parked `workflow_dispatch`-only block (push/tags dropped)
# when the package has parked the workflow for an unregistered `[sources]` dep.
# The parked form self-heals to the full triggers once the package removes the
# park (registers), the same detect-and-preserve idempotency as
# `_downgrade_compat_job`.
function _benchmark_history_triggers(parked::Bool)
    parked && return string(
        "  # push/tags parked until this package is registered: an\n",
        "  # unregistered `[sources]`-pinned dependency never resolves in\n",
        "  # benchpkg's temp environment, so a push/tag `history` run always\n",
        "  # fails (#153). Restore the push/tags triggers once registered.\n",
        "  workflow_dispatch:")
    return string(
        "  push:\n",
        "    branches: [main]\n",
        "    tags: ['v*']\n",
        "  workflow_dispatch:")
end

"""
    _apply(target_dir; managed_only, force, ad, benchmarks,
        downgrade_compat, inputs)

Shared worker for `scaffold`/`scaffold_update`.

`managed_only` restricts to managed templates (the `scaffold_update` path).
`force` overwrites package-owned files too (only meaningful for
`scaffold`). `ad` selects the AD-enabled or AD-disabled standard;
`benchmarks` gates the opt-in benchmark CI/suite/docs page;
`downgrade_compat` gates the opt-in `downgrade-compat` CI job. Returns a
`(created, updated, preserved, removed, warnings)` manifest of destination
paths (`removed` being the retired managed paths cleaned up; see
`RETIRED_PATHS`; `warnings` a `Vector{String}` of non-fatal issues raised
while applying, e.g. a diverged-but-unmarked `test/ad/setup.jl` about to be
overwritten).
"""
function _apply(target_dir::AbstractString; managed_only::Bool, force::Bool,
        ad::Bool, benchmarks::Bool, downgrade_compat::Bool, inputs::NamedTuple)
    isdir(target_dir) || error("target_dir $target_dir does not exist")
    # Read once, before anything is written: the opt-in lives in the
    # package-owned `docs/docs_config.jl`, which `scaffold` seeds (defaulting
    # the flag off) in this same pass, so a fresh package is unbranded and a
    # resync sees the choice the package actually committed (#242).
    org_branding = _detect_org_branding(target_dir)
    # Expose the AD + benchmarks + downgrade-compat flags as substitution values
    # so the scheduled template-sync workflow re-applies the standard with the
    # same choices the package adopted. `BENCHMARKS_NAV` is the benchmark docs
    # nav entry (present only when enabled); `BENCHMARK_PAGE` the `docs_config`
    # default the build reads; `DOWNGRADE_COMPAT_JOB` the `test.yaml` job block
    # (present only when kept).
    bench_nav = benchmarks ?
                ",\n    \"Benchmarks\" => \"benchmarks.md\"" : ""
    # The `benchmark-history.yaml` `on:` triggers preserve a package's parked
    # state (push/tags dropped for an unregistered `[sources]` dep) across a
    # resync (#153), detected from the committed workflow — a fresh target
    # defaults to the full triggers.
    inputs = merge(inputs,
        (AD = string(ad), BENCHMARKS = string(benchmarks),
            BENCHMARKS_NAV = bench_nav, BENCHMARK_PAGE = string(benchmarks),
            DOWNGRADE_COMPAT = string(downgrade_compat),
            DOWNGRADE_COMPAT_JOB = _downgrade_compat_job(
                inputs.ORG, downgrade_compat),
            BENCHMARK_HISTORY_TRIGGERS = _benchmark_history_triggers(
                _detect_benchmark_history_parked(target_dir)),
            # The ad=true docs surface: the AD-backends tutorial page's
            # registration in the package-owned docs seeds and the docs-env
            # deps it executes against (see `_ad_heavy_tutorials` etc.).
            AD_HEAVY_TUTORIALS = _ad_heavy_tutorials(ad),
            AD_TUTORIAL_STUBS = _ad_tutorial_stubs(ad),
            AD_TUTORIALS_NAV = _ad_tutorials_nav(ad),
            AD_DOCS_DEPS = _ad_docs_deps(ad, inputs.ADFIXTURES_UUID),
            AD_DOCS_SOURCES = _ad_docs_sources(ad),
            AD_DOCS_COMPAT = _ad_docs_compat(ad),
            # The benchmarks=true docs surface: the trend-plot dependency the
            # overall summary needs (see `_bench_docs_deps`).
            BENCH_DOCS_DEPS = _bench_docs_deps(benchmarks),
            BENCH_DOCS_COMPAT = _bench_docs_compat(benchmarks),
            # The managed docs footer: the EpiAware logo + org links when the
            # package opted in (`ORG_BRANDING` in the package-owned
            # docs_config), otherwise the DocumenterVitepress credit alone —
            # detected from the destination, like the other opt-ins, so a sync
            # that passes no kwargs preserves the package's choice (#242).
            ORG_FOOTER_MESSAGE = _org_footer_message(org_branding)))
    src_dir = _templates_dir()
    created = String[]
    updated = String[]
    preserved = String[]
    warnings = String[]
    for t in SCAFFOLD_TEMPLATES
        managed_only && !t.managed && continue
        _ad_selected(t, ad) || continue
        _bench_selected(t, benchmarks) || continue
        from = joinpath(src_dir, t.src)
        isfile(from) || error("missing bundled template $(t.src) at $from")
        to = joinpath(target_dir, t.dest)
        exists = isfile(to)
        # Any managed file can be opted out of management by marking it
        # package-owned (#224), generalising the AD driver's original
        # file-specific opt-out (#162): the generic `test/ad/setup.jl` assumes
        # the package's ADFixtures registry satisfies the current `ADRegistry`
        # contract (`scenarios(; category=)`), so force-clobbering a
        # pre-contract adopter's hand-kept driver would `MethodError` every AD
        # test. When the committed file carries an ownership marker, preserve
        # it rather than overwriting — `scaffold`/`scaffold_generate`
        # (`force = true`) still (re)lays it down so a fresh package starts
        # managed. The marker lives in the file, so the opt-out is explicit and
        # visible to anyone reading it.
        #
        # The fresh render is passed in so a managed template that itself
        # carried the marker literal cannot hand every adopter a permanently
        # self-preserving file (see `_detect_managed_override`); the kit's own
        # tests also assert no template ships the marker.
        rendered = exists && !force && t.managed ?
                   _render(from, t.substitute, inputs) : nothing
        if rendered !== nothing &&
           _detect_managed_override(target_dir, t.dest, rendered)
            push!(preserved, to)
            continue
        end
        # A managed file that already diverges substantially from what a
        # fresh render would produce, with no ownership marker, is a strong
        # signal the adopter customised it and simply never added the
        # marker — silently force-overwriting it (the standard "managed
        # files always resync" rule) is exactly the footgun that nearly
        # broke CensoredDistributions' AD CI: a heavily customised
        # `test/ad/setup.jl` carrying no ownership marker was clobbered with
        # the generic driver, which would `MethodError` on every AD job. Warn
        # (rather than silently proceed) so a maintainer notices before the
        # next scheduled template-sync does this again; still overwrites,
        # matching every other managed file.
        #
        # This warning stays scoped to `test/ad/setup.jl` and is deliberately
        # not generalised to every managed file (#224). Divergence from a fresh
        # render is the normal state of a managed file on an adopter running an
        # older kit version, precisely what `scaffold_update` exists to fix, so
        # a generic divergence check cannot tell "the adopter customised this"
        # from "the adopter is simply behind" and would warn on every file on
        # every sync. The AD driver is the one file where a clobber is
        # silently fatal (a `MethodError` in every AD CI job) rather than merely
        # a resync, which is what earns it the noise. A package that genuinely
        # owns any other managed file says so with the
        # `$(_MANAGED_OVERRIDE_MARKER)` marker above, which needs no heuristic.
        if rendered !== nothing && t.dest == _AD_SETUP_DEST
            if read(to, String) != rendered
                msg = string(_AD_SETUP_DEST,
                    " differs from the managed driver but carries no ",
                    "ownership marker — overwriting. If this divergence is ",
                    "intentional, add a comment containing \"",
                    _MANAGED_OVERRIDE_MARKER,
                    "\" to keep it across future scaffold_update calls.")
                push!(warnings, msg)
                @warn msg
            end
        end
        # Package-owned files are written once and never overwritten (unless
        # `force`); managed files are always (re)written to remove drift.
        if exists && !t.managed && !force
            push!(preserved, to)
            continue
        end
        _emit(from, to, t.substitute, inputs)
        push!(exists ? updated : created, to)
    end
    # The README body is package-owned, but the standard badge block between the
    # markers is managed: inject it when absent, refresh it when present. Only
    # the marker region is touched. This is reported separately (`readme`) so the
    # template manifest stays template-driven.
    readme = joinpath(target_dir, "README.md")
    repo = inputs.REPO
    pkg = inputs.PACKAGE
    readme_action = :skipped
    if repo !== nothing && pkg !== nothing
        lic = String(inputs.LICENSE)
        readme_action = first(
            _apply_badges(readme, repo, pkg; ad = ad, license = lic,
            docs_url = inputs.DOCS_URL, doi = inputs.DOI,
            zenodo_badge = inputs.ZENODO_BADGE))
    end
    # The README title's inline logo tag is managed the same way as the badge
    # block: added once a `docs/src/assets/logo.svg` exists, left alone
    # otherwise. Reported separately for the same reason as `readme` above.
    logo_action = pkg === nothing ? :skipped : _apply_logo_title(target_dir, pkg)
    # The standard sections (Contributing / How to cite / Code of conduct) are
    # managed between markers, like the badge block: refreshed on every sync but
    # only within the markers, so a package's own body sections are preserved.
    # Reported separately (`standard_sections`) for the same reason as `readme`.
    sections_action = first(_apply_standard_sections(target_dir, inputs))
    # CITATION.cff is package-owned and write-once (like LICENSE): only
    # `scaffold`/`scaffold_generate` (`managed_only = false`) seed it, and only when
    # absent. `scaffold_update` (`managed_only = true`) never touches it, so a package's
    # real citation metadata (authors, DOI, version) is preserved. Reported
    # separately (`citation`) so the template manifest stays template-driven.
    citation_action = managed_only ? :skipped :
                      _apply_citation_cff(target_dir, inputs)
    # LICENSE is package-owned and write-once: only `scaffold`/`scaffold_generate`
    # (`managed_only = false`) may write it, and only when absent. `scaffold_update`
    # (`managed_only = true`) never touches it, so a deliberate licence stands.
    # Reported separately (`license`) so the template manifest stays
    # template-driven (the count-based scaffold tests track `SCAFFOLD_TEMPLATES`).
    license_action = managed_only ? :skipped : _apply_license(target_dir, inputs)
    # The standard `[workspace]` stanza is injected into the (package-owned) root
    # Project.toml when absent, on both scaffold and scaffold_update, and preserved
    # thereafter. Reported separately so the template manifest stays
    # template-driven.
    workspace_action = _apply_workspace(target_dir)
    # `.gitignore` is managed between markers so package-owned additions below
    # the block survive `scaffold_update` (#65). Reported separately for the same
    # reason as `readme`/`license`/`workspace` above.
    gitignore_action = first(_apply_gitignore(target_dir, inputs))
    # Managed files the kit has retired are deleted, not just left unwritten, so
    # a sync converges on the current standard rather than accreting dead infra
    # (#185). Reported as `removed`.
    removed = _remove_retired(target_dir)
    # The org logo asset follows the same `ORG_BRANDING` opt-in as the README
    # section and the docs footer: written when on, removed when off, so a
    # package that opts out carries no EpiAware asset (#242). Reported
    # separately, like `license`/`logo`, so the template manifest stays
    # template-driven.
    org_branding_action = _apply_org_branding(target_dir, org_branding)
    return (created = created, updated = updated, preserved = preserved,
        removed = removed, readme = readme_action, license = license_action,
        workspace = workspace_action, gitignore = gitignore_action,
        logo = logo_action, standard_sections = sections_action,
        citation = citation_action, org_branding = org_branding_action,
        warnings = warnings)
end

"""
    scaffold(target_dir; force = false, ad = true, benchmarks = nothing,
        kwargs...)

Adopt the standard EpiAware package tooling in `target_dir` (a package root).

Writes the shipped standard configuration and test infrastructure so a package
adopts the whole kit in one call. Two kinds of file are written:

  - managed standard infra — always written (overwriting any existing copy):
    root dev config (`Taskfile.yml`, `.pre-commit-config.yaml`,
    `.JuliaFormatter.toml`, `.gitattributes`, `.secrets.baseline`,
    `codecov.yml`), CI
    caller workflows + `.github/dependabot.yml` (which invoke the org reusables,
    including the opt-in per-backend `ad.yaml` matrix), and the test-infra
    drivers and
    isolated-env manifests (`test/package/quality.jl`, `test/jet/runtests.jl` +
    `test/jet/Project.toml`, `test/formatter/runtests.jl` +
    `test/formatter/Project.toml`, `test/ad/setup.jl`, `test/ad/runtests.jl`,
    `benchmark/run.jl`, `benchmark/compare.jl`).
  - package-owned skeletons — written only when absent, never overwritten:
    `test/runtests.jl`, `test/Project.toml` (the test env), `test/package/
    qa_config.jl` (the QA config values the managed testset reads), `LICENSE`
    (the `license`-selected licence text — see below), `NEWS.md` (the
    hybrid-changelog seed), `docs/src/assets/logo.svg` (a placeholder logo —
    see the `logo` return value below), `test/ad/scenarios.jl` +
    `test/ad/Project.toml`, an `ADFixtures` registry skeleton implementing the
    `ADRegistry` contract (`test/ADFixtures/Project.toml` +
    `src/ADFixtures.jl`), `benchmark/benchmarks.jl` (the `SUITE`), and
    `CITATION.cff` (the citation metadata the managed "How to cite" README
    section points at — see the `citation` return value below). These
    are where a package's own unit tests, AD scenarios, registry, citation, and
    config values live.

The README body is package-owned, but three standard sections — Contributing,
How to cite, and Code of conduct — are managed between the
`<!-- standard-sections:start -->`/`:end` markers and refreshed on every sync
(like the badge block), so their wording stays consistent across adopters. The
citation *content* stays package-owned in `CITATION.cff`; the managed "How to
cite" section only points at it.

Placeholders (`{{PACKAGE}}`, `{{AUTHORS}}`, `{{HOLDER}}`, `{{ORG}}`, `{{REPO}}`,
`{{REVIEWER}}`, `{{YEAR}}`) are filled by [`scaffold_inputs`](@ref): each
defaults from the target `Project.toml` or a sensible org default and is
overridable by keyword (e.g. `scaffold(dir; org = "MyOrg")`). No person, org, or
repo name is hardcoded in any template.

`LICENSE` is package-owned and write-once: the `license` keyword (an SPDX id,
one of `$(join(SUPPORTED_LICENSES, ", "))`, default `$(repr(DEFAULT_LICENSE))`)
selects the bundled licence text, written with `{{YEAR}}`/`{{HOLDER}}` filled
only when no `LICENSE` exists. [`scaffold_update`](@ref) never rewrites it, so a package
that deliberately changes its licence is not reverted on a sync.

The managed `.github/workflows/Register.yml` triggers Julia General Registry
registration: a `/register` comment on an issue or PR, or a manual
`workflow_dispatch` run, both post `@JuliaRegistrator register` on `main`'s
HEAD commit (gated on the actor having write/maintain/admin access). See
[`setup_checklist`](@ref) for the rest of the one-off manual setup a fresh
repo needs (Codecov, GitHub Pages, branch protection, ...).

`ad` controls whether the AD CI caller and AD test infrastructure are
scaffolded, so a numerical package opts in and a tooling/non-numerical package
opts out. It defaults to `true` (the common case for an EpiAware modelling
package). When `ad = true` the managed AD-backends tutorial page
(`docs/src/getting-started/tutorials/ad-backends.jl`, generalised from
CensoredDistributions.jl) is also written: its body stays kit-current across
syncs while the scenarios, backends, and broken/skip declarations it reports
are read at docs-build time from the package-owned `test/ADFixtures` registry
(rendered via [`ad_backend_support_table`](@ref)), and its registration plus
docs-env deps are seeded into the package-owned `docs/docs_config.jl`,
`docs/pages.jl`, and `docs/Project.toml`. When `ad = false`, none of the AD
infra is written — no `.github/workflows/ad.yaml`, no `test/ad/` drivers,
scenarios, or env, no `test/ADFixtures/` registry skeleton, no AD-backends
docs page — and the files whose content depends on AD (`Taskfile.yml`,
`codecov.yml`, `test/Project.toml`, and the docs seeds above) are emitted in
their no-AD variants (no `test-ad` tasks, no per-backend `ad-*` coverage
flags, no AD test/docs deps). Pass the same `ad` value to
[`scaffold_update`](@ref) to keep the standard stable.

`benchmarks` controls the opt-in benchmark suite: the benchmark CI callers
(`.github/workflows/benchmark.yaml`, `benchmark-history.yaml`), the `benchmark/`
suite + compare script, and the docs benchmark page (its nav entry, the
package-owned `docs/benchmarks.md` prose hook, and the package-owned
`docs/benchmarks_notes.md` skipped/broken-benchmarks hook, gated by
`docs_config`'s `BENCHMARK_PAGE`). It defaults to `nothing`, which detects
the target's current state from the benchmark workflows so re-scaffolding
preserves an opt-in; a
fresh package has none, so the default is opt-out. When disabled, none of the
benchmark files are written and the docs emit no Benchmarks page. Pass
`benchmarks = true` to opt in; [`scaffold_update`](@ref) detects and preserves the state.

`downgrade_compat` controls the opt-in `downgrade-compat` CI job in
`.github/workflows/test.yaml` (the `julia-downgrade-compat` reusable, which
resolves the oldest compatible dep versions). A package pinned to a Julia floor
— or one depending on an unregistered, `[sources]`-pinned package that the
downgrade resolver cannot see — can never pass that job, so it opts out. It
defaults to `nothing`, which detects the target's current state from the
committed `test.yaml` so a resync preserves the choice; a fresh package keeps
the job (the standard). Pass `downgrade_compat = false` to drop it (#121); the
`test`/`downgrade` `julia_versions` inputs are separately preserved as a
package-owned `with:` override (see `_preserve_caller_with_inputs`).

The README body is package-owned, but the standard badge set is managed: a block
between `$(BADGES_START)` / `$(BADGES_END)` markers carries the docs/CI/coverage/
quality/license badges (plus per-backend AD CI + coverage badges when
`ad = true`), parameterised from `{{REPO}}`/`{{PACKAGE}}` (no owner/repo
hardcoded). The block is injected after the README's `# ` title when the markers
are absent and refreshed in place when present; nothing outside the markers is
touched. A missing README is created with a title and the block.

`.gitignore` follows the same managed-block pattern: the standard ignore rules
live between `$(GITIGNORE_START)` / `$(GITIGNORE_END)` markers and are
(re)rendered on every scaffold/scaffold_update, but anything after the end marker is a
package-owned tail that is never touched — add your own ignore rules there. A
pre-existing `.gitignore` with no markers (e.g. one written by a kit version
before this behaviour existed) is treated the same way a legacy README is:
the managed block is inserted at the top and the whole existing file is kept
below as the tail, so nothing a package added is ever silently dropped.

`docs_subdomain` selects how the docs site is hosted. The default (`nothing`) is
a GitHub project-pages deploy: `docs/make.jl` gets `deploy_url = nothing`, so
DocumenterVitepress derives the VitePress base from the repo name and the site
renders at `epiaware.org/<Repo>.jl/` with no DNS to wire — the docs work out of
the box. Pass `docs_subdomain = true` for the conventional `<pkg>.epiaware.org`,
or a host string for a bespoke domain, to deploy at a custom subdomain instead;
this sets `deploy_url` to that host and points the README docs badges at it. A
custom subdomain also needs a DNS record for the host and the repo's GitHub
Pages custom domain set (which writes the gh-pages `CNAME`); until both exist
the site will not resolve, so the project-pages default is preferred unless
that wiring is in place. When no explicit choice is passed, the hosting is
recovered from the repo's existing `docs/make.jl` `deploy_url`, so
[`scaffold_update`](@ref) preserves a subdomain-hosted package (and self-heals a
drifted one) without the maintainer re-supplying `docs_subdomain` on every
sync (#123). Only a never-scaffolded target falls back to the default: the kit
itself dogfoods the opt-in path, defaulting to its own DNS-wired subdomain
(`epiawarepackagetools.epiaware.org`), so its dogfood `scaffold_update` stays stable.

The three managed README sections (Contributing, How to cite, Code of conduct)
follow the same managed-block pattern between
`$(STANDARD_SECTIONS_START)` / `$(STANDARD_SECTIONS_END)` markers: appended to a
freshly seeded README and refreshed in place thereafter. A marker-less README
that already carries a bespoke Contributing/citation/Code-of-conduct section is
left untouched — migrating it to the managed block is a deliberate per-repo
wording change (#67). `CITATION.cff` is package-owned and write-once, seeded
from `{{PACKAGE}}`/`{{AUTHORS}}`/`{{REPO}}` (and the DOI when known); `scaffold_update`
never rewrites it, so the real author list and DOI stand.

`force = true` overwrites the package-owned skeletons too, and lays every
managed file down fresh regardless of any `$(_MANAGED_OVERRIDE_MARKER)` marker
(see [`scaffold_update`](@ref)), so a new package always starts fully managed.
`target_dir` must exist. Use [`scaffold_update`](@ref) to re-apply only the
managed files later.

Returns a `(created, updated, preserved, removed, readme, license, workspace,
gitignore, logo, standard_sections, citation, warnings)` named tuple:
destination paths newly written, managed files overwritten, package-owned
files left in place, retired managed paths deleted (`RETIRED_PATHS`, #185),
the README badge action (`:created`, `:injected`, `:refreshed`, or
`:skipped`), the `LICENSE` action, the root `[workspace]` stanza action
(`:injected`, `:preserved`, or `:skipped`), the `.gitignore` managed-block
action (`:created`, `:injected`, or `:refreshed`), the README logo-title
action (`:injected`, `:preserved`, or `:skipped` when no logo file exists
yet), the managed standard-sections action (`:refreshed`, `:injected`, or
`:skipped`), the `CITATION.cff` action (`:created`, `:preserved`, or
`:skipped`), and non-fatal `warnings` raised while applying (a
`Vector{String}`).
"""
function scaffold(target_dir::AbstractString; force::Bool = false,
        ad::Bool = true, benchmarks::Union{Nothing, Bool} = nothing,
        downgrade_compat::Union{Nothing, Bool} = nothing,
        kwargs...)
    inputs = scaffold_inputs(target_dir; kwargs...)
    bench = benchmarks === nothing ? _detect_benchmarks(target_dir) : benchmarks
    dg = downgrade_compat === nothing ?
         _detect_downgrade_compat(target_dir) : downgrade_compat
    return _apply(target_dir; managed_only = false, force = force, ad = ad,
        benchmarks = bench, downgrade_compat = dg, inputs = inputs)
end

"""
    scaffold_update(target_dir; ad = true, benchmarks = nothing,
        downgrade_compat = nothing, kwargs...)

Re-apply only the managed standard files to an already-adopted package and
report the drift.

This is the entry point the scheduled template-sync workflow calls: it rewrites
every managed standard file (root config, CI caller workflows, dependabot, and
the test-infra drivers) from the bundled templates, leaving all package-owned
files (unit tests, `qa_config.jl`, AD scenarios, `benchmarks.jl`, and `LICENSE`)
untouched. In particular `LICENSE` is never rewritten, so a package that
deliberately switches licence is not silently reverted. The workflow opens a PR
when the result differs from what is committed. Placeholder inputs are resolved
exactly as in [`scaffold`](@ref); pass the same overrides to keep substitution
stable across a sync.

`ad` must match the value the package was scaffolded with (default `true`): with
`ad = false` the managed AD files (`ad.yaml`, `test/ad/setup.jl`,
`test/ad/runtests.jl`) are not managed and the no-AD variants of `Taskfile.yml`
and `codecov.yml` are re-applied instead.

`benchmarks` controls the opt-in benchmark CI + suite. It defaults to `nothing`,
which detects the package's current state from the managed benchmark workflows
(`benchmark.yaml` / `benchmark-history.yaml`) so a resync preserves an adopter's
benchmarks rather than stripping them — the scheduled template-sync bakes the
adopted value into its own `scaffold_update` call, but a repo scaffolded before this flag
re-passes nothing, so detection is what keeps that first sync idempotent. Pass
`benchmarks = true`/`false` to force enable/disable.

`downgrade_compat` controls the opt-in `downgrade-compat` CI job the same way:
it defaults to `nothing`, detecting the job's presence in the committed
`test.yaml` so a resync preserves a package's decision to drop it (#121) rather
than reintroducing a job it deliberately removed. Pass
`downgrade_compat = true`/`false` to force keep/drop.

The README's managed badge block is also refreshed: `scaffold_update` injects it when the
`$(BADGES_START)` / `$(BADGES_END)` markers are absent and re-renders it from the
current placeholders when present, so a package gets and keeps the standard
badges automatically without its README body being touched.

The managed `.gitignore` block is handled the same way: refreshed between its
markers (or migrated in place if a pre-existing file has none yet), with any
package-owned tail after the block left untouched.

The README logo title (see `scaffold`) is also (re)checked: once a package has
a `docs/src/assets/logo.svg`, the tag is added to the title if missing.

Every managed file written from a template has a package-owned opt-out (#224).
Putting the marker `$(_MANAGED_OVERRIDE_MARKER)` in a comment in the committed
file tells `scaffold_update()` to preserve it (leaving it in `preserved`)
instead of resyncing it, so a package keeps its own version of that file; remove
the marker to hand management back to the kit. `scaffold`/`scaffold_generate`
(`force = true`) ignore the marker and lay the managed file down fresh, so a new
package always starts managed. Use the marker sparingly: an overridden file no
longer tracks the standard, which is the whole point of the kit.

Three limits on the marker, all deliberate:

  - It covers whole files emitted from a template, not the marker-delimited
    *regions* the kit injects into otherwise package-owned files. The
    `.gitignore` managed block, the README badge and standard-sections blocks,
    and `Project.toml`'s `[workspace]` stanza are refreshed on every sync
    regardless of any `$(_MANAGED_OVERRIDE_MARKER)`; a package customises those
    by editing outside their markers, which is what the markers are for.
  - It opts a file out of resyncing, not out of retirement: a marked file whose
    path the kit has retired (`RETIRED_PATHS`, below) is still deleted, since a
    retired path is infrastructure the kit no longer supports at all.
  - The marker must appear in a comment, so the two managed JSON files
    (`docs/package.json`, `.secrets.baseline`) cannot carry it — JSON has no
    comment syntax — and cannot be overridden this way. The match is
    case-sensitive: `$(_MANAGED_OVERRIDE_MARKER)`, in capitals, or it does
    nothing.

The AD-harness driver `test/ad/setup.jl` is where this began (#162): the generic
driver assumes the package's `ADFixtures` registry satisfies the current
`ADRegistry` contract (its `scenarios` accepts a `category` keyword), so a
package whose registry predates that contract would `MethodError` on every AD
test if the driver were overwritten. That file still honours its original marker
`$(_AD_SETUP_OWNED_MARKER)` as well as the generic one; either preserves it.
When the committed driver has diverged from the managed one but carries no
marker — a strong signal it was customised and the marker just never got
added — `scaffold_update()` still overwrites it (managed files always
resync) but records a message in `warnings` (and emits `@warn`) rather than
clobbering it silently. That divergence warning is deliberately scoped to
`test/ad/setup.jl`, the one file whose clobber is silently fatal: divergence
from a fresh render is the normal state of any managed file on an adopter simply
running an older kit version, so a generic divergence check would fire on every
sync and mean nothing. Mark a file you own instead.

Managed files the kit has retired (`RETIRED_PATHS`) are deleted, so a sync
converges on the current standard instead of leaving dead infra behind (#185).

Returns a `(created, updated, preserved, removed, readme, license, workspace,
gitignore, logo, warnings)` named tuple: managed files newly added, managed
files rewritten, preserved files, retired paths deleted, the README badge
action, the `LICENSE` action (`:skipped` on scaffold_update), the root
`[workspace]` stanza action, the `.gitignore` managed-block action, the
README logo-title action, and non-fatal warnings raised while applying (a
`Vector{String}`).
"""
function scaffold_update(target_dir::AbstractString; ad::Bool = true,
        benchmarks::Union{Nothing, Bool} = nothing,
        downgrade_compat::Union{Nothing, Bool} = nothing, kwargs...)
    inputs = scaffold_inputs(target_dir; kwargs...)
    bench = benchmarks === nothing ? _detect_benchmarks(target_dir) : benchmarks
    dg = downgrade_compat === nothing ?
         _detect_downgrade_compat(target_dir) : downgrade_compat
    return _apply(target_dir; managed_only = true, force = false, ad = ad,
        benchmarks = bench, downgrade_compat = dg, inputs = inputs)
end

# Write a minimal package skeleton (Project.toml + src/<Package>.jl) into
# `target_dir`, so a fresh package has the source files `scaffold` needs to
# substitute placeholders from. Returns nothing.
function _emit_package_skeleton(target_dir::AbstractString, package::AbstractString,
        uuid::AbstractString, authors_array::AbstractString)
    mkpath(joinpath(target_dir, "src"))
    proj = joinpath(target_dir, "Project.toml")
    write(proj, """
    name = "$package"
    uuid = "$uuid"
    authors = $authors_array
    version = "0.1.0"

    [deps]
    DocStringExtensions = "ffbed154-4ef7-542d-bbb7-c09d3a79fcae"

    [compat]
    DocStringExtensions = "0.9"
    julia = "1.10, 1.11, 1.12"
    """)
    write(joinpath(target_dir, "src", "$package.jl"), """
    \"\"\"
        $package

    A fresh EpiAware package. Replace this skeleton with the package's API.

    # Example

    ```@example
    using $package
    ```
    \"\"\"
    module $package

    # All genuine module-scope `using`/`import` statements live here, in
    # the main module file, rather than scattered across included files.
    using DocStringExtensions: @template, DOCSTRING, EXPORTS, IMPORTS,
                               TYPEDEF, TYPEDFIELDS, TYPEDSIGNATURES

    # Register the standard EpiAware docstring conventions before any
    # docstrings are defined (see src/docstrings.jl).
    include("docstrings.jl")

    end # module $package
    """)
    return nothing
end

"""
    scaffold_generate(target_dir, package; authors = String[], uuid = <fresh>,
        ad = true, benchmarks = false, kwargs...)

Generate a fresh package at `target_dir` and adopt the standard tooling.

Creates the target directory if needed, writes a minimal package skeleton (a
`Project.toml` naming `package` with a fresh UUID, and a `src/<package>.jl`
module stub), then runs [`scaffold`](@ref) over it so the new package starts
fully managed. Unlike [`scaffold`](@ref) — which adopts the tooling into an
existing package — `scaffold_generate` also lays down the package's own `Project.toml`
and source module, so it works from an empty (or non-existent) directory.

  - `package` — the package name (no `.jl` suffix).
  - `authors` — author entries (a `Vector{String}`); written to the new
    `Project.toml` and used for `{{AUTHORS}}`/`{{HOLDER}}` substitution.
  - `uuid` — the package UUID; a fresh `uuid4()` by default.
  - `ad` — forwarded to [`scaffold`](@ref): `true` (default) scaffolds the AD
    infra, `false` opts out. See [`scaffold`](@ref) for the full AD-opt-in
    behaviour.
  - `benchmarks` — forwarded to [`scaffold`](@ref): opt into the benchmark CI +
    suite + docs page. A fresh package has no benchmark workflows to detect, so
    this defaults to `false` (opt-out); pass `benchmarks = true` to enable.

Remaining keyword arguments (`org`, `repo`, `reviewer`, `year`, `license`, ...)
are forwarded to [`scaffold_inputs`](@ref); e.g. `license = "Apache-2.0"` writes
the Apache licence. Returns the `scaffold` manifest.
"""
function scaffold_generate(target_dir::AbstractString, package::AbstractString;
        authors::AbstractVector{<:AbstractString} = String[],
        uuid::AbstractString = string(UUIDs.uuid4()),
        ad::Bool = true, benchmarks::Bool = false, kwargs...)
    mkpath(target_dir)
    authors_array = "[" * join(("\"" * a * "\"" for a in authors), ", ") * "]"
    _emit_package_skeleton(target_dir, package, uuid, authors_array)
    return scaffold(target_dir; ad = ad, benchmarks = benchmarks, kwargs...)
end
