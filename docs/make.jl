using Pkg: Pkg
Pkg.instantiate()

using Documenter
using EpiAwarePackageTools

# Generate the docs landing page from the package README so the docs index and
# the README stay in sync (the standard Documenter README-include pattern). The
# managed badge block is dropped (the badges are repo furniture, not docs) and a
# note records that the page is generated.
function readme_to_index(readme, index)
    body = read(readme, String)
    body = replace(body,
        r"<!-- badges:start -->.*?<!-- badges:end -->\n?"s => "")
    note = "<!-- This file is generated from README.md by make.jl; " *
           "edit the README. -->\n\n"
    open(index, "w") do io
        write(io, note, body)
    end
    return nothing
end

readme_to_index(joinpath(@__DIR__, "..", "README.md"),
    joinpath(@__DIR__, "src", "index.md"))

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
