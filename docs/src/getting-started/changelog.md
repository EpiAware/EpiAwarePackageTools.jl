# [Changelog convention](@id changelog)

`scaffold` seeds every package with a `NEWS.md` (package-owned, written once,
never overwritten — see [Infrastructure and template sync](@ref
infrastructure)).
This page is the org-wide convention for what goes in it, decided in
[EpiAwarePackageTools#286](https://github.com/EpiAware/EpiAwarePackageTools.jl/issues/286)
after an audit found four different shapes in use across the ecosystem.

[CensoredDistributions.jl's `NEWS.md`](https://github.com/EpiAware/CensoredDistributions.jl/blob/main/NEWS.md)
is the reference; ModifiedDistributions.jl follows it closely.
Match that shape in a new or updated entry.

## The shape

```markdown
## Unreleased

### Added

- A one-sentence-per-line description of the change, written for a user
  reading the changelog rather than the diff. Closes
  [#123](https://github.com/OWNER/REPO/issues/123).

### Fixed

- ...

## v0.2.0 - Some milestone

### Breaking

- ...
```

- One `## Unreleased` section at the top, holding every entry since the last
  release.
- `### <category>` subsections underneath it, added only when they have an
  entry: `Added`, `Fixed`, `Deprecated`, `Removed`, `Breaking` cover most
  changes, and a repo-specific category (CensoredDistributions.jl's "AD
  gradient infrastructure") is fine when a change doesn't fit the standard
  set.
- One sentence per line, matching the org's prose convention elsewhere.
- A full Markdown link for the closing reference —
  `Closes [#123](https://github.com/OWNER/REPO/issues/123))` — not a bare
  `#123` or a lowercase inline `closes #123`, so the changelog is readable
  standalone (it renders on the docs site) as well as on GitHub.
- At release, `## Unreleased` is renamed to the version heading
  (`## vX.Y.Z - <short label>`) and a fresh empty `## Unreleased` is added
  above it.

## When to add an entry

Add a bullet in the PR that makes the change, not after the fact. A change
belongs in `NEWS.md` if a user of the package (not a contributor reading the
diff) would want to know about it: a new public function, a behaviour
change, a bug fix, a deprecation. Internal refactors, test-only changes, and
CI/infrastructure updates usually don't need an entry.

This is advisory, not enforced by a quality gate — see
[EpiAwarePackageTools#286](https://github.com/EpiAware/EpiAwarePackageTools.jl/issues/286)
for the discussion of whether to add one later.

## Migrating an existing NEWS.md

The convention is a target for new entries, not a mandate to rewrite
history. A repo whose `NEWS.md` predates this page keeps its existing
entries as they are; write new entries in the shape above going forward.
Backfilling old entries to match (adding `Closes` links, splitting a
paragraph into per-category bullets) is a judgement call for that repo's
maintainer, not something `scaffold_update` will ever do for you — `NEWS.md`
stays package-owned and untouched by sync.
