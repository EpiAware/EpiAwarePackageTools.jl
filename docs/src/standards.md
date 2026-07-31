# [Package standards](@id standards)

The standards an EpiAware package is held to.
Each is three lines: the rule, why it exists, and how it is enforced.

The third line is the point of the page.
It names the check that catches a breach, or says the rule is reviewed by hand, so what CI will catch and what a reviewer has to catch is visible in one place.
Adding a check later replaces an enforcement line here rather than adding to it.

What each check does, and how a package configures it, lives with the check: see [Test infrastructure](@ref test-infrastructure) and the API reference.
This page does not restate any of it.

## Overview page and README

Adopted in [#292](https://github.com/EpiAware/EpiAwarePackageTools.jl/issues/292).
The README pitch and its equivalent on the getting-started overview page are what a user reads first, so they carry their own standard.

### 1. The "Why" section is a list of motivation bullets

- Rule: bullets stating why a user needs the package, not a feature inventory (`**Name**: does X`) and not prose paragraphs.
- Why: a reader deciding whether to install needs a reason to care before a list of parts.
- Enforced by [`test_readme_bullets`](@ref) for bullet shape and count; whether a bullet states real motivation is not enforced, reviewed by hand.

### 2. The headline example earns its place

- Rule: real executed values, no placeholders and no bare booleans, showing genuine depth where the package has a nested or compositional concept, and using the package's natural-syntax macro in preference to the functional form.
- Why: a flat call with placeholder output shows the syntax and hides the reason the package exists.
- Enforced by [`test_readme_placeholders`](@ref) for unfilled scaffold text, and by the docs build, which runs the README's `julia` blocks as examples (`README_EXECUTE`) so a broken one fails the build; whether the example lands the package's point is not enforced, reviewed by hand.

### 3. No internal-facing caveats in the pitch

- Rule: scope apologies ("we don't support X") and org-internal detail stay out of the Why section and the first example; put them in a FAQ if anywhere.
- Why: a first-time reader should not meet an apology before a benefit.
- Not enforced, reviewed by hand.

### 4. A "Related packages" section

- Rule: one bullet per sibling package with a real relationship, one sentence each, linked to that sibling's live docs (`/stable/` once released, `/dev/` while not, the repo when no site is deployed).
- Why: the ecosystem is only navigable if each package points at its neighbours.
- Enforced for link validity by the Documenter linkcheck on the generated home page; the section is not yet required by [`test_readme_sections`](@ref) (`STANDARD_README_SECTIONS` gains the entry under #292), and which siblings belong is reviewed by hand.

### 5. The overview page does not repeat the home page

- Rule: where a package has both a README-derived home page and a getting-started overview, the overview cross-links to the home page's Related packages section instead of repeating it.
- Why: two copies of one list drift apart.
- Not enforced, reviewed by hand.

## Prose and comments

### 6. Prose is direct

- Rule: short sentences, one sentence per line in Markdown, no adjective padding, and none of the banned filler words.
- Why: docs that pad get skipped, so their content is lost ([#331](https://github.com/EpiAware/EpiAwarePackageTools.jl/issues/331)).
- Enforced by [`test_readme_prose`](@ref), which owns the banned-word list and the sentence-length limit for the README; prose elsewhere is not enforced, reviewed by hand.

### 7. Comments say why, not what

- Rule: a comment records a decision or a constraint that is not visible in the code; it does not narrate the lines beneath it.
- Why: narration duplicates the code and then rots against it ([#331](https://github.com/EpiAware/EpiAwarePackageTools.jl/issues/331)).
- Not enforced, reviewed by hand.

### 8. NEWS.md follows one shape

- Rule: `## Unreleased`, `### <category>` subsections, one sentence per line, full `Closes [#N](url)` links, promoted to a version heading at release, as set out in [Changelog convention](@ref changelog).
- Why: the convention had forked four ways across the org, so the changelogs could not be read as a set ([#286](https://github.com/EpiAware/EpiAwarePackageTools.jl/issues/286)).
- Not enforced, reviewed by hand; [#329](https://github.com/EpiAware/EpiAwarePackageTools.jl/issues/329) tracks whether entry size needs managing too.

## Code and design

### 9. Public API is documented and its examples run

- Rule: every public binding carries a docstring in the standard shape, with a runnable example.
- Why: an undocumented export is not a public API, and an example that no longer runs is worse than none.
- Enforced by [`test_docstring_format`](@ref), Aqua's undocumented-names check through [`test_aqua`](@ref), and [`test_doctest`](@ref).

### 10. Source is machine formatted

- Rule: JuliaFormatter with the org style, configured by the managed `.JuliaFormatter.toml` (the org is moving from `sciml` to `blue`, [#318](https://github.com/EpiAware/EpiAwarePackageTools.jl/issues/318)).
- Why: no review time is spent on layout, and diffs stay about the change.
- Enforced by the `julia-formatter` pre-commit hook and [`test_formatting`](@ref) (`task test-formatting`).

### 11. New variants arrive by dispatch

- Rule: a new variant of any component is a new type plus one or two methods, with no edit to the existing component's source; a component that still branches internally on a flag or a `Symbol` is recorded as a known deviation ([#311](https://github.com/EpiAware/EpiAwarePackageTools.jl/issues/311)).
- Why: it turns "does this change respect the design?" into a reviewable criterion rather than a judgement call.
- Not enforced, reviewed by hand.

### 12. Package hygiene has one implementation

- Rule: this kit is the single implementation of the shared checks and templates; a package that needs to differ does so through its package-owned `qa_config.jl` and docs config, not by forking a managed file ([#307](https://github.com/EpiAware/EpiAwarePackageTools.jl/issues/307)).
- Why: a forked copy drifts, and the drift is invisible until the two disagree.
- Enforced by template sync, which rewrites every managed file on `update` (see [Infrastructure and template sync](@ref infrastructure)); a check reimplemented outside a managed file is not enforced, reviewed by hand.

### 13. Named options are validated where they enter

- Rule: a value passed by name is checked at the point of entry and rejected there rather than propagated.
- Why: a bad option that propagates surfaces as a confusing failure far from its cause.
- Not enforced; automated fuzz enforcement is proposed in [#310](https://github.com/EpiAware/EpiAwarePackageTools.jl/issues/310) under epic [#307](https://github.com/EpiAware/EpiAwarePackageTools.jl/issues/307).

### 14. Composed objects are conformant and queryable

- Rule: a composition agrees with itself (sampling matches density, leaf protocols are complete) or fails loudly, and can report how it will be evaluated with no silent fallback.
- Why: a composition that degrades quietly gives an answer that is trusted and wrong.
- Not enforced; the per-package checks are being added under epic [#308](https://github.com/EpiAware/EpiAwarePackageTools.jl/issues/308).
