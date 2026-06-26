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
struct Template
    src::String
    dest::String
    managed::Bool
    substitute::Bool
end

# The standard template set. Order is informational only.
const SCAFFOLD_TEMPLATES = Template[
    # --- root dev config (managed) ---
    Template("Taskfile.yml", "Taskfile.yml", true, false),
    Template(".pre-commit-config.yaml", ".pre-commit-config.yaml", true, false),
    Template(".JuliaFormatter.toml", ".JuliaFormatter.toml", true, false),
    Template(".secrets.baseline", ".secrets.baseline", true, false),
    Template("codecov.yml", "codecov.yml", true, false),
    Template("LICENSE", "LICENSE", true, true),

    # --- CI caller workflows + dependabot (managed) ---
    Template(".github/dependabot.yml", ".github/dependabot.yml", true, true),
    Template(".github/workflows/test.yaml",
        ".github/workflows/test.yaml", true, true),
    Template(".github/workflows/ad.yaml",
        ".github/workflows/ad.yaml", true, true),
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

    # --- shipped test infrastructure (managed) ---
    Template("test/package/quality.jl",
        "test/package/quality.jl", true, false),
    Template("test/jet/runtests.jl", "test/jet/runtests.jl", true, true),
    Template("test/jet/Project.toml", "test/jet/Project.toml", true, true),
    Template("test/formatter/runtests.jl",
        "test/formatter/runtests.jl", true, false),
    Template("test/formatter/Project.toml",
        "test/formatter/Project.toml", true, false),
    Template("test/ad/setup.jl", "test/ad/setup.jl", true, false),
    Template("test/ad/runtests.jl", "test/ad/runtests.jl", true, false),
    Template("benchmark/run.jl", "benchmark/run.jl", true, false),
    Template("benchmark/compare.jl", "benchmark/compare.jl", true, false),

    # --- package-owned skeletons (written once, never overwritten) ---
    Template("test/runtests.jl", "test/runtests.jl", false, false),
    Template("test/Project.toml", "test/Project.toml", false, true),
    Template("test/package/qa_config.jl",
        "test/package/qa_config.jl", false, true),
    Template("test/ad/scenarios.jl", "test/ad/scenarios.jl", false, false),
    Template("test/ad/Project.toml", "test/ad/Project.toml", false, true),
    Template("test/ADFixtures/Project.toml",
        "test/ADFixtures/Project.toml", false, true),
    Template("test/ADFixtures/src/ADFixtures.jl",
        "test/ADFixtures/src/ADFixtures.jl", false, true),
    Template("benchmark/benchmarks.jl", "benchmark/benchmarks.jl", false, true)
]

# The default org used to derive `{{ORG}}`/`{{REPO}}` when a caller does not
# pass them. This is the only org default in the kit; it is overridable.
const DEFAULT_ORG = "EpiAware"

# Absolute path to the bundled `templates/` directory.
_templates_dir() = joinpath(pkgdir(EpiAwarePackageTools), "templates")

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
    return [String(x.captures[1])
            for x in eachmatch(r"\"([^\"]*)\"", m.captures[1])]
end

# Strip a trailing `<email>` from an author entry, leaving the display name.
_author_name(a::AbstractString) = strip(replace(a, r"<[^>]*>" => ""))

"""
    scaffold_inputs(target_dir; package = nothing, authors = nothing,
        holder = nothing, org = $(repr(DEFAULT_ORG)), repo = nothing,
        reviewer = nothing, year = <current year>) -> NamedTuple

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

Returns a `NamedTuple` of `placeholder => value` `String` pairs.
"""
function scaffold_inputs(target_dir::AbstractString;
        package::Union{Nothing, AbstractString} = nothing,
        authors::Union{Nothing, AbstractString} = nothing,
        holder::Union{Nothing, AbstractString} = nothing,
        org::AbstractString = DEFAULT_ORG,
        repo::Union{Nothing, AbstractString} = nothing,
        reviewer::Union{Nothing, AbstractString} = nothing,
        year::Union{Nothing, Integer} = nothing)
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
    return (PACKAGE = pkg, UUID = uuid, ADFIXTURES_UUID = adfix_uuid,
        AUTHORS = auth, HOLDER = hold, ORG = org, REPO = rp,
        REVIEWER = rev, YEAR = string(yr))
end

# Apply placeholder substitution to `content`. A template may use any subset of
# the placeholders; each used placeholder must resolve to a non-nothing value.
function _substitute(content::AbstractString, inputs, from::AbstractString)
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

# Copy one template to `to`, substituting placeholders when requested.
function _emit(from::AbstractString, to::AbstractString, substitute::Bool,
        inputs)
    mkpath(dirname(to))
    if substitute
        write(to, _substitute(read(from, String), inputs, from))
    else
        cp(from, to; force = true)
    end
    return nothing
end

# Shared worker for `scaffold`/`update`. `managed_only` restricts to managed
# templates (the `update` path). `force` overwrites package-owned files too
# (only meaningful for `scaffold`). Returns a `(created, updated, preserved)`
# manifest of destination paths.
function _apply(target_dir::AbstractString; managed_only::Bool, force::Bool,
        inputs)
    isdir(target_dir) || error("target_dir $target_dir does not exist")
    src_dir = _templates_dir()
    created = String[]
    updated = String[]
    preserved = String[]
    for t in SCAFFOLD_TEMPLATES
        managed_only && !t.managed && continue
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
    return (created = created, updated = updated, preserved = preserved)
end

"""
    scaffold(target_dir; force = false, kwargs...)

Adopt the standard EpiAware package tooling in `target_dir` (a package root).

Writes the shipped standard configuration and test infrastructure so a package
adopts the whole kit in one call. Two kinds of file are written:

  - MANAGED standard infra — always written (overwriting any existing copy):
    root dev config (`Taskfile.yml`, `.pre-commit-config.yaml`,
    `.JuliaFormatter.toml`, `.secrets.baseline`, `codecov.yml`, `LICENSE`), CI
    caller workflows + `.github/dependabot.yml` (which invoke the org reusables,
    including the per-backend `ad.yaml` matrix), and the test-infra drivers and
    isolated-env manifests (`test/package/quality.jl`, `test/jet/runtests.jl` +
    `test/jet/Project.toml`, `test/formatter/runtests.jl` +
    `test/formatter/Project.toml`, `test/ad/setup.jl`, `test/ad/runtests.jl`,
    `benchmark/run.jl`, `benchmark/compare.jl`).
  - PACKAGE-OWNED skeletons — written only when absent, never overwritten:
    `test/runtests.jl`, `test/Project.toml` (the test env), `test/package/
    qa_config.jl` (the QA config values the managed testset reads),
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

`force = true` overwrites the package-owned skeletons too. `target_dir` must
exist. Use [`update`](@ref) to re-apply only the managed files later.

Returns a `(created, updated, preserved)` named tuple of destination paths:
files newly written, managed files overwritten, and package-owned files left in
place.
"""
function scaffold(target_dir::AbstractString; force::Bool = false, kwargs...)
    inputs = scaffold_inputs(target_dir; kwargs...)
    return _apply(target_dir; managed_only = false, force = force,
        inputs = inputs)
end

"""
    update(target_dir; kwargs...)

Re-apply only the MANAGED standard files to an already-adopted package and
report the drift.

This is the entry point the scheduled template-sync workflow calls: it rewrites
every managed standard file (root config, `LICENSE`, CI caller workflows,
dependabot, and the test-infra drivers) from the bundled templates, leaving all
package-owned files (unit tests, `qa_config.jl`, AD scenarios, `benchmarks.jl`)
untouched. The workflow opens a PR when the result differs from what is
committed. Placeholder inputs are resolved exactly as in [`scaffold`](@ref);
pass the same overrides to keep substitution stable across a sync.

Returns a `(created, updated, preserved)` named tuple: managed files newly
added, managed files rewritten, and (always empty here, since package-owned
files are skipped entirely) preserved.
"""
function update(target_dir::AbstractString; kwargs...)
    inputs = scaffold_inputs(target_dir; kwargs...)
    return _apply(target_dir; managed_only = true, force = false,
        inputs = inputs)
end
