# [Customising your docs](@id customising)

`scaffold` seeds a starting set of docs source pages for `{{PACKAGE}}`
once; after that they belong to `{{PACKAGE}}`, not to the kit.
This page explains which files are yours to rewrite and where to start.

## What's package-owned here

`update` never rewrites these, no matter how many times it runs:

- `getting-started/index.md` — the quickstart a new user lands on
  first.
- `getting-started/infrastructure.md` and any further page added under
  `docs/src/`.
- `docs/pages.jl` — the navigation tree; add, remove, or reorder
  entries freely.
- The README body (only the badge block between the managed markers is
  rewritten on sync; everything else is package-owned).

See [Infrastructure and template sync](@ref infrastructure) for the
full managed-versus-package-owned breakdown.

## Making it your own

- Replace the seeded quickstart in `getting-started/index.md` with
  `{{PACKAGE}}`'s real installation steps and a runnable first example.
- Add new pages under `docs/src/` as the package grows (tutorials,
  guides, worked examples), then list them in `docs/pages.jl`.
- Reorder or rename any `Getting started` entry; `pages.jl` is read
  fresh on every `docs/make.jl` run, so there is no drift to fight.
- Keep or delete this page once it has served its purpose — it is
  package-owned like the rest of `getting-started/`.

## What stays managed

- `docs/make.jl`, the thin caller into the kit's build logic.
- The VitePress theme, config, and components under
  `docs/src/.vitepress/` and `docs/src/components/`.
- The API reference pages, generated fresh from `{{PACKAGE}}`'s
  docstrings on every build rather than stored as source.

Editing a managed file directly works until the next `update` or
template-sync run reverts it — put customisation in the package-owned
files above instead.
