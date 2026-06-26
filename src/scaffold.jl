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

using Test: @testset, @test

# A template entry. `src` is the path under `templates/`; `dest` the path under
# the target package root (usually equal). `managed = true` means standard
# infra (overwritten on update); `false` a package-owned skeleton (write once).
# `substitute = true` runs `{{PACKAGE}}` substitution on copy.
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

    # --- CI caller workflows + dependabot (managed) ---
    Template(".github/dependabot.yml", ".github/dependabot.yml", true, false),
    Template(".github/workflows/test.yaml",
        ".github/workflows/test.yaml", true, false),
    Template(".github/workflows/document.yaml",
        ".github/workflows/document.yaml", true, false),
    Template(".github/workflows/pre-commit.yaml",
        ".github/workflows/pre-commit.yaml", true, false),
    Template(".github/workflows/codecoverage.yaml",
        ".github/workflows/codecoverage.yaml", true, false),
    Template(".github/workflows/docpreviewcleanup.yaml",
        ".github/workflows/docpreviewcleanup.yaml", true, false),
    Template(".github/workflows/TagBot.yaml",
        ".github/workflows/TagBot.yaml", true, false),
    Template(".github/workflows/downstream.yaml",
        ".github/workflows/downstream.yaml", true, false),

    # --- shipped test infrastructure (managed) ---
    Template("test/package/quality.jl",
        "test/package/quality.jl", true, false),
    Template("test/jet/runtests.jl", "test/jet/runtests.jl", true, true),
    Template("test/formatter/runtests.jl",
        "test/formatter/runtests.jl", true, false),
    Template("test/ad/setup.jl", "test/ad/setup.jl", true, false),
    Template("test/ad/runtests.jl", "test/ad/runtests.jl", true, false),
    Template("benchmark/run.jl", "benchmark/run.jl", true, false),
    Template("benchmark/compare.jl", "benchmark/compare.jl", true, false),

    # --- package-owned skeletons (written once, never overwritten) ---
    Template("test/runtests.jl", "test/runtests.jl", false, false),
    Template("test/package/qa_config.jl",
        "test/package/qa_config.jl", false, true),
    Template("test/ad/scenarios.jl", "test/ad/scenarios.jl", false, false),
    Template("benchmark/benchmarks.jl", "benchmark/benchmarks.jl", false, true)
]

# Absolute path to the bundled `templates/` directory.
_templates_dir() = joinpath(pkgdir(EpiAwareTestUtils), "templates")

# Read the package name from a target dir's Project.toml `name = "..."` line, or
# `nothing` if absent. Used for `{{PACKAGE}}` substitution.
function _package_name(target_dir::AbstractString)
    proj = joinpath(target_dir, "Project.toml")
    isfile(proj) || return nothing
    for line in eachline(proj)
        m = match(r"^\s*name\s*=\s*\"([^\"]+)\"", line)
        m === nothing || return m.captures[1]
    end
    return nothing
end

# Copy one template to `to`, substituting `{{PACKAGE}}` when requested.
function _emit(from::AbstractString, to::AbstractString, substitute::Bool,
        pkgname)
    mkpath(dirname(to))
    if substitute
        pkgname === nothing &&
            error("template $from needs a package name but target " *
                  "Project.toml has none; set its `name` first")
        content = replace(read(from, String), "{{PACKAGE}}" => pkgname)
        write(to, content)
    else
        cp(from, to; force = true)
    end
    return nothing
end

# Shared worker for `scaffold`/`update`. `managed_only` restricts to managed
# templates (the `update` path). `force` overwrites package-owned files too
# (only meaningful for `scaffold`). Returns a `(created, updated, preserved)`
# manifest of destination paths.
function _apply(target_dir::AbstractString; managed_only::Bool, force::Bool)
    isdir(target_dir) || error("target_dir $target_dir does not exist")
    src_dir = _templates_dir()
    pkgname = _package_name(target_dir)
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
        _emit(from, to, t.substitute, pkgname)
        push!(exists ? updated : created, to)
    end
    return (created = created, updated = updated, preserved = preserved)
end

"""
    scaffold(target_dir; force = false)

Adopt the standard EpiAware package tooling in `target_dir` (a package root).

Writes the shipped standard configuration and test infrastructure so a package
adopts the whole kit in one call. Two kinds of file are written:

  - MANAGED standard infra — always written (overwriting any existing copy):
    root dev config (`Taskfile.yml`, `.pre-commit-config.yaml`,
    `.JuliaFormatter.toml`), CI caller workflows + `.github/dependabot.yml`
    (which invoke the EpiAware/.github reusables), and the test-infra drivers
    (`test/package/quality.jl`, `test/jet/runtests.jl`,
    `test/formatter/runtests.jl`, `test/ad/setup.jl`, `test/ad/runtests.jl`,
    `benchmark/run.jl`, `benchmark/compare.jl`).
  - PACKAGE-OWNED skeletons — written only when absent, never overwritten:
    `test/runtests.jl`, `test/package/qa_config.jl` (the QA config values the
    managed testset reads), `test/ad/scenarios.jl` (AD scenario items), and
    `benchmark/benchmarks.jl` (the `SUITE`). These are where a package's own
    unit tests, AD scenarios, and config values live.

`{{PACKAGE}}` placeholders are filled from the target `Project.toml` `name`.
`force = true` overwrites the package-owned skeletons too. `target_dir` must
exist. Use [`update`](@ref) to re-apply only the managed files later.

Returns a `(created, updated, preserved)` named tuple of destination paths:
files newly written, managed files overwritten, and package-owned files left in
place.
"""
function scaffold(target_dir::AbstractString; force::Bool = false)
    return _apply(target_dir; managed_only = false, force = force)
end

"""
    update(target_dir)

Re-apply only the MANAGED standard files to an already-adopted package and
report the drift.

This is the entry point the scheduled template-sync workflow calls: it rewrites
every managed standard file (root config, CI caller workflows, dependabot, and
the test-infra drivers) from the bundled templates, leaving all package-owned
files (unit tests, `qa_config.jl`, AD scenarios, `benchmarks.jl`) untouched. The
workflow opens a PR when the result differs from what is committed.

Returns a `(created, updated, preserved)` named tuple: managed files newly
added, managed files rewritten, and (always empty here, since package-owned
files are skipped entirely) preserved.
"""
function update(target_dir::AbstractString)
    return _apply(target_dir; managed_only = true, force = false)
end
