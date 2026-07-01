# [Getting started](@id getting-started)

Welcome to the `{{PACKAGE}}` documentation.
This page is the quickstart.
The home page is generated from the README, so it stays short; put the
walkthrough a new user needs here and grow it into tutorials as the package
develops.

!!! note "These docs are generated"
    This site's layout, navigation, and infrastructure are produced by
    [EpiAwarePackageTools](https://github.com/EpiAware/EpiAwarePackageTools.jl).
    Editing the generated pages by hand is not needed; write your content in
    the package-owned source pages and let the scaffold render the rest.
    See [Infrastructure and template sync](@ref infrastructure) for how the
    kit keeps this repository in sync.

## Installation

```julia
using Pkg
Pkg.add("{{PACKAGE}}")
```

Load the package:

```julia
using {{PACKAGE}}
```

## A first example

_Replace this with a short, runnable example that shows the package's main
entry point._

## Learning more

- Want the full interface? See the [Public API](@ref public-api).
- See [Customising your docs](@ref customising) for how to make the
  seeded pages (this one included) your own.
- Want to report a problem or ask a question? Open an issue or start a
  discussion on the [GitHub repository](https://github.com/{{REPO}}).
