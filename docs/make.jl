# MANAGED by EpiAwarePackageTools.scaffold — do not edit by hand.
#
# The standard EpiAware documentation build: Documenter + DocumenterVitepress
# (the org docs standard, as used by CensoredDistributions.jl). It
#
#   - generates `src/index.md` from the package README (badge block stripped),
#   - generates the API reference pages (`lib/public.md`, `lib/internals.md`)
#     from the module's documented bindings (one `@docs` entry per binding so the
#     index has one entry per function, not one per method signature), and
#   - renders the site with `DocumenterVitepress.MarkdownVitepress` and deploys
#     it with `DocumenterVitepress.deploydocs`.
#
# Build it with `task docs` (or `julia --project=docs docs/make.jl`).

using Pkg: Pkg
Pkg.instantiate()

using DocumenterVitepress
using Documenter
using EpiAwarePackageTools

include("pages.jl")

# Generate index.md from README.md, stripping the managed badge block (the
# markers and everything between them) so the docs landing page mirrors the
# README prose without the badge table.
let readme = joinpath(dirname(@__DIR__), "README.md"),
    index = joinpath(@__DIR__, "src", "index.md")

    mkpath(dirname(index))
    open(index, "w") do io
        println(io, "```@meta")
        println(io,
            "EditURL = \"https://github.com/EpiAware/EpiAwarePackageTools.jl/blob/main/README.md\"")
        println(io, "```")
        println(io)
        in_badges = false
        for line in eachline(readme)
            if occursin("<!-- badges:start -->", line)
                in_badges = true
                continue
            elseif occursin("<!-- badges:end -->", line)
                in_badges = false
                continue
            end
            in_badges && continue
            # README ```julia blocks are rendered as highlighted (non-executed)
            # code. A README block that should be EXECUTED on the docs home page
            # is written as ```@example readme directly in the README; it carries
            # through unchanged. This keeps an illustrative README (with
            # placeholder names) from failing the docs build, while still
            # supporting runnable home-page examples when wanted.
            println(io, line)
        end
    end
    println("Generated index.md from README.md")
end

# Whether `sym` is part of `mod`'s public API, matching how Documenter's
# `@autodocs` partitions `Public`/`Private` (`Base.ispublic` on >= 1.11, else
# exported).
function _is_public(mod::Module, sym::Symbol)
    return @static if isdefined(Base, :ispublic)
        Base.ispublic(mod, sym)
    else
        Base.isexported(mod, sym)
    end
end

# The bindings `mod` documents, split into public and private. Listing each
# binding ONCE (rather than once per method signature, as `@autodocs` would)
# keeps every method docstring while collapsing the `@index` to one entry per
# function.
function api_bindings(mod::Module)
    meta = Base.Docs.meta(mod)
    vars = sort!([b.var for b in keys(meta)]; by = string)
    public = Symbol[]
    private = Symbol[]
    for v in vars
        v === nameof(mod) && continue  # skip the module's own docstring
        push!(_is_public(mod, v) ? public : private, v)
    end
    return public, private
end

function write_api_page(path, title, anchor, page, intro, api_heading, mod, names)
    mkpath(dirname(path))
    open(path, "w") do io
        if anchor === nothing
            println(io, "# $title")
        else
            println(io, "# [$title](@id $anchor)")
        end
        println(io)
        println(io, intro)
        println(io)
        println(io, "## Contents")
        println(io)
        println(io, "```@contents")
        println(io, "Pages = [\"$page\"]")
        println(io, "Depth = 2:2")
        println(io, "```")
        println(io)
        println(io, "## Index")
        println(io)
        println(io, "```@index")
        println(io, "Pages = [\"$page\"]")
        println(io, "```")
        println(io)
        println(io, "## $api_heading")
        println(io)
        println(io, "```@docs")
        for name in names
            println(io, string(mod, ".", name))
        end
        println(io, "```")
    end
end

let (public, private) = api_bindings(EpiAwarePackageTools)
    lib_dir = joinpath(@__DIR__, "src", "lib")
    write_api_page(
        joinpath(lib_dir, "public.md"),
        "Public Documentation", "public-api", "public.md",
        "Documentation for `EpiAwarePackageTools`'s public interface.",
        "Public API", EpiAwarePackageTools, public
    )
    write_api_page(
        joinpath(lib_dir, "internals.md"),
        "Internal Documentation", nothing, "internals.md",
        "Documentation for `EpiAwarePackageTools`'s internal interface.",
        "Internal API", EpiAwarePackageTools, private
    )
    println(
        "Generated API pages: $(length(public)) public, " *
        "$(length(private)) internal bindings")
end

DocMeta.setdocmeta!(EpiAwarePackageTools, :DocTestSetup,
    :(using EpiAwarePackageTools); recursive = true)

makedocs(; sitename = "EpiAwarePackageTools.jl",
    authors = "Sam Abbott, EpiAware contributors",
    clean = true, doctest = false,
    warnonly = [
        :docs_block, :missing_docs, :autodocs_block, :cross_references
    ],
    modules = [EpiAwarePackageTools],
    pages = pages,
    format = DocumenterVitepress.MarkdownVitepress(
        repo = "github.com/EpiAware/EpiAwarePackageTools.jl",
        devbranch = "main",
        devurl = "dev",
        # `deploy_url` controls the VitePress base path. The DEFAULT is
        # `nothing`: DocumenterVitepress then derives the base from the repo
        # name, so the site renders at the GitHub project-pages URL
        # (`epiaware.org/<Repo>.jl/`) with NO DNS to wire. A bare-domain
        # `deploy_url` would set base `/`, which only renders correctly when the
        # site is served at that domain's root (a wired custom subdomain). To
        # opt into `<pkg>.epiaware.org`, scaffold/update with
        # `docs_subdomain = true` (or a host string) AND set the repo's GitHub
        # Pages custom domain + a DNS record for that host.
        deploy_url = "epiawarepackagetools.epiaware.org",
        keep = :patch
    )
)

DocumenterVitepress.deploydocs(
    repo = "github.com/EpiAware/EpiAwarePackageTools.jl",
    target = "build",
    branch = "gh-pages",
    devbranch = "main",
    push_preview = true
)
