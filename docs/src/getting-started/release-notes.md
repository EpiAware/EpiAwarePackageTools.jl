# [Release notes convention](@id release-notes)

Release notes live on the GitHub release, not in a file in the repository.
There is no `NEWS.md` to keep in step with the tags.

The docs site reproduces them: the managed `docs/make.jl` fetches the repo's
published releases when the site is built and writes them into
`docs/src/release-notes.md`, newest first.
Nothing is committed, so the page cannot drift from what was actually
released.

## Writing a release

TagBot opens each release body with the list of pull requests merged since the
previous tag.
That list is the record of what changed and needs no editing.

Add a short paragraph above it whenever the release is more than routine: what
the release is for, and anything a user has to do differently because of it.
A breaking change always gets one, naming what broke and what to do instead.
Write it in the org's prose style, one sentence per line.

Edit the release itself when a note needs fixing.
The docs page picks the change up on the next build.

## How the page is built

`EpiAwarePackageTools.DocsBuild.build_release_notes` reads
`https://api.github.com/repos/OWNER/REPO/releases` and renders the most recent
ten.
Each is written under its tag as a `##` heading with its date and a link to
the release; headings inside the body shift down two levels to nest under it,
and TagBot's repeated title line is dropped.

The fetch is unauthenticated unless `GITHUB_TOKEN` or `GH_TOKEN` is in the
environment, which CI always sets.
Without one, GitHub allows 60 requests an hour per IP address, which is ample
for docs builds but is the first thing to check if the page starts degrading
locally.

The page never fails a build.
When the releases cannot be fetched (offline, rate-limited, no API access) or
the repo has no releases yet, it degrades to a short note and a link to the
releases page, and the build logs why.
This is the same degradation the benchmark history page uses for its
`benchmarks` branch.

## The page header

`docs/release_notes_header.jl` is package-owned and holds the prose above the
releases.
A package with no header file gets the standard one.

A header that still mentions `NEWS.md` predates this convention: it describes
a file the page no longer renders, so the build warns, names the file, and
uses the standard header instead.
Rewriting that one file clears the warning.

## Packages with an existing NEWS.md

A `NEWS.md` already in a repository is left alone.
The kit no longer seeds one, reads one, or renders one, so the file is inert.
Delete it once the published releases cover its contents, or keep it as a
historical record.
Either way, new entries go on the release.
