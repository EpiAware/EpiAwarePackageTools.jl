# [Infrastructure and template sync](@id infrastructure)

The kit does two jobs for an adopting package: it writes the standard
infrastructure once (`scaffold`), and it keeps that infrastructure current
afterwards (`update`, driven on a schedule).
This page explains the sync machinery and how the kit applies it to itself on
its own repository.
For what that infrastructure actually contains, see the reference pages on the
[test infrastructure](@ref test-infrastructure), [benchmarking](@ref
benchmarking), and [AD tooling](@ref ad-tooling).

## Managed and package-owned files

Every file the kit writes is one of two kinds.

- Managed files are the standard infrastructure: the CI caller workflows, the
  documentation build (`docs/make.jl` and the VitePress theme, config, and
  components), the formatter and pre-commit config, and the coverage config.
  `update` rewrites them from the bundled templates on every sync, so drift is
  removed automatically.
  Each managed file carries a `MANAGED by EpiAwarePackageTools.scaffold`
  header; do not edit them by hand.
- Package-owned files are written once and never overwritten: the package's
  unit tests, its QA config values, the navigation tree (`docs/pages.jl`), the
  README body, `LICENSE`, `CITATION.cff` (your citation metadata), `NEWS.md`
  (see the [changelog convention](@ref changelog) for its shape), and the docs
  source pages such as this one.
  These are yours to edit.

The README badge block, the README standard sections (Contributing, How to
cite, Code of conduct), the `.gitignore` standard rules, and the coding
standards in `CLAUDE.md` are a hybrid: they
are managed between markers, so their wording and the ignore rules stay current
while anything you add outside the markers is preserved. The managed "How to
cite" section points at the package-owned `CITATION.cff`, so GitHub renders a
"Cite this repository" widget and the citation content stays yours to edit.

## Coding standards

The root `CLAUDE.md` carries the org's coding standards between the
`<!-- epiaware-standards:start -->` and `<!-- epiaware-standards:end -->`
markers.
They cover comments, docstrings, `@testitem` tests, formatting, and commit
hygiene, and they apply to coding agents and human contributors alike.
Every sync re-renders the block, so a change made once in the kit's
`templates/CLAUDE.md` reaches every adopting package.
Package-specific agent notes go after the end marker and are never touched.
A package that already had a `CLAUDE.md` keeps it, moved below the standards
block on the first sync.

## Overriding a managed file

A package that must keep its own version of a managed file says so in the file.
Put the marker `EPIAWARE_MANAGED_OVERRIDE` in a comment anywhere in it, and
`update` preserves the file rather than resyncing it, reporting it
under `preserved` in the manifest.

```yaml
# EPIAWARE_MANAGED_OVERRIDE: this package needs its own test matrix.
```

Remove the marker to hand the file back to the kit. `scaffold` with
`force = true` ignores the marker and lays the managed file down fresh, so a new
package always starts fully managed.

Use this sparingly. An overridden file stops tracking the standard, so kit fixes
no longer reach it, which is the opposite of what the kit is for. Prefer the
supported hooks (the package-owned config values, the marker-delimited regions,
and the `ad`/`benchmarks`/`downgrade_compat` flags) where they cover the need.

What the marker does **not** cover:

- The marker-delimited regions described above, in files that are otherwise
  package-owned: the README badge block, the README standard sections, the
  `.gitignore` managed block, the `CLAUDE.md` standards block, and the
  `[workspace]` stanza in `Project.toml`.
  Those are refreshed on every sync whether or not the file carries the marker.
  Customise them by editing outside their markers, which is what the markers are
  for. There is no region-level opt-out.
- Retirement. When the kit retires a path, a sync deletes it whether or not it
  carries the marker, because a retired path is infrastructure the kit no longer
  supports at all.
- The two managed JSON files (`docs/package.json` and `.secrets.baseline`). The
  marker has to live in a comment and JSON has no comments, so these cannot be
  overridden this way.

The match is case-sensitive: write `EPIAWARE_MANAGED_OVERRIDE` in capitals. A
mis-cased marker does nothing and the file is resynced as usual.

The AD-harness driver `test/ad/setup.jl` is the original case: a package whose
`ADFixtures` registry predates the current `ADRegistry` contract must keep a
hand-written driver while it migrates. That file also honours its older marker
`EPIAWARE_AD_SETUP_OWNED`; either marker preserves it. It is also the one file
where `update` warns before overwriting a version that has diverged
from the kit's and carries no marker, because a clobber there breaks every AD CI
job. No such warning exists for managed files generally: divergence from the
current template is the normal state of an adopter that is simply on an older
kit version, so a general divergence warning would fire on every sync and tell
you nothing. Mark the files you own instead.

A bespoke `docs/make.jl` is the other case the marker is meant for. The managed
`make.jl` is a thin [`build_docs`](@ref) entry point, which regenerates
`docs/src/index.md` from the README and reads a package-owned
`docs/docs_config.jl`. A package that has deliberately kept a direct
`DocumenterVitepress` build with a hand-authored home page marks its `make.jl`,
and `update` then leaves the build alone instead of migrating it on a
routine sync.

## What the kit preserves without a marker

Some parts of a managed file are adopter configuration rather than standard, and
the kit recovers them from the committed repository on every sync, so the file
keeps tracking the standard while the customisation survives. No marker is
needed, and none of these values has to be re-passed to `update`.

- The reviewer handle, the docs-hosting choice, the benchmark and
  downgrade-compat opt-ins, Dependabot's action and reusable-workflow pins, and
  any package-owned `with:` input added to a managed CI caller.
- The Zenodo DOI badge and the licence badge in the README. A non-MIT package
  keeps its licence badge across a sync; pass `license` explicitly only to
  change it.
- The `downstreams` list in `.github/workflows/downstream.yaml`. Which packages
  depend on yours is a fact about your package, so the list you commit wins over
  the template's empty seed, while the rest of the workflow stays managed.

## Staying in sync

Two workflows keep an adopting package aligned with the kit.

- The scheduled template-sync workflow
  (`.github/workflows/template-sync.yaml`) re-runs `update` against the
  repository on a schedule and on Dependabot updates, then opens or refreshes a
  pull request whenever the committed infrastructure has drifted from the
  current standard.
  A scheduled run has nobody watching it, so a run that fails opens an issue on
  the repository rather than leaving a red mark on the Actions tab.
  It is one issue, labelled `template-sync`, edited in place on each failing run
  and closed again by the first clean run.
  The two routes out are to re-apply the standard locally and commit the result,
  or, when `update` throws or overwrites something the package needs to keep, to
  open an issue on the kit asking for the flexibility.
  Editing the managed file to silence the failure is not one of them, since the
  next sync reverts it.
- Dependabot (`.github/dependabot.yml`) keeps the pinned reusable-workflow and
  action references current, so fixes in the shared workflows reach the
  repository without manual edits.
  It runs daily, and every bump within an ecosystem is grouped into one pull
  request, so a run refreshes that pull request rather than opening more.
  The refresh is a new commit, so it costs a check run; a package that would
  rather wait longer than spend the runner time sets the `julia` ecosystem
  back to `weekly` in its own copy.

An improvement made once in the kit therefore propagates to every adopting
package on the next sync.

## Registration safety

The managed `registrability.yaml` caller runs the shared
`EpiAware/.github` registrability workflow whenever a package's `Project.toml`
changes (and on demand, and on `main`).
It runs two read-only checks.

- Registrability asserts that every non-stdlib `[deps]` entry exists in the
  General registry with a version satisfying the package's own `[compat]`.
  A dependency pinned in `[sources]` to a git revision is unregistered, so the
  check fails with a per-dependency message.
  This is the failure that had ConvolvedDistributions 0.2.0 rejected from
  General with nothing in CI to catch it.
- The reverse-dependency scan reports which org packages depend on this one
  and whether their `[compat]` admits the version under test.
  A breaking release legitimately strands a downstream bound, so this is a
  warning by default; set `fail_on_revdep_break: true` on the caller job to
  gate on it.

## [Release documentation](@id release-docs)

Documenter publishes a versioned `stable` and `vX.Y` copy of the docs only when
the build runs at a release tag, and only a `push` event at that tag starts one.
TagBot raises that event when a `DOCUMENTER_KEY` deploy key is set.
Without the key it tags with the Actions app token, which raises no event, so
the site keeps serving `dev` alone.
The same fallback is refused outright when the tagged commit touches a workflow
file.

### [Adding the deploy key](@id documenter-key)

Once per package, at repository creation.
It needs repository admin, so `scaffold` cannot do it.

```bash
repo=EpiAware/YourPackage.jl
ssh-keygen -t rsa -b 4096 -m PEM -N "" -C documenter -f /tmp/dk
gh repo deploy-key add /tmp/dk.pub --repo "$repo" \
  --title documenter --allow-write
gh secret set DOCUMENTER_KEY --repo "$repo" --body "$(base64 -w0 < /tmp/dk)"
shred -u /tmp/dk /tmp/dk.pub
```

`DocumenterTools.genkeys` prints the same two halves to paste by hand.
Four details each break the deploy silently when wrong.

- The deploy key needs **write** access.
- The secret holds the **private** half, base64-encoded on one line.
- One keypair per repository: GitHub refuses to reuse a deploy key, so there is
  no org-wide version.
- RSA in PEM form, matching what `DocumenterTools` emits.

The secret does two jobs: TagBot reads it as `ssh:` to push the tag, Documenter
as `DOCUMENTER_KEY` to push to `gh-pages`.
Only the tag push needs it, since `deploydocs` also works from `GITHUB_TOKEN`.
That is why a keyless package still ships `dev` docs and simply never a
versioned copy.

## Release nudges

The managed `release-nudge.yaml` caller runs the shared `EpiAware/.github`
release-nudge workflow weekly and on demand.
It compares `Project.toml`'s version and the commits on `main` since the
latest release/tag (and, best-effort, the version registered in the Julia
General registry) and, whenever `main` has unreleased changes, opens or
refreshes a single labelled issue that reports the released vs
`Project.toml` version, how many commits are unreleased with a compare
link and a short recent-commit list, and whether a version bump is still
needed or only registration is outstanding.
The issue spells out the next steps: comment `/version patch`, `/version
minor`, or `/version major` on a pull request to bump, update `NEWS.md`,
then either comment `/register` or run the Register workflow manually.
When nothing is unreleased it closes any open nudge issue instead.

An open nudge issue is never edited in place.
A run that finds the state has changed, or finds the issue has simply sat
open too long, closes it with a short comment and opens a fresh one, so
the issue is always current rather than accumulating an edit history.
The generated issue body can never contain a literal `@`: the workflow
strips it from any repository-derived text (commit subject lines) before
it can reach the body, and names the Register workflow and the
`/register` slash command instead of ever writing out a handle.

## How the kit applies this to itself

The kit manages its own repository the same way an adopter's is managed, with
one difference: it is a tooling package, so it scaffolds itself with
`ad = false` (no AD CI or harness).

A `self-drift` CI check runs `update("."; ad = false)` and asserts the result
is zero drift, proving the committed infrastructure matches what the templates
currently produce.
Because the kit is its own first adopter, this documentation site and its
generated pages are the live example described in the
[getting-started note](@ref getting-started): what you see here is exactly what
the scaffold writes.

## Running a sync by hand

You can drive the same sync from a Julia session:

```julia
using EpiAwarePackageTools

# Re-apply the managed standard files and report drift. `update` is
# `public`, not exported (#294), so call it qualified.
EpiAwarePackageTools.update(pkgdir(MyPackage))
```

`update` rewrites only the managed files and returns a manifest of what was
created, updated, or preserved; package-owned files are left untouched.
