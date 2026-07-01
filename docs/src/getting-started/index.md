# [Getting started](@id getting-started)

EpiAwarePackageTools (the kit) is the scaffolding toolkit for EpiAware Julia
packages.
It writes and keeps in sync the standard CI, documentation build, quality
checks, and AD-gradient harness a package would otherwise copy by hand.
This page is a quickstart; the home page is the full reference.

!!! note "This site is a live example of the generated output"
    This documentation is itself produced by the kit's scaffold.
    The navigation, the VitePress theme, the GitHub-stars widget in the navbar,
    the API reference, the release-notes page, and the badge table on the home
    page are all what `scaffold`/`update` write for an adopting package.
    So this site doubles as a reference for what your package's docs will look
    like once it adopts the kit.
    See [Infrastructure and template sync](@ref infrastructure) for how the
    generated files are kept current.

## Adopting the kit

Add EpiAwarePackageTools to a package's test environment, then scaffold once:

```julia
using EpiAwarePackageTools

# Adopt the standard tooling into an existing package.
scaffold(pkgdir(MyPackage))

# A tooling / non-numerical package opts out of the AD infrastructure.
scaffold(pkgdir(MyTooling); ad = false)
```

`scaffold` writes the managed standard files (CI callers, the docs build,
formatter and coverage config, the QA and AD harness wiring) and a set of
package-owned skeletons (the package's own unit tests, QA config values, AD
scenarios, `LICENSE`, and the docs source pages you are reading now).
Managed files are overwritten on every sync; package-owned files are written
once and left for you to edit.

## Keeping a package in sync

`update` re-applies only the managed files and reports what changed:

```julia
update(pkgdir(MyPackage))
```

This is the entry point the scheduled template-sync workflow calls, so an
improvement made once in the kit reaches every adopting package.
See [Infrastructure and template sync](@ref infrastructure) for the full loop.

## Starting a fresh package

`generate` lays down a new package's `Project.toml` and source module, then
scaffolds it:

```julia
generate("path/to/NewPkg", "NewPkg")
```

## Learning more

- The home page documents every helper, the managed-versus-package-owned
  split, and the AD opt-in behaviour in full.
- The [Public API](@ref public-api) lists the exported functions.
- See [Customising your docs](@ref customising) for how to make the
  seeded pages (this one included) your own.
- Questions or problems? Open an issue on the
  [GitHub repository](https://github.com/EpiAware/EpiAwarePackageTools.jl).
