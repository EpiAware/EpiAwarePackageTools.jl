# [Package standards](@id standards)

The standards an EpiAware package is held to.
Each is three lines: the rule, why it exists, and how it is enforced.

The third line is the point of the page.
It names the check that catches a breach, or says the rule is reviewed by hand, so what CI will catch and what a reviewer has to catch is visible in one place.
Adding a check later replaces an enforcement line here rather than adding to it.

What each check does, and how a package configures it, lives with the check: see [Test infrastructure](@ref test-infrastructure) and the API reference.
This page does not restate any of it.

## Overview page and README

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
- Enforced for link validity by the Documenter linkcheck on the generated home page; the section is not yet required by [`test_readme_sections`](@ref) (`STANDARD_README_SECTIONS` is expected to gain the entry), and which siblings belong is reviewed by hand.

### 5. The overview page does not repeat the home page

- Rule: where a package has both a README-derived home page and a getting-started overview, the overview cross-links to the home page's Related packages section instead of repeating it.
- Why: two copies of one list drift apart.
- Not enforced, reviewed by hand.

## Prose and comments

### 6. Prose is direct

- Rule: short sentences, one sentence per line in Markdown, no adjective padding, and none of the banned filler words.
- Why: docs that pad get skipped, so their content is lost.
- Enforced by [`test_readme_prose`](@ref), which owns the banned-word list and the sentence-length limit for the README; prose elsewhere is not enforced, reviewed by hand.

### 7. Comments say why, not what

- Rule: a comment records a decision or a constraint that is not visible in the code; it does not narrate the lines beneath it. Keep it short: if a comment needs a paragraph, the code under it usually needs simplifying instead.
- Why: narration duplicates the code and then rots against it.
- Not enforced, reviewed by hand.

### 8. Comments and docs carry no development history

- Rule: a comment, a docstring or a docs page says what is true now. It carries no issue or pull request numbers, and no account of what the code used to do or which bug a change fixed. `git blame` and the pull request hold that.
- Why: history and issue numbers in the source are a second copy of the repository's own record, and it is the copy that rots. A reader who wants the discussion finds it through the commit.
- Not enforced, reviewed by hand.

### 9. Release notes live on the GitHub release

- Rule: notes are written on the release itself, on top of TagBot's merged-PR list, and the docs page renders them by fetching the published releases at build time, as set out in [Release notes convention](@ref release-notes).
- Why: a changelog file in the repo has to be kept in step with the tags by hand, and the shape it should take had already forked four ways across the org. The release is the one copy that cannot drift from what shipped.
- Not enforced, reviewed by hand.

## Code and design

### 10. Public API is documented and its examples run

- Rule: every public binding carries a docstring in the standard shape, with a runnable example.
- Why: an undocumented export is not a public API, and an example that no longer runs is worse than none.
- Enforced by [`test_docstring_format`](@ref), Aqua's undocumented-names check through [`test_aqua`](@ref), and [`test_doctest`](@ref).

### 11. Source is machine formatted

- Rule: [Runic](https://github.com/fredrikekre/Runic.jl), which is unconfigurable — there is one canonical style, so no per-package config file.
- Why: no review time is spent on layout, and diffs stay about the change.
- Enforced by the `runic` pre-commit hook and [`test_formatting`](@ref) (`task test-formatting`).

### 12. Extension points are `public`, not exported

- Rule: export the first tier of usage only, the handful of names a user reaches for to do the package's main job. A binding that exists so a developer can extend the package, or whose name is generic enough to collide, is marked `public` and documented, not exported.
- Why: a crowded export list stops saying which names matter, and a generic exported name collides on `using`. `public` still publishes the name and its docstring without putting it in every caller's namespace.
- Not enforced, reviewed by hand.

### 13. New variants arrive by dispatch

- Rule: a new variant of any component is a new type plus one or two methods, with no edit to the existing component's source; a component that still branches internally on a flag or a `Symbol` is recorded as a known deviation.
- Why: it turns "does this change respect the design?" into a reviewable criterion rather than a judgement call.
- Not enforced, reviewed by hand.

An audit against this rule found two deviations in the kit itself.

- `Template.ad::Symbol` and `Template.bench::Symbol` in `src/scaffold.jl`, read by `_ad_selected` and `_bench_selected`, gate every entry in `SCAFFOLD_TEMPLATES` through a `Symbol` switch; adding a new gating criterion means editing the struct and both selector chains.
This is the primary deviation, and the mirror image of `ad_harness.jl`'s `ADRegistry`, which is duck-typed and method-based and stands as the worked example of the pattern this rule asks for.
- About eight private content generators in `src/scaffold.jl`, including the tutorial, benchmark and docs-dependency helpers, open with `ad || return ""` or `benchmarks || return ""`.
This is a weaker deviation: real flag branching, but each function gates one fixed on/off feature rather than an extension point.

Not deviations: `_resolve_docs_subdomain` already dispatches on type rather than branching on a flag; `benchmarks.jl`'s `status::Symbol` is a closed three-state tag, not an extension point; `quality.jl`'s `expr.head in (...)` branches on someone else's API (Julia's own AST) rather than this package's; and an ordinary `::Bool` keyword option is not a deviation on its own.

### 14. Package hygiene has one implementation

- Rule: this kit is the single implementation of the shared checks and templates; a package that needs to differ does so through its package-owned `qa_config.jl` and docs config, not by forking a managed file.
- Why: a forked copy drifts, and the drift is invisible until the two disagree.
- Enforced by template sync, which rewrites every managed file on `update` (see [Infrastructure and template sync](@ref infrastructure)); a check reimplemented outside a managed file is not enforced, reviewed by hand.

### 15. Named options are validated where they enter

- Rule: a value passed by name is checked at the point of entry and rejected there rather than propagated.
- Why: a bad option that propagates surfaces as a confusing failure far from its cause.
- Not enforced; automated fuzz enforcement is proposed but not yet built.

### 16. Composed objects are conformant and queryable

- Rule: a composition agrees with itself (sampling matches density, leaf protocols are complete) or fails loudly, and can report how it will be evaluated with no silent fallback.
- Why: a composition that degrades quietly gives an answer that is trusted and wrong.
- Not enforced; the per-package checks are being added across the ecosystem over time.

### 17. Interfaces are duck-typed, not type-constrained

- Rule: a component asks for the methods it calls (e.g. `rand` and `logpdf` for "a distribution"), not a concrete type or a package's type hierarchy. The required methods are documented, typically in an `interfaces.jl`, with a conformance check a new implementation can run against itself. That latitude stops at performance: call sites stay type-stable regardless of which conforming type is passed in.
- Why: constraining to a concrete type locks out anything that satisfies the same contract another way; asking for the methods keeps the interface open without paying for it in dynamic dispatch.
- Not enforced, reviewed by hand.
