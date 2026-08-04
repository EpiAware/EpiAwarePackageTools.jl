# PACKAGE-OWNED — scaffold writes this once and never overwrites it.
#
# Header content for the release notes page. The managed `make.jl` prints this
# above the GitHub releases it fetches at build time, so it introduces those
# rather than describing a changelog file in the repo. There is no such file to
# keep in step with the tags: a release's notes are written on the release.

const RELEASE_NOTES_HEADER = """
```@meta
EditURL = "https://github.com/{{REPO}}/releases"
```

# Release notes

Every release of this package is published as a GitHub release.
The most recent are reproduced below, as they were written there.

"""
