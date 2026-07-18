# PACKAGE-OWNED — scaffold writes this once and never overwrites it.
#
# Header content for the release notes page. The managed `make.jl` prepends
# this to the project-root NEWS.md when both exist.

const RELEASE_NOTES_HEADER = """
```@meta
EditURL = "https://github.com/{{REPO}}/blob/main/NEWS.md"
```

# Release notes

NEWS.md (shown below) is the curated changelog: user-facing changes land
under `## Unreleased` in the PR that makes them, and that section is
renamed to a version heading at release.
See [GitHub Releases](https://github.com/{{REPO}}/releases) for the exact
commit list of every release.

"""
