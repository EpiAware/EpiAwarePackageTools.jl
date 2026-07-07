# A `usethis`-style manual-setup checklist: `scaffold`/`scaffold_generate` write every
# file-based standard, but a handful of one-off steps need a human with
# dashboard access (Codecov, GitHub Pages, branch protection, the first
# registration) and no file-writer can do them. `setup_checklist` prints that
# list plus a ready-to-paste tracking-issue body.
#
# Deliberately dependency-free: unlike the QA helpers (`test_jet`,
# `test_formatting`, ...), which lazily `Base.require` an optional dependency
# at call time to keep it out of every caller's `[deps]`, this needs nothing
# beyond the standard library — it never shells out to the `gh` CLI or calls
# the GitHub API, so the printed issue body is meant to be copied into a new
# issue (or GitHub Discussion) by hand.

# The checklist steps, parameterised by the resolved package name/repo slug.
# Kept as a function (not a `const`) so it always reflects the actual target
# rather than a module-load-time snapshot.
function _setup_checklist_steps(pkg::AbstractString, repo::AbstractString)
    return String[
        string("Enable ", pkg, " on Codecov (https://app.codecov.io/gh/",
            repo, ") and add the `CODECOV_TOKEN` repo secret (Settings -> ",
            "Secrets and variables -> Actions)."),
        string("Enable GitHub Pages for ", pkg, "'s `gh-pages` branch ",
            "(Settings -> Pages) so the docs site deploys."),
        string("If ", pkg, " uses a custom docs subdomain (the ",
            "`docs_subdomain` input to `scaffold`/`scaffold_update`), add a DNS ",
            "CNAME for it and set it as the custom domain in Settings -> ",
            "Pages; the default project-pages URL needs no DNS."),
        string("Protect ", pkg, "'s `main` branch (Settings -> Branches): ",
            "require a pull-request review and passing status checks ",
            "before merge."),
        string("Once ", pkg, " is ready to publish, register it with the ",
            "Julia General Registry: comment `/register` on an issue or ",
            "pull request, or run the managed `Register` workflow ",
            "manually (Actions -> Register -> Run workflow).")
    ]
end

# The suggested tracking-issue body (title + checklist), as a single string
# ending in a newline, ready to paste into a new GitHub issue.
function _setup_checklist_issue_body(
        pkg::AbstractString, steps::AbstractVector{<:AbstractString})
    lines = String["# Manual setup for $pkg", "",
        string("Tracking issue for the one-off setup steps `scaffold`/",
            "`scaffold_generate` cannot do on their own (each needs dashboard ",
            "access). Check each off as it is done."),
        ""]
    for step in steps
        push!(lines, "- [ ] " * step)
    end
    push!(lines, "")
    push!(lines, "_Printed by `EpiAwarePackageTools.setup_checklist`._")
    return join(lines, "\n") * "\n"
end

"""
    setup_checklist(target_dir = "."; package = nothing, repo = nothing,
        org = $(repr(DEFAULT_ORG)), io = stdout)

Print the manual setup steps left after [`scaffold`](@ref)/[`scaffold_generate`](@ref).

`scaffold` writes every file-based standard, but a handful of one-off steps
need a human with dashboard access and no file-writer can do them for us:
enabling Codecov and adding its `CODECOV_TOKEN` secret, wiring a docs custom
domain (when one was chosen), enabling GitHub Pages, protecting `main`, and
running the first Julia General Registry registration (via the managed
`Register.yml` workflow — see its docstring in [`scaffold`](@ref)). This
prints that checklist, followed by a ready-to-paste tracking-issue body.

`package`/`repo`/`org` resolve exactly as in [`scaffold_inputs`](@ref)
(defaulting from `target_dir`'s `Project.toml`), so the checklist reads
naturally for the target package with no arguments in the common case
(`setup_checklist()` from the package root).

This prints only: it never shells out to the `gh` CLI or calls the GitHub API,
so it has no extra dependency and works offline. The suggested issue body is
meant to be copied into a new issue by hand, or piped straight through, e.g.
`gh issue create --body-file -`, if the `gh` CLI happens to be installed —
[`setup_checklist`](@ref) itself makes no such assumption.

Returns `nothing`; everything is written to `io`.

# Example

```julia
setup_checklist()
```
"""
function setup_checklist(target_dir::AbstractString = ".";
        package::Union{Nothing, AbstractString} = nothing,
        repo::Union{Nothing, AbstractString} = nothing,
        org::AbstractString = DEFAULT_ORG,
        io::IO = stdout)
    inputs = scaffold_inputs(target_dir; package = package, repo = repo,
        org = org)
    pkg = something(inputs.PACKAGE, "<package>")
    rp = something(inputs.REPO, "<org>/<package>.jl")
    steps = _setup_checklist_steps(pkg, rp)
    println(io, "Manual setup checklist for ", pkg, " (", rp, "):")
    println(io)
    for step in steps
        println(io, "- [ ] ", step)
    end
    println(io)
    println(io,
        "Suggested tracking issue body (copy into a new issue, or e.g. ",
        "`gh issue create --body-file -`):")
    println(io, "-"^72)
    print(io, _setup_checklist_issue_body(pkg, steps))
    return nothing
end
