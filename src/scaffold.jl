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
struct Template
    src::String
    dest::String
    managed::Bool
    substitute::Bool
    ad::Symbol
end

# Convenience constructor: most templates are AD-agnostic (`:always`).
Template(src, dest, managed, substitute) = Template(src, dest, managed, substitute, :always)

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
    Template(".gitignore", ".gitignore", true, false),
    Template(".secrets.baseline", ".secrets.baseline", true, false),
    Template("codecov.yml", "codecov.yml", true, false, :ad_only),
    Template("codecov.noad.yml", "codecov.yml", true, false, :noad_only),
    # NOTE: `LICENSE` is NOT a managed template. It is written once from the
    # `license` input (see `_apply_license`) and never overwritten by `update`,
    # so a package that deliberately changes its licence is not silently
    # reverted on a sync. See the `license` field of `scaffold_inputs`.

    # --- CI caller workflows + dependabot (managed) ---
    Template(".github/dependabot.yml", ".github/dependabot.yml", true, true),
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
    # Scheduled template-sync: re-applies the managed standard on a schedule
    # (and on Dependabot updates) and opens a PR / refreshes the branch when the
    # committed infra has drifted from the kit. The auto-refresh half of the
    # dogfooding loop (the `self-drift` check guards it the rest of the time).
    Template(".github/workflows/template-sync.yaml",
        ".github/workflows/template-sync.yaml", true, true),

    # --- org issue + PR templates (managed) ---
    # The shared EpiAware/.github issue forms, contact links, and PR checklist,
    # so every adopting repo offers the same reporting experience.
    Template(".github/ISSUE_TEMPLATE/bug_report.md",
        ".github/ISSUE_TEMPLATE/bug_report.md", true, false),
    Template(".github/ISSUE_TEMPLATE/feature_request.md",
        ".github/ISSUE_TEMPLATE/feature_request.md", true, false),
    Template(".github/ISSUE_TEMPLATE/scientific_improvement.md",
        ".github/ISSUE_TEMPLATE/scientific_improvement.md", true, false),
    Template(".github/ISSUE_TEMPLATE/config.yml",
        ".github/ISSUE_TEMPLATE/config.yml", true, true),
    Template(".github/PULL_REQUEST_TEMPLATE.md",
        ".github/PULL_REQUEST_TEMPLATE.md", true, false),

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
    Template("benchmark/run.jl", "benchmark/run.jl", true, false),
    Template("benchmark/compare.jl", "benchmark/compare.jl", true, false),

    # --- documentation: Documenter + DocumenterVitepress (managed) ---
    # The standard org docs build (mirrors CensoredDistributions.jl). `make.jl`
    # (the build logic), the VitePress site config/theme/components, the node
    # deps, and the version stub are managed; `Project.toml` (doc deps) and
    # `pages.jl` (the nav tree) are package-owned so a package extends them.
    Template("docs/make.jl", "docs/make.jl", true, true),
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
    # CODEOWNERS names real people/teams, so it is seeded once (commented) for
    # the package to fill in; a bare org cannot be a code owner.
    Template(".github/CODEOWNERS", ".github/CODEOWNERS", false, true),
    # The standard DocStringExtensions `@template` conventions. Package-owned
    # because it lives in `src/` and must be `include`d by the package module
    # BEFORE its docstrings are defined for the templates to take effect (see
    # CensoredDistributions.jl `src/docstrings.jl`).
    Template("src/docstrings.jl", "src/docstrings.jl", false, false),
    Template("docs/Project.toml", "docs/Project.toml", false, true),
    Template("docs/pages.jl", "docs/pages.jl", false, false),
    Template("test/runtests.jl", "test/runtests.jl", false, false),
    # The test env differs by AD deps, so it ships as an AD/no-AD pair.
    Template("test/Project.toml", "test/Project.toml", false, true, :ad_only),
    Template("test/Project.noad.toml", "test/Project.toml", false, true,
        :noad_only),
    Template("test/package/qa_config.jl",
        "test/package/qa_config.jl", false, true),
    # The optional JET report filter (e.g. for a DynamicPPL @model package).
    Template("test/jet/jet_config.jl", "test/jet/jet_config.jl", false, false),
    # The benchmark environment, so `--project=benchmark` resolves.
    Template("benchmark/Project.toml", "benchmark/Project.toml", false, true),
    # The AD scenarios + registry skeleton are opt-in (only when `ad = true`).
    Template("test/ad/scenarios.jl", "test/ad/scenarios.jl", false, false,
        :ad_only),
    Template("test/ad/Project.toml", "test/ad/Project.toml", false, true,
        :ad_only),
    Template("test/ADFixtures/Project.toml",
        "test/ADFixtures/Project.toml", false, true, :ad_only),
    Template("test/ADFixtures/src/ADFixtures.jl",
        "test/ADFixtures/src/ADFixtures.jl", false, true, :ad_only),
    Template("benchmark/benchmarks.jl", "benchmark/benchmarks.jl", false, true)
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
  - `reviewer` — dependabot reviewer/assignee handle (`{{REVIEWER}}`); default
    `org` (so a person is never hardcoded; pass `""` to omit reviewers).
  - `year` — copyright year (`{{YEAR}}`); default the current year.
  - `license` — the SPDX licence identifier (one of
    `$(join(SUPPORTED_LICENSES, ", "))`) selecting which `LICENSE` text
    [`scaffold`](@ref) writes; default `$(repr(DEFAULT_LICENSE))`. This is a
    scaffold-time choice, not a substitution placeholder, and the `LICENSE` is
    written once and never overwritten by [`update`](@ref) so a deliberate
    licence is never reverted.

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
        license::AbstractString = DEFAULT_LICENSE)
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
    rev = reviewer === nothing ? org : reviewer
    yr = year === nothing ? Dates.year(Dates.now()) : year
    uuid = _project_string(proj, "uuid")
    # A fresh UUID for the seeded ADFixtures registry skeleton (a new path
    # package). Generated once per call; the author keeps it thereafter.
    adfix_uuid = string(UUIDs.uuid4())
    # The docs site host, e.g. `MyPkg` -> `mypkg.epiaware.org` (the
    # DocumenterVitepress `deploy_url`). Derived from the package name;
    # `nothing` when the name is unknown so a docs template errors clearly.
    docs_host = pkg === nothing ? nothing : _docs_host(pkg)
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
    return (PACKAGE = pkg, UUID = uuid, ADFIXTURES_UUID = adfix_uuid,
        AUTHORS = auth, HOLDER = hold, ORG = org, REPO = rp,
        REVIEWER = rev, YEAR = string(yr), LICENSE = license,
        DOCS_HOST = docs_host, KIT_DEP_LINE = kit_dep,
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

# The per-backend AD jobs, as (label, workflow/flag slug) pairs. Matches the
# `ad-*` codecov flags and the org `ad.yml` backend matrix.
const _AD_BACKENDS = [
    ("ForwardDiff", "ad-forwarddiff"),
    ("ReverseDiff", "ad-reversediff"),
    ("Enzyme forward", "ad-enzyme-forward"),
    ("Enzyme reverse", "ad-enzyme-reverse"),
    ("Mooncake reverse", "ad-mooncake-reverse"),
    ("Mooncake forward", "ad-mooncake-forward")
]

# The docs site host for a package, e.g. `MyPkg` -> `mypkg.epiaware.org`.
_docs_host(pkg::AbstractString) = lowercase(pkg) * ".epiaware.org"

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

# Render the standard badge block (without the markers) from resolved inputs.
# `repo` is the `owner/name.jl` slug; `pkg` the package name; `ad` adds the
# per-backend AD CI + coverage badge rows; `license` is the SPDX id whose badge
# is shown. No owner/repo is hardcoded — every URL is built from `repo`/`pkg`.
function _render_badges(repo::AbstractString, pkg::AbstractString; ad::Bool,
        license::AbstractString = DEFAULT_LICENSE)
    gh = "https://github.com/" * repo
    cov = "https://codecov.io/gh/" * repo
    host = _docs_host(pkg)
    docs = "[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)]" *
           "(https://" * host * "/stable/) " *
           "[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)]" *
           "(https://" * host * "/dev/)"
    ci = "[![Test](" * gh * "/actions/workflows/test.yaml/badge.svg" *
         "?branch=main)](" * gh * "/actions/workflows/test.yaml) " *
         "[![codecov](" * cov * "/graph/badge.svg)](" * cov * ")"
    quality = "[![SciML Code Style](https://img.shields.io/static/v1?" *
              "label=code%20style&message=SciML&color=9558b2&" *
              "labelColor=389826)](https://github.com/SciML/SciMLStyle) " *
              "[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/" *
              "Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/" *
              "Aqua.jl) " *
              "[![JET](https://img.shields.io/badge/" *
              "%E2%9C%88%EF%B8%8F%20tested%20with%20-%20JET.jl%20-%20red)]" *
              "(https://github.com/aviatesk/JET.jl)"
    license_cell = _license_badge(license)
    lines = String[
        "| | |",
        "|---|---|",
        "| Docs | " * docs * " |",
        "| CI | " * ci * " |",
        "| Quality | " * quality * " |",
        "| License | " * license_cell * " |"
    ]
    if ad
        ci_badges = join(
            ["[![AD $label]($gh/actions/workflows/$slug.yaml/" *
             "badge.svg?branch=main)]($gh/actions/workflows/" *
             "$slug.yaml)" for (label, slug) in _AD_BACKENDS],
            " ")
        cov_badges = join(
            ["[![cov $label]($cov/graph/badge.svg?flag=$slug)]" *
             "(https://app.codecov.io/gh/$repo?flags%5B0%5D=" *
             "$slug)" for (label, slug) in _AD_BACKENDS],
            " ")
        push!(lines, "| AD CI | " * ci_badges * " |")
        push!(lines, "| AD coverage | " * cov_badges * " |")
    end
    # Registration badges (added once the package is in the General registry):
    push!(lines, "")
    push!(lines,
        "<!-- Once registered, add a version badge, e.g.:")
    push!(lines,
        "[![$(pkg)](https://juliahub.com/docs/General/$pkg/stable/" *
        "version.svg)](https://juliahub.com/ui/Packages/General/$pkg) -->")
    return join(lines, "\n")
end

# Inject or refresh the managed badge block in a README. If the markers are
# present, the content between them is replaced; otherwise the block is inserted
# just after the first `# ` H1 title (or at the top when there is no title).
# Content outside the markers is never touched. Returns `(action, changed)`
# where action is `:created`/`:injected`/`:refreshed` and `changed` is whether
# the file content changed.
function _apply_badges(readme::AbstractString, repo, pkg; ad::Bool,
        license::AbstractString = DEFAULT_LICENSE)
    badges = _render_badges(repo, pkg; ad = ad, license = license)
    block = BADGES_START * "\n" * badges * "\n" * BADGES_END
    if !isfile(readme)
        write(readme, "# " * pkg * "\n\n" * block * "\n")
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

# Whether a template is emitted for the requested `ad` value: `:always` always,
# `:ad_only` when `ad = true`, `:noad_only` when `ad = false`.
function _ad_selected(t::Template, ad::Bool)
    t.ad === :always && return true
    t.ad === :ad_only && return ad
    t.ad === :noad_only && return !ad
    error("template $(t.src) has unknown ad mode $(t.ad)")
end

# Shared worker for `scaffold`/`update`. `managed_only` restricts to managed
# templates (the `update` path). `force` overwrites package-owned files too
# (only meaningful for `scaffold`). `ad` selects the AD-enabled or AD-disabled
# standard. Returns a `(created, updated, preserved)` manifest of destination
# paths.
function _apply(target_dir::AbstractString; managed_only::Bool, force::Bool,
        ad::Bool, inputs::NamedTuple)
    isdir(target_dir) || error("target_dir $target_dir does not exist")
    # Expose the AD flag as a substitution value so the scheduled template-sync
    # workflow re-applies the standard with the same `ad` the package adopted.
    inputs = merge(inputs, (AD = string(ad),))
    src_dir = _templates_dir()
    created = String[]
    updated = String[]
    preserved = String[]
    for t in SCAFFOLD_TEMPLATES
        managed_only && !t.managed && continue
        _ad_selected(t, ad) || continue
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
            _apply_badges(readme, repo, pkg; ad = ad, license = lic))
    end
    # LICENSE is package-owned and write-once: only `scaffold`/`generate`
    # (`managed_only = false`) may write it, and only when absent. `update`
    # (`managed_only = true`) never touches it, so a deliberate licence stands.
    # Reported separately (`license`) so the template manifest stays
    # template-driven (the count-based scaffold tests track `SCAFFOLD_TEMPLATES`).
    license_action = managed_only ? :skipped : _apply_license(target_dir, inputs)
    return (created = created, updated = updated, preserved = preserved,
        readme = readme_action, license = license_action)
end

"""
    scaffold(target_dir; force = false, ad = true, kwargs...)

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

The README body is package-owned, but the standard badge set is MANAGED: a block
between `$(BADGES_START)` / `$(BADGES_END)` markers carries the docs/CI/coverage/
quality/license badges (plus per-backend AD CI + coverage badges when
`ad = true`), parameterised from `{{REPO}}`/`{{PACKAGE}}` (no owner/repo
hardcoded). The block is injected after the README's `# ` title when the markers
are absent and refreshed in place when present; nothing outside the markers is
touched. A missing README is created with a title and the block.

`force = true` overwrites the package-owned skeletons too. `target_dir` must
exist. Use [`update`](@ref) to re-apply only the managed files later.

Returns a `(created, updated, preserved, readme)` named tuple: destination paths
newly written, managed files overwritten, package-owned files left in place, and
the README badge action (`:created`, `:injected`, `:refreshed`, or `:skipped`).
"""
function scaffold(target_dir::AbstractString; force::Bool = false,
        ad::Bool = true, kwargs...)
    inputs = scaffold_inputs(target_dir; kwargs...)
    return _apply(target_dir; managed_only = false, force = force, ad = ad,
        inputs = inputs)
end

"""
    update(target_dir; ad = true, kwargs...)

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

The README's managed badge block is also refreshed: `update` injects it when the
`$(BADGES_START)` / `$(BADGES_END)` markers are absent and re-renders it from the
current placeholders when present, so a package gets and keeps the standard
badges automatically without its README body being touched.

Returns a `(created, updated, preserved, readme)` named tuple: managed files
newly added, managed files rewritten, (always empty here) preserved, and the
README badge action.
"""
function update(target_dir::AbstractString; ad::Bool = true, kwargs...)
    inputs = scaffold_inputs(target_dir; kwargs...)
    return _apply(target_dir; managed_only = true, force = false, ad = ad,
        inputs = inputs)
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
        ad = true, kwargs...)

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

Remaining keyword arguments (`org`, `repo`, `reviewer`, `year`, `license`, ...)
are forwarded to [`scaffold_inputs`](@ref); e.g. `license = "Apache-2.0"` writes
the Apache licence. Returns the `scaffold` manifest.
"""
function generate(target_dir::AbstractString, package::AbstractString;
        authors::AbstractVector{<:AbstractString} = String[],
        uuid::AbstractString = string(UUIDs.uuid4()),
        ad::Bool = true, kwargs...)
    mkpath(target_dir)
    authors_array = "[" * join(("\"" * a * "\"" for a in authors), ", ") * "]"
    _emit_package_skeleton(target_dir, package, uuid, authors_array)
    return scaffold(target_dir; ad = ad, kwargs...)
end
