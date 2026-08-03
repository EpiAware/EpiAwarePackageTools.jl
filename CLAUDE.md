<!-- epiaware-standards:start -->
<!--
MANAGED by EpiAwarePackageTools.scaffold — do not edit by hand.
These standards are re-rendered on every scaffold_update. Edit them in
the kit's `templates/CLAUDE.md`. Package-specific agent notes go after
the closing marker; they are preserved across updates.
-->

# Working in this package

Standards for Claude and other coding agents working in an EpiAware package.
They apply to human contributors too.
Contributor practice follows [ColPrac](https://github.com/SciML/ColPrac); this
file covers how the code itself is written.

## Comments

Comment the reason, not the action.
Code that says what it does needs no restatement above it.

Keep a comment when the reason is invisible from the code.
An upstream bug being worked around, an ordering constraint, a failure mode
that only shows up at runtime.

Do not record history.
No note of what the code used to do, which bug a line fixed, or which revision
changed it.
`git blame` and the pull request hold that.

Do not put issue or pull request numbers in comments.
A reader who wants the discussion finds it through the commit.

Docstrings are not comments and stay.
They are the public API documentation.

## Docstrings

Every exported name has a docstring.
`src/docstrings.jl` registers DocStringExtensions `@template` blocks, so the
signature and the field list are generated.
Write the prose only.

Say what the function does, then arguments and return value where they are not
obvious from the signature.
Examples are doctested, so they must run.

## Tests

Tests are TestItemRunner `@testitem` blocks.
`test/runtests.jl` discovers them, so there is no include list to update.

The `test/` tree mirrors `src/`.

A `@testitem` is self-contained.
Its `using` statements go inside the block.
Items share no state and run in any order.

Name an item after the behaviour it pins, not the function it calls.

```julia
@testitem "interval_censored rejects an unsorted boundary vector" begin
    using Distributions
    @test_throws ArgumentError interval_censored(Normal(), [2.0, 1.0])
end
```

Shared fixtures go in a `@testsnippet`, pulled into an item with
`setup = [Name]`.

Tags select the groups a runner filters on, such as `:quality`, `:ad` and
`:readme`.
Add a tag only when something filters on it.

A behaviour change ships with a test in the same pull request.

## Formatting

`.JuliaFormatter.toml` is authoritative.
Run `task format` before committing.

Format only the lines you changed.
No whole-file reflows.

## Files you do not edit

Any file whose header reads `MANAGED by EpiAwarePackageTools.scaffold` is
overwritten by the next template sync.
Change the template in
[EpiAwarePackageTools.jl](https://github.com/EpiAware/EpiAwarePackageTools.jl)
instead.

These packages do not track `Manifest.toml`.
Never commit one.

Do not move dependency versions in a feature change.
Dependabot owns bumps.

## Commits and pull requests

Conventional commit subjects with a scope, such as `feat(scaffold):` or
`fix(docs):`.

One logical change per pull request.
Reference the issue in the pull request body, not in the code.

Never sign a commit or a pull request as an agent.
No `Generated with Claude Code` line and no `Co-Authored-By: Claude` trailer.

## Prose

UK English.

One sentence per line in Markdown, Quarto and docstrings.
Do not wrap mid-sentence.

Short sentences, plainly written.
Say each point once.
Drop adjectives that carry no information.
<!-- epiaware-standards:end -->
