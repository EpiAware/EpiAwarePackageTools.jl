# Scaffolder for the standard EpiAware package tooling. Writes/updates the
# SHIPPED standard configuration and test infrastructure into a package so it
# adopts (and stays in sync with) the kit in one call. The templates live in
# `templates/` at this package's root and are the single source of truth.
#
# Each template is either MANAGED (the standard infra: re-applied on update,
# overwritten to remove drift) or PACKAGE-OWNED (a starting skeleton written
# once and never touched again — the package's unit tests, AD scenarios, and
# QA config values live here). `scaffold` adopts; `update` re-applies only the
# managed files. Both return a manifest distinguishing what was created,
# updated, or preserved.
#
# No person, org, or repository name is baked into a template. Every such value
# is a `{{PLACEHOLDER}}` filled from `scaffold`/`update` inputs, which default
# to reading the target package's `Project.toml` (name, authors) and a sensible
# org default. A caller can override any of them by keyword.

using Test: @testset, @test
import Dates
import UUIDs

# A template entry. `src` is the path under `templates/`; `dest` the path under
# the target package root (usually equal). `managed = true` means standard
# infra (overwritten on update); `false` a package-owned skeleton (write once).
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
#                     callers, the `benchmark/` suite + comment harness, and the
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
    Template(".pre-commit-config.yaml", ".pre-commit-config.yaml", true, false),
    Template(".JuliaFormatter.toml", ".JuliaFormatter.toml", true, false),
    Template(".gitattributes", ".gitattributes", true, false),
    # NOTE: `.gitignore` is NOT in this list. It is managed between markers
    # (see `_apply_gitignore`) so a package's own ignore-rule additions below
    # the managed block survive `update`, rather than being copied verbatim
    # and clobbered on the next sync (#65).
    Template(".secrets.baseline", ".secrets.baseline", true, false),
    Template("codecov.yml", "codecov.yml", true, true, :ad_only),
    Template("codecov.noad.yml", "codecov.yml", true, false, :noad_only),
    # NOTE: `LICENSE` is NOT a managed template. It is written once from the
    # `license` input (see `_apply_license`) and never overwritten by `update`,
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
    Template(".github/workflows/downstream.yaml",
        ".github/workflows/downstream.yaml", true, true),
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
    # CensoredDistributions.jl benchmark CI. Both call AirspeedVelocity and build
    # the comment via the shared `Benchmarks` harness (see `benchmark/comment`).
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
    # PULL_REQUEST_TEMPLATE, CONTRIBUTING/CODE_OF_CONDUCT/SUPPORT) are NOT
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
    Template("test/formatter/Project.toml",
        "test/formatter/Project.toml", true, false),
    # The AD harness drivers are opt-in (managed, but only when `ad = true`).
    Template("test/ad/setup.jl", "test/ad/setup.jl", true, false, :ad_only),
    Template("test/ad/runtests.jl", "test/ad/runtests.jl", true, false,
        :ad_only),
    # The benchmark suite drivers are opt-in (managed, only when
    # `benchmarks = true`).
    Template("benchmark/run.jl", "benchmark/run.jl", true, false, :always,
        :bench_only),
    Template("benchmark/compare.jl", "benchmark/compare.jl", true, false,
        :always, :bench_only),
    # The benchmark-comment job's thin script + isolated env (it calls
    # `Benchmarks.asv_comment`); used by `benchmark.yaml`.
    Template("benchmark/comment/comment.jl",
        "benchmark/comment/comment.jl", true, false, :always, :bench_only),
    Template("benchmark/comment/Project.toml",
        "benchmark/comment/Project.toml", true, true, :always, :bench_only),

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

    # --- package-owned skeletons (written once, never overwritten) ---
    # The standard DocStringExtensions `@template` conventions. Package-owned
    # because it lives in `src/` and must be `include`d by the package module
    # BEFORE its docstrings are defined for the templates to take effect (see
    # CensoredDistributions.jl `src/docstrings.jl`).
    Template("src/docstrings.jl", "src/docstrings.jl", false, false),
    Template("docs/Project.toml", "docs/Project.toml", false, true),
    # Substituted so the benchmark nav entry (`{{BENCHMARKS_NAV}}`) is present
    # only when `benchmarks = true`; package-owned so a package extends the tree.
    Template("docs/pages.jl", "docs/pages.jl", false, true),
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
    Template("test/ad/scenarios.jl", "test/ad/scenarios.jl", false, false,
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

# The default org used to derive `{{ORG}}`/`{{REPO}}` when a caller does not
# pass them. This is the only org default in the kit; it is overridable.
const DEFAULT_ORG = "EpiAware"

# The kit's own name + UUID, used to source it into the managed JET env for an
# adopting package. When the adopting package IS the kit (it dogfoods itself),
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

# The template default for the tutorial subdir (see `templates/docs/
# docs_config.jl`), used when a target has no `docs_config.jl` yet.
const _DEFAULT_TUTORIALS_SUBDIR = "getting-started/tutorials"

# Read `TUTORIALS_SUBDIR` from the package-owned `docs/docs_config.jl`: the
# subdir (relative to `docs/src`) holding the Literate tutorial sources and
# their rendered `.md` pages. The managed `.gitignore` ignores those rendered
# pages, so the ignore must track whatever path the package configures rather
# than hardcode one. The const is written as a quoted string or a
# `joinpath("a", "b")` of quoted segments; join every quoted segment with `/`
# (the gitignore separator). Falls back to the template default when the config
# is absent (e.g. at first scaffold, before it is written) or omits the const.
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

# Recover a persisted reviewer handle from an already-scaffolded repo so a resync
# (`update` with no `reviewer` kwarg) keeps it instead of reverting to the org
# placeholder (#72). CODEOWNERS and the Dependabot `reviewers` block are MANAGED
# (re-emitted on every sync), and the scheduled template-sync never re-passes
# `reviewer`, so the handle must be read back from the destination — exactly as
# `_preserve_reusable_refs` reads existing reusable-workflow refs to stay
# idempotent against Dependabot SHA bumps. The destination is the source of
# truth. Reads the active (uncommented) CODEOWNERS owner line the kit renders
# from the handle and returns its first `@handle` (the leading `@` stripped, an
# `org/team` slug kept whole), or `nothing` when CODEOWNERS is absent or carries
# only the commented placeholder (so a never-configured repo stays unconfigured).
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
    scaffold_inputs(target_dir; package = nothing, authors = nothing,
        holder = nothing, org = $(repr(DEFAULT_ORG)), repo = nothing,
        reviewer = nothing, year = <current year>,
        license = $(repr(DEFAULT_LICENSE))) -> NamedTuple

Resolve the placeholder substitution values for [`scaffold`](@ref) /
[`update`](@ref).

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
    written once and never overwritten by [`update`](@ref) so a deliberate
    licence is never reverted.
  - `doi` / `zenodo_badge` — an optional Zenodo DOI and badge id; when both are
    given a DOI badge is added to the README "License & DOI" cell (mirroring
    CensoredDistributions.jl). Default `nothing` (no DOI badge).

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
        zenodo_badge::Union{Nothing, AbstractString} = nothing)
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
    # `org/team` slug) is required — GitHub cannot assign a BARE org, so when no
    # handle is given those owners are left empty (with a note) rather than
    # producing PRs that error with "can't assign <org> as a reviewer".
    # When no `reviewer` is passed, recover any handle a previous scaffold/update
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
    yr = year === nothing ? Dates.year(Dates.now()) : year
    uuid = _project_string(proj, "uuid")
    # A fresh UUID for the seeded ADFixtures registry skeleton (a new path
    # package). Generated once per call; the author keeps it thereafter.
    adfix_uuid = string(UUIDs.uuid4())
    # How the docs site is hosted. The DEFAULT (`docs_subdomain = nothing`) is
    # a GitHub project-pages deploy: `deploy_url = nothing`, so
    # DocumenterVitepress derives the VitePress base from the repo name and the
    # site renders at `epiaware.org/<Repo>.jl/` with NO DNS to wire. Opting into
    # a custom subdomain (`docs_subdomain = true` for the conventional
    # `<pkg>.epiaware.org`, or a string for a bespoke host) sets `deploy_url` to
    # that host, which then needs a DNS record and the repo's GitHub Pages
    # custom domain (see the `docs_subdomain` note in `scaffold`).
    # `DOCS_DEPLOY_URL` is the `deploy_url` Julia literal substituted into
    # `docs/make.jl`; `DOCS_URL` is the bare host(+path) for the README badges.
    #
    # The KIT ITSELF dogfoods the opt-in path: its custom subdomain
    # (`epiawarepackagetools.epiaware.org`) is DNS-wired, so when no explicit
    # choice is passed and the adopting package is the kit, default to the
    # subdomain. This keeps the kit's own deploy on base `/` (correct at the
    # subdomain root) while every other package still defaults to project-pages.
    ds = docs_subdomain === nothing && pkg == KIT_NAME ? true : docs_subdomain
    docs_sub = _resolve_docs_subdomain(ds, pkg)
    docs_deploy_url = _docs_deploy_url(docs_sub)
    docs_url = _docs_url(rp, docs_sub)
    # The managed JET env depends on EpiAwarePackageTools (for its report
    # filter). The kit dogfoods itself, so when the ADOPTING package IS the kit
    # the `{{PACKAGE}}` dep/source already cover it — adding a second
    # EpiAwarePackageTools dep (and a git source clashing with the path source)
    # would make a duplicate/invalid env. These placeholders emit the kit dep +
    # git source for every OTHER package, and nothing for the kit itself.
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
    # `update(".")`. The kit dogfoods itself, so when the adopting package IS
    # the kit it syncs from its OWN checked-out project; every other package
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
        DOI = doi, ZENODO_BADGE = zenodo_badge,
        TUTORIALS_SUBDIR = tutorials_subdir, AD_BUILD_COUNT = ad_build_count,
        CODEOWNERS_LINE = codeowners_line,
        DEPENDABOT_REVIEWERS = dependabot_reviewers,
        KIT_DEP_LINE = kit_dep,
        KIT_SOURCE_LINE = kit_source, SYNC_INSTALL = sync_install)
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
            "scaffold/update or set the target Project.toml")
        content = replace(content, token => val)
    end
    return content
end

# A reusable-workflow `uses:` line in a managed CI caller, capturing the prefix
# up to and including the `@`, the workflow filename, and the pinned ref. The
# EpiAware/.github reusables are pinned by ref (a SHA), which Dependabot bumps in
# each adopting repo. See `_preserve_reusable_refs`.
const _REUSABLE_USES = r"(uses:\s*\S+/\.github/\.github/workflows/([^@\s]+)@)(\S+)"

# Keep the destination's existing reusable-workflow refs when re-emitting a
# managed CI caller. Dependabot owns the EpiAware/.github reusable SHAs in every
# adopting repo, so a template that hard-pinned one SHA would report drift (and
# fail self-drift / churn the scheduled sync) every time Dependabot moved the
# live pin. When the destination already pins a ref for the same reusable
# workflow, that ref wins and only the rest of the caller body is re-applied
# from the template; on first adoption (no destination yet) the template's seed
# ref is used. This makes `update` idempotent against Dependabot's bumps.
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

# Copy one template to `to`, substituting placeholders when requested. Managed
# CI callers additionally keep any reusable-workflow ref the destination already
# pins (see `_preserve_reusable_refs`), so a Dependabot bump is never reverted.
function _emit(from::AbstractString, to::AbstractString, substitute::Bool,
        inputs::NamedTuple)
    mkpath(dirname(to))
    if substitute
        content = _substitute(read(from, String), inputs, from)
        content = _preserve_reusable_refs(content, to)
        write(to, content)
    else
        cp(from, to; force = true)
    end
    return nothing
end

# --- package-owned LICENSE (write-once) -----------------------------------
#
# LICENSE is PACKAGE-OWNED: the `license` input selects a bundled
# `templates/LICENSE.<spdx>`, which `scaffold`/`generate` write once with
# `{{YEAR}}`/`{{HOLDER}}` filled. `update` never touches it, so a package that
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
# inputs on every scaffold/update, so an adopting package gets and keeps the
# standard badges automatically. Nothing outside the markers is touched.

const BADGES_START = "<!-- badges:start -->"
const BADGES_END = "<!-- badges:end -->"

# The per-backend AD jobs, as (badge label, column header, workflow/flag slug)
# triples. The badge label is the `AD <label>` / `cov <label>` alt text; the
# column header is the table heading (matching CensoredDistributions.jl, which
# labels the tape-based ReverseDiff column explicitly). Both match the `ad-*`
# codecov flags and the org `ad.yml` backend matrix.
const _AD_BACKENDS = [
    ("ForwardDiff", "ForwardDiff", "ad-forwarddiff"),
    ("ReverseDiff", "ReverseDiff (tape)", "ad-reversediff"),
    ("Enzyme forward", "Enzyme forward", "ad-enzyme-forward"),
    ("Enzyme reverse", "Enzyme reverse", "ad-enzyme-reverse"),
    ("Mooncake reverse", "Mooncake reverse", "ad-mooncake-reverse"),
    ("Mooncake forward", "Mooncake forward", "ad-mooncake-forward")
]

# The conventional custom-subdomain docs host for a package, e.g.
# `MyPkg` -> `mypkg.epiaware.org`. Only used on the opt-in subdomain path
# (`docs_subdomain = true`); the default project-pages path needs no host.
_docs_host(pkg::AbstractString) = lowercase(pkg) * ".epiaware.org"

# The GitHub Pages domain the org serves project-pages from. A repo without a
# custom domain is reachable at `<this>/<Repo>.jl/`.
const DOCS_PAGES_APEX = "epiaware.org"

# Resolve the `docs_subdomain` input to either `nothing` (project-pages, the
# default) or a concrete host string. `true` selects the conventional
# `<pkg>.epiaware.org`; a string is taken verbatim; `nothing`/`false` opt out.
# The Bool and Nothing cases dispatch to their own methods so the `String`
# conversion only ever runs on a genuine string input (keeps JET type-stable —
# `String(::Bool)` has no method and would otherwise show as a possible error).
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

# Render the standard badge block (without the markers) from resolved inputs.
# `repo` is the `owner/name.jl` slug; `pkg` the package name; `ad` adds the
# per-backend AD CI + coverage badge table; `license` is the SPDX id whose badge
# is shown. `doi`/`zenodo_badge` add a Zenodo DOI badge when both are given. The
# layout matches CensoredDistributions.jl: a five-column header table
# (Documentation, Build Status, Code Quality, License & DOI, Downloads) plus the
# per-backend AD table. No owner/repo is hardcoded — every URL is built from
# `repo`/`pkg`.
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
        # Per-backend AD COVERAGE flags (one codecov upload per backend from the
        # aggregate ad.yaml matrix). No per-backend *status* badges: only the
        # aggregate ad.yaml exists, so per-backend status URLs would 404 — the
        # single aggregate AD status badge lives in the Build Status cell above.
        headers = join((h for (_, h, _) in _AD_BACKENDS), " | ")
        sep = "|" * join((":---:" for _ in _AD_BACKENDS), "|") * "|"
        cov_badges = join(
            ["[![cov $alt]($cov/graph/badge.svg?flag=$slug)]" *
             "(https://app.codecov.io/gh/$repo?flags%5B0%5D=" *
             "$slug)" for (alt, _, slug) in _AD_BACKENDS],
            " | ")
        push!(lines, "")
        push!(lines, "| " * headers * " |")
        push!(lines, sep)
        push!(lines, "| " * cov_badges * " |")
    end
    return join(lines, "\n")
end

# Inject or refresh the managed badge block in a README. If the markers are
# present, the content between them is replaced; otherwise the block is inserted
# just after the first `# ` H1 title (or at the top when there is no title).
# Content outside the markers is never touched. Returns `(action, changed)`
# where action is `:created`/`:injected`/`:refreshed` and `changed` is whether
# the file content changed.
# A starter README body for a package that has none yet, following the section
# structure of CensoredDistributions.jl (Why / Getting started / Where to learn
# more / Supporting and citing / Contributing / Code of conduct), parameterised
# from the repo slug, package name, and docs host. Only seeded when no README
# exists; thereafter the body is package-owned and only the badge block is
# managed.
function _seed_readme_body(repo::AbstractString, pkg::AbstractString,
        docs_url::Union{Nothing, AbstractString})
    host = docs_url === nothing ? _docs_url(repo, nothing) : docs_url
    org = first(split(repo, '/'))
    stable = host === nothing ? nothing : "https://" * host * "/stable/"
    docs_link = stable === nothing ? "the documentation" :
                "[documentation](" * stable * ")"
    coc = "https://github.com/" * org *
          "/.github/blob/main/CODE_OF_CONDUCT.md"
    return string(
        "_One-line description of $pkg._\n\n",
        "## Why $pkg?\n\n",
        "- _List the package's key features here._\n\n",
        "## Getting started\n\n",
        "See $docs_link for a full walkthrough.\n\n",
        "```julia\nusing $pkg\n```\n\n",
        "## Where to learn more\n\n",
        "- [GitHub Discussions](https://github.com/$repo/discussions)\n",
        "- [GitHub Repository](https://github.com/$repo)\n\n",
        "## Supporting and citing\n\n",
        "If you would like to support $pkg, please star the repository — ",
        "such metrics help secure future funding. If you use $pkg in your ",
        "work, please cite it.\n\n",
        "## Contributing\n\n",
        "We welcome contributions and new contributors! This package ",
        "follows [ColPrac](https://github.com/SciML/ColPrac) and the ",
        "[SciML style](https://github.com/SciML/SciMLStyle).\n\n",
        "## Code of conduct\n\n",
        "Please note that the $pkg project is released with a ",
        "[Contributor Code of Conduct]($coc). By contributing, you agree ",
        "to abide by its terms.\n")
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
# `.gitignore` used to be a fully-managed template: `update` copied it
# verbatim, so a package's own ignore-rule additions (e.g. a keep-rule for
# bundled data the standard rules would otherwise exclude) were silently
# dropped on the next sync (#65). It now follows the same managed-block
# pattern as the README badges: the standard rules live between the markers
# below and are (re)rendered on every scaffold/update; anything outside the
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

# Apply the managed `.gitignore` block to `target_dir`. Returns `(action,
# changed)` where action is `:created`, `:injected` (markers added to an
# existing file, e.g. on first run of a kit version with this fix, or
# `:refreshed` (markers already present; only the marked region is
# touched). Mirrors `_apply_badges`.
function _apply_gitignore(target_dir::AbstractString, inputs::NamedTuple)
    path = joinpath(target_dir, ".gitignore")
    body = _render_gitignore(inputs)
    # The explanatory header lives INSIDE the marker pair (the start marker is
    # always the block's first line) so the whole block — header included —
    # is replaced as one unit on refresh. Putting the header before the start
    # marker would leave it sitting in the "preserved" prefix on every
    # subsequent refresh, duplicating it on each `update` call.
    block = GITIGNORE_START * "\n" *
            "# MANAGED by EpiAwarePackageTools.scaffold — do not edit by hand.\n" *
            "# Standard ignore rules live between the markers below and are\n" *
            "# replaced on every update. Add package-specific rules after the\n" *
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

# Whether a repo already has benchmarks enabled, so a resync (`update` with no
# `benchmarks` kwarg) preserves an adopter's opt-in instead of reverting to the
# opt-out default and STRIPPING their benchmark CI/suite/page (the #72 trap).
# The scheduled template-sync bakes `benchmarks = {{BENCHMARKS}}` into its
# `update` call, but a repo scaffolded BEFORE this flag has a template-sync that
# re-passes nothing, so the state must also be recoverable from the destination.
# The managed benchmark CI workflows are the marker: present iff benchmarks were
# enabled. A fresh (never-scaffolded) target has neither, so it defaults to
# opt-out — exactly the intended behaviour for a new package.
function _detect_benchmarks(target_dir::AbstractString)
    wf = joinpath(target_dir, ".github", "workflows")
    return isfile(joinpath(wf, "benchmark.yaml")) ||
           isfile(joinpath(wf, "benchmark-history.yaml"))
end

# Shared worker for `scaffold`/`update`. `managed_only` restricts to managed
# templates (the `update` path). `force` overwrites package-owned files too
# (only meaningful for `scaffold`). `ad` selects the AD-enabled or AD-disabled
# standard; `benchmarks` gates the opt-in benchmark CI/suite/docs page. Returns
# a `(created, updated, preserved)` manifest of destination paths.
function _apply(target_dir::AbstractString; managed_only::Bool, force::Bool,
        ad::Bool, benchmarks::Bool, inputs::NamedTuple)
    isdir(target_dir) || error("target_dir $target_dir does not exist")
    # Expose the AD + benchmarks flags as substitution values so the scheduled
    # template-sync workflow re-applies the standard with the same `ad` /
    # `benchmarks` the package adopted. `BENCHMARKS_NAV` is the benchmark docs
    # nav entry (present only when enabled); `BENCHMARK_PAGE` the `docs_config`
    # default the build reads.
    bench_nav = benchmarks ?
                ",\n    \"Benchmarks\" => \"benchmarks.md\"" : ""
    inputs = merge(inputs,
        (AD = string(ad), BENCHMARKS = string(benchmarks),
            BENCHMARKS_NAV = bench_nav, BENCHMARK_PAGE = string(benchmarks)))
    src_dir = _templates_dir()
    created = String[]
    updated = String[]
    preserved = String[]
    for t in SCAFFOLD_TEMPLATES
        managed_only && !t.managed && continue
        _ad_selected(t, ad) || continue
        _bench_selected(t, benchmarks) || continue
        from = joinpath(src_dir, t.src)
        isfile(from) || error("missing bundled template $(t.src) at $from")
        to = joinpath(target_dir, t.dest)
        exists = isfile(to)
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
    # LICENSE is package-owned and write-once: only `scaffold`/`generate`
    # (`managed_only = false`) may write it, and only when absent. `update`
    # (`managed_only = true`) never touches it, so a deliberate licence stands.
    # Reported separately (`license`) so the template manifest stays
    # template-driven (the count-based scaffold tests track `SCAFFOLD_TEMPLATES`).
    license_action = managed_only ? :skipped : _apply_license(target_dir, inputs)
    # The standard `[workspace]` stanza is injected into the (package-owned) root
    # Project.toml when absent, on both scaffold and update, and preserved
    # thereafter. Reported separately so the template manifest stays
    # template-driven.
    workspace_action = _apply_workspace(target_dir)
    # `.gitignore` is managed between markers so package-owned additions below
    # the block survive `update` (#65). Reported separately for the same
    # reason as `readme`/`license`/`workspace` above.
    gitignore_action = first(_apply_gitignore(target_dir, inputs))
    return (created = created, updated = updated, preserved = preserved,
        readme = readme_action, license = license_action,
        workspace = workspace_action, gitignore = gitignore_action)
end

"""
    scaffold(target_dir; force = false, ad = true, benchmarks = nothing,
        kwargs...)

Adopt the standard EpiAware package tooling in `target_dir` (a package root).

Writes the shipped standard configuration and test infrastructure so a package
adopts the whole kit in one call. Two kinds of file are written:

  - MANAGED standard infra — always written (overwriting any existing copy):
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
  - PACKAGE-OWNED skeletons — written only when absent, never overwritten:
    `test/runtests.jl`, `test/Project.toml` (the test env), `test/package/
    qa_config.jl` (the QA config values the managed testset reads), `LICENSE`
    (the `license`-selected licence text — see below),
    `test/ad/scenarios.jl` + `test/ad/Project.toml`, an `ADFixtures` registry
    skeleton implementing the `ADRegistry` contract
    (`test/ADFixtures/Project.toml` + `src/ADFixtures.jl`), and
    `benchmark/benchmarks.jl` (the `SUITE`). These are where a package's own
    unit tests, AD scenarios, registry, and config values live.

Placeholders (`{{PACKAGE}}`, `{{AUTHORS}}`, `{{HOLDER}}`, `{{ORG}}`, `{{REPO}}`,
`{{REVIEWER}}`, `{{YEAR}}`) are filled by [`scaffold_inputs`](@ref): each
defaults from the target `Project.toml` or a sensible org default and is
overridable by keyword (e.g. `scaffold(dir; org = "MyOrg")`). No person, org, or
repo name is hardcoded in any template.

`LICENSE` is package-owned and write-once: the `license` keyword (an SPDX id,
one of `$(join(SUPPORTED_LICENSES, ", "))`, default `$(repr(DEFAULT_LICENSE))`)
selects the bundled licence text, written with `{{YEAR}}`/`{{HOLDER}}` filled
only when no `LICENSE` exists. [`update`](@ref) never rewrites it, so a package
that deliberately changes its licence is not reverted on a sync.

`ad` controls whether the AD CI caller and AD test infrastructure are
scaffolded, so a numerical package opts in and a tooling/non-numerical package
opts out. It defaults to `true` (the common case for an EpiAware modelling
package). When `ad = false`, NONE of the AD infra is written — no
`.github/workflows/ad.yaml`, no `test/ad/` drivers, scenarios, or env, no
`test/ADFixtures/` registry skeleton — and the files whose content depends on AD
(`Taskfile.yml`, `codecov.yml`, `test/Project.toml`) are emitted in their no-AD
variants (no `test-ad` tasks, no per-backend `ad-*` coverage flags, no AD test
deps). Pass the same `ad` value to [`update`](@ref) to keep the standard stable.

`benchmarks` controls the opt-in benchmark suite: the benchmark CI callers
(`.github/workflows/benchmark.yaml`, `benchmark-history.yaml`), the `benchmark/`
suite + comment harness, and the docs benchmark page (its nav entry and the
package-owned `docs/benchmarks.md` prose hook, gated by `docs_config`'s
`BENCHMARK_PAGE`). It defaults to `nothing`, which DETECTS the target's current
state from the benchmark workflows so re-scaffolding preserves an opt-in; a
fresh package has none, so the default is opt-out. When disabled, none of the
benchmark files are written and the docs emit no Benchmarks page. Pass
`benchmarks = true` to opt in; [`update`](@ref) detects and preserves the state.

The README body is package-owned, but the standard badge set is MANAGED: a block
between `$(BADGES_START)` / `$(BADGES_END)` markers carries the docs/CI/coverage/
quality/license badges (plus per-backend AD CI + coverage badges when
`ad = true`), parameterised from `{{REPO}}`/`{{PACKAGE}}` (no owner/repo
hardcoded). The block is injected after the README's `# ` title when the markers
are absent and refreshed in place when present; nothing outside the markers is
touched. A missing README is created with a title and the block.

`.gitignore` follows the same managed-block pattern: the standard ignore rules
live between `$(GITIGNORE_START)` / `$(GITIGNORE_END)` markers and are
(re)rendered on every scaffold/update, but anything after the end marker is a
package-owned tail that is never touched — add your own ignore rules there. A
pre-existing `.gitignore` with no markers (e.g. one written by a kit version
before this behaviour existed) is treated the same way a legacy README is:
the managed block is inserted at the top and the whole existing file is kept
below as the tail, so nothing a package added is ever silently dropped.

`docs_subdomain` selects how the docs site is hosted. The DEFAULT (`nothing`) is
a GitHub project-pages deploy: `docs/make.jl` gets `deploy_url = nothing`, so
DocumenterVitepress derives the VitePress base from the repo name and the site
renders at `epiaware.org/<Repo>.jl/` with no DNS to wire — the docs work out of
the box. Pass `docs_subdomain = true` for the conventional `<pkg>.epiaware.org`,
or a host string for a bespoke domain, to deploy at a custom subdomain instead;
this sets `deploy_url` to that host and points the README docs badges at it. A
custom subdomain ALSO needs a DNS record for the host and the repo's GitHub
Pages custom domain set (which writes the gh-pages `CNAME`); until both exist
the site will not resolve, so the project-pages default is preferred unless
that wiring is in place. The kit itself dogfoods the opt-in path: with no
explicit choice it defaults to its own DNS-wired subdomain
(`epiawarepackagetools.epiaware.org`), so its dogfood `update` stays stable.

`force = true` overwrites the package-owned skeletons too. `target_dir` must
exist. Use [`update`](@ref) to re-apply only the managed files later.

Returns a `(created, updated, preserved, readme, license, workspace, gitignore)`
named tuple: destination paths newly written, managed files overwritten,
package-owned files left in place, the README badge action (`:created`,
`:injected`, `:refreshed`, or `:skipped`), the `LICENSE` action, the root
`[workspace]` stanza action (`:injected`, `:preserved`, or `:skipped`), and the
`.gitignore` managed-block action (`:created`, `:injected`, or `:refreshed`).
"""
function scaffold(target_dir::AbstractString; force::Bool = false,
        ad::Bool = true, benchmarks::Union{Nothing, Bool} = nothing,
        kwargs...)
    inputs = scaffold_inputs(target_dir; kwargs...)
    bench = benchmarks === nothing ? _detect_benchmarks(target_dir) : benchmarks
    return _apply(target_dir; managed_only = false, force = force, ad = ad,
        benchmarks = bench, inputs = inputs)
end

"""
    update(target_dir; ad = true, benchmarks = nothing, kwargs...)

Re-apply only the MANAGED standard files to an already-adopted package and
report the drift.

This is the entry point the scheduled template-sync workflow calls: it rewrites
every managed standard file (root config, CI caller workflows, dependabot, and
the test-infra drivers) from the bundled templates, leaving all package-owned
files (unit tests, `qa_config.jl`, AD scenarios, `benchmarks.jl`, and `LICENSE`)
untouched. In particular `LICENSE` is NEVER rewritten, so a package that
deliberately switches licence is not silently reverted. The workflow opens a PR
when the result differs from what is committed. Placeholder inputs are resolved
exactly as in [`scaffold`](@ref); pass the same overrides to keep substitution
stable across a sync.

`ad` must match the value the package was scaffolded with (default `true`): with
`ad = false` the managed AD files (`ad.yaml`, `test/ad/setup.jl`,
`test/ad/runtests.jl`) are not managed and the no-AD variants of `Taskfile.yml`
and `codecov.yml` are re-applied instead.

`benchmarks` controls the opt-in benchmark CI + suite. It defaults to `nothing`,
which DETECTS the package's current state from the managed benchmark workflows
(`benchmark.yaml` / `benchmark-history.yaml`) so a resync PRESERVES an adopter's
benchmarks rather than stripping them — the scheduled template-sync bakes the
adopted value into its own `update` call, but a repo scaffolded before this flag
re-passes nothing, so detection is what keeps that first sync idempotent. Pass
`benchmarks = true`/`false` to force enable/disable.

The README's managed badge block is also refreshed: `update` injects it when the
`$(BADGES_START)` / `$(BADGES_END)` markers are absent and re-renders it from the
current placeholders when present, so a package gets and keeps the standard
badges automatically without its README body being touched.

The managed `.gitignore` block is handled the same way: refreshed between its
markers (or migrated in place if a pre-existing file has none yet), with any
package-owned tail after the block left untouched.

Returns a `(created, updated, preserved, readme, license, workspace, gitignore)`
named tuple: managed files newly added, managed files rewritten, (always empty
here) preserved, the README badge action, the `LICENSE` action (`:skipped` on
update), the root `[workspace]` stanza action, and the `.gitignore`
managed-block action.
"""
function update(target_dir::AbstractString; ad::Bool = true,
        benchmarks::Union{Nothing, Bool} = nothing, kwargs...)
    inputs = scaffold_inputs(target_dir; kwargs...)
    bench = benchmarks === nothing ? _detect_benchmarks(target_dir) : benchmarks
    return _apply(target_dir; managed_only = true, force = false, ad = ad,
        benchmarks = bench, inputs = inputs)
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
    \"\"\"
    module $package

    # Register the standard EpiAware docstring conventions before any
    # docstrings are defined (see src/docstrings.jl).
    include("docstrings.jl")

    end # module $package
    """)
    return nothing
end

"""
    generate(target_dir, package; authors = String[], uuid = <fresh>,
        ad = true, benchmarks = false, kwargs...)

Generate a fresh package at `target_dir` and adopt the standard tooling.

Creates the target directory if needed, writes a minimal package skeleton (a
`Project.toml` naming `package` with a fresh UUID, and a `src/<package>.jl`
module stub), then runs [`scaffold`](@ref) over it so the new package starts
fully managed. Unlike [`scaffold`](@ref) — which adopts the tooling into an
EXISTING package — `generate` also lays down the package's own `Project.toml`
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
function generate(target_dir::AbstractString, package::AbstractString;
        authors::AbstractVector{<:AbstractString} = String[],
        uuid::AbstractString = string(UUIDs.uuid4()),
        ad::Bool = true, benchmarks::Bool = false, kwargs...)
    mkpath(target_dir)
    authors_array = "[" * join(("\"" * a * "\"" for a in authors), ", ") * "]"
    _emit_package_skeleton(target_dir, package, uuid, authors_array)
    return scaffold(target_dir; ad = ad, benchmarks = benchmarks, kwargs...)
end
