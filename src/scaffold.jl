# Scaffolder for the standard EpiAware package dev configuration. Copies the
# vetted templates (Taskfile, pre-commit, JuliaFormatter style) into a package
# so it adopts the shared config in one call. The templates live in `templates/`
# at the package root and are the single source of truth for the standard.

using Test: @testset, @test

# The names of the template files copied by `scaffold`, relative to both the
# `templates/` source directory and the target package root.
const SCAFFOLD_TEMPLATES = (
    "Taskfile.yml",
    ".pre-commit-config.yaml",
    ".JuliaFormatter.toml"
)

# Absolute path to the bundled `templates/` directory.
_templates_dir() = joinpath(pkgdir(EpiAwareTestUtils), "templates")

"""
    scaffold(target_dir; force = false)

Copy the standard EpiAware package dev-config templates into `target_dir`.

Writes the shared development configuration so a package adopts the EpiAware
standard in one call:

  - `Taskfile.yml` — standard `task` targets (test, lint, format, docs,
    benchmark, and development workflows);
  - `.pre-commit-config.yaml` — the standard pre-commit hooks, including
    JuliaFormatter;
  - `.JuliaFormatter.toml` — the SciML formatter style.

`target_dir` must exist. By default an existing file is left untouched and
reported as skipped; pass `force = true` to overwrite. Returns a named tuple
`(written, skipped)` of the destination paths in each category, so a caller (or
the test below) has a manifest of exactly what changed.
"""
function scaffold(target_dir::AbstractString; force::Bool = false)
    isdir(target_dir) || error("target_dir $target_dir does not exist")
    src = _templates_dir()
    written = String[]
    skipped = String[]
    for name in SCAFFOLD_TEMPLATES
        from = joinpath(src, name)
        isfile(from) || error("missing bundled template $name at $from")
        to = joinpath(target_dir, name)
        if isfile(to) && !force
            push!(skipped, to)
        else
            cp(from, to; force = true)
            push!(written, to)
        end
    end
    return (written = written, skipped = skipped)
end
