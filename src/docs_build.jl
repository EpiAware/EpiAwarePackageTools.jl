# Generic documentation-build machinery: the build steps every package's
# `docs/make.jl` would otherwise copy inline. The managed `make.jl` template is
# a thin caller that wires the package-owned `pages.jl` + `docs_config.jl` into
# `build_docs`.
#
# Documenter / DocumenterVitepress / DocumenterCitations / Literate are loaded
# at call time via `Base.require` so they stay out of the kit's own
# dependencies; a caller only needs them in its `docs` environment. Calls into
# the loaded modules go through `invokelatest` (newer world age).

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

import Pkg

import ..EpiAwarePackageTools: _require_pkg
import Downloads
import Statistics

export build_docs, build_index, build_release_notes, build_benchmark_page,
    build_api_pages, api_bindings, api_owning_modules, api_remotes
export ADBenchmarkResults, load_ad_benchmarks, ad_benchmark_note,
    ad_benchmark_results_path, published_ad_benchmark_results

# ---- lazy dependency loading ----------------------------------------------

# Resolve the heavy docs dependencies at call time via the shared
# `_require_pkg` (#58) so they stay out of the kit's own Project.toml.
function _documenter()
    return _require_pkg("e30172f5-a6a5-5a46-863b-614d45cd2de4", "Documenter")
end
function _vitepress()
    return _require_pkg("4710194d-e776-4893-9690-8d956a29c365", "DocumenterVitepress")
end
function _citations()
    return _require_pkg("daee34ce-89f3-4625-b898-19384cb65244", "DocumenterCitations")
end
function _literate()
    return _require_pkg("98b081ad-f1c9-55d3-8b20-4c87d4299306", "Literate")
end
# `Plots` (GR backend) draws the overall trend plot (#202).
function _plots()
    return _require_pkg("91a5bcdd-55d7-5caf-9e0b-520d859cae80", "Plots")
end
# `JSON` parses the GitHub Releases API response for the release-notes page.
# It is not declared by the docs environment and does not need to be: it is a
# dependency of Documenter, DocumenterVitepress and Literate, so it is in every
# adopter's docs manifest already, and `Base.require` resolves a manifest entry
# by UUID whether it is a direct or an indirect dependency. A build where it
# cannot be loaded degrades to the link-out page like any other fetch failure.
function _json()
    return _require_pkg("682c06a0-de6a-54ab-a142-c8b1cf79cde6", "JSON")
end

# The AD benchmark page's results reader: a path in, measurements out, no
# Documenter coupling.
include("ad_benchmarks.jl")

# ---- empty-anchor inventory guard (#232) ----------------------------------

# Shim for DocumenterVitepress 0.3.x: its inventory writer pushes an
# `InventoryItem` per anchored header, and that constructor rejects an empty
# `name`, so one header with an empty anchor id aborts the whole docs build.
# The kit's own markdown no longer emits one (#204/#211), but a third-party
# docstring rendered via the widened `modules` list (#175) can.
#
# The guard swaps in a writer that warns (naming page + heading) and skips the
# entry instead of throwing. Self-retiring: applied only when the installed
# writer is observed to abort (`_empty_anchor_aborts`, which stops firing once
# LuxDL/DocumenterVitepress.jl#375 lands) and the installed version is no newer
# than the release the body below was copied from.
const _VITEPRESS_LAST_KNOWN_BROKEN = v"0.3.5"

# The quoted replacement method, evaluated inside DocumenterVitepress so every
# name resolves in that module exactly as the original does.
function _empty_anchor_writer()
    return quote
        function render(
                io::IO, mime::MIME"text/plain",
                node::Documenter.MarkdownAST.Node,
                header::Documenter.AnchoredHeader, page, doc; kwargs...
            )
            anchor = header.anchor
            id = replace(sanitized_anchor_label(anchor), " " => "-")
            heading = first(node.children)
            println(io)
            print(io, "#"^(heading.element.level), " ")
            heading_iob = IOBuffer()
            render(
                heading_iob, mime, node, heading.children, page, doc;
                kwargs...
            )
            heading_text = rstrip(String(take!(heading_iob)))
            print(io, heading_text)
            print(io, " {#$(id)}")
            if haskey(kwargs, :inventory)
                if isempty(anchor.id)
                    # Patched by EpiAwarePackageTools (kit #232).
                    @warn "Skipping inventory entry: anchored header has " *
                        "an empty anchor id" page = page.source heading = heading_text
                else
                    item = InventoryItem(
                        name = anchor.id,
                        domain = "std",
                        role = "label",
                        dispname = _get_inventory_dispname(
                            anchor.id,
                            Documenter.MDFlatten.mdflatten(anchor.node)
                        ),
                        priority = -1,
                        uri = _get_inventory_uri(doc, page, id)
                    )
                    push!(kwargs[:inventory], item)
                end
            end
            return println(io)
        end
    end
end

# Render a synthetic anchored header through DocumenterVitepress' writer with
# an inventory attached, returning the markdown and the collected items.
# `page`/`doc` are duck-typed stand-ins: on this path the writer only reads
# `page.source`, `page.build` and `doc.user.build`, and touches no files. Used
# by the probe below and by the regression test.
function _anchor_probe_render(
        Documenter, DocumenterVitepress;
        id::AbstractString = "", heading::AbstractString = "Probe heading"
    )
    # `Base.eval` runs in the latest world age, so the freshly `require`d (and,
    # after patching, redefined) methods are visible without `invokelatest`.
    return Base.eval(
        @__MODULE__,
        quote
            let D = $Documenter, V = $DocumenterVitepress
                MA = D.MarkdownAST
                head = MA.Node(MA.Heading(2))
                push!(head.children, MA.Node(MA.Text($heading)))
                anchor = D.Anchor(nothing)
                anchor.id = $id
                anchor.node = head
                node = MA.Node(D.AnchoredHeader(anchor))
                push!(node.children, head)
                page = (
                    source = "probe.md",
                    build = joinpath("build", "probe.md"),
                    globals = nothing,
                )
                doc = (user = (build = "build",),)
                io = IOBuffer()
                items = Any[]
                V.render(
                    io, MIME("text/plain"), node, node.element, page, doc;
                    inventory = items
                )
                (String(take!(io)), items)
            end
        end
    )
end

# Does the installed writer still abort on an empty anchor id? `true` only for
# the known-broken `InventoryItem` `ArgumentError`; a clean render (upstream
# fixed) or an unexpected failure (API drift) gives `false`, so the kit never
# overwrites a method it no longer understands.
function _empty_anchor_aborts(Documenter, DocumenterVitepress)
    try
        # Silenced: on an already-guarded writer the probe would log a fake
        # culprit (`page = "probe.md"`) into the adopter's real docs log.
        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            _anchor_probe_render(Documenter, DocumenterVitepress; id = "")
        end
        return false
    catch err
        e = err isa LoadError ? err.error : err
        if e isa ArgumentError && occursin("non-zero length", e.msg)
            return true
        end
        @warn "Empty-anchor probe failed unexpectedly; leaving the " *
            "DocumenterVitepress writer unpatched (kit #232)" exception = e
        return false
    end
end

# Is `version`'s writer the one the shim's copied body was taken from, and so
# safe to overwrite? Patching a newer release would silently revert unseen
# upstream changes to that method. `pkgversion` returns `nothing` for a module
# loaded from a bare path, which is treated the same as "too new". A pure
# predicate so the refuse-to-patch branch is testable.
function _vitepress_patchable(version::Union{Nothing, VersionNumber})
    if version === nothing
        @warn "Could not determine the installed DocumenterVitepress " *
            "version, so cannot confirm its writer is the one this shim " *
            "copies ($(_VITEPRESS_LAST_KNOWN_BROKEN)); leaving it " *
            "unpatched rather than overwriting a method body that may not " *
            "match (kit #232)."
        return false
    end
    version > _VITEPRESS_LAST_KNOWN_BROKEN || return true
    @warn "DocumenterVitepress $version still aborts the docs build on " *
        "an anchored header with an empty anchor id, but its writer is " *
        "newer than the version this shim copies " *
        "($(_VITEPRESS_LAST_KNOWN_BROKEN)); leaving it unpatched " *
        "rather than silently reverting unseen upstream changes. " *
        "Refresh the kit's copy of the method and the version bound " *
        "(kit #232)."
    return false
end

"""
    _guard_empty_anchors()

Make the DocumenterVitepress inventory writer warn-and-skip (rather than abort)
on an anchored header with an empty anchor id. Returns `true` when the writer
was patched, `false` when no patch was needed (upstream fixed, or too new to
patch safely). Idempotent, and self-retiring once the upstream fix
(LuxDL/DocumenterVitepress.jl#375) lands.
"""
function _guard_empty_anchors()
    Documenter = _documenter()
    DocumenterVitepress = _vitepress()
    _empty_anchor_aborts(Documenter, DocumenterVitepress) || return false
    _vitepress_patchable(pkgversion(DocumenterVitepress)) || return false
    Base.eval(DocumenterVitepress, _empty_anchor_writer())
    return true
end

# ---- README -> index.md ---------------------------------------------------

# Whether `line` opens or closes a fenced code block. Nested fences of a
# different backtick/tilde count are not distinguished.
function _is_fence_delimiter(line::AbstractString)
    return startswith(line, "```") ||
        startswith(line, "~~~")
end

# Whether `line` is an indented (4-space) CommonMark code block line. A
# per-line property, not a toggled span, so callers need no carried state.
function _is_indented_code_line(line::AbstractString)
    return startswith(line, "    ")
end

# Strip HTML comments from one README line, carrying `in_comment` (a comment
# opened on an earlier line and not yet closed) in and out. Loops so multiple
# comments on one line are handled, not just the first.
function _strip_line_comments(line::AbstractString, in_comment::Bool)
    out = IOBuffer()
    rest = line
    while true
        if in_comment
            close = findfirst("-->", rest)
            close === nothing && return String(take!(out)), true
            rest = rest[(close[end] + 1):end]
            in_comment = false
        else
            open = findfirst("<!--", rest)
            if open === nothing
                print(out, rest)
                return String(take!(out)), false
            end
            print(out, rest[1:(open[1] - 1)])
            after_open = rest[(open[end] + 1):end]
            close = findfirst("-->", after_open)
            if close === nothing
                return String(take!(out)), true
            end
            rest = after_open[(close[end] + 1):end]
        end
    end
    return
end

# Inline code spans (`` `...` ``) must survive verbatim even where they show
# literal `<!--`/`-->` text (#306). They open and close on one line, so a
# line-level regex finds each span and `_strip_line_comments` runs only on the
# text between spans, threading `in_comment` across those gaps.
const _INLINE_CODE_SPAN = r"`[^`]*`"

function _strip_line_comments_outside_code_spans(line::AbstractString, in_comment::Bool)
    out = IOBuffer()
    pos = firstindex(line)
    for m in eachmatch(_INLINE_CODE_SPAN, line)
        before, in_comment = _strip_line_comments(
            line[pos:prevind(line, m.offset)],
            in_comment
        )
        print(out, before)
        print(out, m.match)
        pos = m.offset + ncodeunits(m.match)
    end
    tail, in_comment = _strip_line_comments(line[pos:end], in_comment)
    print(out, tail)
    return String(take!(out)), in_comment
end

"""
    build_index(; readme, dest, repo, execute=true,
                rewrites=Pair{String,String}[], strip_sections=String[])

Generate `dest` (the docs home page) from the package `readme`.

The managed badge block (between the `<!-- badges:start -->` /
`<!-- badges:end -->` markers) and an inline logo `<img>` in the title are
removed. Every other HTML comment is stripped too, including multi-line ones:
DocumenterVitepress' typographic pass turns the `--` inside a surviving
comment into an en-dash, rendering the marker as literal text (#297). The
README itself is left untouched. All four CommonMark code forms are
recognised, so a `<!-- -->` shown as literal example text inside a fence, an
indented block or an inline code span survives verbatim (#301, #306).

```julia fences become runnable `@example readme` blocks when `execute` is
`true`. Each `from => to` in `rewrites` is applied line by line. Any heading
listed in `strip_sections` is dropped together with its body, up to the next
heading of the same or a higher level; the managed build hardcodes no such
section.
"""
function build_index(;
        readme::AbstractString, dest::AbstractString,
        repo::AbstractString, execute::Bool = true,
        rewrites = Pair{String, String}[],
        strip_sections = String[]
    )
    mkpath(dirname(dest))
    buf = IOBuffer()
    println(buf, "```@meta")
    println(buf, "EditURL = \"https://github.com/$repo/blob/main/README.md\"")
    println(buf, "```")
    println(buf)
    in_badges = false
    strip_level = 0
    in_fence = false
    in_comment = false
    for line in eachline(readme)
        if occursin("<!-- badges:start -->", line)
            in_badges = true
            continue
        elseif occursin("<!-- badges:end -->", line)
            in_badges = false
            continue
        end
        in_badges && continue
        if in_comment
            # Comment state wins over fence state: a fence delimiter falling
            # inside a still-open comment does not toggle `in_fence` (#301).
            rest, in_comment = _strip_line_comments(line, true)
            println(buf, rest)
            continue
        end
        # A heading at a level <= the section being stripped ends the stripped
        # span, and is then itself considered as a new strip start.
        m = match(r"^(#+)\s+(.*?)\s*$", line)
        if m !== nothing
            level = length(something(m.captures[1]))
            if strip_level > 0 && level <= strip_level
                strip_level = 0
            end
            if strip_level == 0 && strip(something(m.captures[2])) in strip_sections
                strip_level = level
                continue
            end
        end
        strip_level > 0 && continue
        # `was_in_fence` is captured before the toggle so the delimiter line
        # itself, and everything up to the matching close, is left alone
        # (#301).
        was_in_fence = in_fence
        _is_fence_delimiter(line) && (in_fence = !in_fence)
        in_indented_code = !was_in_fence && _is_indented_code_line(line)
        if execute && startswith(line, "```julia")
            println(buf, "```@example readme")
        elseif occursin("docs/src/assets/logo.svg", line)
            println(
                buf, replace(
                    line,
                    r"\s*<img[^>]*docs/src/assets/logo\.svg[^>]*>" => ""
                )
            )
        else
            for (from, to) in rewrites
                line = replace(line, from => to)
            end
            if !was_in_fence && !in_indented_code
                line, in_comment = _strip_line_comments_outside_code_spans(line, false)
            end
            println(buf, line)
        end
    end
    content = String(take!(buf))
    # A stripped multi-line comment leaves one blank line per removed line;
    # collapse them so the generated index.md reads tidily when diffed.
    content = replace(content, r"\n{3,}" => "\n\n")
    write(dest, content)
    println("Generated index.md from README.md")
    return dest
end

# ---- release-notes.md -----------------------------------------------------

# How many releases the page renders. GitHub's own release bodies list every
# merged pull request, so a page of the last ten is already long; everything
# older is one click away behind the link the page always carries.
const _RELEASE_NOTES_COUNT = 10

# The GitHub REST API root. A kwarg only so the offline degradation path is
# testable without a network (point it at a closed port).
const _GITHUB_API = "https://api.github.com"

# A token for the Releases request, or `nothing`. Unauthenticated calls are
# capped at 60/hour/IP; CI has `GITHUB_TOKEN`, a local build often has
# `GH_TOKEN` from the `gh` CLI. Only public metadata is read, so a token is
# never required -- it just raises the rate limit.
function _github_token()
    for key in ("GITHUB_TOKEN", "GH_TOKEN")
        value = get(ENV, key, "")
        isempty(value) || return value
    end
    return nothing
end

"""
    _fetch_releases(repo; limit, token, api)

The `repo`'s published releases, newest first, or `nothing` on failure.

Returns the decoded JSON array from GitHub's `/repos/{repo}/releases`
endpoint (empty when there are no releases yet). Any failure -- offline,
rate-limited, not found, bad response -- is caught and logged as `nothing`,
since a docs build must not depend on GitHub being reachable.
"""
function _fetch_releases(
        repo::AbstractString;
        limit::Integer = _RELEASE_NOTES_COUNT,
        token::Union{Nothing, AbstractString} = _github_token(),
        api::AbstractString = _GITHUB_API
    )
    url = "$api/repos/$repo/releases?per_page=$limit"
    headers = [
        "Accept" => "application/vnd.github+json",
        "X-GitHub-Api-Version" => "2022-11-28",
    ]
    token === nothing || push!(headers, "Authorization" => "Bearer $token")
    try
        JSON = _json()
        buf = IOBuffer()
        Downloads.download(url, buf; headers = headers, timeout = 30)
        parsed = Base.invokelatest(JSON.parse, String(take!(buf)))
        parsed = Base.invokelatest(_plain_json, parsed)
        parsed isa AbstractVector && return parsed
        @info "release notes: unexpected response from the GitHub releases " *
            "API; rendering the fallback link" repo
        return nothing
    catch err
        @info "release notes: could not fetch the published releases " *
            "(offline, rate-limited, or the repo has no API access); the " *
            "page will link to the releases page instead" repo exception = err
        return nothing
    end
end

# Convert a decoded JSON value into plain `Dict`/`Vector`/scalars. JSON.jl's
# `JSON.Object` methods live in the world age created by the lazy
# `Base.require` and cannot be called outside `invokelatest`; converting once
# here means the rendering below is ordinary Julia over ordinary containers.
function _plain_json(x)
    x isa AbstractDict &&
        return Dict{String, Any}(string(k) => _plain_json(v) for (k, v) in x)
    x isa AbstractVector && return Any[_plain_json(v) for v in x]
    return x
end

# The `YYYY-MM-DD` part of a release's ISO 8601 `published_at`, or `""`.
# Taking it off the front rather than parsing avoids a timezone question
# nobody asked: a release date is a day, not an instant.
function _release_date(release)
    stamp = get(release, "published_at", nothing)
    stamp isa AbstractString || return ""
    return length(stamp) >= 10 ? String(first(stamp, 10)) : ""
end

# Rewrite a release body for inclusion under a `##` release heading. Headings
# shift down two levels so nothing competes with the page title; a leading
# heading matching TagBot's `## <Package> vX.Y.Z` title is dropped so it
# doesn't repeat the heading just above it. HTML comments are stripped for
# the same reason `build_index` strips them: DocumenterVitepress' typographic
# pass turns a surviving `--` into an en-dash, rendering the marker as
# literal text on the built page (#297).
#
# Fenced code is left verbatim -- a release note may show a `#` comment or
# `<!-- -->` as an example. A body left with an open fence is closed at the
# end: bodies are concatenated onto one page, so an unterminated fence would
# otherwise swallow every release below it.
function _normalise_release_body(body::AbstractString, tag::AbstractString)
    text = replace(String(body), "\r\n" => "\n", "\r" => "\n")
    out = IOBuffer()
    in_fence = false
    fence = ""
    opened = ""
    in_comment = false
    dropped_title = false
    seen_content = false
    for line in split(text, '\n')
        if in_comment
            rest, in_comment = _strip_line_comments(line, true)
            println(out, rest)
            continue
        end
        m = match(r"^\s{0,3}(`{3,}|~{3,})", line)
        if m !== nothing
            marker = String(something(m.captures[1]))
            if !in_fence
                in_fence = true
                fence = string(marker[1])
                opened = marker
            elseif startswith(marker, fence)
                in_fence = false
            end
            seen_content = true
            println(out, line)
            continue
        end
        if in_fence
            println(out, line)
            continue
        end
        line, in_comment = _strip_line_comments_outside_code_spans(
            line,
            in_comment
        )
        h = match(r"^(#{1,6})\s+(.*?)\s*$", line)
        if h !== nothing
            level = length(something(h.captures[1]))
            title = something(h.captures[2])
            if !seen_content && !dropped_title &&
                    occursin(lowercase(tag), lowercase(title))
                dropped_title = true
                continue
            end
            seen_content = true
            println(out, "#"^min(level + 2, 6), " ", title)
            continue
        end
        isempty(strip(line)) || (seen_content = true)
        println(out, line)
    end
    in_fence && println(out, opened)
    # Stripped comments leave runs of blank lines behind; collapse them so the
    # generated page reads tidily when diffed directly.
    return strip(replace(String(take!(out)), r"\n{3,}" => "\n\n"))
end

# Render `releases` (the decoded API array) into `io`, newest first, and return
# how many were written. Drafts are skipped: they are not published, so they
# are not release notes.
function _render_releases(
        io, releases, repo::AbstractString;
        limit::Integer = _RELEASE_NOTES_COUNT
    )
    shown = 0
    for release in releases
        shown >= limit && break
        release isa AbstractDict || continue
        get(release, "draft", false) === true && continue
        tag = get(release, "tag_name", nothing)
        (tag isa AbstractString && !isempty(tag)) || continue
        url = get(release, "html_url", nothing)
        url isa AbstractString && !isempty(url) ||
            (url = "https://github.com/$repo/releases/tag/$tag")
        println(io, "## ", tag)
        println(io)
        meta = String[]
        date = _release_date(release)
        isempty(date) || push!(meta, "Released $date.")
        get(release, "prerelease", false) === true &&
            push!(meta, "Pre-release.")
        push!(meta, "[Read it on GitHub]($url).")
        println(io, join(meta, " "))
        println(io)
        body = get(release, "body", nothing)
        body = body isa AbstractString ? _normalise_release_body(body, tag) : ""
        println(
            io, isempty(body) ?
                "This release was published without notes." : body
        )
        println(io)
        shown += 1
    end
    return shown
end

# The page body when nothing was rendered. `fetched` distinguishes the two
# reasons: no releases yet (waiting for the first tag) vs a failed fetch
# (GitHub unreachable, page out of date).
function _write_release_fallback(io, repo::AbstractString, fetched::Bool)
    if fetched
        println(io, "No releases have been published yet.")
        println(io, "They will appear here once the first one is tagged.")
    else
        println(
            io,
            "The published releases could not be fetched when this page was"
        )
        println(io, "built, so they are not shown here.")
    end
    println(io)
    println(
        io, "Read them on the [releases page]" *
            "(https://github.com/$repo/releases)."
    )
    return nothing
end

# The header used when a package has none, or when its header still
# describes the retired NEWS.md convention (#286) -- honouring that would
# caption the page with a description of a file that is no longer rendered.
function _default_release_notes_header(repo::AbstractString)
    return """
    ```@meta
    EditURL = "https://github.com/$repo/releases"
    ```

    # Release notes

    Every release of this package is published as a GitHub release.
    The most recent are reproduced below, as they were written there.

    """
end

# The package-owned header, or the managed default. A header that still refers
# to NEWS.md predates the move to GitHub Releases; it is replaced rather than
# rendered, and the warning names the file so the fix is one edit.
function _release_notes_header(
        header_file::AbstractString,
        repo::AbstractString
    )
    isfile(header_file) || return _default_release_notes_header(repo)
    # Evaluate the header file in a throwaway module and take its return
    # value (the trailing `const RELEASE_NOTES_HEADER = "..."`), avoiding the
    # stricter global-binding world-age rules in Julia >= 1.12.
    header = Base.include(Module(:ReleaseNotesHeader), header_file)
    if header isa AbstractString && occursin("NEWS.md", header)
        @warn "release notes: $(header_file) still describes the retired " *
            "NEWS.md convention, so the standard header is used instead; " *
            "rewrite it to introduce the GitHub releases shown on the page"
        return _default_release_notes_header(repo)
    end
    return header
end

"""
    build_release_notes(; repo, header_file, dest, fetch=true,
                        limit=$(_RELEASE_NOTES_COUNT), releases=nothing)

Generate `dest` (the release-notes page) from `repo`'s published GitHub
releases, prefixed with the package-owned header defined in `header_file`
(which must set `RELEASE_NOTES_HEADER`).

The releases are fetched at build time, so the page is written once and the
notes stay wherever they were authored -- there is no changelog file to keep
in step with the tags. The most recent $(_RELEASE_NOTES_COUNT) are rendered,
each under its tag heading, with a link to the rest.

The page is always written. When the releases cannot be fetched (offline,
rate-limited, no API access) or the repo has none yet, it degrades to a
short note and a link to the releases page rather than failing the build.
`fetch=false` skips the request and `releases` supplies a decoded array
directly; both exist for tests and offline builds.

`header_file` is optional. A package with none, or whose header still
describes the retired NEWS.md convention, gets the standard header instead
(with a warning naming the file to rewrite).
"""
function build_release_notes(;
        repo::AbstractString,
        header_file::AbstractString, dest::AbstractString,
        fetch::Bool = true, limit::Integer = _RELEASE_NOTES_COUNT,
        releases = nothing
    )
    mkpath(dirname(dest))
    header = _release_notes_header(header_file, repo)
    if releases === nothing && fetch
        releases = _fetch_releases(repo; limit = limit)
    end
    shown = 0
    open(dest, "w") do io
        print(io, header)
        if releases !== nothing
            shown = _render_releases(io, releases, repo; limit = limit)
        end
        if shown == 0
            _write_release_fallback(io, repo, releases !== nothing)
        else
            println(io, "Every release, including any older than those above,")
            println(
                io, "is listed on the [releases page]" *
                    "(https://github.com/$repo/releases)."
            )
        end
    end
    println(
        shown == 0 ?
            "Generated release-notes.md (no releases shown; linking out)" :
            "Generated release-notes.md from $shown GitHub release(s)"
    )
    return dest
end

# ---- benchmark history page -----------------------------------------------

"""
    _embed_benchmark_history(io, repo, project_root; fetch = true,
                             history_suites = String[], history_commits = 5,
                             history_regression_threshold = 1.1,
                             overall_plot_dest = nothing, notes = "")

Render the published benchmark timeline into `io`.

`benchmark-history.yaml` publishes the history to the repo's `benchmarks`
branch under `history/` (per-benchmark PNG plots + a `table.md` ratio
summary). Pages serves only the gh-pages site, so the branch is enumerated at
build time after a best-effort `git fetch`, degrading to a link to the branch
when it does not exist yet.

The raw `table.md` is one flat table per leaf benchmark, unreadable spliced
verbatim at realistic suite sizes (#193). It is reshaped by
[`_render_benchmark_overview`](@ref) into a `## Summary` table plus a combined
trend plot, then one open `##` section per suite carrying that suite's ratio
tables, with the per-benchmark plot wall collapsed below them. Both cap to the
last `history_commits` revisions, with columns relabelled by commit date, and
`history_suites` (when non-empty) restricts them to the named headline suites.
`overall_plot_dest` is where the combined trend plot PNG is written, skipped
when `nothing`.
"""
function _embed_benchmark_history(
        io, repo::AbstractString,
        project_root::AbstractString; fetch::Bool = true,
        history_suites = String[], history_commits::Integer = 5,
        history_regression_threshold::Real = 1.1,
        overall_plot_dest::Union{Nothing, AbstractString} = nothing,
        notes::AbstractString = ""
    )
    ref = _benchmarks_ref(project_root; fetch = fetch)
    if ref !== nothing
        files = _history_files(project_root, ref)
        pngs = sort!(filter(f -> endswith(f, ".png"), files))
        has_table = "history/table.md" in files
        if has_table || !isempty(pngs)
            if has_table
                tbl = read(
                    `git -C $project_root show $ref:history/table.md`,
                    String
                )
                _render_benchmark_overview(
                    io, tbl, project_root, pngs, repo;
                    last_n = history_commits, suites = history_suites,
                    regression_threshold = history_regression_threshold,
                    plot_dest = overall_plot_dest, notes = notes
                )
            elseif !isempty(pngs)
                _write_benchmark_notes(io, notes)
                _embed_history_plots(io, repo, pngs)
            end
            return true
        end
    end
    _write_benchmark_notes(io, notes)
    println(
        io,
        "The performance timeline (per-benchmark plots and a ratio table) is"
    )
    println(
        io,
        "published to the [`benchmarks` branch]" *
            "(https://github.com/$repo/tree/benchmarks/history) on each push to"
    )
    println(io, "`main` and each tagged release.")
    return false
end

# The resolvable git ref for the `benchmarks` branch, or `nothing`, after a
# best-effort fetch. The explicit refspec matters: a bare
# `git fetch origin benchmarks` lands only in `FETCH_HEAD` and never creates
# the tracking ref the lookup below checks, so on a shallow CI checkout the
# page rendered empty (#192). Fetch failures are expected and non-fatal.
function _benchmarks_ref(project_root::AbstractString; fetch::Bool = true)
    if fetch
        try
            run(
                pipeline(
                    `git -C $project_root fetch --no-tags origin
                    +refs/heads/benchmarks:refs/remotes/origin/benchmarks`;
                    stdout = devnull, stderr = devnull
                )
            )
        catch err
            @info "benchmark history: could not fetch the `benchmarks` " *
                "branch (offline, or it does not exist yet); the page " *
                "will use any locally present ref or the fallback link" exception = err
        end
    end
    for ref in ("origin/benchmarks", "benchmarks")
        try
            run(
                pipeline(
                    `git -C $project_root rev-parse --verify --quiet $ref`;
                    stdout = devnull, stderr = devnull
                )
            )
            return ref
        catch
        end
    end
    @info "benchmark history: no `benchmarks` ref resolvable after fetch; " *
        "rendering the fallback link (publish a timeline via " *
        "benchmark-history.yaml to populate this page)"
    return nothing
end

function _history_files(project_root::AbstractString, ref::AbstractString)
    try
        out = read(
            `git -C $project_root ls-tree -r --name-only $ref -- history`,
            String
        )
        return filter(!isempty, split(out, '\n'))
    catch
        return String[]
    end
end

# ---- benchmark history: table reshaping (#193) -----------------------------

# Parse a GitHub-flavoured pipe table into a vector of cell-rows (the leading
# and trailing empty cells from the `|...|` delimiters dropped). Non-table
# lines are ignored, so surrounding prose in `table.md` is skipped.
function _parse_pipe_table(md::AbstractString)
    rows = Vector{String}[]
    for raw in split(md, '\n')
        ln = strip(raw)
        startswith(ln, "|") || continue
        cells = map(strip, split(ln, '|'))
        length(cells) >= 2 || continue
        push!(rows, String.(cells[2:(end - 1)]))
    end
    return rows
end

# Whether every cell is a markdown alignment marker (`---`, `:---`, `:---:`),
# i.e. the header separator row.
_is_alignment_row(cells) = !isempty(cells) && all(c -> occursin(r"^:?-+:?$", c), cells)

# Whether row `i` is a table header: a row immediately followed by an
# alignment row. benchpkgtable's `--mode time,memory` output is two stacked
# tables, each with its own header, so a header can appear anywhere (#204).
_is_header_row(rows, i) = i < length(rows) && _is_alignment_row(rows[i + 1])

# Split a parsed `table.md` into its revision-column labels and its data rows
# (`name => values`). The header's first cell is the empty benchmark-name
# column, so the revision labels are the remaining header cells.
#
# Every header and alignment row is skipped, not just the first pair: the
# stacked second table's header would otherwise land in the data rows as an
# empty-named entry, which renders as a bare `### ` heading and aborts the
# deploy build on the empty anchor id (#204). Empty-named rows are dropped for
# the same reason, whatever a future benchpkgtable format change produces.
function _history_table_parts(md::AbstractString)
    all_rows = _parse_pipe_table(md)
    isempty(all_rows) && return (String[], Pair{String, Vector{String}}[])
    header = all_rows[1]
    col_labels = length(header) > 1 ? header[2:end] : String[]
    entries = Pair{String, Vector{String}}[]
    for (i, r) in enumerate(all_rows)
        i == 1 && continue
        (isempty(r) || _is_alignment_row(r) || _is_header_row(all_rows, i)) &&
            continue
        isempty(r[1]) && continue
        push!(entries, r[1] => (length(r) > 1 ? r[2:end] : String[]))
    end
    return (col_labels, entries)
end

# ---- benchmark history: metric-aware parsing (#231) ------------------------

# Whether a table cell holds an allocation/memory measurement rather than a
# timing. The cells are the only durable signal of which stacked block is
# which. Byte units cover `Base.format_bytes` output and the `kB`/`MB` short
# forms; timing cells (`10.3 ± 0.1 μs`, `0.865 s`) match neither pattern.
function _looks_like_memory(cell::AbstractString)
    return occursin(r"alloc"i, cell) ||
        occursin(r"\b[0-9]+(?:\.[0-9]+)?\s*(?:bytes?|[kKMGT]i?B|B)\b", cell)
end

# The metric label (`"Time"` or `"Memory"`) for one parsed table block, by
# majority vote over its non-blank data cells so a stray unparseable cell
# cannot flip it. An all-blank block defaults to `"Time"`.
function _block_metric(entries)
    mem = 0
    tot = 0
    for (_, vals) in entries, v in vals

        isempty(strip(v)) && continue
        tot += 1
        _looks_like_memory(v) && (mem += 1)
    end
    return (tot > 0 && 2mem > tot) ? "Memory" : "Time"
end

# Whether a parsed block carries any measurement at all. An all-blank block
# would default to `"Time"` and merge into the timing block, adding a blank
# duplicate row and a spurious "no data" note, so it is dropped instead.
function _block_has_data(entries)
    return any(!isempty(strip(v)) for (_, vals) in entries for v in vals)
end

# Split a parsed `table.md` into its shared revision-column labels and its
# stacked table blocks, each tagged with its metric; a new block begins at
# each header row (#204). Header, alignment, empty and empty-named rows are
# dropped as in [`_history_table_parts`](@ref). Unlike that flat parse,
# timings and allocations stay SEPARATE so their duplicate leaf labels never
# collide and the headline ratio is never a median of times and allocation
# counts (#231). Same-metric blocks are merged. Returns `(col_labels, blocks)`
# with `blocks::Vector{metric => entries}` in first-seen metric order.
function _history_metric_blocks(md::AbstractString)
    all_rows = _parse_pipe_table(md)
    empty_blocks = Pair{String, Vector{Pair{String, Vector{String}}}}[]
    isempty(all_rows) && return (String[], empty_blocks)
    header = all_rows[1]
    col_labels = length(header) > 1 ? header[2:end] : String[]
    raw_blocks = Vector{Pair{String, Vector{String}}}[]
    current = Pair{String, Vector{String}}[]
    for (i, r) in enumerate(all_rows)
        if _is_header_row(all_rows, i)
            if !isempty(current)
                push!(raw_blocks, current)
                current = Pair{String, Vector{String}}[]
            end
            continue
        end
        (isempty(r) || _is_alignment_row(r) || isempty(r[1])) && continue
        push!(current, r[1] => (length(r) > 1 ? r[2:end] : String[]))
    end
    isempty(current) || push!(raw_blocks, current)
    blocks = empty_blocks
    index = Dict{String, Int}()
    for b in raw_blocks
        (isempty(b) || !_block_has_data(b)) && continue
        m = _block_metric(b)
        if haskey(index, m)
            append!(blocks[index[m]].second, b)
        else
            push!(blocks, m => b)
            index[m] = length(blocks)
        end
    end
    return (col_labels, blocks)
end

# Keep only the last `n` revision columns (the most recent points on the
# timeline). Rows whose width does not match the header are left untouched so a
# malformed row never throws.
function _cap_columns(col_labels, entries, n::Integer)
    ncol = length(col_labels)
    (n <= 0 || n >= ncol) && return (col_labels, entries)
    keep = (ncol - n + 1):ncol
    capped = map(entries) do (name, vals)
        length(vals) == ncol ? (name => vals[keep]) : (name => vals)
    end
    return (col_labels[keep], capped)
end

# The short commit date for `label` (a benchpkgtable column header), or
# `label` unchanged. Only the truncated-SHA headers resolve to a date; tag
# revs are plain names.
function _commit_date(project_root::AbstractString, label::AbstractString)
    ref = rstrip(replace(strip(label), "..." => "", "…" => ""))
    (isempty(ref) || !occursin(r"^[0-9a-fA-F]{7,40}$", ref)) && return label
    try
        d = strip(read(pipeline(`git -C $project_root show -s
                --date=short --format=%cd $ref`; stderr = devnull), String))
        return isempty(d) ? label : d
    catch
        return label
    end
end

# Relabel each revision column with its commit date where resolvable.
function _relabel_history_columns(col_labels, project_root)
    return [_commit_date(project_root, l) for l in col_labels]
end

# Group `name => values` rows by the first `/`-segment of each name, preserving
# first-seen order; the segment is stripped from the per-row label. A name with
# no `/` (e.g. `time_to_load`) forms its own single-row suite. Empty names are
# skipped as a second line of defence: an empty-named suite renders as a bare
# `### ` heading and aborts the deploy build (#204).
function _group_rows_by_suite(entries)
    groups = Pair{String, Vector{Pair{String, Vector{String}}}}[]
    index = Dict{String, Int}()
    for (name, vals) in entries
        isempty(strip(name)) && continue
        slash = findfirst('/', name)
        if slash === nothing
            suite, label = name, name
        else
            suite = name[1:prevind(name, slash)]
            label = name[nextind(name, slash):end]
        end
        if !haskey(index, suite)
            push!(groups, suite => Pair{String, Vector{String}}[])
            index[suite] = length(groups)
        end
        push!(groups[index[suite]].second, label => vals)
    end
    return groups
end

# Parse, cap, relabel and group `table.md` into per-suite rows: the shared
# reshaping step behind both the detail sub-tables and the overall summary.
# Returns `(col_labels, metric_groups)` with
# `metric_groups::Vector{metric => groups}`, each `groups` the per-suite shape
# [`_group_rows_by_suite`](@ref) produces; timings and allocations stay
# separate metric entries (#231). Capping and relabelling are shared across
# metrics, which share their revision columns. Empty when `suites` filters
# everything out; an unparseable `md` is the caller's concern (check
# `_history_table_parts(md)` first).
function _reshape_history_metrics(
        md::AbstractString,
        project_root::AbstractString; last_n::Integer = 5, suites = String[]
    )
    col_labels, blocks = _history_metric_blocks(md)
    wanted = isempty(suites) ? nothing : Set(String.(suites))
    capped_labels = col_labels
    metric_groups = Pair{
        String,
        Vector{Pair{String, Vector{Pair{String, Vector{String}}}}},
    }[]
    for (metric, entries) in blocks
        capped_labels, capped = _cap_columns(col_labels, entries, last_n)
        groups = _group_rows_by_suite(capped)
        wanted === nothing || (groups = filter(g -> g.first in wanted, groups))
        push!(metric_groups, metric => groups)
    end
    capped_labels = _relabel_history_columns(capped_labels, project_root)
    return (capped_labels, metric_groups)
end

# The headline (summary/plot) metric's per-suite groups: the `"Time"` block if
# present, else the first block so a memory-only table still summarises. A
# single metric keeps the median from mixing timings with allocations (#231).
function _headline_groups(metric_groups)
    isempty(metric_groups) &&
        return Pair{String, Vector{Pair{String, Vector{String}}}}[]
    idx = findfirst(mg -> mg.first == "Time", metric_groups)
    return metric_groups[something(idx, firstindex(metric_groups))].second
end

# Reorganise metric-first groups into suite-first order for the detail
# section: `Vector{suite => Vector{metric => subrows}}`, suites in first-seen
# order, metrics in table order. Keeps a leaf's timing and allocation rows
# under one suite heading but in separate per-metric sub-tables (#231).
function _suite_metric_detail(metric_groups)
    suites = String[]
    seen = Set{String}()
    for (_, groups) in metric_groups, (suite, _) in groups

        suite in seen || (push!(suites, suite); push!(seen, suite))
    end
    out = Pair{
        String,
        Vector{Pair{String, Vector{Pair{String, Vector{String}}}}},
    }[]
    for suite in suites
        per_metric = Pair{String, Vector{Pair{String, Vector{String}}}}[]
        for (metric, groups) in metric_groups
            idx = findfirst(g -> g.first == suite, groups)
            idx === nothing || push!(per_metric, metric => groups[idx].second)
        end
        push!(out, suite => per_metric)
    end
    return out
end

# Write one grouped markdown sub-table (`| Benchmark | <cols...> |`).
function _write_history_subtable(io, col_labels, subrows)
    println(io, "| Benchmark | ", join(col_labels, " | "), " |")
    println(io, "|:---|", repeat(":---:|", max(length(col_labels), 1)))
    for (label, vals) in subrows
        println(io, "| ", label, " | ", join(vals, " | "), " |")
    end
    return
end

# Write the reshaped per-suite results: one section per suite (at
# `heading_level`, `##` on the page proper so each suite reads as its own
# section under the summary), or a "no suites matched" note when
# `history_suites` filtered everything out. Each suite renders separate
# `Time` / `Memory` sub-tables one level down (#231); a single-metric suite
# skips the sub-heading. `caption` controls whether the revision-window line
# is emitted here -- the page proper prints it as the closing line of
# `## Summary` instead. Takes the already reshaped suite-first detail so the
# caller need not re-parse `table.md` and re-shell out to `git show`.
function _write_reshaped_detail(
        io, col_labels, suite_detail;
        heading_level::Integer = 3, caption::Bool = true
    )
    suite_h = "#"^heading_level
    metric_h = "#"^(heading_level + 1)
    if caption && !isempty(col_labels)
        println(io, _history_window_caption(col_labels))
        println(io)
    end
    if isempty(suite_detail)
        println(
            io,
            "_No benchmark suites matched the configured `history_suites`._"
        )
        println(io)
        return
    end
    for (suite, per_metric) in suite_detail
        println(io, suite_h, " ", suite)
        println(io)
        single = length(per_metric) == 1
        for (metric, subrows) in per_metric
            single || (println(io, metric_h, " ", metric); println(io))
            _write_history_subtable(io, col_labels, subrows)
            println(io)
        end
    end
    return
end

# The one-line caption naming the revision window every per-suite table below
# shares. Emitted once, as the closing line of `## Summary`.
function _history_window_caption(col_labels)
    n = length(col_labels)
    return string(
        "_Tables below show the most recent ", n,
        n == 1 ? " revision" : " revisions",
        ", columns labelled by commit date._"
    )
end

# Give a pipe table's header its benchmark-name label when the first cell is
# empty. benchpkgtable emits the leaf-name column with a blank header; spliced
# verbatim by the parse-failure fallback below, that empty cell becomes an
# anchored header with an empty anchor id and aborts the deploy build (#204).
# The reshaped path already labels its tables. Only the header is relabelled.
function _label_empty_leading_header(
        md::AbstractString; label::AbstractString = "Benchmark"
    )
    repl = SubstitutionString("\\1| " * label * " |")
    return replace(md, r"(?m)^([ \t]*)\|[ \t]*\|" => repl; count = 1)
end

# Reshape the raw `table.md` into grouped, capped, date-labelled per-suite
# tables (see [`_embed_benchmark_history`](@ref)). Falls back to splicing the
# table verbatim if it cannot be parsed, so a format change never blanks the
# page — sanitising the header first so the fallback cannot emit an empty
# anchor (#204).
function _render_ratio_table(
        io, md::AbstractString,
        project_root::AbstractString; last_n::Integer = 5,
        suites = String[]
    )
    if isempty(_history_table_parts(md)[2])
        println(io, _label_empty_leading_header(rstrip(md)))
        println(io)
        return
    end
    col_labels, metric_groups = _reshape_history_metrics(
        md, project_root;
        last_n = last_n, suites = suites
    )
    _write_reshaped_detail(io, col_labels, _suite_metric_detail(metric_groups))
    return
end

# Collapse the per-benchmark plot wall behind a `<details>` so the page stays
# skimmable (#193). benchpkgplot names plots with no suite in the filename, so
# they cannot be grouped; they are shown as one block of raw-GitHub images.
function _embed_history_plots(io, repo::AbstractString, pngs)
    println(io, "## Per-benchmark timelines")
    println(io)
    println(io, "<details>")
    println(
        io, "<summary>Show ", length(pngs),
        length(pngs) == 1 ? " plot" : " plots", "</summary>"
    )
    println(io)
    for p in pngs
        url = "https://raw.githubusercontent.com/$repo/benchmarks/$p"
        println(io, "![$(basename(p))]($url)")
        println(io)
    end
    println(io, "</details>")
    println(io)
    return
end

# ---- benchmark history: overall summary (#202) -----------------------------

# The leading number in a benchpkgtable cell, e.g. `"0.112 ± 0.0006 ms"` ->
# `0.112`. `nothing` for a cell with no leading number, so a malformed cell
# never throws. Reads `m.match` (a concrete `SubString`) rather than
# `m.captures[1]`, whose `Union{Nothing,SubString}` element type JET flags.
function _parse_metric_value(cell::AbstractString)
    m = match(r"^\s*[0-9]+(?:\.[0-9]+)?", cell)
    m === nothing && return nothing
    return tryparse(Float64, strip(m.match))
end

# One value per (already capped) revision column: the median of a suite's
# per-benchmark values there, `missing` when none parse. A row whose width
# does not match `ncol` is skipped rather than read positionally: `_cap_columns`
# leaves a malformed row uncapped (#193), so indexing it would pair stale
# values with the newest columns and feed that into the headline summary.
function _suite_column_medians(subrows, ncol::Integer)
    out = Vector{Union{Float64, Missing}}(missing, ncol)
    for j in 1:ncol
        vals = Float64[]
        for (_, cellvals) in subrows
            length(cellvals) == ncol || continue
            v = _parse_metric_value(cellvals[j])
            v === nothing || push!(vals, v)
        end
        isempty(vals) || (out[j] = Statistics.median(vals))
    end
    return out
end

# Normalise a suite's per-column medians to a ratio series against its first
# finite and non-zero value, i.e. 1.0 at the oldest comparable revision. A
# genuine `0.0` median (e.g. "0 bytes allocated") is skipped as a baseline
# rather than divided by, which would give `NaN`/`±Inf` throughout. All
# `missing` when no such baseline exists. `medians` is `AbstractVector`
# because a comprehension with no `missing` values narrows to
# `Vector{Float64}`.
function _suite_ratio_series(medians::AbstractVector)
    baseline_idx = findfirst(v -> !ismissing(v) && v != 0, medians)
    baseline_idx === nothing &&
        return Vector{Union{Float64, Missing}}(missing, length(medians))
    baseline = medians[baseline_idx]
    return [ismissing(v) ? missing : v / baseline for v in medians]
end

# `(ratio, trend, status)` for one suite's ratio series. `ratio` is the most
# recent finite value (1.0 == no change since the oldest shown revision).
# `trend` compares it against `1 ± flat_threshold`; `status` flags a
# regression at `regression_threshold` (higher-is-worse, matching the metrics
# `table.md` reports). Fewer than two finite points give no signal.
# Non-finite ratios are excluded alongside `missing` so they degrade to "n/a"
# rather than comparing `NaN` against the thresholds, which is silently
# `false` and renders as an unremarkable "no change" row.
function _suite_trend_status(
        ratio_series::AbstractVector;
        regression_threshold::Real = 1.1, flat_threshold::Real = 0.02
    )
    finite = findall(v -> !ismissing(v) && isfinite(v), ratio_series)
    length(finite) < 2 && return (missing, "→", "n/a")
    ratio = ratio_series[finite[end]]
    trend = if ratio >= 1 + flat_threshold
        "↗"
    elseif ratio <= 1 - flat_threshold
        "↘"
    else
        "→"
    end
    status = ratio >= regression_threshold ? "⚠ reg" : "ok"
    return (ratio, trend, status)
end

_fmt_ratio(::Missing) = "n/a"
_fmt_ratio(r::Real) = isfinite(r) ? string(round(r; digits = 2)) : "n/a"

# Per-suite ratio series from the headline metric's `groups` — the shared
# input to both the summary table and the overall trend plot.
function _suite_ratio_series_by_group(groups, ncol::Integer)
    return [
        (suite, _suite_ratio_series(_suite_column_medians(subrows, ncol)))
            for (suite, subrows) in groups
    ]
end

# One summary row per suite: `(suite, ratio, trend, status)`.
function _benchmark_summary_rows(
        series_by_suite;
        regression_threshold::Real = 1.1
    )
    rows = NamedTuple{
        (:suite, :ratio, :trend, :status),
        Tuple{String, Union{Float64, Missing}, String, String},
    }[]
    for (suite, series) in series_by_suite
        ratio, trend, status = _suite_trend_status(
            series;
            regression_threshold = regression_threshold
        )
        push!(
            rows, (
                suite = suite, ratio = ratio, trend = trend,
                status = status,
            )
        )
    end
    return rows
end

# Write the `## Summary` table: one row per suite, its ratio against the
# oldest shown revision, a trend arrow and a regression flag. Leads the page,
# above the per-suite sections.
function _write_benchmark_summary(io, rows)
    println(io, "## Summary")
    println(io)
    println(
        io,
        "Each benchmark suite's headline timing across recent revisions."
    )
    println(io)
    if isempty(rows)
        println(io, "_No benchmark suites to summarise._")
        println(io)
        return
    end
    # A single-revision package has a `missing` ratio for every suite, so the
    # table would be all-`n/a` and read as broken (#282).
    if all(r -> ismissing(r.ratio), rows)
        println(
            io,
            "_Not enough comparable revisions to compute ratios yet — the " *
                "summary populates once a second revision is benchmarked._"
        )
        println(io)
        return
    end
    println(io, "| Suite | Median ratio | Trend | Status |")
    println(io, "|:---|:---:|:---:|:---:|")
    for r in rows
        println(
            io, "| ", r.suite, " | ", _fmt_ratio(r.ratio), " | ",
            r.trend, " | ", r.status, " |"
        )
    end
    println(io)
    println(
        io,
        "_Ratio: latest vs oldest shown revision (1.00 = no change, " *
            "higher = slower/larger). ⚠ reg = at/above the regression " *
            "threshold._"
    )
    println(io)
    return
end

# Render the combined multi-suite trend plot to `dest_png`: one line per suite
# plotting its ratio series across the date-relabelled `col_labels`,
# regenerated from the same `table.md` data as the summary table. Never fails
# the docs build. The two failure modes are logged separately so a broken
# render (`@warn`) is distinguishable from `Plots` not being installed in the
# docs environment yet (`@info`) — the scaffold seeds `docs/Project.toml` with
# it, but an already-scaffolded package must add it by hand.
function _write_overall_trend_plot(
        dest_png::AbstractString, col_labels,
        series_by_suite
    )
    plottable = filter(series_by_suite) do (_, series)
        count(!ismissing, series) >= 2
    end
    if isempty(plottable)
        @info "benchmark history: fewer than two comparable revisions; " *
            "skipping the overall trend plot"
        return false
    end
    local Plots
    try
        Plots = _plots()
    catch err
        @info "benchmark history: `Plots` is not available in the docs " *
            "environment; add it to `docs/Project.toml` to enable the " *
            "overall trend plot" exception = err
        return false
    end
    try
        Base.invokelatest() do
            # GR's default Qt/X11 terminal hangs on a headless CI runner; the
            # null terminal renders straight to file with no display.
            ENV["GKSwstype"] = get(ENV, "GKSwstype", "100")
            Plots.gr()
            x = 1:length(col_labels)
            plt = Plots.plot(;
                xlabel = "Revision", ylabel = "Ratio",
                legend = :outertopright, size = (900, 500),
                xticks = (x, col_labels), xrotation = 30,
                title = "Overall benchmark trend"
            )
            for (suite, series) in plottable
                Plots.plot!(plt, x, series; label = suite, marker = :circle)
            end
            mkpath(dirname(dest_png))
            Plots.savefig(plt, dest_png)
        end
        return true
    catch err
        @warn "benchmark history: the overall trend plot failed to " *
            "render; the summary table still renders without it" exception = err
        return false
    end
end

# Suite-qualified labels of leaf benchmarks whose every capped-column cell
# fails to parse as a number: present in the published table but errored or
# skipped in the run. A no-`/` name is its own single-row suite, so its flat
# name is that value rather than `"name/name"`.
function _unparsed_benchmarks(groups)
    out = String[]
    for (suite, subrows) in groups
        for (label, vals) in subrows
            isempty(vals) && continue
            all(v -> _parse_metric_value(v) === nothing, vals) &&
                push!(out, label == suite ? label : "$suite/$label")
        end
    end
    return out
end

# Write the "Skipped & broken benchmarks" block: the package-owned `notes`
# prose plus any auto-detected no-data benchmarks. Rendered even before any
# history has published, so a maintainer can document a known-skipped suite
# ahead of CI running. Renders nothing when there is neither.
function _write_benchmark_notes(
        io, notes::AbstractString,
        auto::AbstractVector{<:AbstractString} = String[]
    )
    (isempty(strip(notes)) && isempty(auto)) && return
    println(io, "## Skipped & broken benchmarks")
    println(io)
    isempty(strip(notes)) || (println(io, notes); println(io))
    if !isempty(auto)
        println(
            io, "_No data in the shown revisions: ",
            join(("`$a`" for a in auto), ", "), "._"
        )
        println(io)
    end
    return
end

# Orchestrates the page body as a presentation of results: a `## Summary`
# table and combined trend plot across the package, then one `##` section per
# suite ([`_write_reshaped_detail`](@ref)), then the notes and the
# per-benchmark plot wall ([`_embed_history_plots`](@ref), still collapsed --
# a wall of images, not a section read top to bottom). The per-suite tables
# used to sit behind one `<details>`, which hid every measurement the page
# existed to show. An unparseable `table.md` falls back to the unreshaped
# splice so a format change never blanks the page. `plot_dest === nothing`
# skips plot generation. Reshapes `table.md` once and reuses the result.
function _render_benchmark_overview(
        io, md::AbstractString,
        project_root::AbstractString, pngs, repo::AbstractString;
        last_n::Integer = 5, suites = String[],
        regression_threshold::Real = 1.1,
        plot_dest::Union{Nothing, AbstractString} = nothing,
        notes::AbstractString = ""
    )
    if isempty(_history_table_parts(md)[2])
        println(io, "## Ratio summary")
        println(io)
        _render_ratio_table(
            io, md, project_root; last_n = last_n,
            suites = suites
        )
        _write_benchmark_notes(io, notes)
        !isempty(pngs) && _embed_history_plots(io, repo, pngs)
        return
    end
    col_labels, metric_groups = _reshape_history_metrics(
        md, project_root;
        last_n = last_n, suites = suites
    )
    # A single metric, never a median mixing timings with allocations (#231).
    headline = _headline_groups(metric_groups)
    series_by_suite = _suite_ratio_series_by_group(headline, length(col_labels))
    _write_benchmark_summary(
        io,
        _benchmark_summary_rows(
            series_by_suite;
            regression_threshold = regression_threshold
        )
    )
    if plot_dest !== nothing &&
            _write_overall_trend_plot(plot_dest, col_labels, series_by_suite)
        println(io, "![Overall benchmark trend](", basename(plot_dest), ")")
        println(io)
    end
    # Closes `## Summary` by naming the revision window every per-suite table
    # below shares, so the caption introduces those sections instead of
    # orphaning itself under whichever heading happens to precede them.
    if !isempty(col_labels)
        println(io, _history_window_caption(col_labels))
        println(io)
    end
    _write_reshaped_detail(
        io, col_labels, _suite_metric_detail(metric_groups);
        heading_level = 2, caption = false
    )
    _write_benchmark_notes(io, notes, _unparsed_benchmarks(headline))
    !isempty(pngs) && _embed_history_plots(io, repo, pngs)
    return
end

# The package-owned seed files open with an HTML authoring-guidance comment.
# Strip it so Documenter never renders it as literal text (#145). Done on the
# splice side because sync never rewrites a package-owned seed.
function _strip_seed_comment(s::AbstractString)
    return lstrip(replace(s, r"^\s*<!--.*?-->"s => ""))
end

# The package-owned seed file's content, or `default` when the file is
# absent (a package predating it, or one that opted out).
function _read_seed(file::AbstractString, default::AbstractString)
    isfile(file) || return default
    return _strip_seed_comment(rstrip(read(file, String)))
end

"""
    build_benchmark_page(; dest, repo, package, prose_file, embed_history=true,
                         project_root=dirname(dirname(dirname(dirname(dest)))),
                         notes_file=joinpath(dirname(dirname(dirname(dest))),
                                              "benchmarks_notes.md"),
                         history_suites=String[], history_commits=5,
                         history_regression_threshold=1.1)

Generate `dest` (the performance-over-time docs page).

The page is a presentation of results, not a how-to: a one-line managed
intro, then the timeline published to the repo's `benchmarks` branch (see
[`_embed_benchmark_history`](@ref)) as a `## Summary` across the package
followed by one `##` section per benchmark suite. The package-owned
`prose_file` is spliced verbatim (minus any leading HTML comment, which is
stripped so the seed's authoring guidance never renders) at the *foot* of the
page under `## About these benchmarks`, so what the suite covers and how to
run it is available without leading the page ahead of the numbers.

`notes_file` is a second package-owned seed (`docs/benchmarks_notes.md`) for
hand-written notes on skipped or broken benchmarks, spliced under a
"Skipped & broken benchmarks" heading below the per-suite sections; any
benchmark with no parseable data across the shown revisions is auto-appended
there too. `history_suites` (when non-empty) restricts the history to the
named headline suites, `history_commits` caps the per-suite tables and trend
plot to that many most-recent revisions, and `history_regression_threshold`
sets the summary ratio (relative to the oldest shown revision) at or above
which a suite's `Status` flags "⚠ reg". Returns the list of linkcheck-ignore
regexes for the history URLs (the branch may not be live yet).
"""
function build_benchmark_page(;
        dest::AbstractString, repo::AbstractString,
        package::AbstractString, prose_file::AbstractString,
        embed_history::Bool = true,
        project_root::AbstractString = dirname(
            dirname(dirname(dirname(dest)))
        ),
        notes_file::AbstractString = joinpath(
            dirname(dirname(dirname(dest))), "benchmarks_notes.md"
        ),
        history_suites = String[], history_commits::Integer = 5,
        history_regression_threshold::Real = 1.1
    )
    prose = _read_seed(prose_file, "Performance benchmarks for `$package`.")
    notes = _read_seed(notes_file, "")
    intro = "How `$package`'s benchmark suites have moved across recent " *
        "revisions: an overall summary across the package first, then " *
        "one section per suite."
    mkpath(dirname(dest))
    # A build artefact regenerated on every docs build, so it lives beside
    # `dest` in the built `src/` tree rather than on the `benchmarks` branch
    # alongside the externally pre-rendered per-benchmark plots.
    plot_dest = joinpath(dirname(dest), "overall_trend.png")
    open(dest, "w") do io
        println(io, "# [Performance over time](@id benchmarks)")
        println(io)
        println(io, intro)
        println(io)
        if embed_history
            _embed_benchmark_history(
                io, repo, project_root;
                history_suites = history_suites,
                history_commits = history_commits,
                history_regression_threshold = history_regression_threshold,
                overall_plot_dest = plot_dest, notes = notes
            )
        else
            println(
                io,
                "A performance timeline is published on each release."
            )
        end
        if !isempty(strip(prose))
            println(io)
            println(io, "## About these benchmarks")
            println(io)
            println(io, prose)
        end
    end
    println("Generated $(basename(dest)) (benchmark history page)")
    esc = replace(repo, "." => "\\.", "/" => "/")
    return Regex[
        Regex("raw\\.githubusercontent\\.com/$esc/benchmarks"),
        Regex("github\\.com/$esc/tree/benchmarks"),
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
# aliases to the owning module (#160). A re-exported binding keeps its
# docstring in the module that defines it, not in `Base.Docs.meta(mod)`, so a
# scan of `mod`'s own meta alone would omit it from the `@docs` block and
# leave every `@ref` to that name broken.
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
`mod` exports or declares `public`, including re-exports whose docstrings live
in the defining module (#160). A public/exported name is only included when it
resolves to a documented binding, so the generated `@docs` block never lists
an undocumented name, which Documenter would reject.
"""
function api_bindings(mod::Module)
    own = Set(b.var for b in keys(Base.Docs.meta(mod)))
    surface = Set(names(mod; all = false))
    candidates = sort!(collect(union(own, surface)); by = string)
    public = Symbol[]
    private = Symbol[]
    for v in candidates
        # The module's own docstring would render mid-list here without
        # introducing the package, so `build_api_pages` prepends it to
        # `public.md` separately (#313).
        v === nameof(mod) && continue
        # An undocumented re-export is dropped to keep the `@docs` block
        # render-safe; `mod`'s own meta entries are documented by construction.
        (v in own || _is_documented(mod, v)) || continue
        push!(_is_public(mod, v) ? public : private, v)
    end
    return public, private
end

# Whether `mod` itself carries a docstring. `api_bindings` excludes this one
# binding from its split, so `build_api_pages` uses this to decide whether to
# prepend a `@docs` block for `mod` to `public.md` — without which a
# `checkdocs = :all` scan always flags it as missing from the manual (#313).
function _has_own_docstring(mod::Module)
    return haskey(Base.Docs.meta(mod), Base.Docs.Binding(mod, nameof(mod)))
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
    return
end

"""
    api_owning_modules(mod) -> Set{Module}

The external *owning* modules of the re-exported docstrings `mod` documents —
each module outside `mod`'s own module tree that records a docstring for one of
the bindings [`api_bindings`](@ref) lists.

Documenter's `@docs` resolver only resolves a listed name when the module that
owns its docstring is in `makedocs`' `modules`. A re-export's docstring lives
in the defining module, not `mod`, so [`build_docs`](@ref) folds this set into
`modules`; otherwise every such entry raises "no docs found" and its `@ref`s
break in the built HTML (#175). `mod` and its own submodules are excluded,
since Documenter discovers those from `mod` itself.
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

# Whether `mod` (or a submodule) owns `name`'s docstring, rather than only
# adding methods to another package's generic (e.g. `Statistics.mean`). A bare
# `@docs mod.name` entry resolves with an implicit `typesig = Union{}`, and
# since `Union{} <: anything` Documenter's fallback subtype search matches
# every signature registered under the aliased binding, pulling in the owning
# package's unrelated docstrings (#290).
function _owns_binding(mod::Module, name::Symbol)
    b = Base.Docs.aliasof(Base.Docs.Binding(mod, name))
    return _within(b.mod, mod)
end

# Construct a signature-qualified `@docs` entry (e.g.
# `Pkg.mean(::Pkg.SomeType)`) for one method `mod` documents, so Documenter
# resolves an exact typesig match instead of the bleed-prone bare form (#290).
# Parameters render via `string`, which Base module-qualifies for anything not
# a well-known Base/Core name, so the entry resolves whichever module
# Documenter evaluates the signature expression in.
#
# The constructed string is round-tripped through `Meta.parse` +
# `Base.Docs.signature` + `eval` in `mod` and checked for exact type equality
# before it is trusted: some signatures (a `where` clause, a `Vararg`, a
# closed-over `TypeVar`) do not stringify back to the identical type. Building
# the string is inside the `try` too, because a method with an optional
# positional argument is recorded as a `Union` of `Tuple`s, which has no
# `.parameters` field. Returns `nothing` on any mismatch or error so the
# caller can fall back rather than emit an entry Documenter mis-resolves.
function _qualified_docs_entry(mod::Module, name::Symbol, sig::Type)
    try
        params = Base.unwrap_unionall(sig).parameters
        entry = if isempty(params)
            string(mod, ".", name, "()")
        else
            args = join(("::" * string(p) for p in params), ", ")
            string(mod, ".", name, "(", args, ")")
        end
        sig_expr = Base.Docs.signature(Meta.parse(entry))
        Core.eval(mod, sig_expr) === sig || return nothing
        return entry
    catch
        return nothing
    end
end

# The `@docs` entry/entries for `name`: the bare `mod.name` form when `mod`
# owns the binding outright, else one signature-qualified entry per method
# `mod` documents, so an extended generic never pulls in the owning package's
# docstrings (#290). Falls back to the bare form with a warning if the
# `MultiDoc` is missing or a signature fails the round-trip check: that
# re-risks the bleed, but an unresolvable `@docs` block is worse.
function _docs_entries(mod::Module, name::Symbol)
    bare = string(mod, ".", name)
    _owns_binding(mod, name) && return [bare]
    b = Base.Docs.aliasof(Base.Docs.Binding(mod, name))
    own_md = get(Base.Docs.meta(mod), b, nothing)
    if own_md === nothing || isempty(own_md.order)
        @warn "no own MultiDoc found for $bare (extends $(b.mod).$(name)); " *
            "emitting the bare entry, which may pull in $(b.mod)'s own docs"
        return [bare]
    end
    entries = String[]
    for sig in own_md.order
        qualified = _qualified_docs_entry(mod, name, sig)
        if qualified === nothing
            @warn "could not build a signature-qualified @docs entry for " *
                "$bare at signature $sig; falling back to the bare entry, " *
                "which may pull in $(b.mod)'s own docs for this method too"
            return [bare]
        end
        push!(entries, qualified)
    end
    return entries
end

function _write_api_page(
        path, title, anchor, page, intro, api_heading,
        mod, names; own_docstring_entry::Union{Nothing, AbstractString} = nothing
    )
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
        # `mod`'s own module docstring goes ahead of Contents/Index rather
        # than into the alphabetical `@docs` block, so it reads as the page's
        # introduction (#313).
        if own_docstring_entry !== nothing
            println(io, "```@docs")
            println(io, own_docstring_entry)
            println(io, "```")
            println(io)
        end
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
            for entry in _docs_entries(mod, name)
                println(io, entry)
            end
        end
        println(io, "```")
    end
    return path
end

"""
    build_api_pages(mod, lib_dir)

Write `lib/public.md` and `lib/internals.md` under `lib_dir` from `mod`'s
documented bindings (see [`api_bindings`](@ref)). `mod`'s own module
docstring, which that split excludes, is prepended to `public.md` as its own
`@docs` block, so it is both readable on the built site and counted towards a
`:all` `checkdocs` scan (#313).
"""
function build_api_pages(mod::Module, lib_dir::AbstractString)
    public, private = api_bindings(mod)
    own_docstring = _has_own_docstring(mod) ? string(mod, ".", nameof(mod)) : nothing
    _write_api_page(
        joinpath(lib_dir, "public.md"),
        "Public Documentation", "public-api", "public.md",
        "Documentation for `$mod`'s public interface.",
        "Public API", mod, public; own_docstring_entry = own_docstring
    )
    _write_api_page(
        joinpath(lib_dir, "internals.md"),
        "Internal Documentation", nothing, "internals.md",
        "Documentation for `$mod`'s internal interface.",
        "Internal API", mod, private
    )
    println(
        "Generated API pages: $(length(public)) public, " *
            "$(length(private)) internal bindings"
    )
    return public, private
end

# ---- source remotes for the owning modules --------------------------------

# The (org, repo) pair of a GitHub clone/browse URL, in either the https or the
# ssh form and with or without the `.git` suffix; `nothing` for any other host
# (Documenter can only build source links for GitHub remotes).
function _github_org_repo(url::AbstractString)
    m = match(r"github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?/*$", url)
    m === nothing && return nothing
    # Both groups are mandatory; the assertions narrow for JET.
    return (String(m[1]::AbstractString), String(m[2]::AbstractString))
end

# The `(org, repo, ref)` a source link for a dependency needs, from its git
# source URL and how it was installed. A git-tracked dependency links against
# the revision it tracks; otherwise the installed version names its release tag
# (registered packages tag `vX.Y.Z`). `nothing` when no GitHub source URL or no
# ref can be found — the caller then leaves the package to Documenter.
function _remote_spec(
        url::Union{Nothing, AbstractString},
        rev::Union{Nothing, AbstractString},
        version::Union{Nothing, VersionNumber}
    )
    url === nothing && return nothing
    org_repo = _github_org_repo(url)
    org_repo === nothing && return nothing
    ref = if rev !== nothing && !isempty(rev)
        String(rev)
    elseif version !== nothing
        "v$version"
    else
        return nothing
    end
    return (org_repo[1], org_repo[2], ref)
end

# The active environment's Pkg entry for `mod`'s package, or `nothing` when it
# has no UUID (e.g. `Base`) or the environment cannot be read.
function _package_entry(mod::Module)
    uuid = Base.PkgId(mod).uuid
    uuid === nothing && return nothing
    deps = try
        Pkg.dependencies()
    catch
        return nothing
    end
    return get(deps, uuid, nothing)
end

# Expand one `extra_remotes` value into what Documenter's `remotes` accepts: an
# "Org/Repo.jl" string becomes a GitHub remote on `main`, anything else (a
# `Remotes.Remote`, or a `(remote, ref)` tuple) passes through untouched.
function _extra_remote(Documenter, value)
    value isa AbstractString || return value
    parts = split(value, '/')
    length(parts) == 2 || error(
        "extra_remotes: \"$value\" is not an \"Org/Repo.jl\" pair"
    )
    remote = Base.invokelatest(
        Documenter.Remotes.GitHub, String(parts[1]), String(parts[2])
    )
    return (remote, "main")
end

"""
    api_remotes(mods; extra_remotes = Dict()) -> Dict{String, Any}

Documenter `remotes` entries for the owning modules `mods` — a
`pkgdir(mod) => (Remotes.GitHub(org, repo), ref)` mapping so Documenter can
build source links for the docstrings those modules own.

[`build_docs`](@ref) folds each re-export's owning module into Documenter's
`modules` (#175), and Documenter needs a remote for that module's source tree.
It derives one for a `develop`ed or registered dependency, but not for a
package `Pkg.add`ed from a git URL, where the build dies with
`MissingRemoteError` (#190). The remote is taken from the dependency's git
source URL as recorded in the active environment; a module with no GitHub
source URL is left for Documenter to resolve. `extra_remotes` maps a `Module`
or a path to an `"Org/Repo.jl"` string or anything Documenter's `remotes`
accepts, and overrides any derived entry for the same path.
"""
function api_remotes(mods; extra_remotes = Dict())
    Documenter = _documenter()
    remotes = Dict{String, Any}()
    for mod in mods
        root = pkgdir(mod)
        (root === nothing || !isdir(root)) && continue
        entry = _package_entry(mod)
        entry === nothing && continue
        spec = _remote_spec(
            entry.git_source, entry.git_revision, entry.version
        )
        spec === nothing && continue
        remote = Base.invokelatest(Documenter.Remotes.GitHub, spec[1], spec[2])
        remotes[realpath(root)] = (remote, spec[3])
    end
    for (key, value) in extra_remotes
        root = key isa Module ? pkgdir(key) : String(key)
        (root === nothing || !isdir(root)) && continue
        remotes[realpath(root)] = _extra_remote(Documenter, value)
    end
    return remotes
end

# ---- Literate tutorial pipeline -------------------------------------------

# The runner subprocess opens with `using Literate`, so a tutorial's own
# environment has to declare it. Same UUID `_literate` resolves against.
const _LITERATE_UUID = "98b081ad-f1c9-55d3-8b20-4c87d4299306"

# A `source file => environment directory` lookup from the package-owned
# `tutorial_environments` pairs. A relative directory resolves against
# `docs_dir`, so a package writes `"environments/petri"` and the build finds
# `docs/environments/petri`; an absolute path is taken as given.
function _tutorial_env_map(docs_dir, envs)
    lookup = Dict{String, String}()
    for (file, dir) in envs
        path = String(dir)
        lookup[String(file)] = isabspath(path) ? path : joinpath(docs_dir, path)
    end
    return lookup
end

# Whether an environment's `Project.toml` declares Literate. Read from the
# file rather than resolved, so the check runs before instantiation and its
# error can name what to add. An unreadable or malformed file counts as not
# declaring it; the error then names the same fix.
function _declares_literate(project::AbstractString)
    table = try
        Pkg.TOML.parsefile(project)
    catch
        return false
    end
    deps = get(table, "deps", nothing)
    deps isa AbstractDict || return false
    return _LITERATE_UUID in values(deps)
end

# Ready a tutorial's own environment before its subprocess runs: the directory
# must hold a `Project.toml` declaring Literate, and that project is
# instantiated in a subprocess so the docs build's own active environment is
# left alone.
#
# Every failure here errors rather than falling through to the shared docs
# environment. A tutorial that cannot resolve its dependencies is exactly the
# case this exists for, and a page silently replaced by its stub gives the
# reader a fast-build notice where the content should be.
function _prepare_tutorial_env(file, env::AbstractString)
    project = joinpath(env, "Project.toml")
    isfile(project) || error(
        "tutorial $file names its own environment \"$env\", but there is " *
            "no Project.toml there. The environment is package-owned: the " *
            "kit never writes it, so create $(project) declaring the " *
            "tutorial's dependencies plus Literate."
    )
    _declares_literate(project) || error(
        "tutorial $file names its own environment \"$env\", but " *
            "$(project) does not declare Literate. The tutorial runs in a " *
            "subprocess resolving against that environment alone, and the " *
            "runner opens with `using Literate`, so add it there."
    )
    println("  instantiating $file's own environment ($env)...")
    try
        run(
            `$(Base.julia_cmd()) --project=$env -e
            "using Pkg; Pkg.instantiate()"`
        )
    catch err
        error(
            "could not instantiate tutorial $file's own environment " *
                "\"$env\": $(err). Resolve it locally " *
                "(`julia --project=$env -e 'using Pkg; Pkg.instantiate()'`) " *
                "and commit the result."
        )
    end
    return
end

# A light tutorial renders in-process under Documenter, against whatever
# environment the docs build itself runs in, so it has no subprocess to point
# elsewhere. Naming one is a config mistake worth stopping for: the page would
# otherwise build against the shared environment with no sign the requested
# one was ignored.
function _reject_light_tutorial_envs(light, env_map)
    named = filter(in(keys(env_map)), collect(light))
    isempty(named) && return
    return error(
        "tutorial_environments names light tutorial(s) " *
            join(named, ", ") * ", but a light tutorial renders in-process " *
            "and cannot resolve against its own environment. Move it to the " *
            "heavy list, which runs one subprocess per tutorial."
    )
end

# The `--threads` value each heavy-tutorial subprocess is launched with.
#
# A serial build passes `JULIA_NUM_THREADS` straight through, exactly as it
# always has, so a non-numeric setting (`auto`) still reaches the subprocess
# verbatim. A parallel build divides that same budget between the workers, so
# `workers x threads` never exceeds what one serial subprocess was already
# given and the tutorials do not thrash: `auto` (or anything else that is not
# a plain integer) resolves to `Sys.CPU_THREADS` first, since text cannot be
# divided, and every worker keeps at least one thread.
function _tutorial_thread_budget(workers::Integer)
    requested = get(ENV, "JULIA_NUM_THREADS", "4")
    workers > 1 || return requested
    total = something(tryparse(Int, requested), Sys.CPU_THREADS)
    return string(max(1, total ÷ workers))
end

# The subprocess command for one heavy tutorial. `env` is the environment the
# tutorial opted into, or `nothing` for the shared docs one; it is kept as a
# `Union{Nothing,String}` rather than defaulting to `docs_dir` (whose type is
# unconstrained here) so the call stays concrete for JET.
function _tutorial_command(
        jl, runner, docs_dir, tutorials_dir, file,
        env::Union{Nothing, String}, threads::AbstractString
    )
    project = env === nothing ? docs_dir : env
    opts = `--threads=$(threads) --project=$(project)`
    input = joinpath(tutorials_dir, file)
    return `$jl $opts $runner $input $tutorials_dir`
end

# Run the heavy tutorials one at a time, each in a fresh subprocess, streaming
# its output live: the default, and unchanged from before the parallel mode
# existed. The first failure stops the build, named by the tutorial that
# caused it rather than by the julia command line it was buried in.
function _run_heavy_tutorials_serially(
        jl, runner, docs_dir, tutorials_dir, heavy, env_map, threads
    )
    for file in heavy
        env = get(env_map, file, nothing)
        env === nothing || _prepare_tutorial_env(file, env)
        println("  executing $file in a fresh subprocess...")
        cmd = _tutorial_command(
            jl, runner, docs_dir, tutorials_dir, file, env, threads
        )
        try
            run(cmd)
        catch err
            error("heavy tutorial $file failed to execute: $(err)")
        end
    end
    return
end

# Run the heavy tutorials `nworkers` at a time. Each subprocess's output is
# captured to its own log and printed as one block when it finishes, so a
# failure still reads against the tutorial that produced it instead of
# interleaving with whatever else was sampling at the time.
#
# A failure does not cancel its siblings: they are already running, and
# reporting every failure at the end beats the first one masking the rest.
# `run` throws on a non-zero exit, so each launch is caught individually --
# letting it escape `asyncmap` would lose both the other failures and, with
# them, which tutorial was at fault.
function _run_heavy_tutorials_concurrently(
        jl, runner, docs_dir, tutorials_dir, heavy, env_map, threads, nworkers
    )
    failed = String[]
    reporting = ReentrantLock()
    asyncmap(heavy; ntasks = nworkers) do file
        env = get(env_map, file, nothing)
        cmd = _tutorial_command(
            jl, runner, docs_dir, tutorials_dir, file, env, threads
        )
        log = tempname()
        ok = true
        try
            open(log, "w") do io
                run(pipeline(cmd; stdout = io, stderr = io))
            end
        catch
            ok = false
        end
        # One lock around the whole report, so two tutorials finishing
        # together cannot interleave their blocks.
        lock(reporting) do
            println("---- $file: $(ok ? "finished" : "FAILED") ----")
            isfile(log) && print(read(log, String))
            println("---- end $file ----")
            flush(stdout)
            ok || push!(failed, file)
        end
        rm(log; force = true)
        return nothing
    end
    isempty(failed) && return
    return error(
        "heavy tutorial(s) failed: " * join(failed, ", ") *
            ". Each one's output is above, printed as a single block under " *
            "its own name."
    )
end

# Execute the heavy tutorials, up to `workers` subprocesses at a time.
#
# `workers` defaults to 1 everywhere it is threaded through: memory, not
# cores, is what bounds a Turing tutorial, and two concurrent samplers can
# each hold several GB. Raising it is a per-package judgement about that
# package's own tutorials, made in its `docs_config.jl`.
#
# With more workers than tutorials, the surplus buys no concurrency and would
# only shrink each subprocess's share of the thread budget, so the count is
# capped at the work available.
function _execute_heavy_tutorials(
        docs_dir, tutorials_dir, heavy, env_map, workers::Integer
    )
    workers >= 1 || error(
        "heavy_tutorial_workers must be at least 1, got $workers"
    )
    nworkers = max(1, min(workers, length(heavy)))
    threads = _tutorial_thread_budget(nworkers)
    runner = joinpath(docs_dir, "run_literate_tutorial.jl")
    jl = Base.julia_cmd()
    if nworkers == 1
        println(
            "Executing heavy Literate tutorials, one per subprocess " *
                "($(threads) threads each)..."
        )
        return _run_heavy_tutorials_serially(
            jl, runner, docs_dir, tutorials_dir, heavy, env_map, threads
        )
    end
    println(
        "Executing heavy Literate tutorials, $(nworkers) at a time, one " *
            "per subprocess ($(threads) threads each)..."
    )
    # Every opted-in environment is instantiated before any subprocess
    # starts: concurrent `Pkg.instantiate` calls would race on the shared
    # depot, and a broken environment is a config mistake worth failing on
    # before hours of sampling rather than after.
    for file in heavy
        env = get(env_map, file, nothing)
        env === nothing || _prepare_tutorial_env(file, env)
    end
    return _run_heavy_tutorials_concurrently(
        jl, runner, docs_dir, tutorials_dir, heavy, env_map, threads, nworkers
    )
end

# Render the Literate tutorial pipeline into `tutorials_dir`. Light tutorials
# emit `@example` blocks Documenter runs in-process; heavy tutorials are each
# executed once in a fresh subprocess (via the package-owned
# `run_literate_tutorial.jl`) so native/memory state cannot accumulate.
#
# A heavy tutorial named in `envs` resolves against the environment it names
# instead of the shared `docs/` one, for a dependency that cannot co-resolve
# with the rest of the docs environment. Every other tutorial is built exactly
# as before, against `docs_dir`.
#
# `workers` runs that subprocess step up to N tutorials at a time (default 1,
# strictly one after another as before); see `_execute_heavy_tutorials`.
function _process_tutorials(
        docs_dir, tutorials_dir, light, heavy;
        envs = Pair{String, String}[], workers::Integer = 1
    )
    (isempty(light) && isempty(heavy)) && return
    env_map = _tutorial_env_map(docs_dir, envs)
    _reject_light_tutorial_envs(light, env_map)
    Literate = _literate()
    if !isempty(light)
        println(
            "Building light Literate tutorials " *
                "(this may take several minutes)..."
        )
        flavor = Base.invokelatest(Literate.DocumenterFlavor)
        for file in light
            Base.invokelatest(
                Literate.markdown,
                joinpath(tutorials_dir, file), tutorials_dir;
                flavor = flavor, mdstrings = true, credit = false
            )
        end
    end
    if !isempty(heavy)
        _execute_heavy_tutorials(
            docs_dir, tutorials_dir, heavy, env_map, workers
        )
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
# tested directly. Under `skip_notebooks` the light tutorials still render
# in-process (they are cheap) and only the heavy ones fall back to
# `tutorial_stubs`. Independent of that, a heavy tutorial named in
# `force_stub` never executes: the escape hatch for one that cannot run at all
# (e.g. a non-terminating sampler), leaving its siblings unaffected. `envs`
# carries the per-tutorial environment opt-in through to the subprocess
# launcher; a force-stubbed or skipped tutorial never reaches it, so its
# environment is never instantiated. `workers` is passed through on the same
# terms: it only reaches the subprocess step, so a skipped or force-stubbed
# tutorial is never counted as work to spread over.
function _render_tutorials(
        docs_dir, tutorials_dir, skip_notebooks::Bool,
        light, heavy, stubs; force_stub = String[],
        envs = Pair{String, String}[], workers::Integer = 1
    )
    # A registration whose Literate source is not there is dropped rather than
    # fatal. `docs_config.jl` is package-owned and write-once, so when the kit
    # retires a managed page (the AD-backends tutorial) the sync deletes the
    # source but cannot remove the adopter's entry for it. Erroring here would
    # red every docs build between the sync and the hand edit, over a page that
    # is deliberately gone. `update` warns about the dead entry separately.
    #
    # Scoped to execution only. Stubbing needs no source — a stub is written
    # from the `TUTORIAL_STUBS` heading — so the fast-build path below is left
    # exactly as it was.
    #
    # A tutorial with its own environment is exempt. Declaring one is
    # deliberate package configuration and the kit never gives a retired page
    # one, so a missing source there is a real mistake rather than a page the
    # kit removed, and it keeps failing loudly.
    declares_env = Set(first(p) for p in envs)
    present(files) = filter(files) do f
        f in declares_env && return true
        isfile(joinpath(tutorials_dir, f)) && return true
        @warn "skipping $f: registered in docs_config.jl but not present"
        return false
    end
    if !skip_notebooks
        run_heavy = filter(!in(force_stub), present(heavy))
        _process_tutorials(
            docs_dir, tutorials_dir, present(light), run_heavy;
            envs = envs, workers = workers
        )
        if !isempty(force_stub)
            force_stub_md = _tutorial_md_names(force_stub)
            _write_tutorial_stubs(
                tutorials_dir,
                filter(p -> first(p) in force_stub_md, stubs)
            )
        end
    else
        println(
            "Fast docs build: rendering light tutorials in-process, " *
                "stubbing heavy tutorials (--skip-notebooks or " *
                "SKIP_NOTEBOOKS=true)"
        )
        _process_tutorials(
            docs_dir, tutorials_dir, present(light), String[]; envs = envs
        )
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
            println(
                io,
                "_This tutorial is omitted from the fast documentation " *
                    "build. Build the full documentation (`task docs`) to " *
                    "render it._"
            )
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

# Remove any `... => "extensions/<page>.md"` leaf whose source page is absent
# under `src_dir`, and any nav group left empty by that removal. The extension
# nav group and its pages are both package-owned, so a package that drops an
# extension (or predates the kit seeding these pages) would otherwise build a
# nav with a dangling link. Judged on the page rather than on the current
# `[extensions]` table, so an authored page that outlives its extension is
# kept: what the package committed wins (#319).
function _strip_extensions_nav(pages, src_dir::AbstractString)
    kept = Any[]
    for entry in pages
        if entry isa Pair && entry.second isa AbstractString
            target = entry.second
            if startswith(target, "extensions/") && endswith(target, ".md") &&
                    !isfile(joinpath(src_dir, split(target, '/')...))
                continue
            end
            push!(kept, entry)
        elseif entry isa Pair && entry.second isa AbstractVector
            inner = _strip_extensions_nav(entry.second, src_dir)
            # An empty "Extensions" dropdown is worse than none.
            isempty(inner) && !isempty(entry.second) && continue
            push!(kept, entry.first => inner)
        else
            push!(kept, entry)
        end
    end
    return kept
end

# A benchmark nav target: any page under `benchmarks/`, plus the legacy flat
# `benchmarks.md` the performance-history page used to live at. The legacy
# form has to count: Documenter hard-errors on a nav entry with no page, so an
# adopter who has not yet edited their package-owned `pages.jl` would lose
# their docs build outright rather than just a sidebar entry.
function _is_benchmark_nav_target(target::AbstractString)
    return (startswith(target, "benchmarks/") || target == "benchmarks.md") &&
        endswith(target, ".md")
end

# Remove any benchmark leaf whose page is absent under `src_dir`, at any
# depth, and any group left empty by that removal -- mirroring
# `_strip_extensions_nav`, not gated on `benchmark_page`. Two package-owned
# files decide whether a leaf has a page: `pages.jl` names it,
# `docs_config.jl` registers it for rendering. `update` warns when either is
# stale, but nothing stops an adopter fixing one and not the other, so judge
# on the page and every combination self-heals.
function _strip_benchmark_nav(pages, src_dir::AbstractString)
    kept = Any[]
    for entry in pages
        if entry isa Pair && entry.second isa AbstractString
            target = entry.second
            if _is_benchmark_nav_target(target) &&
                    !isfile(joinpath(src_dir, split(target, '/')...))
                continue
            end
            push!(kept, entry)
        elseif entry isa Pair && entry.second isa AbstractVector
            inner = _strip_benchmark_nav(entry.second, src_dir)
            # A group left with no entries by that removal -- "Benchmarks"
            # with only one of over-time.md/ad-comparison.md ever built --
            # is itself dropped.
            isempty(inner) && !isempty(entry.second) && continue
            push!(kept, entry.first => inner)
        else
            push!(kept, entry)
        end
    end
    return kept
end

# Verify the Documenter-processed home page was not silently truncated by the
# npm/vitepress pipeline (#91): depending on `docs/node_modules` ordering,
# `docs/make.jl` can exit 0 having copied only a partial `index.md` into
# `docs/build/.documenter/`, with no error or warning. A complete Documenter
# pass never drops prose lines, so a line-count comparison against the
# generated source catches it. A missing built `index.md` (a caller that skips
# the Documenter build) leaves nothing to check.
function _check_index_not_truncated(
        index_src::AbstractString,
        built_dir::AbstractString
    )
    isfile(index_src) || return nothing
    built = joinpath(built_dir, "index.md")
    isfile(built) || return nothing
    src_lines = countlines(index_src)
    built_lines = countlines(built)
    if built_lines < max(5, src_lines ÷ 2)
        error(
            "docs build looks truncated (kit issue #91): the built home " *
                "page has $built_lines lines but the generated " *
                "docs/src/index.md has $src_lines lines. This matches the " *
                "silent npm/vitepress ordering failure from #91 — re-run the " *
                "docs build; if it persists, run `julia --project=docs -e " *
                "'using Pkg; Pkg.instantiate()'` once (so docs/node_modules " *
                "already exists) before running `docs/make.jl`."
        )
    end
    return nothing
end

"""
    build_docs(mod; repo, authors, pages, deploy_url=nothing,
               skip_notebooks=false, tutorials_subdir, light_tutorials=[],
               heavy_tutorials=[], tutorial_stubs=[], force_stub_tutorials=[],
               tutorial_environments=[], heavy_tutorial_workers=1,
               heavy_benchmarks=[], benchmark_stubs=[],
               ad_benchmark_results=nothing,
               linkcheck_ignore=[], index_rewrites=[], readme_execute=true,
               index_strip_sections=[], benchmark_page=true,
               history_suites=[], history_commits=5,
               history_regression_threshold=1.1, extra_modules=[],
               extra_remotes=Dict(), build_vitepress=true, deploy=true)

Run the standard EpiAware documentation build for package module `mod`. All
paths derive from `pkgdir(mod)`, so the managed `docs/make.jl` only forwards
the package-owned config. Generates the home page, release notes, benchmark
page and API pages, processes the Literate tutorials, then renders with
`DocumenterVitepress` and (when `deploy`) deploys. The release-notes page is
fetched from `repo`'s GitHub releases at build time and degrades to a link
when they cannot be read (see [`build_release_notes`](@ref)).

Under `skip_notebooks` the light tutorials still render in-process and only
the heavy ones fall back to `tutorial_stubs` headings. Independent of that,
any `heavy_tutorials` entry named in `force_stub_tutorials` never executes:
for one with a problem of its own (e.g. a model that does not terminate), so
it need not block its siblings.

`tutorial_environments` is a list of `"file.jl" => "environment/dir"` pairs
naming heavy tutorials that resolve against their own environment rather than
the shared `docs/` one, for a dependency that cannot co-resolve with the rest
of the docs environment. The directory is relative to `docs/` unless
absolute, is package-owned (the kit never writes it, as it never writes
`docs/Project.toml`), and must declare Literate alongside the tutorial's own
dependencies. It is instantiated before the tutorial runs; a missing,
Literate-less or unresolvable environment fails the build rather than
quietly stubbing the page. Every tutorial not named here is built against
`docs/` exactly as before.

`heavy_tutorial_workers` runs that many heavy tutorials concurrently, each
still in its own subprocess. It defaults to `1`, one after another as
before: memory rather than cores is what bounds a sampling tutorial, so
raising it is a judgement about one package's own tutorials. The thread
budget is divided rather than multiplied — each worker is launched with
`JULIA_NUM_THREADS ÷ workers` threads (at least one), so the total stays what
a serial build already asked for. Under it, each tutorial's output is
captured and printed as one block when it finishes rather than interleaved,
and every failure is reported by name at the end rather than the first
masking the rest.

`heavy_benchmarks`/`benchmark_stubs` drive the
same pipeline again over `src/benchmarks/`, so a benchmark report renders
under its own top-level "Benchmarks" nav group rather than under Tutorials.

`ad_benchmark_results` names where the scaffolded AD-comparison page's gradient
numbers are, so it renders what the package's benchmark run already measured
rather than measuring every (backend, scenario) pair again during the build. It
is a results file or a directory of them; a relative path resolves against
`docs/`, and the `AD_BENCHMARK_RESULTS` environment variable overrides it so CI
can name a checkout without the package editing its config. See
[`ad_benchmark_results_path`](@ref) and [`load_ad_benchmarks`](@ref).

It defaults to `nothing`, which falls back to the results the package's
benchmark run deploys to its `benchmarks` branch (see
[`published_ad_benchmark_results`](@ref)), and leaves the page measuring live
only where that branch carries no gradient numbers.

`deploy=false` builds without deploying and `build_vitepress=false` runs
Documenter without the final npm pass; both are used by tests and fast local
builds. On the benchmark page, `history_suites` (when non-empty) restricts the
summary and detail to the named headline suites, `history_commits` caps both
to that many most-recent revisions, and `history_regression_threshold` sets
the regression-flag cutoff (see [`_embed_benchmark_history`](@ref)).

The owning modules of `mod`'s re-exported docstrings are auto-discovered (see
`api_owning_modules`) and folded into Documenter's `modules` so those `@docs`
blocks resolve (#175); `extra_modules` adds any owner auto-discovery cannot
reach. Documenter drives its missing-docstring completeness check off the same
list, with no way to scope one without the other, so widening the resolution
set disables the check — a package is never held responsible for a
dependency's docstring hygiene, and `mod`'s own completeness is guaranteed by
[`build_api_pages`](@ref) rendering every docstring it owns (#313).

Each owning module also needs a source remote, which Documenter cannot derive
for a dependency installed from a git URL (#190). [`api_remotes`](@ref)
derives one from the recorded git source URL; `extra_remotes` supplies the
rest, e.g. `Dict(SomeDep => "EpiAware/SomeDep.jl")`.
"""
function build_docs(
        mod::Module; repo::AbstractString, authors::AbstractString,
        pages, deploy_url = nothing, skip_notebooks::Bool = false,
        tutorials_subdir::AbstractString = joinpath(
            "getting-started", "tutorials"
        ),
        light_tutorials = String[], heavy_tutorials = String[],
        tutorial_stubs = Pair{String, String}[],
        force_stub_tutorials = String[],
        tutorial_environments = Pair{String, String}[],
        heavy_tutorial_workers::Integer = 1,
        heavy_benchmarks = String[],
        benchmark_stubs = Pair{String, String}[],
        ad_benchmark_results::Union{Nothing, AbstractString} = nothing,
        linkcheck_ignore = Regex[], index_rewrites = Pair{String, String}[],
        readme_execute::Bool = true, index_strip_sections = String[],
        benchmark_page::Bool = true, history_suites = String[],
        history_commits::Integer = 5,
        history_regression_threshold::Real = 1.1, extra_modules = Module[],
        extra_remotes = Dict(),
        build_vitepress::Bool = true, deploy::Bool = true
    )
    project_root = pkgdir(mod)
    # Narrow `pkgdir`'s `Union{Nothing,String}` up front so the downstream
    # `joinpath` calls stay type-stable for JET.
    project_root === nothing &&
        error("Cannot locate the package directory for module $mod")
    docs_dir = joinpath(project_root, "docs")
    src_dir = joinpath(docs_dir, "src")
    tutorials_dir = joinpath(src_dir, tutorials_subdir)
    benchmarks_dir = joinpath(src_dir, "benchmarks")

    # --- tutorials -----------------------------------------------------
    _render_tutorials(
        docs_dir, tutorials_dir, skip_notebooks, light_tutorials,
        heavy_tutorials, tutorial_stubs; force_stub = force_stub_tutorials,
        envs = tutorial_environments, workers = heavy_tutorial_workers
    )

    # --- docs/src/benchmarks/ (e.g. the AD-comparison report) --------------
    # Same pipeline, its own directory, so a benchmark report renders under
    # its own top-level "Benchmarks" nav group rather than under Tutorials
    # (#299/#305). Heavy-only: nothing currently needs a light benchmark
    # page, but `_render_tutorials` costs nothing extra to call generically.
    # Shares `force_stub_tutorials` with the tutorials pipeline above -- it
    # is matched against whichever `heavy` list is passed at each call site,
    # so one config list parks a heavy page in either directory by name.
    # `tutorial_environments` and `heavy_tutorial_workers` are shared on the
    # same terms.
    #
    # The AD-comparison page reads the gradient numbers the benchmark run
    # published when this build has them. Resolved and exported here because
    # the page executes in a subprocess that inherits this environment; with
    # nothing configured and nothing in the environment the variable is left
    # alone and the page measures live.
    _export_ad_benchmark_results(
        docs_dir, ad_benchmark_results, project_root
    )
    _render_tutorials(
        docs_dir, benchmarks_dir, skip_notebooks, String[],
        heavy_benchmarks, benchmark_stubs; force_stub = force_stub_tutorials,
        envs = tutorial_environments, workers = heavy_tutorial_workers
    )

    # --- generated pages ---------------------------------------------------
    build_index(;
        readme = joinpath(project_root, "README.md"),
        dest = joinpath(src_dir, "index.md"), repo = repo,
        execute = readme_execute, rewrites = index_rewrites,
        strip_sections = index_strip_sections
    )
    build_release_notes(;
        repo = repo,
        header_file = joinpath(docs_dir, "release_notes_header.jl"),
        dest = joinpath(src_dir, "release-notes.md")
    )
    benchmark_linkcheck = Regex[]
    if benchmark_page
        benchmark_linkcheck = build_benchmark_page(;
            dest = joinpath(benchmarks_dir, "over-time.md"), repo = repo,
            package = string(mod),
            prose_file = joinpath(docs_dir, "benchmarks.md"),
            notes_file = joinpath(docs_dir, "benchmarks_notes.md"),
            project_root = project_root, history_suites = history_suites,
            history_commits = history_commits,
            history_regression_threshold = history_regression_threshold
        )
    else
        println("BENCHMARK_PAGE = false; skipping benchmark history page")
    end
    # Judged on the built page existing, not on `benchmark_page` alone, so a
    # Benchmarks nav leaf left dangling by either package-owned file
    # (`pages.jl` naming a page `docs_config.jl` never registers, or vice
    # versa) is dropped whichever of the two `update` warnings the adopter
    # acted on (see `_strip_benchmark_nav`).
    pages = _strip_benchmark_nav(pages, src_dir)
    pages = _strip_extensions_nav(pages, src_dir)
    build_api_pages(mod, joinpath(src_dir, "lib"))

    # --- render ------------------------------------------------------------
    Documenter = _documenter()
    DocumenterVitepress = _vitepress()
    # A third-party docstring can carry an empty anchor id: warn and skip that
    # inventory entry rather than abort (#232). No-op once upstream fixes it.
    _guard_empty_anchors()
    Base.invokelatest(
        Documenter.DocMeta.setdocmeta!, mod, :DocTestSetup,
        Expr(:using, Expr(:., nameof(mod))); recursive = true
    )

    bib_path = joinpath(src_dir, "refs.bib")
    plugins = if isfile(bib_path)
        DocumenterCitations = _citations()
        [
            Base.invokelatest(
                DocumenterCitations.CitationBibliography, bib_path;
                style = :numeric
            ),
        ]
    else
        Documenter.Plugin[]
    end

    format = Base.invokelatest(
        DocumenterVitepress.MarkdownVitepress;
        repo = "github.com/$repo", devbranch = "main", devurl = "dev",
        deploy_url = deploy_url, build_vitepress = build_vitepress,
        keep = :patch
    )

    # The modules Documenter's `@docs` resolver searches: `mod` leads, then
    # the owners of its re-exported docstrings so those entries resolve
    # instead of raising "no docs found" (#175).
    owning_modules = union(Set{Module}(extra_modules), api_owning_modules(mod))
    delete!(owning_modules, mod)
    doc_modules = Module[mod]
    append!(doc_modules, collect(owning_modules))
    # Documenter's missing-docstring check runs off this same `modules` list
    # and cannot be scoped separately: `checkdocs_ignored_modules` does not
    # exclude a top-level owner, and there is no allowlist keyword. So
    # widening for re-export resolution disables the check, keeping a package
    # off the hook for its dependencies' hygiene; `build_api_pages` already
    # renders every docstring `mod` owns (#313). With no re-exports the
    # default `:all` check over `mod` alone is kept.
    checkdocs = length(doc_modules) > 1 ? :none : :all
    # `mod` is left out: its docs build runs in its own checkout, which
    # Documenter resolves from git (#190).
    remotes = api_remotes(owning_modules; extra_remotes = extra_remotes)
    # `root` is pinned explicitly because Documenter otherwise defaults it to
    # the running script's directory, and the thin caller may run from
    # anywhere. `source`/`build` keep their defaults relative to it.
    Base.invokelatest(
        Documenter.makedocs; root = docs_dir,
        sitename = "$mod.jl",
        authors = authors, clean = true, doctest = false,
        linkcheck = !skip_notebooks,
        linkcheck_ignore = vcat(linkcheck_ignore, benchmark_linkcheck),
        warnonly = [
            :docs_block, :missing_docs, :autodocs_block, :cross_references,
        ],
        checkdocs = checkdocs, remotes = remotes,
        modules = doc_modules, pages = pages, format = format,
        plugins = plugins
    )

    # Fail loudly rather than silently ship a truncated home page (#91).
    _check_index_not_truncated(
        joinpath(src_dir, "index.md"),
        joinpath(docs_dir, "build", ".documenter")
    )

    _copy_tutorial_data(src_dir, joinpath(docs_dir, "build"))

    if deploy
        Base.invokelatest(
            DocumenterVitepress.deploydocs;
            repo = "github.com/$repo", target = "build", branch = "gh-pages",
            devbranch = "main", push_preview = true
        )
    end
    return
end

end # module DocsBuild
