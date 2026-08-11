# [Customising your docs](@id customising)

`scaffold` seeds a starting set of docs source pages once; after that
they belong to the adopting package, not to the kit.
This page explains which files are yours to rewrite and where to start.

## What's package-owned here

`update` never rewrites these, no matter how many times it runs:

- `getting-started/index.md` — the quickstart a new user lands on
  first.
- `getting-started/infrastructure.md` and any further page added under
  `docs/src/`.
- `docs/pages.jl` — the navigation tree; add, remove, or reorder
  entries freely.
- The README body (the badge block and the standard sections between
  their managed markers are rewritten on sync; everything else is
  package-owned).
- `CITATION.cff` — your citation metadata (authors, DOI, version).
  Seeded once so GitHub renders a "Cite this repository" widget, then
  never rewritten; edit it as the package is released.
- `docs/src/extensions/*.md` — one page per package extension, seeded
  from the `[extensions]` your `Project.toml` declared at scaffold time.
  See [Documenting extensions](@ref documenting-extensions) below.

See [Infrastructure and template sync](@ref infrastructure) for the
full managed-versus-package-owned breakdown.

## Making it your own

- Replace the seeded quickstart in `getting-started/index.md` with the
  package's real installation steps and a runnable first example.
- Add new pages under `docs/src/` as the package grows (tutorials,
  guides, worked examples), then list them in `docs/pages.jl`.
- Reorder or rename any `Getting started` entry; `pages.jl` is read
  fresh on every `docs/make.jl` run, so there is no drift to fight.
- Keep or delete this page once it has served its purpose — it is
  package-owned like the rest of `getting-started/`.

The kit's own copies of these pages (the ones this documentation site
renders) are the worked example: this site is a real adopter of the
scaffold, seeded once and then hand-edited the same way any adopting
package's docs would be.

## [Documenting extensions](@id documenting-extensions)

A package that declares `[extensions]` gets an `Extensions` group in its
nav when it is scaffolded, one entry per extension, each pointing at a
seeded page under `docs/src/extensions/`.
The entry is labelled with the weakdep that triggers the extension, so a
reader sees `Plots`, not `MyPackagePlotsExt`.

Each page is yours: write what the extension adds and what a reader has
to load to get it.
The public-API block is seeded inert, shown as a code sample rather than
run, because an extension module exists only once its weakdeps are loaded
— a live `@autodocs` block would fail the docs build of a package whose
docs environment does not carry them.
To turn it on, add the weakdep to `docs/Project.toml`, add the extension
module to `EXTRA_MODULES` in `docs/docs_config.jl`, and replace the outer
block with the one inside it.

`docs/pages.jl` is written once, so an extension added after scaffolding
needs its page and its one nav line by hand — as a package does today
when it turns benchmarks on.
A build drops any `Extensions` entry whose page is missing, so a nav
never carries a dangling link, and the group disappears entirely once
nothing is left in it.

## [Tutorials with their own environment](@id tutorial-environments)

Every tutorial resolves against the shared `docs/` environment by default.
Some cannot.
A dependency may cap a shared package below the version your own extension
needs, leaving the two unable to co-resolve at all.

`TUTORIAL_ENVIRONMENTS` in `docs/docs_config.jl` opts one heavy tutorial out,
as a `"file.jl" => "environment/dir"` pair.
The directory is relative to `docs/` unless absolute, and the tutorial's
subprocess resolves against it instead.

Put it under `environments/`, so `docs/environments/my-tutorial/` on disk.
The managed Dependabot config watches that path and no other.
Such an environment cannot join the root `[workspace]`, because workspace
members share a single manifest and a tutorial opts out precisely because its
dependencies do not co-resolve with the shared docs project.
An environment elsewhere still builds, but nothing will ever update its
dependencies.

That environment is yours, like `docs/Project.toml` is.
The kit never writes it.
Create the directory with a `Project.toml` declaring the tutorial's
dependencies plus `Literate`, and a `[sources]` entry pointing at the package
root so `using` your package resolves:

```toml
[deps]
Literate = "98b081ad-f1c9-55d3-8b20-4c87d4299306"

[sources]
MyPackage = {path = "../.."}
```

The build instantiates it before the tutorial runs.
A missing directory, a `Project.toml` without `Literate`, or one that will not
resolve fails the build with a message naming the environment.
It does not fall back to the shared environment: a page that quietly becomes
its stub shows the reader a fast-build notice where the content should be.

Reach for this only when a dependency genuinely cannot co-resolve.
Everything else belongs in `docs/Project.toml`, and a tutorial listed here
pays for a second environment to resolve and precompile on every build.

## What stays managed

- `docs/make.jl`, the thin caller into the kit's build logic.
- The VitePress theme, config, and components under
  `docs/src/.vitepress/` and `docs/src/components/`.
- The API reference pages, generated fresh from the module's
  docstrings on every build rather than stored as source.
- The README standard sections (Contributing, How to cite, Code of
  conduct) between the `standard-sections` markers, so their wording
  stays consistent across adopters. Put package-specific prose outside
  the markers, and your citation details in `CITATION.cff`.

Editing a managed file directly works until the next `update` or
template-sync run reverts it — put customisation in the package-owned
files above instead. If a package genuinely has to own a managed file, add
an `EPIAWARE_MANAGED_OVERRIDE` comment to it and the sync preserves it; see
[Infrastructure and template sync](@ref infrastructure).
