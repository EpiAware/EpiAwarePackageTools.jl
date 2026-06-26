using Pkg: Pkg
Pkg.instantiate()

using Documenter
using EpiAwarePackageTools

makedocs(;
    sitename = "EpiAwarePackageTools.jl",
    authors = "EpiAware contributors",
    modules = [EpiAwarePackageTools],
    pages = [
        "Home" => "index.md",
        "API" => "api.md"
    ],
    format = Documenter.HTML(;
        prettyurls = get(ENV, "CI", "false") == "true"),
    warnonly = [:missing_docs]
)

deploydocs(;
    repo = "github.com/EpiAware/EpiAwarePackageTools.jl",
    devbranch = "main",
    push_preview = true
)
