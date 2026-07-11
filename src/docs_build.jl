# Generic documentation-build machinery.
#
# This is the package-agnostic core of the EpiAware docs standard: the build
# steps that every package's `docs/make.jl` would otherwise copy inline. The
# managed `make.jl` template is a thin caller — it wires the package-owned
# `pages.jl` + `docs_config.jl` into [`build_docs`](@ref) and nothing else, so
# the logic lives here (versioned + tested) rather than in each repo.
#
# The steps reproduce CensoredDistributions.jl's bespoke build generically:
#
#   - the Literate.jl tutorial pipeline (light tutorials rendered in-process,
#     heavy tutorials each executed in a fresh subprocess); on `skip_notebooks`
#     the light tutorials still render in-process (they are cheap) and only
#     the heavy tutorials fall back to fast-build heading stubs,
#   - `src/index.md` generated from the package README (badge block stripped,
#     optional package-named sections stripped, ```julia blocks turned into
#     `@example readme`, link rewrites applied),
#   - `src/release-notes.md` generated from a project-root `NEWS.md` + the
#     package-owned header,
#   - `src/benchmarks.md`: a tight managed skeleton (page heading + the
#     package-owned prose hook + a data-driven performance-history section that
#     renders the published timeline) — no package-specific free text,
#   - the API reference pages (`lib/public.md`, `lib/internals.md`) from the
#     module's documented bindings (one `@docs` entry per binding), and
#   - the render + deploy with `DocumenterVitepress` (adding DocumenterCitations
#     when a `src/refs.bib` exists).
#
# Documenter / DocumenterVitepress / DocumenterCitations / Literate are loaded
# at call time via `Base.require` (as the Benchmarks harness loads JSON3 /
# BenchmarkTools) so they stay out of the kit's own dependencies; a caller only
# needs them in its `docs` environment. Calls into the loaded modules go through
# `invokelatest` because their methods live in a newer world age.

"""
    EpiAwarePackageTools.DocsBuild

Generic documentation-build machinery shared across EpiAware packages.

[`build_docs`](@ref) runs the whole standard build for a package module; the
managed `docs/make.jl` is a thin caller that forwards the package-owned
`pages.jl` + `docs_config.jl` values. The individual steps
([`build_index`](@ref), [`build_release_notes`](@ref),
[`build_benchmark_page`](@ref), [`build_api_pages`](@ref)) are public so they
can be unit-tested and reused in isolation.
"""
module DocsBuild

import ..EpiAwarePackageTools: _require_pkg

export build_docs, build_index, build_release_notes, build_benchmark_page,
       build_api_pages, api_bindings, api_owning_modules

# ---- lazy dependency loading ----------------------------------------------

# Resolve the heavy docs dependencies at call time so they are not hard
# dependencies of EpiAwarePackageTools; a package only needs them in its `docs`
# environment. `_require_pkg` (defined once in the parent module, #58) is
# shared with every other lazy-load site in the kit.
function _documenter()
    _require_pkg("e30172f5-a6a5-5a46-863b-614d45cd2de4", "Documenter")
end
function _vitepress()
    _require_pkg("4710194d-e776-4893-9690-8d956a29c365", "DocumenterVitepress")
end
function _citations()
    _require_pkg("daee34ce-89f3-4625-b898-19384cb65244", "DocumenterCitations")
end
function _literate()
    _require_pkg("98b081ad-f1c9-55d3-8b20-4c87d4299306", "Literate")
end

# ---- README -> index.md ---------------------------------------------------

"""
    build_index(; readme, dest, repo, execute=true,
                rewrites=Pair{String,String}[], strip_sections=String[])

Generate `dest` (the docs home page) from the package `readme`.

The managed badge block (between the `<!-- badges:start -->` /
`<!-- badges:end -->` markers) and an inline logo `<img>` in the title are
removed. ```julia fences become runnable `@example readme` blocks when
`execute` is `true`. Each `from => to` in `rewrites` is applied line by line
(e.g. an absolute docs URL rewritten to an in-site `@ref`). Any heading whose
title is listed in `strip_sections` is dropped together with its body (up to
the next heading of the same or a higher level) — this is the package-owned
hook for omitting a named README section from the home page; the managed build
hardcodes no such section.
"""
function build_index(; readme::AbstractString, dest::AbstractString,
        repo::AbstractString, execute::Bool = true,
        rewrites = Pair{String, String}[],
        strip_sections = String[])
    mkpath(dirname(dest))
    open(dest, "w") do io
        println(io, "```@meta")
        println(io, "EditURL = \"https://github.com/$repo/blob/main/README.md\"")
        println(io, "```")
        println(io)
        in_badges = false
        strip_level = 0
        for line in eachline(readme)
            if occursin("<!-- badges:start -->", line)
                in_badges = true
                continue
            elseif occursin("<!-- badges:end -->", line)
                in_badges = false
                continue
            end
            in_badges && continue
            # Named-section stripping (package-config driven). A heading at a
            # level <= the section being stripped ends the stripped span; that
            # heading is then itself considered as a possible new strip start.
            m = match(r"^(#+)\s+(.*?)\s*$", line)
            if m !== nothing
                level = length(m.captures[1])
                if strip_level > 0 && level <= strip_level
                    strip_level = 0
                end
                if strip_level == 0 && strip(m.captures[2]) in strip_sections
                    strip_level = level
                    continue
                end
            end
            strip_level > 0 && continue
            if execute && startswith(line, "```julia")
                println(io, "```@example readme")
            elseif occursin("docs/src/assets/logo.svg", line)
                println(io, replace(line,
                    r"\s*<img[^>]*docs/src/assets/logo\.svg[^>]*>" => ""))
            else
                for (from, to) in rewrites
                    line = replace(line, from => to)
                end
                println(io, line)
            end
        end
    end
    println("Generated index.md from README.md")
    return dest
end

# ---- release-notes.md -----------------------------------------------------

"""
    build_release_notes(; news, header_file, dest)

Generate `dest` from a project-root `news` file prefixed with the package-owned
release-notes header defined in `header_file` (which must set
`RELEASE_NOTES_HEADER`). Both are optional: if either is missing nothing is
written and `nothing` is returned.
"""
function build_release_notes(; news::AbstractString, header_file::AbstractString,
        dest::AbstractString)
    if isfile(news) && isfile(header_file)
        # Evaluate the header file in a throwaway module and take the value it
        # returns (its trailing `const RELEASE_NOTES_HEADER = "..."`). Using the
        # include return value rather than reading the binding back avoids the
        # stricter global-binding world-age rules in Julia >= 1.12.
        header = Base.include(Module(:ReleaseNotesHeader), header_file)
        open(dest, "w") do io
            print(io, header)
            for line in eachline(news)
                println(io, line)
            end
        end
        println("Generated release-notes.md from header + NEWS.md")
        return dest
    else
        println("No NEWS.md / release-notes header found; skipping release notes")
        return nothing
    end
end

# ---- benchmark history page -----------------------------------------------

"""
    _embed_benchmark_history(io, repo, project_root; fetch = true)

Render the published benchmark timeline into `io`.

The history is published by `benchmark-history.yaml` to the repo's
`benchmarks` branch under `history/` (per-benchmark PNG plots + a
`table.md` ratio summary). GitHub Pages serves only the gh-pages docs
site, so the history is shown here by enumerating the branch at build
time (a best-effort `git fetch`) and embedding the ratio table inline
plus each plot via its raw GitHub URL. When the branch does not exist
yet (no release has published a timeline) it degrades to a link to
the branch.
"""
function _embed_benchmark_history(io, repo::AbstractString,
        project_root::AbstractString; fetch::Bool = true)
    ref = _benchmarks_ref(project_root; fetch = fetch)
    if ref !== nothing
        files = _history_files(project_root, ref)
        pngs = sort!(filter(f -> endswith(f, ".png"), files))
        has_table = "history/table.md" in files
        if has_table || !isempty(pngs)
            if has_table
                tbl = read(`git -C $project_root show $ref:history/table.md`,
                    String)
                println(io, "### Ratio summary")
                println(io)
                println(io, rstrip(tbl))
                println(io)
            end
            if !isempty(pngs)
                println(io, "### Per-benchmark timelines")
                println(io)
                for p in pngs
                    url = "https://raw.githubusercontent.com/$repo/benchmarks/$p"
                    println(io, "![$(basename(p))]($url)")
                    println(io)
                end
            end
            return true
        end
    end
    println(io,
        "The performance timeline (per-benchmark plots and a ratio table) is")
    println(io,
        "published to the [`benchmarks` branch]" *
        "(https://github.com/$repo/tree/benchmarks/history) on each push to")
    println(io, "`main` and each tagged release.")
    return false
end

# The resolvable git ref for the `benchmarks` branch, or `nothing`. A
# best-effort fetch first so a CI checkout (which fetches only the built ref)
# can still see it; failures (offline, no branch) are swallowed.
function _benchmarks_ref(project_root::AbstractString; fetch::Bool = true)
    if fetch
        try
            run(pipeline(`git -C $project_root fetch --quiet origin benchmarks`;
                stdout = devnull, stderr = devnull))
        catch
        end
    end
    for ref in ("origin/benchmarks", "benchmarks")
        try
            run(pipeline(`git -C $project_root rev-parse --verify --quiet $ref`;
                stdout = devnull, stderr = devnull))
            return ref
        catch
        end
    end
    return nothing
end

function _history_files(project_root::AbstractString, ref::AbstractString)
    try
        out = read(
            `git -C $project_root ls-tree -r --name-only $ref -- history`,
            String)
        return filter(!isempty, split(out, '\n'))
    catch
        return String[]
    end
end

"""
    build_benchmark_page(; dest, repo, package, prose_file, embed_history=true,
                         project_root=dirname(dirname(dest)))

Generate `dest` (the benchmark docs page). The managed skeleton is deliberately
tight: the page heading, the package-owned `prose_file` spliced verbatim (all
narrative lives there, minus any leading HTML comment, which is stripped so the
seed's authoring guidance never renders), and a data-driven
`## Performance history` section that
renders the timeline published to the repo's `benchmarks` branch (see
[`_embed_benchmark_history`](@ref)). Returns the list of linkcheck-ignore
regexes for the history URLs (the branch may not be live yet).
"""
function build_benchmark_page(; dest::AbstractString, repo::AbstractString,
        package::AbstractString, prose_file::AbstractString,
        embed_history::Bool = true,
        project_root::AbstractString = dirname(dirname(dest)))
    prose = isfile(prose_file) ? rstrip(read(prose_file, String)) :
            "Performance benchmarks for `$package`."
    # The package-owned prose file opens with an HTML comment that guides the
    # author (what to write, that the build splices it verbatim). Strip a
    # leading comment block so Documenter never renders it as literal text on
    # the Benchmarks page (#145). Splice-side so it holds even though the seed
    # is package-owned and sync never rewrites it.
    prose = lstrip(replace(prose, r"^\s*<!--.*?-->"s => ""))
    mkpath(dirname(dest))
    open(dest, "w") do io
        println(io, "# [Benchmarks](@id benchmarks)")
        println(io)
        println(io, prose)
        println(io)
        println(io, "## Performance history")
        println(io)
        if embed_history
            _embed_benchmark_history(io, repo, project_root)
        else
            println(io,
                "A performance timeline is published on each release.")
        end
    end
    println("Generated benchmarks.md (benchmark history page)")
    esc = replace(repo, "." => "\\.", "/" => "/")
    return Regex[
        Regex("raw\\.githubusercontent\\.com/$esc/benchmarks"),
        Regex("github\\.com/$esc/tree/benchmarks")
    ]
end

# ---- API reference pages --------------------------------------------------

# Whether `sym` is part of `mod`'s public API, matching how Documenter's
# `@autodocs` partitions Public/Private (`Base.ispublic` on >= 1.11, else
# exported).
function _is_public(mod::Module, sym::Symbol)
    return @static if isdefined(Base, :ispublic)
        Base.ispublic(mod, sym)
    else
        Base.isexported(mod, sym)
    end
end

# Whether `mod.sym` resolves to a documented binding, following re-export
# aliases to the owning module (#160). A binding re-exported from another
# module (or declared `public`/exported from a submodule) keeps its docstring
# in the module that *defines* it, not in `Base.Docs.meta(mod)`, so a scan of
# `mod`'s own meta alone misses it and the generated `@docs` block omits it —
# leaving every `@ref` to that name a broken link in the built HTML. `aliasof`
# walks the alias to the canonical binding; the docstring is present iff that
# binding's own module records it.
function _is_documented(mod::Module, sym::Symbol)
    isdefined(mod, sym) || return false
    b = Base.Docs.aliasof(Base.Docs.Binding(mod, sym))
    return haskey(Base.Docs.meta(b.mod), b)
end

"""
    api_bindings(mod) -> (public, private)

The bindings `mod` documents, split into public and private symbol vectors.
Each binding is listed once (not once per method signature, as `@autodocs`
would), so the rendered `@index` has one entry per function.

The scan covers both the docstrings defined directly in `mod` and the names
`mod` exports or declares `public` — including bindings re-exported from
another module or a submodule, whose docstrings live in the defining module
rather than `mod`'s own metadata (#160). A public/exported name is only
included when it actually resolves to a documented binding, so the generated
`@docs` block never lists an undocumented name (which Documenter would reject).
"""
function api_bindings(mod::Module)
    # `mod`'s own documented bindings (public + private) plus every name it
    # exports or declares `public` (`names` returns exported + public names,
    # re-exports included). De-duplicate by symbol.
    own = Set(b.var for b in keys(Base.Docs.meta(mod)))
    surface = Set(names(mod; all = false))
    candidates = sort!(collect(union(own, surface)); by = string)
    public = Symbol[]
    private = Symbol[]
    for v in candidates
        v === nameof(mod) && continue  # skip the module's own docstring
        # A re-exported / `public` name that carries no docstring is dropped so
        # the emitted `@docs` block stays render-safe; `mod`'s own meta entries
        # are documented by construction.
        (v in own || _is_documented(mod, v)) || continue
        push!(_is_public(mod, v) ? public : private, v)
    end
    return public, private
end

# Whether `m` is `root` or nested inside it (a submodule at any depth). The
# parent chain of a top-level module is itself; `Main`/`Base` terminate it.
function _within(m::Module, root::Module)
    while true
        m === root && return true
        p = parentmodule(m)
        p === m && return false
        m = p
    end
end

"""
    api_owning_modules(mod) -> Set{Module}

The external *owning* modules of the re-exported docstrings `mod` documents —
each module outside `mod`'s own module tree that records a docstring for one of
the bindings [`api_bindings`](@ref) lists.

`mod`'s generated `@docs` blocks list re-exported / `public`-declared bindings
by their `mod.name` (e.g. `ComposedDistributions.Convolved`), but Documenter's
`@docs` resolver only resolves a listed name when the module that *owns* its
docstring is in `makedocs`' `modules` (it filters found docstrings to that
set). A re-export's docstring lives in the defining module, not `mod`, so
[`build_docs`](@ref) folds this set into `modules` — otherwise every such
`@docs` entry raises Documenter's "no docs found ... in `@docs` block" warning
and its `@ref`s break in the built HTML (#175). The owner is found by the same
`Base.Docs.aliasof` walk `api_bindings` uses. `mod` and its own submodules are
excluded: Documenter already discovers a package's submodules from `mod`
itself, so only cross-package owners need adding.
"""
function api_owning_modules(mod::Module)
    public, private = api_bindings(mod)
    owners = Set{Module}()
    for v in Iterators.flatten((public, private))
        isdefined(mod, v) || continue
        b = Base.Docs.aliasof(Base.Docs.Binding(mod, v))
        haskey(Base.Docs.meta(b.mod), b) || continue
        _within(b.mod, mod) && continue
        push!(owners, b.mod)
    end
    return owners
end

function _write_api_page(path, title, anchor, page, intro, api_heading,
        mod, names)
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
    return path
end

"""
    build_api_pages(mod, lib_dir)

Write `lib/public.md` and `lib/internals.md` under `lib_dir` from `mod`'s
documented bindings (see [`api_bindings`](@ref)).
"""
function build_api_pages(mod::Module, lib_dir::AbstractString)
    public, private = api_bindings(mod)
    _write_api_page(
        joinpath(lib_dir, "public.md"),
        "Public Documentation", "public-api", "public.md",
        "Documentation for `$mod`'s public interface.",
        "Public API", mod, public)
    _write_api_page(
        joinpath(lib_dir, "internals.md"),
        "Internal Documentation", nothing, "internals.md",
        "Documentation for `$mod`'s internal interface.",
        "Internal API", mod, private)
    println(
        "Generated API pages: $(length(public)) public, " *
        "$(length(private)) internal bindings")
    return public, private
end

# ---- Literate tutorial pipeline -------------------------------------------

# Render the Literate tutorial pipeline into `tutorials_dir`. Light tutorials
# emit `@example` blocks Documenter runs in-process; heavy tutorials are each
# executed once in a fresh subprocess (via the package-owned
# `run_literate_tutorial.jl`) so native/memory state cannot accumulate.
function _process_tutorials(docs_dir, tutorials_dir, light, heavy)
    (isempty(light) && isempty(heavy)) && return
    Literate = _literate()
    if !isempty(light)
        println("Building light Literate tutorials " *
                "(this may take several minutes)...")
        # `DocumenterFlavor` lives in a newer world age than this function
        # (Literate is lazily `Base.require`d), so construct it through
        # `invokelatest` like every other call into the lazily-loaded deps.
        flavor = Base.invokelatest(Literate.DocumenterFlavor)
        for file in light
            Base.invokelatest(Literate.markdown,
                joinpath(tutorials_dir, file), tutorials_dir;
                flavor = flavor, mdstrings = true, credit = false)
        end
    end
    if !isempty(heavy)
        tutorial_threads = get(ENV, "JULIA_NUM_THREADS", "4")
        println("Executing heavy Literate tutorials, one per subprocess " *
                "($(tutorial_threads) threads each)...")
        runner = joinpath(docs_dir, "run_literate_tutorial.jl")
        jl = Base.julia_cmd()
        for file in heavy
            input = joinpath(tutorials_dir, file)
            println("  executing $file in a fresh subprocess...")
            opts = `--threads=$(tutorial_threads) --project=$(docs_dir)`
            run(`$jl $opts $runner $input $tutorials_dir`)
        end
    end
    println("Literate tutorial processing complete")
    return
end

# The rendered `.md` basename Literate produces for a tutorial source file
# (`tutorial_stubs` is keyed by this name, `light`/`heavy_tutorials` by the
# `.jl` source name).
_tutorial_md_name(jl_file) = string(splitext(jl_file)[1], ".md")

# The rendered `.md` names for `files` (a subset of `light`/`heavy_tutorials`
# `.jl` source names), as the `Set` `tutorial_stubs` is keyed by.
_tutorial_md_names(files) = Set(_tutorial_md_name(f) for f in files)

# The tutorial-processing step of `build_docs`, split out so it can be unit
# tested directly (`build_docs` itself is an integration point, exercised by
# each package's own docs build rather than by the kit's own test suite).
# Under `skip_notebooks`, light tutorials still render in-process (they are
# cheap); only the heavy tutorials — the ones the flag exists to skip — fall
# back to `tutorial_stubs` heading stubs. Independent of `skip_notebooks`,
# any heavy tutorial named in `force_stub` never executes and always renders
# from its `tutorial_stubs` heading — the escape hatch for a heavy tutorial
# that is not just slow but has an unresolved model/identifiability problem
# (so running it is not a matter of CI budget, e.g. a hung/non-terminating
# sampler), while its siblings keep executing for real in their own
# subprocess (unaffected — no need to fall back to whole-build stubbing just
# because one tutorial cannot run yet).
function _render_tutorials(docs_dir, tutorials_dir, skip_notebooks::Bool,
        light, heavy, stubs; force_stub = String[])
    if !skip_notebooks
        run_heavy = filter(!in(force_stub), heavy)
        _process_tutorials(docs_dir, tutorials_dir, light, run_heavy)
        if !isempty(force_stub)
            force_stub_md = _tutorial_md_names(force_stub)
            _write_tutorial_stubs(tutorials_dir,
                filter(p -> first(p) in force_stub_md, stubs))
        end
    else
        println("Fast docs build: rendering light tutorials in-process, " *
                "stubbing heavy tutorials (--skip-notebooks or " *
                "SKIP_NOTEBOOKS=true)")
        _process_tutorials(docs_dir, tutorials_dir, light, String[])
        heavy_md = _tutorial_md_names(heavy)
        heavy_stubs = filter(p -> first(p) in heavy_md, stubs)
        _write_tutorial_stubs(tutorials_dir, heavy_stubs)
    end
    return nothing
end

# Fast-build stubs: a lightweight `.md` for each tutorial so the nav resolves
# and cross-references still anchor without running the heavy pipeline.
function _write_tutorial_stubs(tutorials_dir, stubs)
    isempty(stubs) && return
    mkpath(tutorials_dir)
    for (file, heading) in stubs
        open(joinpath(tutorials_dir, file), "w") do io
            println(io, heading)
            println(io)
            println(io,
                "_This tutorial is omitted from the fast documentation " *
                "build. Build the full documentation (`task docs`) to " *
                "render it._")
        end
    end
    println("Wrote fast-build tutorial stubs")
    return
end

# Copy every tutorial data directory into the matching build output dir so the
# bundled data ships with the rendered site. Generic over any tutorial that
# carries a `data` or `<name>-data` dir.
function _copy_tutorial_data(src_root, build_root)
    for (root, dirs, _) in walkdir(src_root)
        for d in dirs
            (d == "data" || endswith(d, "-data")) || continue
            src_data = joinpath(root, d)
            rel = relpath(src_data, src_root)
            dest_data = joinpath(build_root, rel)
            mkpath(dirname(dest_data))
            cp(src_data, dest_data; force = true)
            println("Copied tutorial data: $rel")
        end
    end
    return
end

# ---- orchestrator ---------------------------------------------------------

# Remove any `... => "benchmarks.md"` leaf from a Documenter `pages` nav tree
# (at any nesting depth). Used when the benchmark page is disabled but a
# package-owned `pages.jl` still lists the entry, so the built nav carries no
# dangling link. Every non-benchmark entry is kept unchanged.
function _strip_benchmark_nav(pages)
    kept = Any[]
    for entry in pages
        if entry isa Pair && entry.second isa AbstractString
            endswith(entry.second, "benchmarks.md") && continue
            push!(kept, entry)
        elseif entry isa Pair && entry.second isa AbstractVector
            push!(kept, entry.first => _strip_benchmark_nav(entry.second))
        else
            push!(kept, entry)
        end
    end
    return kept
end

# Verify the Documenter-processed home page was not silently truncated by the
# (`npm install` + `vitepress build`) pipeline (#91): reproduced (though not
# reliably — the failure appears to depend on `docs/node_modules`/instantiate
# ordering) on a clean `docs/build`/`docs/node_modules`, `docs/make.jl` can
# exit 0 having copied only a PARTIAL `docs/src/index.md` into the internal
# `docs/build/.documenter/index.md`, with no error or warning — silently
# hiding real content (and any dead links inside it) from a local
# contributor. A genuinely complete Documenter pass never drops prose lines
# (`@ref`/`@example`/docstring expansion only ever adds content), so
# comparing line counts against the kit-generated source (already past any
# package's own rewrites/`strip_sections`) catches the failure loudly instead
# of silently shipping a half-built home page. `built_dir` may lack an
# `index.md` for callers that skip the Documenter build entirely (tests
# exercising only the page generators); there is then nothing to check.
function _check_index_not_truncated(index_src::AbstractString,
        built_dir::AbstractString)
    isfile(index_src) || return nothing
    built = joinpath(built_dir, "index.md")
    isfile(built) || return nothing
    src_lines = countlines(index_src)
    built_lines = countlines(built)
    if built_lines < max(5, src_lines ÷ 2)
        error("docs build looks truncated (kit issue #91): the built home " *
              "page has $built_lines lines but the generated " *
              "docs/src/index.md has $src_lines lines. This matches the " *
              "silent npm/vitepress ordering failure from #91 — re-run the " *
              "docs build; if it persists, run `julia --project=docs -e " *
              "'using Pkg; Pkg.instantiate()'` once (so docs/node_modules " *
              "already exists) before running `docs/make.jl`.")
    end
    return nothing
end

"""
    build_docs(mod; repo, authors, pages, deploy_url=nothing,
               skip_notebooks=false, tutorials_subdir, light_tutorials=[],
               heavy_tutorials=[], tutorial_stubs=[], force_stub_tutorials=[],
               linkcheck_ignore=[], index_rewrites=[], readme_execute=true,
               index_strip_sections=[], benchmark_page=true, extra_modules=[],
               build_vitepress=true, deploy=true)

Run the standard EpiAware documentation build for package module `mod`. All
paths derive from `pkgdir(mod)`, so the managed `docs/make.jl` only forwards the
package-owned config. Generates the home page, release notes, benchmark page,
and API pages, processes the Literate tutorials, then renders with
`DocumenterVitepress` and (when `deploy`) deploys. Under `skip_notebooks`,
light tutorials still render in-process (cheap: seconds, not minutes) and only
the heavy tutorials fall back to `tutorial_stubs` heading stubs — the flag
exists to skip the slow ones, not the cheap ones. Independent of
`skip_notebooks`, any `heavy_tutorials` entry named in `force_stub_tutorials`
never executes and always renders from its `tutorial_stubs` heading — for a
heavy tutorial with an unresolved problem of its own (e.g. a model that does
not terminate in reasonable time), so it need not block its siblings from
running for real. `deploy=false` builds without deploying, and
`build_vitepress=false` runs Documenter without the final VitePress (npm)
pass — both used by tests and fast local content builds.

The owning modules of `mod`'s re-exported docstrings are auto-discovered (see
`api_owning_modules`) and folded into Documenter's `modules` so the
generated `@docs` blocks for those re-exports resolve (#175); `extra_modules`
adds any further owner modules auto-discovery cannot reach (e.g. a re-export
referenced only from prose). Because Documenter drives its missing-docstring
completeness check off the same `modules` list — with no working way to scope
that check while widening `@docs` resolution — the completeness check is
disabled whenever the resolution set is widened, so a package is never held
responsible for a dependency's own missing-docstring hygiene (`mod`'s own
completeness is already guaranteed by construction: `api_bindings` emits every
docstring `mod` owns).
"""
function build_docs(mod::Module; repo::AbstractString, authors::AbstractString,
        pages, deploy_url = nothing, skip_notebooks::Bool = false,
        tutorials_subdir::AbstractString = joinpath(
            "getting-started", "tutorials"),
        light_tutorials = String[], heavy_tutorials = String[],
        tutorial_stubs = Pair{String, String}[],
        force_stub_tutorials = String[],
        linkcheck_ignore = Regex[], index_rewrites = Pair{String, String}[],
        readme_execute::Bool = true, index_strip_sections = String[],
        benchmark_page::Bool = true, extra_modules = Module[],
        build_vitepress::Bool = true, deploy::Bool = true)
    project_root = pkgdir(mod)
    # `pkgdir` returns `Union{Nothing,String}`; narrow to a concrete String up
    # front so the downstream `joinpath` calls never see `Nothing` (keeps JET
    # type-stable). A missing package directory is unrecoverable here.
    project_root === nothing &&
        error("Cannot locate the package directory for module $mod")
    docs_dir = joinpath(project_root, "docs")
    src_dir = joinpath(docs_dir, "src")
    tutorials_dir = joinpath(src_dir, tutorials_subdir)

    # --- tutorials ---------------------------------------------------------
    _render_tutorials(docs_dir, tutorials_dir, skip_notebooks, light_tutorials,
        heavy_tutorials, tutorial_stubs; force_stub = force_stub_tutorials)

    # --- generated pages ---------------------------------------------------
    build_index(; readme = joinpath(project_root, "README.md"),
        dest = joinpath(src_dir, "index.md"), repo = repo,
        execute = readme_execute, rewrites = index_rewrites,
        strip_sections = index_strip_sections)
    build_release_notes(; news = joinpath(project_root, "NEWS.md"),
        header_file = joinpath(docs_dir, "release_notes_header.jl"),
        dest = joinpath(src_dir, "release-notes.md"))
    benchmark_linkcheck = Regex[]
    if benchmark_page
        benchmark_linkcheck = build_benchmark_page(;
            dest = joinpath(src_dir, "benchmarks.md"), repo = repo,
            package = string(mod),
            prose_file = joinpath(docs_dir, "benchmarks.md"),
            project_root = project_root)
    else
        println("BENCHMARK_PAGE = false; skipping benchmark history page")
        # Drop any stale Benchmarks nav entry so a package that disabled the page
        # without regenerating its (package-owned) `pages.jl` still gets a nav
        # tree with no dangling "benchmarks.md" link.
        pages = _strip_benchmark_nav(pages)
    end
    build_api_pages(mod, joinpath(src_dir, "lib"))

    # --- render ------------------------------------------------------------
    Documenter = _documenter()
    DocumenterVitepress = _vitepress()
    Base.invokelatest(Documenter.DocMeta.setdocmeta!, mod, :DocTestSetup,
        Expr(:using, Expr(:., nameof(mod))); recursive = true)

    bib_path = joinpath(src_dir, "refs.bib")
    plugins = if isfile(bib_path)
        DocumenterCitations = _citations()
        [Base.invokelatest(DocumenterCitations.CitationBibliography, bib_path;
            style = :numeric)]
    else
        Documenter.Plugin[]
    end

    format = Base.invokelatest(DocumenterVitepress.MarkdownVitepress;
        repo = "github.com/$repo", devbranch = "main", devurl = "dev",
        deploy_url = deploy_url, build_vitepress = build_vitepress,
        keep = :patch)

    # The modules Documenter's `@docs` resolver searches. `mod` always leads;
    # the owning modules of `mod`'s re-exported docstrings follow so their
    # `@docs` entries resolve instead of raising "no docs found" (#175). A
    # package may name further owner modules via `extra_modules` (docs_config)
    # for a re-export auto-discovery cannot reach.
    owning_modules = union(Set{Module}(extra_modules), api_owning_modules(mod))
    delete!(owning_modules, mod)
    doc_modules = Module[mod]
    append!(doc_modules, collect(owning_modules))
    # Documenter drives its missing-docstring completeness check off this same
    # `modules` list, and there is no working way to scope that check to `mod`
    # while widening `@docs` resolution: `checkdocs_ignored_modules` does not
    # exclude a top-level owner module (Documenter's `submodules` always keeps
    # the roots it is handed), and no `checkdocs`-allowlist keyword exists. So
    # whenever we widen for re-export resolution we disable the completeness
    # check (`:none`), keeping a package off the hook for its dependencies'
    # own missing-docstring hygiene; `mod`'s own completeness needs no check
    # here because `api_bindings` emits every docstring `mod` owns by
    # construction. With no re-exports the default `:all` check over `mod`
    # alone is kept.
    checkdocs = length(doc_modules) > 1 ? :none : :all
    # `root` is pinned to the package's docs dir. Documenter otherwise defaults
    # it to the running script's directory; because the build now lives in the
    # kit rather than in `docs/make.jl`, the thin caller (or a test) may run
    # from anywhere, so set it explicitly. `source`/`build` keep their defaults
    # relative to `root` (`src`/`build`), matching the previous layout.
    Base.invokelatest(Documenter.makedocs; root = docs_dir,
        sitename = "$mod.jl",
        authors = authors, clean = true, doctest = false,
        linkcheck = !skip_notebooks,
        linkcheck_ignore = vcat(linkcheck_ignore, benchmark_linkcheck),
        warnonly = [
            :docs_block, :missing_docs, :autodocs_block, :cross_references],
        checkdocs = checkdocs,
        modules = doc_modules, pages = pages, format = format,
        plugins = plugins)

    # Fail loudly rather than silently ship a truncated home page (#91).
    _check_index_not_truncated(joinpath(src_dir, "index.md"),
        joinpath(docs_dir, "build", ".documenter"))

    _copy_tutorial_data(src_dir, joinpath(docs_dir, "build"))

    if deploy
        Base.invokelatest(DocumenterVitepress.deploydocs;
            repo = "github.com/$repo", target = "build", branch = "gh-pages",
            devbranch = "main", push_preview = true)
    end
    return
end

end # module DocsBuild
