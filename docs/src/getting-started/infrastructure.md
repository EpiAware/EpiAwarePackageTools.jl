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
  README body, `LICENSE`, `CITATION.cff` (your citation metadata), and the docs
  source pages such as this one.
  These are yours to edit.

The README badge block, the README standard sections (Contributing, How to
cite, Code of conduct), the `.gitignore` standard rules, and the docs pointers
in `AGENTS.md` and `CLAUDE.md` are a hybrid: they
are managed between markers, so their wording and the ignore rules stay current
while anything you add outside the markers is preserved. The managed "How to
cite" section points at the package-owned `CITATION.cff`, so GitHub renders a
"Cite this repository" widget and the citation content stays yours to edit.

## Agent files

`AGENTS.md` links the docs an agent should read: [Package standards](@ref
standards), [Test infrastructure](@ref test-infrastructure), this page, and the
package's own documentation.
`CLAUDE.md` points at `AGENTS.md`.
Neither restates a standard, because a copy drifts from the page it was copied
from.

Both carry the managed block between
`<!-- epiaware-standards:start MANAGED by EpiAwarePackageTools.scaffold -->`
and `<!-- epiaware-standards:end -->`.
Edit the block in the kit's `templates/AGENTS.md` and `templates/CLAUDE.md`,
not in the adopting package.
A package's own notes go after the end marker and survive every sync.

Both files are read into an agent's context in full at the start of every
session, so the block spends one word on saying it is managed and leaves the
rest to this page.
The marker is matched on its prefix, so a package carrying an older, longer
form is rewritten to this one on the next sync.

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
and the `ad`/`benchmarks`/`downgrade_compat`/`unregistered_sources` flags) where
they cover the need.

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

Two workflows keep a package aligned with the kit.

- **Template sync** (`.github/workflows/template-sync.yaml`) re-runs `update`
  on a schedule and on Dependabot updates, opening or refreshing a pull
  request when infrastructure has drifted.
  A failed run opens a single `template-sync` issue instead, edited in place
  and closed by the next clean run.
  Fix a failure by re-applying the standard locally, or ask the kit for more
  flexibility if `update` overwrote something needed.
  Hand-editing the managed file does not work: the next sync reverts it.
  Scheduled runs also freshen reusable-workflow pins
  (`freshen_reusable_refs = true`): each managed caller takes the newest
  commit that touched the shared workflow it wraps, only ever moving a pin
  forwards, and skips one it cannot resolve or that floats on a branch or tag.
  This is the only part of `update` that needs the network, so it is off by
  default and on only for the scheduled run's token.
- **Dependabot** (`.github/dependabot.yml`) keeps pinned workflow and action
  references current, daily, grouped into one pull request per ecosystem.
  Slow it down by setting the `julia` ecosystem to `weekly` in your own copy.

A fix made once in the kit reaches every adopting package on its next sync.

### After a sync, read your own docs

<!-- EPIAWARE_PROSE_OK: this section names a retired tool to explain the
     scan, which is the one thing the scan itself cannot tell apart from
     drift. -->

A sync converges the managed files and nothing else.
Your README and the authored pages under `docs/src/` are package-owned, so
prose describing the standard as it used to be survives every sync.
This is the common way an adopting package ends up documenting something it no
longer does: the kit moved the formatter to Runic, and a contributing guide
still telling readers to run JuliaFormatter kept telling them so.

`update` scans that prose for names the standard has retired (the entries in
`RETIRED_PATHS`, plus tools the standard has moved away from) and reports each
one in `warnings`, which the sync prints to its job log.
It only reports; the wording is yours, so it never rewrites it.

The scan catches a retired name, not a stale claim.
Counts, worked examples and descriptions of how a suite is organised all go
stale silently, so read the pages that describe the parts of the standard the
sync changed.

A page that names a retired tool in order to explain the retirement is not
drift.
Put `EPIAWARE_PROSE_OK` in it, in an HTML comment so it does not render, and
the scan skips that file.
Changelogs are never scanned, because recording what the package used to do is
the point of one.
That covers `NEWS.md`, `CHANGELOG.md`, and the generated
`docs/src/release-notes.md` this kit writes in their place.

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

## Unregistered `[sources]` pins and the Julia floor

`[sources]` is a Pkg 1.11 feature.
Before 1.11 it is ignored without error, so Pkg resolves whatever a registry
carries instead of the pin.

EpiAwarePackageTools is registered in General, so every managed environment
bounds it in `[compat]` and nothing in the standard is pinned by git.
A package's own `[compat] julia` is free to reach 1.10.

A package pinning a dependency of its own by git `[sources]`, such as an
ecosystem sibling awaiting registration, is a different case.
The kit detects such a pin from the committed environments, or takes
`unregistered_sources = true` on `scaffold`/`update`, and then holds the package
to Julia 1.11.
It warns about a `[compat]` bound or a CI leg that reaches below it.

The `tests.yml` matrix is seeded with its `lts` leg for every other package.
That leg runs `Pkg.test`, which develops the package under test itself, so the
`[sources]` path pin in `test/Project.toml` being ignored costs it nothing.
Only a package holding to the floor is seeded without the leg.

The jobs that run a managed environment directly rather than through
`Pkg.test` — the isolated `test/jet` and `test/ad` runners, the docs build and
the benchmark suite — do need their path pins honoured, so they stay on the
current release.
They are separate jobs, not legs of the test matrix.

Every `[compat]` bound in `test/Project.toml` has to resolve on every leg the
matrix names.
JET is the one to watch: it publishes nothing past 0.9.18 for Julia 1.10, so a
bound starting at 0.10 makes the `lts` leg unresolvable.
The seeded bound reaches back to 0.9 for that reason.
`test/Project.toml` is package-owned, so a package scaffolded before this
either widens the bound or drops `lts` from its own `julia_versions`.

The kit's own bound is the same kind of gate.
EpiAwarePackageTools declares `julia = "1.10, 1.11, 1.12"` from 0.4.0 onward;
0.2.0 and 0.3.0 start at 1.11.
A test environment bounded at `EpiAwarePackageTools = "0.3"` therefore has no
resolvable version on an `lts` leg.
Bump that bound before adding the leg.

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
minor`, or `/version major` on a pull request to bump, then either comment
`/register` or run the Register workflow manually.
The notes for the release are written on the GitHub release once it exists,
not before it (see the [release notes convention](@ref release-notes)).
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
# `public`, not exported, so call it qualified.
EpiAwarePackageTools.update(pkgdir(MyPackage))
```

`update` rewrites only the managed files and returns a manifest of what was
created, updated, or preserved; package-owned files are left untouched.
