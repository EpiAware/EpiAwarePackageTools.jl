<!-- epiaware-standards:start -->
<!--
MANAGED by EpiAwarePackageTools.scaffold — do not edit by hand.
This block is re-rendered on every scaffold_update. Edit it in
the kit's `templates/CLAUDE.md`. Package-specific agent notes go after
the closing marker; they are preserved across updates.
-->

# Working in EpiAwarePackageTools

Guidance for Claude and other coding agents working in this package.

## Read the standards before changing code

The standards this package is held to are written for humans and live in the
docs. This file points at them rather than restating them, because a second
copy drifts from the first.

- [Package standards](https://epiawarepackagetools.epiaware.org/stable/standards)
  — how code, prose, comments, docstrings and tests are written, and which
  check enforces each rule.
- [Test infrastructure](https://epiawarepackagetools.epiaware.org/stable/getting-started/test-infrastructure)
  — the test tree, `@testitem`, and the quality testset.
- [Infrastructure and template sync](https://epiawarepackagetools.epiaware.org/stable/getting-started/infrastructure)
  — which files are managed, which are package-owned, and what a sync rewrites.
- [EpiAwarePackageTools documentation](https://epiawarepackagetools.epiaware.org) — this package's own API
  and guides.
- [EpiAware](https://epiaware.github.io) — the ecosystem and its packages.
- [ColPrac](https://github.com/SciML/ColPrac) — contributor practice.

The standards page names the check that enforces each rule, so it also tells
you what CI will catch and what a reviewer has to catch.

## Rules for agents

These are not in the docs, because they are about how an agent works rather
than how the code is written.

Any file whose header reads `MANAGED by EpiAwarePackageTools.scaffold` is
overwritten by the next template sync. Editing it here is wasted work. Change
the template in
[EpiAwarePackageTools.jl](https://github.com/EpiAware/EpiAwarePackageTools.jl)
instead, or open an issue there if the kit gives you no way to make the change.

Never commit a `Manifest.toml`.

Dependabot owns dependency bumps. Do not move a version as part of a feature
change.

Never sign a commit or a pull request as an agent. No `Generated with Claude
Code` line, and no `Co-Authored-By: Claude` trailer.
<!-- epiaware-standards:end -->
