# Scaffolder for the standard EpiAware package tooling. Writes/updates the
# shipped configuration and test infrastructure into a package so it adopts
# (and stays in sync with) the kit in one call. The templates live in
# `templates/` and are the single source of truth.
#
# Each template is either managed (re-applied on update, overwritten to remove
# drift) or package-owned (a skeleton written once and never touched again).
# `scaffold` adopts; `update` re-applies only the managed files. Both return a
# manifest of what was created, updated, preserved or removed.
#
# No person, org or repository name is baked into a template. Every such value
# is a `{{PLACEHOLDER}}` filled from `scaffold`/`update` inputs, which default
# to the target's `Project.toml` and an org default, and are overridable.

# A template entry. `src` is the path under `templates/`; `dest` the path under
# the target package root (usually equal). `managed = true` means standard
# infra (overwritten on update); `false` a package-owned skeleton (write once).
# `substitute = true` runs placeholder substitution on copy.
#
# `ad` gates a template on the `ad` flag, so a numerical package opts into the
# AD CI caller and test harness while a tooling package opts out: `:always`,
# `:ad_only` (`ad = true`), or `:noad_only` (`ad = false`). A file whose
# content depends on AD ships as an `:ad_only` + `:noad_only` pair writing to
# the same `dest`, so exactly one is emitted.
#
# `bench` mirrors that for the opt-in `benchmarks` flag: `:always` or
# `:bench_only`.
struct Template
    src::String
    dest::String
    managed::Bool
    substitute::Bool
    ad::Symbol
    bench::Symbol
end

# Convenience constructor: most templates are AD- and benchmark-agnostic.
function Template(src, dest, managed, substitute)
    return Template(src, dest, managed, substitute, :always, :always)
end

# AD-flavoured templates specify only `ad`; still benchmark-agnostic.
function Template(src, dest, managed, substitute, ad::Symbol)
    return Template(src, dest, managed, substitute, ad, :always)
end

# The standard template set. Order is informational only.
const SCAFFOLD_TEMPLATES = Template[
    # --- root dev config (managed) ---
    # Taskfile + codecov differ by AD content, so each ships as an
    # AD/no-AD pair writing to the same destination.
    Template("Taskfile.yml", "Taskfile.yml", true, false, :ad_only),
    Template("Taskfile.noad.yml", "Taskfile.yml", true, false, :noad_only),
    # Substituted for the single-source `{{RUNIC_VERSION}}`/
    # `{{RUNIC_PRE_COMMIT_REV}}` hook `rev`s.
    Template(".pre-commit-config.yaml", ".pre-commit-config.yaml", true, true),
    Template(".gitattributes", ".gitattributes", true, false),
    # NOTE: `.gitignore` is not in this list. It is managed between markers
    # (see `_apply_gitignore`) so a package's own ignore-rule additions below
    # the managed block survive `update`, rather than being copied verbatim
    # and clobbered on the next sync (#65).
    Template(".secrets.baseline", ".secrets.baseline", true, false),
    Template("codecov.yml", "codecov.yml", true, true, :ad_only),
    Template("codecov.noad.yml", "codecov.yml", true, false, :noad_only),
    # NOTE: `LICENSE` is not a managed template. It is written once from the
    # `license` input (see `_apply_license`) and never overwritten by `update`,
    # so a package that deliberately changes its licence is not silently
    # reverted on a sync. See the `license` field of `scaffold_inputs`.

    # --- CI caller workflows + dependabot (managed) ---
    Template(".github/dependabot.yml", ".github/dependabot.yml", true, true),
    # Repo-specific (GitHub serves no org-default CODEOWNERS) but fully
    # derived from the `reviewer` handle, so managed like any other file.
    Template(".github/CODEOWNERS", ".github/CODEOWNERS", true, true),
    Template(
        ".github/workflows/test.yaml",
        ".github/workflows/test.yaml", true, true
    ),
    # The AD CI caller is opt-in: only scaffolded when `ad = true`.
    Template(
        ".github/workflows/ad.yaml",
        ".github/workflows/ad.yaml", true, true, :ad_only
    ),
    Template(
        ".github/workflows/document.yaml",
        ".github/workflows/document.yaml", true, true
    ),
    Template(
        ".github/workflows/pre-commit.yaml",
        ".github/workflows/pre-commit.yaml", true, true
    ),
    Template(
        ".github/workflows/codecoverage.yaml",
        ".github/workflows/codecoverage.yaml", true, true
    ),
    Template(
        ".github/workflows/docpreviewcleanup.yaml",
        ".github/workflows/docpreviewcleanup.yaml", true, true
    ),
    Template(
        ".github/workflows/TagBot.yaml",
        ".github/workflows/TagBot.yaml", true, true
    ),
    # Triggers General Registry registration from a `/register` comment or a
    # `workflow_dispatch`. Every value comes from the Actions context, so it
    # ships unsubstituted.
    Template(
        ".github/workflows/Register.yml",
        ".github/workflows/Register.yml", true, false
    ),
    Template(
        ".github/workflows/downstream.yaml",
        ".github/workflows/downstream.yaml", true, true
    ),
    # Fails when a dependency is unregistrable (unregistered or
    # compat-unsatisfiable), and warns when an org reverse-dep's compat is
    # stranded by the version under test.
    Template(
        ".github/workflows/registrability.yaml",
        ".github/workflows/registrability.yaml", true, true
    ),
    # Opens/refreshes one issue when main has unreleased changes, saying
    # whether a version bump or only registration is outstanding.
    Template(
        ".github/workflows/release-nudge.yaml",
        ".github/workflows/release-nudge.yaml", true, true
    ),
    # Cancel a PR's in-flight runs on close/merge, freeing runners that
    # concurrency groups miss.
    Template(
        ".github/workflows/cancel-on-close.yaml",
        ".github/workflows/cancel-on-close.yaml", true, true
    ),
    # "Try this PR!": comments install instructions for the PR branch.
    Template(
        ".github/workflows/try-this-pr.yaml",
        ".github/workflows/try-this-pr.yaml", true, true
    ),
    # The Claude Code review bot, gated on the `reviewer` handle so only that
    # user's comments/PRs trigger it.
    Template(
        ".github/workflows/claude.yml",
        ".github/workflows/claude.yml", true, true
    ),
    Template(
        ".github/workflows/claude-code-review.yml",
        ".github/workflows/claude-code-review.yml", true, true
    ),
    # Scheduled template-sync: re-applies the managed standard and opens a PR
    # when the committed infra has drifted from the kit.
    Template(
        ".github/workflows/template-sync.yaml",
        ".github/workflows/template-sync.yaml", true, true
    ),

    # --- benchmark CI (managed, opt-in via `benchmarks = true`) ---
    # `benchmark.yaml` builds the PR base-vs-head comment from
    # `benchmark/compare.jl`; `benchmark-history.yaml` renders the persistent
    # timeline with AirspeedVelocity's `benchpkgtable`/`benchpkgplot`.
    Template(
        ".github/workflows/benchmark.yaml",
        ".github/workflows/benchmark.yaml", true, true, :always, :bench_only
    ),
    Template(
        ".github/workflows/benchmark-history.yaml",
        ".github/workflows/benchmark-history.yaml", true, true, :always,
        :bench_only
    ),

    # --- version automation (managed) ---
    # Auto-increment the patch version on an unbumped merge to main, plus an
    # on-demand `/version major|minor|patch` PR comment command. Both are
    # driven by the bundled `increment-version` composite action.
    Template(
        ".github/workflows/auto-version-increment.yaml",
        ".github/workflows/auto-version-increment.yaml", true, false
    ),
    Template(
        ".github/workflows/version-on-demand.yaml",
        ".github/workflows/version-on-demand.yaml", true, false
    ),
    Template(
        ".github/actions/increment-version/action.yaml",
        ".github/actions/increment-version/action.yaml", true, true
    ),

    # NOTE: the org-level community health files are not scaffolded. GitHub
    # serves them org-wide from EpiAware/.github to any repo lacking its own
    # copy, so shipping them here would shadow the org defaults and drift.

    # --- shipped test infrastructure (managed) ---
    Template(
        "test/package/quality.jl",
        "test/package/quality.jl", true, false
    ),
    Template("test/jet/runtests.jl", "test/jet/runtests.jl", true, true),
    Template("test/jet/Project.toml", "test/jet/Project.toml", true, true),
    Template(
        "test/formatter/runtests.jl",
        "test/formatter/runtests.jl", true, false
    ),
    # Substituted for the single-source `{{RUNIC_VERSION}}` compat pin.
    Template(
        "test/formatter/Project.toml",
        "test/formatter/Project.toml", true, true
    ),
    # The AD harness drivers are opt-in (managed, but only when `ad = true`).
    Template("test/ad/setup.jl", "test/ad/setup.jl", true, true, :ad_only),
    Template(
        "test/ad/runtests.jl", "test/ad/runtests.jl", true, false,
        :ad_only
    ),
    # A named-filter diagnostic runner, thin over `run_selected` (#384): fast
    # iteration on one scenario/backend without the full per-backend suite.
    Template(
        "test/ad/run_selected.jl", "test/ad/run_selected.jl", true, true,
        :ad_only
    ),
    # The benchmark suite drivers are opt-in (managed, only when
    # `benchmarks = true`).
    Template(
        "benchmark/run.jl", "benchmark/run.jl", true, false, :always,
        :bench_only
    ),
    Template(
        "benchmark/compare.jl", "benchmark/compare.jl", true, false,
        :always, :bench_only
    ),

    # --- documentation: Documenter + DocumenterVitepress (managed) ---
    # `make.jl`, the VitePress site config/theme/components, the node deps and
    # the version stub are managed; `Project.toml` is package-owned so a
    # package extends it. `docs/pages.jl` is not in this list: like
    # `.gitignore`, it needs bespoke merge logic (`_apply_pages`) rather than
    # a plain overwrite-or-preserve template, since overwriting a bespoke nav
    # would delete a package's real docs navigation (#170/#328/#354).
    Template("docs/make.jl", "docs/make.jl", true, true),
    # The per-subprocess heavy-tutorial runner `make.jl` shells out to.
    Template(
        "docs/run_literate_tutorial.jl",
        "docs/run_literate_tutorial.jl", true, false
    ),
    Template("docs/package.json", "docs/package.json", true, false),
    Template("docs/versions.js", "docs/versions.js", true, false),
    Template(
        "docs/src/.vitepress/config.mts",
        "docs/src/.vitepress/config.mts", true, true
    ),
    Template(
        "docs/src/.vitepress/theme/index.ts",
        "docs/src/.vitepress/theme/index.ts", true, false
    ),
    Template(
        "docs/src/.vitepress/theme/style.css",
        "docs/src/.vitepress/theme/style.css", true, false
    ),
    Template(
        "docs/src/components/VersionPicker.vue",
        "docs/src/components/VersionPicker.vue", true, false
    ),
    # The GitHub-stars navbar widget (Vue component + its build-time star-count
    # loader). Both carry `{{REPO}}` so the widget targets the adopting repo.
    Template(
        "docs/src/components/StarUs.vue",
        "docs/src/components/StarUs.vue", true, true
    ),
    Template(
        "docs/src/components/stargazers.data.ts",
        "docs/src/components/stargazers.data.ts", true, true
    ),
    # The AD-backends tutorial page. Managed so the body stays kit-current;
    # everything package-specific it reports (scenarios, backends, broken/skip
    # declarations) is read at docs-build time from the package-owned
    # `test/ADFixtures` registry, so a package never edits this file. Its
    # registration and docs-env deps live in the package-owned docs seeds,
    # filled via the `AD_*` fragments (see `_ad_heavy_tutorials`). Its
    # backend-comparison benchmark lives on the sibling `ad-comparison.jl`
    # page under `docs/src/benchmarks/`.
    Template(
        "docs/src/getting-started/tutorials/ad-backends.jl",
        "docs/src/getting-started/tutorials/ad-backends.jl", true, true,
        :ad_only
    ),
    # The AD backend-comparison benchmark, split out of `ad-backends.jl`
    # (#299) so the cost report gets its own top-level "Benchmarks" nav group
    # (alongside the performance-over-time page, when the package has one)
    # rather than reading as a how-to guide under Tutorials -- physically
    # under `docs/src/benchmarks/`, not nested inside Tutorials (#305, the
    # shape EpiAwareADTools#28 asked for). Same management/registration
    # story as `ad-backends.jl` above, but via `HEAVY_BENCHMARKS`/
    # `BENCHMARK_STUBS` (see `_ad_heavy_benchmarks` etc.), not
    # `HEAVY_TUTORIALS`/`TUTORIAL_STUBS`.
    Template(
        "docs/src/benchmarks/ad-comparison.jl",
        "docs/src/benchmarks/ad-comparison.jl", true, true,
        :ad_only
    ),

    # --- package-owned skeletons (written once, never overwritten) ---
    # The standard DocStringExtensions `@template` conventions. Package-owned
    # because it lives in `src/` and must be `include`d by the package module
    # before its docstrings are defined for the templates to take effect.
    Template("src/docstrings.jl", "src/docstrings.jl", false, false),
    # No NEWS.md seed: release notes are written on the GitHub release itself
    # and fetched at build time (see `docs/release_notes_header.jl` and
    # `build_release_notes`), so there is no changelog file to keep in step
    # with the tags. A package with an existing NEWS.md keeps it — the kit no
    # longer reads it.
    Template("docs/Project.toml", "docs/Project.toml", false, true),
    # A placeholder logo, seeded at this exact path so a package can drop in a
    # real one without further wiring: the README -> index.md step already
    # strips an `<img ... assets/logo.svg ...>` tag from the generated home
    # page. Package-owned like LICENSE — replace the file, never regenerated.
    Template(
        "docs/src/assets/logo.svg",
        "docs/src/assets/logo.svg", false, true
    ),
    # The authored quickstart, distinct from the README-derived home page.
    # Docs about the kit itself are not seeded here: they describe the kit,
    # not the adopting package, so they live on the kit's own site (#194).
    Template(
        "docs/src/getting-started/index.md",
        "docs/src/getting-started/index.md", false, true
    ),
    # The optional Literate/tutorial + README-rewrite config `make.jl` reads,
    # and the release-notes page header. Substituted so `BENCHMARK_PAGE`
    # defaults to the `benchmarks` flag.
    Template("docs/docs_config.jl", "docs/docs_config.jl", false, true),
    Template(
        "docs/release_notes_header.jl",
        "docs/release_notes_header.jl", false, true
    ),
    # The package-owned prose hook spliced into the generated benchmark page.
    # Opt-in: only written when `benchmarks = true` (no page, no hook otherwise).
    Template(
        "docs/benchmarks.md", "docs/benchmarks.md", false, true, :always,
        :bench_only
    ),
    # The "Skipped & broken benchmarks" notes hook, spliced below the overall
    # trend plot. Same write-once/opt-in lifecycle as the prose hook above.
    Template(
        "docs/benchmarks_notes.md", "docs/benchmarks_notes.md", false,
        true, :always, :bench_only
    ),
    Template("test/runtests.jl", "test/runtests.jl", false, false),
    # The test env differs by AD deps, so it ships as an AD/no-AD pair.
    Template("test/Project.toml", "test/Project.toml", false, true, :ad_only),
    Template(
        "test/Project.noad.toml", "test/Project.toml", false, true,
        :noad_only
    ),
    Template(
        "test/package/qa_config.jl",
        "test/package/qa_config.jl", false, true
    ),
    # The optional JET report filter (e.g. for a DynamicPPL @model package).
    Template("test/jet/jet_config.jl", "test/jet/jet_config.jl", false, false),
    # The benchmark environment, so `--project=benchmark` resolves. Opt-in.
    Template(
        "benchmark/Project.toml", "benchmark/Project.toml", false, true,
        :always, :bench_only
    ),
    # The AD scenarios + registry skeleton are opt-in (only when `ad = true`).
    Template(
        "test/ad/scenarios.jl", "test/ad/scenarios.jl", false, true,
        :ad_only
    ),
    Template(
        "test/ad/Project.toml", "test/ad/Project.toml", false, true,
        :ad_only
    ),
    Template(
        "test/ADFixtures/Project.toml",
        "test/ADFixtures/Project.toml", false, true, :ad_only
    ),
    Template(
        "test/ADFixtures/src/ADFixtures.jl",
        "test/ADFixtures/src/ADFixtures.jl", false, true, :ad_only
    ),
    # The package-owned benchmark suite skeleton (the `SUITE`). Opt-in.
    Template(
        "benchmark/benchmarks.jl", "benchmark/benchmarks.jl", false, true,
        :always, :bench_only
    ),
]

# Managed paths the kit has retired (#185): `update` used to leave a dropped
# template behind, so adopters kept dead infra no workflow invokes. Retiring is
# one-way — a path listed here is removed on sync and never written again, so
# it must not be (or contain) a live template destination, which the scaffold
# tests enforce. An entry may be a file or a directory.
const RETIRED_PATHS = String[
    "benchmark/comment",
    # Runic is unconfigurable, so this file has no meaning under the managed
    # standard now the formatter has moved from JuliaFormatter to Runic.
    # Retired rather than left behind, so an adopting package converges
    # instead of keeping a dead config file forever.
    ".JuliaFormatter.toml",
]

# --- stale package-owned prose (#328) ---------------------------------------
#
# A sync converges the managed files and says nothing about the package's own
# docs, so prose describing the old standard survives every sync and nothing
# reports it. EpiAwareADTools is the case that prompted this: after adopting
# the kit's Runic migration its `developer/contributing.md` and
# `developer/faq.md` still told contributors to run JuliaFormatter, against a
# `test/formatter/Project.toml` that pins Runic.
#
# `update` cannot rewrite package-owned prose — the wording is the package's —
# so it names the file and the term instead, the same way the write-once docs
# gaps above are reported.
#
# Two sources feed the scan. `RETIRED_PATHS` is free: a path the kit no longer
# ships should not still be documented, so every future retirement gets a
# prose check without anything being added here. `RETIRED_PROSE` covers what
# retiring a path cannot express, namely a tool or concept the standard has
# moved away from that was never a file in the package.
const RETIRED_PROSE = [
    (
        term = "JuliaFormatter",
        instead = "Runic",
        why = "the managed formatter moved to Runic; the isolated " *
            "test/formatter environment pins Runic and `task format` runs it",
    ),
]

# A page that names a retired tool in order to explain the retirement is not
# drift. Marking it opts it out of the scan, mirroring how
# `EPIAWARE_MANAGED_OVERRIDE` opts a file out of resyncing. In markdown put it
# in an HTML comment so it does not render.
const _PROSE_OK_MARKER = "EPIAWARE_PROSE_OK"

# Changelogs are never scanned: recording what a package used to do is the
# point of one, so naming a retired tool there is correct rather than drift.
# `docs/src/release-notes.md` is this kit's replacement for `NEWS.md` — it is
# generated by the docs build from the repo's GitHub releases and gitignored —
# so excluding one without the other would miss the successor and fire on any
# package whose release history mentions a retired tool.
const _PROSE_CHANGELOGS = ("NEWS.md", "CHANGELOG.md", "release-notes.md")

# Package-owned prose worth scanning, each paired with its contents so the file
# is read once rather than again in `_stale_prose_gap`: the README, a
# hand-written contributing guide, and the authored docs pages. Literate `.jl`
# sources count — they are prose that happens to execute.
function _package_prose_files(target_dir::AbstractString)
    files = Pair{String, String}[]
    for rel in ("README.md", "CONTRIBUTING.md")
        path = joinpath(target_dir, rel)
        isfile(path) || continue
        text = read(path, String)
        occursin(_PROSE_OK_MARKER, text) || push!(files, path => text)
    end
    src = joinpath(target_dir, "docs", "src")
    isdir(src) || return files
    for (root, _, names) in walkdir(src), name in names
        endswith(name, ".md") || endswith(name, ".jl") || continue
        name in _PROSE_CHANGELOGS && continue
        path = joinpath(root, name)
        text = read(path, String)
        # A kit-managed page carries the standard header and is rewritten by
        # this sync, so it is never the package's to fix.
        occursin("MANAGED by EpiAwarePackageTools", text) && continue
        occursin(_PROSE_OK_MARKER, text) && continue
        push!(files, path => text)
    end
    return files
end

# Scan package-owned prose for names the managed standard has retired,
# returning one warning per (file, term) or `nothing` when the prose is clean.
function _stale_prose_gap(target_dir::AbstractString)
    terms = vcat(
        [
            (term = p, instead = nothing, why = "the kit no longer ships it")
                for p in RETIRED_PATHS
        ],
        [
            (term = e.term, instead = e.instead, why = e.why)
                for e in RETIRED_PROSE
        ]
    )
    hits = String[]
    for (path, text) in _package_prose_files(target_dir)
        rel = relpath(path, target_dir)
        matched = filter(t -> occursin(t.term, text), terms)
        # One mention can match two terms: `.JuliaFormatter.toml` is both a
        # retired path and a superstring of the retired tool name, and naming
        # the same mention twice reads as two problems. Keep the longest match
        # and drop any term contained in one already kept.
        sort!(matched; by = t -> length(t.term), rev = true)
        for (i, t) in pairs(matched)
            any(o -> occursin(t.term, o.term), matched[1:(i - 1)]) && continue
            push!(
                hits, string(
                    rel, " still mentions ", t.term,
                    t.instead === nothing ? "" : " rather than $(t.instead)",
                    " (", t.why, ")"
                )
            )
        end
    end
    isempty(hits) && return nothing
    return string(
        "package-owned docs describe a standard this kit has retired: ",
        join(hits, "; "),
        ". A sync converges the managed files only, so this prose is yours ",
        "to update (kit#328)."
    )
end

# Absolute native path of a template destination. Every `dest` is written
# posix-style, so a plain `joinpath` yields a mixed-separator path on Windows.
# Windows accepts that for io, but the scaffold results are public API that
# callers compare against their own backslash-separated `joinpath`, which would
# never match. Splitting on `/` and re-joining gives the native separator.
function _dest_path(target_dir::AbstractString, dest::AbstractString)
    return joinpath(target_dir, split(dest, '/')...)
end

# Remove the retired managed paths from `target_dir`, returning those actually
# deleted. Only paths the kit itself once shipped are listed, so this never
# reaches package-owned content.
function _remove_retired(target_dir::AbstractString)
    removed = String[]
    for rel in RETIRED_PATHS
        path = _dest_path(target_dir, rel)
        ispath(path) || continue
        rm(path; recursive = true, force = true)
        push!(removed, path)
    end
    return removed
end

# The default org used to derive `{{ORG}}`/`{{REPO}}` when a caller does not
# pass them. This is the only org default in the kit; it is overridable.
const DEFAULT_ORG = "EpiAware"

# The single source of truth for the pinned Runic version (#114), feeding the
# `.pre-commit-config.yaml` hook `additional_dependencies` pin and the
# `test/formatter/Project.toml` compat pin. `runic-check.yml` greps the
# calling repo's `.pre-commit-config.yaml` for the literal string
# `Runic@<runic_version>` and fails if absent, so it does not need this value
# passed as a workflow input the way `format-check.yml` did.
const _RUNIC_VERSION = "1.7.0"

# The single source of truth for the pinned `runic-pre-commit` hook revision,
# feeding the `.pre-commit-config.yaml` `rev`. Released independently of Runic
# itself, so tracked separately from `_RUNIC_VERSION`.
const _RUNIC_PRE_COMMIT_REV = "v2.2.0"

# --- the Julia floor (#246) -------------------------------------------------
#
# The managed standard requires Julia 1.11 because `[sources]` — how
# `test/Project.toml` pins the kit to `main` — is a Pkg 1.11 feature. On 1.10
# it is silently ignored rather than an error, so Pkg resolves whatever the
# registry carries instead of the pinned rev: an LTS job then exercises a stale
# kit while appearing to test the current one, surfacing only once a template
# uses a binding the registered version predates. The org reusables default to
# a matrix including `lts`, so both callers are given the floor explicitly.
const _JULIA_FLOOR = v"1.11"

# Compat for a newly generated package. Only `scaffold_generate` seeds a
# Project.toml, so this cannot rewrite an adopter's own compat;
# `_julia_compat_below_floor` warns about that instead.
const _JULIA_COMPAT = "1.11, 1.12"

# The `julia_versions` matrix for the `tests.yml` caller, dropping the `lts`
# entry the reusable defaults to. Managed, so an adopter's resync moves off
# 1.10 rather than resolving the registry there forever (#183).
const _JULIA_TEST_VERSIONS = "'[\"1\", \"pre\"]'"

# The `julia_version` for the `downgrade.yml` caller, whose own default `'1.10'`
# is the exact version where `[sources]` is ignored (#115).
#
# The current release, not the floor: the job must also be a version the test
# environment resolves on, and 1.11 is not one. JET publishes nothing for 1.11
# beyond 0.9.19/0.9.20, which need JuliaSyntax 0.4 and cannot coexist with the
# pinned Runic 1.7.0 (JuliaSyntax 1). Pinning to the floor would only make CI
# red on a conflict unrelated to the package under test.
const _JULIA_DOWNGRADE_VERSION = "'1'"

# The Julia versions a `test.yaml` caller names that sit below the floor: an
# `lts` entry or an explicit `1.10`/older. A package may pick its own matrix
# (#73), but such a leg silently resolves the registered kit rather than the
# pinned rev, so it is never left unremarked (#246).
function _julia_versions_below_floor(content::AbstractString)
    below = String[]
    for m in eachmatch(r"(?m)^[ \t]*julia_versions?:[ \t]*(\S.*?)[ \t]*$", content)
        # Drop a trailing inline comment first: a note explaining which leg was
        # dropped would otherwise be read as the value.
        value = replace(String(something(m.captures[1])), r"\s+#.*$" => "")
        occursin("lts", value) && push!(below, "lts")
        for v in eachmatch(r"(\d+\.\d+)", value)
            text = String(something(v.captures[1]))
            # Reported as the workflow names it ("1.10"), not normalised, so
            # the warning names the leg the maintainer has to delete.
            VersionNumber(text) < _JULIA_FLOOR && push!(below, text)
        end
    end
    return unique(below)
end

# Whether a package's `[compat] julia` admits a version below the floor. `Pkg`
# is unavailable for a full semver parse here, so read the lowest bound each
# comma-separated range names: `"1.10, 1.11"` → 1.10 (below), `"1"` → 1.0
# (below). `nothing` when there is no julia compat at all.
function _julia_compat_below_floor(compat::AbstractString)
    lowest = nothing
    for range in split(compat, ',')
        m = match(r"(\d+)(?:\.(\d+))?", range)
        m === nothing && continue
        major = parse(Int, something(m.captures[1]))
        minor = m.captures[2] === nothing ? 0 : parse(Int, something(m.captures[2]))
        v = VersionNumber(major, minor)
        (lowest === nothing || v < lowest) && (lowest = v)
    end
    lowest === nothing && return nothing
    return lowest < _JULIA_FLOOR ? lowest : nothing
end

# The seed reusable-workflow ref for the opt-in `downgrade-compat` caller job
# (#121). Dependabot bumps the live pin in each adopting repo and
# `_preserve_reusable_refs` keeps it across `update`, so this seed is only what
# a first scaffold commits. Kept in step with the `test` job's pin.
const _DOWNGRADE_SEED_REF = "6fcdcde033ec670ac3832b239427fd2ded591bbc"  # pragma: allowlist secret

# The seed ref for the registrability caller: the squash-merge SHA of
# EpiAware/.github#31, which is newer than `_DOWNGRADE_SEED_REF` because
# `registrability.yml` does not exist on that shared seed. The refs converge
# once Dependabot bumps the pins.
const _REGISTRABILITY_SEED_REF = "26387a36be3d093723b5f85e4f93d99af98456b8"  # pragma: allowlist secret

# The seed ref for the release-nudge caller, newer than `_DOWNGRADE_SEED_REF`
# for the same reason as `_REGISTRABILITY_SEED_REF`.
#
# Confirmed to contain `release-nudge.yml`. A ref that does not is worse than
# useless: the caller scaffolds fine and then fails at run time with "workflow
# was not found", so check a replacement resolves before changing it:
#   gh api repos/<org>/.github/contents/.github/workflows/release-nudge.yml?ref=<sha>
const _RELEASE_NUDGE_SEED_REF = "8c1e09003b9cf0d2eb3cbec7aa726855bb365ac5"  # pragma: allowlist secret

# The seed ref for the `pre-commit.yaml` caller's `runic-check.yml`, newer
# than `_DOWNGRADE_SEED_REF` for the same reason as `_REGISTRABILITY_SEED_REF`
# (`runic-check.yml` post-dates that shared seed, #114/Runic migration
# phase 1). The squash-merge SHA of EpiAware/.github#53.
const _RUNIC_CHECK_SEED_REF = "8c1e09003b9cf0d2eb3cbec7aa726855bb365ac5"  # pragma: allowlist secret

# The kit's own name + UUID, used to source it into the managed JET env for an
# adopting package. When the adopting package is the kit (it dogfoods itself),
# these are omitted so the env does not depend on / source itself twice.
const KIT_NAME = "EpiAwarePackageTools"
const KIT_UUID = "7aaea248-0d11-4a0d-a7dc-86da30abb951"

# The SPDX licence identifiers a package may select, each backed by a bundled
# `templates/LICENSE.<spdx>` file carrying `{{YEAR}}`/`{{HOLDER}}` placeholders.
const SUPPORTED_LICENSES = ("MIT", "Apache-2.0")
const DEFAULT_LICENSE = "MIT"

# Reject an unsupported `license` eagerly, naming the value and the valid set,
# rather than letting it propagate into a substitution that fails later with no
# reference back to the bad input (#310). The reference implementation
# `test_option_validation` fuzzes against; extend a new option-accepting entry
# point the same way.
function _validate_license(license::AbstractString)
    license in SUPPORTED_LICENSES || error(
        "unsupported license $(repr(license)); choose one of " *
            join(repr.(SUPPORTED_LICENSES), ", ")
    )
    return nothing
end

# Absolute path to the bundled `templates/` directory.
function _templates_dir()
    dir = pkgdir(EpiAwarePackageTools)
    dir === nothing && error("could not locate EpiAwarePackageTools package dir")
    return joinpath(dir, "templates")
end

# Read a scalar `key = "..."` from a Project.toml line; `nothing` if absent.
function _project_string(proj::AbstractString, key::AbstractString)
    isfile(proj) || return nothing
    pat = Regex("^\\s*" * key * "\\s*=\\s*\"([^\"]+)\"")
    for line in eachline(proj)
        m = match(pat, line)
        m === nothing || return m.captures[1]
    end
    return nothing
end

# Read the `authors = [...]` array from Project.toml as a vector of strings, or
# an empty vector if absent. Handles the common single-line array form
# `authors = ["A <a@x>", "B"]`.
function _project_authors(proj::AbstractString)
    isfile(proj) || return String[]
    txt = read(proj, String)
    m = match(r"authors\s*=\s*\[(.*?)\]"s, txt)
    m === nothing && return String[]
    inner = m.captures[1]
    inner === nothing && return String[]
    return [
        String(something(x.captures[1], ""))
            for x in eachmatch(r"\"([^\"]*)\"", inner)
    ]
end

# Strip a trailing `<email>` from an author entry, leaving the display name.
_author_name(a::AbstractString) = strip(replace(a, r"<[^>]*>" => ""))

"""
    _logo_initial(pkg)

The single glyph shown on the placeholder logo
(`templates/docs/src/assets/logo.svg`): the package's first letter,
uppercased, or `"?"` when the package name is unknown, which keeps
`scaffold_inputs` total.
"""
function _logo_initial(pkg::Union{Nothing, AbstractString})
    (pkg === nothing || isempty(pkg)) && return "?"
    return uppercase(string(first(pkg)))
end

# The template default for the tutorial subdir (see `templates/docs/
# docs_config.jl`), used when a target has no `docs_config.jl` yet.
const _DEFAULT_TUTORIALS_SUBDIR = "getting-started/tutorials"

"""
    _tutorials_subdir(target_dir)

Read `TUTORIALS_SUBDIR` from the package-owned `docs/docs_config.jl`: the
subdir (relative to `docs/src`) holding the Literate tutorial sources and
their rendered `.md` pages.

The managed `.gitignore` ignores those rendered pages, so it must track
whatever path the package configures. The const is written as a quoted string
or a `joinpath` of quoted segments; every quoted segment is joined with `/`.
Falls back to the template default when the config is absent or omits it.
"""
function _tutorials_subdir(target_dir::AbstractString)
    cfg = joinpath(target_dir, "docs", "docs_config.jl")
    isfile(cfg) || return _DEFAULT_TUTORIALS_SUBDIR
    m = match(r"const\s+TUTORIALS_SUBDIR\s*=\s*([^\n]+)", read(cfg, String))
    m === nothing && return _DEFAULT_TUTORIALS_SUBDIR
    rhs = String(something(m.captures[1]))
    segs = [
        String(something(x.captures[1], ""))
            for x in eachmatch(r"\"([^\"]*)\"", rhs)
    ]
    isempty(segs) && return _DEFAULT_TUTORIALS_SUBDIR
    return join(segs, "/")
end

"""
    _detect_reviewer(target_dir)

Recover a persisted reviewer handle from an already-scaffolded repo so a
resync (`update` with no `reviewer` kwarg) keeps it instead of reverting to
the org placeholder (#72).

CODEOWNERS is managed and the scheduled template-sync never re-passes
`reviewer`, so the handle is read back from the destination, as
`_preserve_reusable_refs` does for reusable-workflow refs. Returns the first
`@handle` on the active CODEOWNERS owner line (leading `@` stripped, an
`org/team` slug kept whole), or `nothing` when CODEOWNERS is absent or carries
only the commented placeholder.
"""
function _detect_reviewer(target_dir::AbstractString)
    co = joinpath(target_dir, ".github", "CODEOWNERS")
    isfile(co) || return nothing
    for line in eachline(co)
        s = strip(line)
        (isempty(s) || startswith(s, "#")) && continue
        m = match(r"@(\S+)", s)
        m === nothing && continue
        return String(something(m.captures[1]))
    end
    return nothing
end

"""
    _detect_docs_subdomain(target_dir)

Recover the docs-hosting choice from an already-scaffolded repo so a resync
(`update` with no `docs_subdomain` kwarg) keeps it instead of silently
reverting a subdomain-hosted package to project-pages (#123).

The managed `docs/make.jl` carries the resolved `deploy_url` literal: a quoted
host means the custom-subdomain path, a bare `nothing` means project-pages.
Returns the host string, `nothing` (explicit project-pages), or `:missing`
when `docs/make.jl` is absent or carries no `deploy_url`, so the caller falls
back to the scaffold default.

When `deploy_url = nothing` but the repo has a gh-pages `CNAME` (a Pages
custom domain set out of band) the two disagree: the site is served from the
CNAME root while the build uses the `/<Repo>.jl/` base, so every asset 404s
and the docs render unstyled. CI cannot see it — the deploy passes — so the
CNAME is consulted in that one case and its host recovered as the subdomain.
"""
function _detect_docs_subdomain(target_dir::AbstractString)
    mk = joinpath(target_dir, "docs", "make.jl")
    isfile(mk) || return :missing
    m = match(r"deploy_url\s*=\s*(nothing|\"([^\"]*)\")", read(mk, String))
    m === nothing && return :missing
    if m.captures[2] === nothing  # `deploy_url = nothing` (project-pages)
        # No CNAME is a genuine project-pages repo, left unchanged; a CNAME is
        # the base mismatch described above, healed on the next `update`.
        cname = _gh_pages_cname(target_dir)
        cname === nothing && return nothing
        @warn "docs/make.jl has `deploy_url = nothing` (project-pages) but " *
            "the gh-pages CNAME is `$cname`, a custom domain served at its " *
            "root. That mismatch deploys the docs with the wrong VitePress " *
            "base, so every CSS/JS asset 404s and the site renders " *
            "unstyled. Recovering the subdomain from the CNAME. To force " *
            "project-pages instead, pass `docs_subdomain = nothing` and " *
            "remove the repo's Pages custom domain."
        return cname
    end
    # Strip any scheme so the recovered value is always a bare host, matching
    # the CNAME path and what the README badges expect. The managed literal
    # carries `https://` (DocumenterVitepress needs it to build a root base),
    # but an older bare-host literal must read back to the same host so a
    # resync re-emits the scheme form rather than churning.
    host = replace(String(something(m.captures[2])), r"^https?://" => "")
    return isempty(host) ? nothing : host
end

# The custom domain committed to the gh-pages `CNAME`, or `nothing` if no
# gh-pages branch / CNAME is reachable from this checkout. Read-only and
# offline-tolerant: a checkout without a fetched gh-pages ref (a shallow
# single-branch CI clone, say) yields `nothing`, so a repo with no custom
# domain keeps the project-pages default — this never changes existing
# behaviour there. For the recovery to fire in the scheduled template-sync,
# that workflow must `git fetch origin gh-pages` first (see
# `template-sync.yaml`); a maintainer's local checkout usually already has it.
function _gh_pages_cname(target_dir::AbstractString)
    for ref in ("gh-pages", "origin/gh-pages")
        host = try
            strip(readchomp(Cmd(`git show $ref:CNAME`; dir = target_dir)))
        catch
            continue
        end
        isempty(host) || return String(host)
    end
    return nothing
end

"""
    _detect_doi(target_dir)

Recover a persisted Zenodo DOI and badge id from an already-scaffolded
repo so a resync (`update` with no `doi`/`zenodo_badge` kwargs) keeps an
adopter's DOI badge instead of stripping it (#161).

The README "License & DOI" badge cell is fully managed and re-rendered
on every sync, but `doi`/`zenodo_badge` default to `nothing` and the
scheduled template-sync never re-passes them, so the values must be read
back from the destination — exactly as `_detect_reviewer` recovers the
code-owner handle. Reads the managed DOI badge the kit renders
(`[![DOI](https://zenodo.org/badge/<id>.svg)](https://doi.org/<doi>)`)
back from the existing README and returns the `(doi, zenodo_badge)`
pair, or `(nothing, nothing)` when the README is absent or carries no
DOI badge (so a never-configured repo stays unconfigured).
"""
function _detect_doi(target_dir::AbstractString)
    readme = joinpath(target_dir, "README.md")
    isfile(readme) || return (nothing, nothing)
    m = match(
        r"\[!\[DOI\]\(https://zenodo\.org/badge/([^)]+?)\.svg\)\]\(https://doi\.org/([^)]+?)\)",
        read(readme, String)
    )
    m === nothing && return (nothing, nothing)
    return (String(something(m.captures[2])), String(something(m.captures[1])))
end

"""
    _detect_license(target_dir)

Recover an already-scaffolded repo's licence so a resync (`update`
with no `license` kwarg) keeps it instead of resetting the README badge to
`$(repr(DEFAULT_LICENSE))` (#235).

The README badge cell is managed, but `license` defaults to
`$(repr(DEFAULT_LICENSE))` and the scheduled template-sync never re-passes it,
so a non-MIT adopter's badge was flipped to MIT on every sync — the same
failure mode `_detect_doi` fixed for the DOI badge (#161). The value is read
back from the destination: first the managed License badge, then the
`Project.toml` `license` field. Returns the SPDX id, or `nothing` when neither
carries one. Only a `SUPPORTED_LICENSES` id is recovered; an explicit
`license` keyword still wins.
"""
function _detect_license(target_dir::AbstractString)
    readme = joinpath(target_dir, "README.md")
    if isfile(readme)
        m = match(
            r"\[!\[License: ([^\]]+)\]\(https://img\.shields\.io/badge/",
            read(readme, String)
        )
        if m !== nothing
            spdx = String(something(m.captures[1]))
            spdx in SUPPORTED_LICENSES && return spdx
        end
    end
    proj = _project_string(joinpath(target_dir, "Project.toml"), "license")
    proj !== nothing && proj in SUPPORTED_LICENSES && return proj
    return nothing
end

"""
    scaffold_inputs(target_dir; package = nothing, authors = nothing,
        holder = nothing, org = $(repr(DEFAULT_ORG)), repo = nothing,
        reviewer = nothing, year = <current year>,
        license = nothing) -> NamedTuple

Resolve the placeholder substitution values for [`scaffold`](@ref) /
[`update`](@ref).

Every value defaults from the target `Project.toml` (or a sensible org default)
and is overridable by keyword, so no person, org, or repository name is baked
into a template:

  - `package` — the package name (`{{PACKAGE}}`); default the `Project.toml`
    `name`. The package UUID (`{{UUID}}`) is read from `Project.toml` `uuid`.
  - `authors` — `{{AUTHORS}}`; default the joined `Project.toml` `authors`.
  - `holder` — copyright holder (`{{HOLDER}}`); default `authors`.
  - `org` — GitHub org (`{{ORG}}`); default `$(repr(DEFAULT_ORG))`.
  - `repo` — `owner/name` slug (`{{REPO}}`); default `"{org}/{package}.jl"`.
  - `reviewer` — the GitHub handle (`{{REVIEWER}}`) that drives every place a
    real reviewer/code-owner is needed: the `.github/CODEOWNERS` rule
    (`* @{{REVIEWER}}`), the Dependabot `reviewers`, the version-bump assignee,
    and the Claude bot's actor gate. A username or `org/team` slug — GitHub
    cannot assign a bare org. When omitted (`nothing`), no owner is written
    (CODEOWNERS ships a commented placeholder, Dependabot gets no `reviewers`)
    so a bare org is never hardcoded.
  - `year` — copyright year (`{{YEAR}}`); default the current year.
  - `license` — the SPDX licence identifier (one of
    `$(join(SUPPORTED_LICENSES, ", "))`) selecting which `LICENSE` text
    [`scaffold`](@ref) writes and which README badge is rendered. Default
    `nothing`, in which case the licence already committed to the repo is
    recovered and kept (`#235`), falling back to `$(repr(DEFAULT_LICENSE))`.
    The `LICENSE` text itself is written once and never overwritten by
    [`update`](@ref).
  - `doi` / `zenodo_badge` — an optional Zenodo DOI and badge id; when both are
    given a DOI badge is added to the README "License & DOI" cell. Both default
    to `nothing`, in which case any DOI badge already committed to the README is
    recovered and preserved (`#161`). Passing either supplies or overrides it.
  - `docs_timeout` — an optional docs-build job timeout in minutes for the
    managed `document.yaml` caller. Default `nothing`, which renders no `with:`
    block so the reusable's own default (45 min) applies. A package-owned
    `with:` block hand-added to `document.yaml` survives a resync (see
    `_preserve_caller_with_inputs`).

Returns a `NamedTuple` of `placeholder => value` pairs (plus `LICENSE`, the
resolved SPDX identifier).
"""
function scaffold_inputs(
        target_dir::AbstractString;
        package::Union{Nothing, AbstractString} = nothing,
        authors::Union{Nothing, AbstractString} = nothing,
        holder::Union{Nothing, AbstractString} = nothing,
        org::AbstractString = DEFAULT_ORG,
        repo::Union{Nothing, AbstractString} = nothing,
        reviewer::Union{Nothing, AbstractString} = nothing,
        year::Union{Nothing, Integer} = nothing,
        license::Union{Nothing, AbstractString} = nothing,
        docs_subdomain::Union{Nothing, Bool, AbstractString} = nothing,
        doi::Union{Nothing, AbstractString} = nothing,
        zenodo_badge::Union{Nothing, AbstractString} = nothing,
        docs_timeout::Union{Nothing, Integer} = nothing
    )
    # Recover the committed licence so a bare sync keeps a non-MIT adopter's
    # badge instead of resetting it to the default (#235).
    license = license === nothing ?
        something(_detect_license(target_dir), DEFAULT_LICENSE) : license
    _validate_license(license)
    proj = joinpath(target_dir, "Project.toml")
    pkg = package === nothing ? _project_string(proj, "name") : package
    auth_vec = _project_authors(proj)
    auth = authors === nothing ?
        (isempty(auth_vec) ? nothing : join(_author_name.(auth_vec), ", ")) :
        authors
    hold = holder === nothing ? auth : holder
    rp = repo === nothing ?
        (pkg === nothing ? nothing : string(org, "/", pkg, ".jl")) : repo
    # The `reviewer` handle drives the CODEOWNERS line, the Dependabot
    # `reviewers`, the version bump's assignee and the Claude bot's actor gate.
    # It must be a username or `org/team` slug: GitHub cannot assign a bare
    # org, so with no handle those owners are left empty rather than producing
    # PRs that error with "can't assign <org> as a reviewer". With no
    # `reviewer` passed, any handle persisted in the destination is recovered
    # so a scheduled resync stays idempotent (#72); `reviewer = ""` still omits.
    resolved_reviewer = reviewer === nothing ? _detect_reviewer(target_dir) :
        reviewer
    has_reviewer = resolved_reviewer !== nothing && !isempty(resolved_reviewer)
    rev = resolved_reviewer === nothing ? org : resolved_reviewer
    # Active when a handle is given, else a commented placeholder.
    codeowners_line = has_reviewer ? string("* @", resolved_reviewer) :
        string(
            "# * @", org, "/maintainers  # set the `reviewer` ",
            "input to a GitHub handle to enable"
        )
    # The template carries the indent before the following `commit-message:`
    # key, so this fragment supplies only the reviewers lines themselves.
    dependabot_reviewers = has_reviewer ?
        string(
            "    reviewers:\n      - \"", resolved_reviewer,
            "\"\n"
        ) : ""
    # A user/bot handle or empty, never the bare org: assigning an org fails
    # the update-existing-PR path with `replaceActorsForAssignable` (#122). So
    # not `{{REVIEWER}}`, which is the org placeholder when none was given.
    assignee_default = has_reviewer ? resolved_reviewer : ""
    yr = year === nothing ? Dates.year(Dates.now()) : year
    uuid = _project_string(proj, "uuid")
    # A fresh UUID for the seeded ADFixtures registry skeleton (a new path
    # package). Generated once per call; the author keeps it thereafter.
    adfix_uuid = string(UUIDs.uuid4())
    # How the docs site is hosted. The default is a project-pages deploy
    # (`deploy_url = nothing`), so DocumenterVitepress derives the base from
    # the repo name and no DNS is wired. A custom subdomain (`true` for
    # `<pkg>.epiaware.org`, or a bespoke host string) needs a DNS record and
    # the repo's Pages custom domain. `DOCS_DEPLOY_URL` is the literal
    # substituted into `docs/make.jl`; `DOCS_URL` is the bare host for badges.
    #
    # With no explicit value the committed choice is recovered so a resync
    # never reverts a subdomain-hosted package and serves a CSS-less site
    # (#123). Only a never-scaffolded target falls back to the default: the kit
    # dogfoods its own subdomain, every other package gets project-pages.
    ds = if docs_subdomain !== nothing
        docs_subdomain
    else
        detected = _detect_docs_subdomain(target_dir)
        detected === :missing ? (pkg == KIT_NAME ? true : nothing) : detected
    end
    docs_sub = _resolve_docs_subdomain(ds, pkg)
    docs_deploy_url = _docs_deploy_url(docs_sub)
    docs_url = _docs_url(rp, docs_sub)
    # Recover any DOI persisted in the README badge block so a scheduled
    # resync keeps it instead of stripping it (#161).
    resolved_doi, resolved_zenodo = if doi === nothing && zenodo_badge === nothing
        _detect_doi(target_dir)
    else
        (doi, zenodo_badge)
    end
    # The managed JET env depends on the kit for its report filter. When the
    # adopting package *is* the kit, `{{PACKAGE}}`'s own dep/source already
    # cover it and a second one would make a duplicate/invalid env.
    is_kit = pkg == KIT_NAME
    kit_dep = is_kit ? "" : string(KIT_NAME, " = \"", KIT_UUID, "\"\n")
    kit_source = is_kit ? "" :
        string(
            "\n# Until EpiAwarePackageTools is registered, it is pinned by git so\n",
            "# the env resolves out of the box. Switch to a local path to\n",
            "# develop the kit alongside this package.\n",
            KIT_NAME, " = {url = \"https://github.com/", org, "/",
            KIT_NAME, ".jl\", rev = \"main\"}"
        )
    # How the scheduled template-sync loads the kit before `update(".")`: the
    # kit syncs from its own checked-out project, every other package pulls the
    # kit's newest `main` into a throwaway env. Here rather than in the
    # template because it shares the `is_kit` split above.
    sync_install = is_kit ?
        "Pkg.activate(\".\"); Pkg.instantiate()" :
        string(
            "Pkg.activate(; temp = true); Pkg.add(url = ",
            "\"https://github.com/", org, "/", KIT_NAME,
            ".jl\", rev = \"main\")"
        )
    # The managed `.gitignore` tracks the package's tutorial subdir, and the
    # ad=true `codecov.yml` gate holds the status notification until all flag
    # uploads (unit + one per AD backend) are in.
    tutorials_subdir = _tutorials_subdir(target_dir)
    ad_build_count = string(length(_AD_BACKENDS) + 1)
    return (
        PACKAGE = pkg, UUID = uuid, ADFIXTURES_UUID = adfix_uuid,
        AUTHORS = auth, HOLDER = hold, ORG = org, REPO = rp,
        REVIEWER = rev, YEAR = string(yr), LICENSE = license,
        DOCS_DEPLOY_URL = docs_deploy_url, DOCS_URL = docs_url,
        DOCS_TIMEOUT_WITH = _docs_timeout_with(docs_timeout),
        DOI = resolved_doi, ZENODO_BADGE = resolved_zenodo,
        TUTORIALS_SUBDIR = tutorials_subdir, AD_BUILD_COUNT = ad_build_count,
        AD_CODECOV_FLAGS = _ad_codecov_flags(),
        AD_BACKENDS_JSON = _ad_backends_json(),
        AD_COV_TABLE = _ad_cov_table(rp),
        AD_BACKEND_PACKAGES = _ad_backend_packages(),
        AD_BACKEND_ENTRIES = _ad_backend_entries(),
        AD_SCENARIO_TESTITEMS = _ad_scenario_testitems(),
        CODEOWNERS_LINE = codeowners_line,
        DEPENDABOT_REVIEWERS = dependabot_reviewers,
        ASSIGNEE_DEFAULT = assignee_default,
        KIT_DEP_LINE = kit_dep,
        KIT_SOURCE_LINE = kit_source, SYNC_INSTALL = sync_install,
        RUNIC_VERSION = _RUNIC_VERSION,
        RUNIC_PRE_COMMIT_REV = _RUNIC_PRE_COMMIT_REV,
        # The `tests.yml` caller's Julia matrix, dropping the reusable's `lts`
        # leg: the managed standard needs 1.11 (#246).
        JULIA_TEST_VERSIONS = _JULIA_TEST_VERSIONS,
        LOGO_INITIAL = _logo_initial(pkg),
    )
end

# Apply placeholder substitution to `content`. A template may use any subset of
# the placeholders; each used placeholder must resolve to a non-nothing value.
function _substitute(
        content::AbstractString, inputs::NamedTuple,
        from::AbstractString
    )
    for (key, val) in pairs(inputs)
        token = "{{" * string(key) * "}}"
        occursin(token, content) || continue
        val === nothing && error(
            "template $from uses $token but no value resolved; pass it to " *
                "scaffold/update or set the target Project.toml"
        )
        content = replace(content, token => val)
    end
    return content
end

# A reusable-workflow `uses:` line in a managed CI caller, capturing the prefix
# up to and including the `@`, the workflow filename, and the pinned ref, which
# Dependabot bumps in each adopting repo. See `_preserve_reusable_refs`.
const _REUSABLE_USES = r"(uses:\s*\S+/\.github/\.github/workflows/([^@\s]+)@)(\S+)"

"""
    _preserve_reusable_refs(content, dest)

Keep the destination's existing reusable-workflow refs when
re-emitting a managed CI caller.

Dependabot owns the EpiAware/.github reusable SHAs in every adopting repo, so
a hard-pinned template would report drift every time Dependabot moved the live
pin. When the destination already pins a ref for the same reusable, that ref
wins and only the rest of the caller body is re-applied; on first adoption the
template's seed ref is used.
"""
function _preserve_reusable_refs(content::AbstractString, dest::AbstractString)
    occursin(_REUSABLE_USES, content) || return content
    isfile(dest) || return content
    existing = Dict{String, String}()
    for line in eachline(dest)
        m = match(_REUSABLE_USES, line)
        m === nothing && continue
        existing[String(something(m.captures[2]))] = String(something(m.captures[3]))
    end
    isempty(existing) && return content
    return replace(
        content,
        _REUSABLE_USES => function (s)
            m = match(_REUSABLE_USES, s)
            m === nothing && return String(s)
            prefix = String(something(m.captures[1]))
            workflow = String(something(m.captures[2]))
            seed = String(something(m.captures[3]))
            return prefix * get(existing, workflow, seed)
        end
    )
end

# A third-party action `uses:` pin in a managed workflow (e.g.
# `actions/checkout@v7`, `julia-actions/cache@v3`), capturing the prefix up to
# the action path, the action path, and the pinned ref. Local `./…` actions
# carry no `@ref` and never match; the org reusable callers do match this shape
# but are skipped in favour of `_preserve_reusable_refs`.
const _ACTION_USES = r"(uses:[ \t]*)([A-Za-z0-9][A-Za-z0-9._/-]*)@(\S+)"

"""
    _preserve_action_pins(content, dest)

Keep the destination's existing third-party action pins when re-emitting a
managed workflow.

Dependabot owns the github-actions pins in every adopting repo, so a template
that hard-pins `actions/checkout@v7` would revert a Dependabot bump on every
resync — and when template-sync re-applies on a branch it did not open, that
revert rides silently into the merge (#215). The destination's pin wins and
only the rest of the workflow is re-applied. Mirrors
`_preserve_reusable_refs`, which owns the org reusable-caller lines.
"""
function _preserve_action_pins(content::AbstractString, dest::AbstractString)
    occursin(_ACTION_USES, content) || return content
    isfile(dest) || return content
    existing = Dict{String, String}()
    for line in eachline(dest)
        # Reusable-workflow callers are `_preserve_reusable_refs`' job.
        occursin(_REUSABLE_USES, line) && continue
        m = match(_ACTION_USES, line)
        m === nothing && continue
        existing[String(something(m.captures[2]))] = String(something(m.captures[3]))
    end
    isempty(existing) && return content
    return replace(
        content,
        _ACTION_USES => function (s)
            occursin(_REUSABLE_USES, s) && return String(s)
            m = match(_ACTION_USES, s)
            m === nothing && return String(s)
            prefix = String(something(m.captures[1]))
            action = String(something(m.captures[2]))
            seed = String(something(m.captures[3]))
            return prefix * action * "@" * get(existing, action, seed)
        end
    )
end

# A managed CI caller job's reusable `uses:` line, any interspersed
# blank/comment lines, its optional `with:` block, and the following `secrets:`
# key. Group 3 is the preserved region; group 4 (the `with:` indent) is used
# only via the `\4` backreference, requiring input lines to be indented deeper
# than `with:` so the match does not swallow the sibling `secrets:` line. The
# lazy leading comment/blank run lets a documented override survive when a
# rationale comment sits between `uses:` and `with:` (#117). See
# `_preserve_caller_with_inputs`.
const _CALLER_JOB = r"(uses:[ \t]*\S+/\.github/\.github/workflows/([^@\s]+)@\S+\r?\n)((?:[ \t]*(?:#[^\r\n]*)?\r?\n)*?(?:([ \t]+)with:\r?\n(?:\4[ \t]+\S.*\r?\n?)*)?)([ \t]*secrets:)"

# A `uses:` line repointed at a repo-local reusable *workflow* rather than the
# org's shared `.github` reusable (#325). The `.github/workflows/` segment is
# load-bearing: several bundled templates call a repo-local *composite action*
# (`uses: ./.github/actions/<name>`) with its own `with:` block, a routine
# shape that must not be mistaken for the caller-job override this warns about.
#
# Matches `uses:` directly rather than scanning forward from a job-name line: a
# free-form line-skip prefix caused catastrophic backtracking on multi-job
# files, because false candidate starts (e.g. `concurrency:`'s nested keys)
# sent the lazy skip hunting to end-of-file on every attempt.
# `_warn_local_caller_override!` recovers the job name by a plain backward
# scan instead. Group 3 is the `with:` indent, used via `\3` exactly as in
# `_CALLER_JOB`.
const _LOCAL_CALLER_JOB = r"(uses:[ \t]*\.{1,2}/\.github/workflows/[^@\s]+\.ya?ml\r?\n)((?:[ \t]*(?:#[^\r\n]*)?\r?\n)*?(?:([ \t]+)with:\r?\n(?:\3[ \t]+\S.*\r?\n?)*)?)"

# A non-empty `with:` block, telling a local caller that carries package-owned
# inputs (about to be lost, #325) from one a resync would drop nothing from.
const _LOCAL_CALLER_HAS_INPUTS = r"with:\r?\n[ \t]+\S"

# A job's name: a bare `^  <name>:` line. Used to recover which job a
# `_LOCAL_CALLER_JOB` match belongs to by searching backward from the match.
const _JOB_NAME_LINE = r"(?m)^  ([\w-]+):[ \t]*\r?$"

# Keeping a package-owned `with:` block across `update()` (#73). A package can
# override a reusable's defaults by adding a `with:` block to a managed caller;
# the template carries none for those jobs, so re-emitting it verbatim would
# drop the override. As in `_preserve_reusable_refs` the destination wins, and
# only the rest of the caller is re-applied.
#
# Where the template does render its own `with:` block (e.g. `ad.yaml`'s
# `backends:` passthrough from `_AD_BACKENDS`) those are managed values, so the
# blocks are merged per key (#183): the template wins on a key it renders, and
# a key only the package carries is kept.

# The lines of a caller's preserved region, split into leading blank/comment
# lines and the `with:` inputs. `indent` is the `with:` line's indent, or
# `nothing` when there is no block. Each input is `key => lines`, keeping
# deeper continuation lines with their key so a block/list value survives. A
# comment/blank line is buffered and attached to the key it *precedes*, by the
# convention that a rationale comment documents the key below it; `trailing`
# catches any left dangling at the end. Attaching to the preceding key instead
# dropped the comment when that key was seeded and duplicated it onto the next
# template key (#212).
function _parse_with_block(chunk::AbstractString)
    head = String[]
    inputs = Pair{String, Vector{String}}[]
    indent = nothing
    pending = String[]
    lines = split(chunk, '\n')
    endswith(chunk, "\n") && !isempty(lines) && pop!(lines)
    for line in lines
        if indent === nothing
            m = match(r"^([ \t]+)with:[ \t]*\r?$", line)
            if m === nothing
                push!(head, String(line))
            else
                indent = String(something(m.captures[1]))
            end
            continue
        end
        key = match(r"^[ \t]+([A-Za-z0-9_.-]+):", line)
        if key !== nothing
            name = String(something(key.captures[1]))
            push!(inputs, name => vcat(pending, String[String(line)]))
            empty!(pending)
        elseif occursin(r"^[ \t]*#", line) || isempty(strip(line))
            push!(pending, String(line))  # comment/blank: attach to next key
        elseif !isempty(inputs)
            push!(last(inputs).second, String(line))  # value continuation
        end
    end
    return (head = head, indent = indent, inputs = inputs, trailing = pending)
end

# Render a caller's preserved region back from its parts. `trailing` has no
# default: a default would generate an unreachable, uncovered 3-arg method.
function _render_with_block(
        head::Vector{String}, indent::AbstractString,
        inputs::Vector{Pair{String, Vector{String}}},
        trailing::Vector{String}
    )
    lines = copy(head)
    push!(lines, indent * "with:")
    for (_, value) in inputs
        append!(lines, value)
    end
    append!(lines, trailing)
    return join(lines, "\n") * "\n"
end

# Inputs the template *seeds* rather than manages: the kit supplies a default
# and a destination naming the key keeps its own value (#246). Every other
# template-rendered key is managed and wins on merge (#183). The Julia matrix
# differs in kind: which versions to test is a package's call (#73/#117), and
# the kit's stake is only that the floor is not below 1.11. So it seeds a
# floor-respecting default and `_julia_versions_below_floor` warns when an
# override reaches back below the floor.
#
# Scoped to the reusable that renders the key, not global by name:
# `codecoverage.yaml`'s caller renders a `julia_version` of its own which IS
# managed, and a bare-name set would un-manage that too.
const _WITH_SEED_DEFAULT_KEYS = Dict(
    "tests.yml" => Set(["julia_versions"]),
    "downgrade.yml" => Set(["julia_version"])
)

function _seed_default_keys(workflow::AbstractString)
    return get(_WITH_SEED_DEFAULT_KEYS, workflow, Set{String}())
end

# Merge the template's `with:` block (`seed`) with the destination's, keeping
# every key the template manages, letting the destination win on a seed-default
# key it names (scoped to `workflow`, the reusable being called), and appending
# the keys only the package carries.
function _merge_with_blocks(
        seed::AbstractString, existing::AbstractString,
        workflow::AbstractString = ""
    )
    s = _parse_with_block(seed)
    e = _parse_with_block(existing)
    e.indent === nothing && return seed
    # The template renders no `with:` for this job, so the whole block is a
    # package override: the destination's region stands, rationale comments
    # included (#73, #117).
    s.indent === nothing && return existing
    seeded = Set(first(p) for p in s.inputs)
    named = Dict(first(p) => p for p in e.inputs)
    # A seed-default key the destination names is the package's, comments and
    # all; every other seeded key is the kit's.
    defaults = _seed_default_keys(workflow)
    overridden = Set(k for k in keys(named) if k in defaults)
    merged = Pair{String, Vector{String}}[]
    for p in s.inputs
        key = first(p)
        push!(merged, key in overridden ? named[key] : p)
    end
    extra = [p for p in e.inputs if !(first(p) in seeded)]
    # A genuinely dangling comment in the destination (no key follows it) is
    # package-owned unmatched content, exactly like an extra key — keep it
    # alongside the seed's own trailing lines (if any) rather than dropping it.
    trailing = isempty(e.trailing) ? s.trailing : vcat(s.trailing, e.trailing)
    # The destination's leading comments are its rationale for the block
    # (#117). Only the lines the template does not emit itself are kept:
    # appending the head wholesale would re-append the template's own comments
    # on every sync, growing the file without bound.
    extra_head = [l for l in e.head if !(l in s.head)]
    head = vcat(s.head, extra_head)
    isempty(extra) && isempty(e.trailing) && isempty(overridden) &&
        isempty(extra_head) && return seed
    return _render_with_block(head, s.indent, vcat(merged, extra), trailing)
end

# The `downstreams:` input of the managed `downstream.yaml` caller: its indent
# and key (group 1) and its single-line value (group 2). Only that one template
# renders the key, so the `occursin` guard in `_preserve_downstreams` scopes the
# pass to it.
const _DOWNSTREAMS_INPUT = r"(?m)^([ \t]+downstreams:[ \t]*)(\S.*?)[ \t]*$"

"""
    _preserve_downstreams(content, dest)

Keep the destination's reverse-dependency list when re-emitting the managed
`downstream.yaml`.

Which packages depend on this one is a fact about the adopting package, not a
standard the kit sets, but re-applying the template's `downstreams: '[]'` seed
reset an adopter's list on every sync (#234). So the committed value wins, as
in `_preserve_reusable_refs`. Preferable to marking the whole file
package-owned, which would stop it tracking the standard for one line.

A bespoke pass rather than a `_preserve_caller_with_inputs` case: that keys
off the `uses:`→`with:`→`secrets:` shape, which this caller does not have (it
puts `secrets:` first), and the template renders the key itself so
`_merge_with_blocks` would let the seed win (#183).
"""
function _preserve_downstreams(content::AbstractString, dest::AbstractString)
    occursin(_DOWNSTREAMS_INPUT, content) || return content
    isfile(dest) || return content
    m = match(_DOWNSTREAMS_INPUT, read(dest, String))
    m === nothing && return content
    value = String(something(m.captures[2]))
    return replace(
        content,
        _DOWNSTREAMS_INPUT => function (s)
            mm = match(_DOWNSTREAMS_INPUT, s)
            mm === nothing && return String(s)
            return String(something(mm.captures[1])) * value
        end
    )
end

function _preserve_caller_with_inputs(
        content::AbstractString,
        dest::AbstractString
    )
    occursin(_CALLER_JOB, content) || return content
    isfile(dest) || return content
    existing = Dict{String, String}()
    for m in eachmatch(_CALLER_JOB, read(dest, String))
        block = String(something(m.captures[3], ""))
        isempty(block) && continue
        existing[String(something(m.captures[2]))] = block
    end
    isempty(existing) && return content
    return replace(
        content,
        _CALLER_JOB => function (s)
            m = match(_CALLER_JOB, s)
            m === nothing && return String(s)
            prefix = String(something(m.captures[1]))
            workflow = String(something(m.captures[2]))
            seed = String(something(m.captures[3], ""))
            suffix = String(something(m.captures[5]))
            kept = get(existing, workflow, "")
            replacement = isempty(kept) ? seed :
                _merge_with_blocks(seed, kept, workflow)
            return prefix * replacement * suffix
        end
    )
end

"""
    _warn_local_caller_override!(warnings, to, dest)

Warn when the committed `to` (the managed workflow at relative path `dest`)
carries a caller job repointed at a repo-local reusable workflow with its own
`with:` inputs — a shape `_preserve_caller_with_inputs` cannot see, so the
resync silently drops those inputs and reverts the job to the shared reusable
(#325).

`_CALLER_JOB` matches only `uses: <org>/.github/.github/workflows/<file>@<ref>`.
A package needing an input the shared reusable does not expose points the
caller at a local copy instead, which never matches, so `_emit` re-renders the
job from the template and the inputs are gone with nothing to say so.

This does not change what is emitted; it only makes the loss visible in
`warnings` (and via `@warn`), one message per matching job, so it surfaces in
the sync PR rather than as an unrelated-looking red check days later.
"""
function _warn_local_caller_override!(
        warnings::Vector{String},
        to::AbstractString, dest::AbstractString
    )
    isfile(to) || return nothing
    text = read(to, String)
    for m in eachmatch(_LOCAL_CALLER_JOB, text)
        block = String(something(m.captures[2], ""))
        occursin(_LOCAL_CALLER_HAS_INPUTS, block) || continue
        # The nearest `^  <name>:` line before the match: a plain backward
        # scan, not a free-form in-regex skip (see `_LOCAL_CALLER_JOB`).
        prefix = SubString(text, 1, m.offset - 1)
        job = nothing
        for jm in eachmatch(_JOB_NAME_LINE, prefix)
            job = String(something(jm.captures[1]))
        end
        job === nothing && continue
        msg = string(
            dest, " job \"", job, "\" has `uses:` pointing at a ",
            "repo-local reusable workflow with its own `with:` inputs. ",
            "`_CALLER_JOB` only keys the org's shared reusable, so this ",
            "job cannot be preserved — the next resync will silently drop ",
            "those inputs and revert it to the shared reusable (#325)."
        )
        push!(warnings, msg)
        @warn msg
    end
    return nothing
end

# Make an emitted file writable by its owner (#187). A `Pkg.add`ed kit ships
# its templates in the read-only depot, so `cp` hands the destination mode 444
# and the adopting repo cannot edit its own managed files.
function _make_writable(path::AbstractString)
    isfile(path) || return nothing
    mode = filemode(path)
    mode & 0o200 == 0 && chmod(path, mode | 0o200)
    return nothing
end

# The template's text as the kit would render it: placeholders substituted
# when the template takes substitution, verbatim otherwise. `_emit`'s
# `_preserve_*` passes are not applied — they merge the destination's own pins
# back in, so they say nothing about what the template itself contains, which
# is what the callers here ask about.
function _render(from::AbstractString, substitute::Bool, inputs::NamedTuple)
    text = read(from, String)
    return substitute ? _substitute(text, inputs, from) : text
end

# Copy one template to `to`, substituting placeholders when requested. Managed
# workflows additionally keep the destination's reusable-workflow refs, action
# pins, package-owned `with:` inputs and reverse-dependency list (see the
# `_preserve_*` passes), so neither a Dependabot bump nor a deliberate caller
# override is reverted.
function _emit(
        from::AbstractString, to::AbstractString, substitute::Bool,
        inputs::NamedTuple
    )
    mkpath(dirname(to))
    # A previous sync from a read-only depot may have left `to` unwritable, so
    # restore the write bit before rewriting it (#187).
    _make_writable(to)
    if substitute
        content = _substitute(read(from, String), inputs, from)
        content = _preserve_reusable_refs(content, to)
        content = _preserve_action_pins(content, to)
        content = _preserve_caller_with_inputs(content, to)
        content = _preserve_downstreams(content, to)
        write(to, content)
    else
        cp(from, to; force = true)
    end
    _make_writable(to)
    return nothing
end

# --- package-owned LICENSE (write-once) -----------------------------------
#
# The `license` input selects a bundled `templates/LICENSE.<spdx>`, written
# once with `{{YEAR}}`/`{{HOLDER}}` filled. `update` never touches it, so a
# package that deliberately switches licence is not reverted on a sync.

# Write the selected LICENSE to `target_dir` if absent (write-once). `inputs`
# supplies `LICENSE` (the SPDX id) plus the `{{YEAR}}`/`{{HOLDER}}` values.
# Returns `:created`, `:preserved` (already present), or `:skipped`.
function _apply_license(target_dir::AbstractString, inputs::NamedTuple)
    dest = joinpath(target_dir, "LICENSE")
    isfile(dest) && return :preserved
    spdx::String = String(inputs.LICENSE)::String
    from = joinpath(_templates_dir(), string("LICENSE.", spdx))
    isfile(from) || error("missing bundled LICENSE template for $spdx at $from")
    write(dest, _substitute(read(from, String), inputs, from))
    return :created
end

# --- managed README badge block -------------------------------------------
#
# The README body is package-owned, but the standard badge set is managed: it
# lives between the markers below and is (re)rendered from the placeholder
# inputs on every scaffold/update, so an adopting package gets and keeps the
# standard badges automatically. Nothing outside the markers is touched.

const BADGES_START = "<!-- badges:start -->"
const BADGES_END = "<!-- badges:end -->"

# The single source of truth for the kit's per-backend AD infra: the README
# coverage-flag badge table, the `codecov.yml` `ad-*` flags and
# `AD_BUILD_COUNT` gate, and the `backends` input the `ad.yaml` caller passes
# to the org reusable, so the actual CI matrix is driven from here too. Add,
# remove or reorder a backend and all of those regenerate on the next sync.
#
#   - `alt`: the `cov <alt>` badge alt text.
#   - `header`: the coverage-flag table column heading, and the AD job's
#     display name in the reusable workflow.
#   - `slug`: the `ad-*` codecov flag / reusable-workflow `flag`.
#   - `tag`: the `@testitem` tag `test/ad/runtests.jl` filters on, and the
#     reusable's `tag` selecting which backend to test.
#   - `pkg`: the package the backend loads from (Enzyme forward/reverse share
#     one), used to derive `test/ad/setup.jl`'s `using` line.
const _AD_BACKENDS = [
    (
        alt = "ForwardDiff", header = "ForwardDiff",
        slug = "ad-forwarddiff", tag = "forwarddiff", pkg = "ForwardDiff",
    ),
    (
        alt = "ReverseDiff", header = "ReverseDiff (tape)",
        slug = "ad-reversediff", tag = "reversediff", pkg = "ReverseDiff",
    ),
    (
        alt = "ReverseDiff compiled", header = "ReverseDiff (compiled)",
        slug = "ad-reversediff-compiled", tag = "reversediff_compiled",
        pkg = "ReverseDiff",
    ),
    (
        alt = "Enzyme forward", header = "Enzyme forward",
        slug = "ad-enzyme-forward", tag = "enzyme_forward", pkg = "Enzyme",
    ),
    (
        alt = "Enzyme reverse", header = "Enzyme reverse",
        slug = "ad-enzyme-reverse", tag = "enzyme_reverse", pkg = "Enzyme",
    ),
    (
        alt = "Mooncake reverse", header = "Mooncake reverse",
        slug = "ad-mooncake-reverse", tag = "mooncake_reverse",
        pkg = "Mooncake",
    ),
    (
        alt = "Mooncake forward", header = "Mooncake forward",
        slug = "ad-mooncake-forward", tag = "mooncake_forward",
        pkg = "Mooncake",
    ),
]

# The managed `codecov.yml` `flags:` entries for every AD backend, generated
# from `_AD_BACKENDS` so the list can never drift from `AD_BUILD_COUNT`.
#
# `src` only, except for the Enzyme backends: most AD jobs run without the
# package's weakdeps loaded, so no extension file executes under an `ad-*`
# flag. Listing `ext` there made every AD upload report the extension at 0%,
# redding codecov/patch even when the unit suite covered it fully (#180). But
# an Enzyme rule-file extension only ever loads under the two Enzyme AD jobs,
# so those two flags claim `ext` too, or that file is stuck at 0% forever.
function _ad_codecov_flags()
    blocks = map(_AD_BACKENDS) do b
        paths = b.pkg == "Enzyme" ? "      - src\n      - ext\n" :
            "      - src\n"
        string(
            "  ", b.slug, ":\n", "    paths:\n", paths,
            "    carryforward: true"
        )
    end
    return join(blocks, "\n")
end

# The `backends` JSON array the `ad.yaml` caller passes to the org reusable,
# pinning the CI matrix to the same source as the badges and codecov flags.
# Emitted on one line and single-quoted by the template, so no block scalar
# can be mis-indented by the substitution.
function _ad_backends_json()
    entries = [
        string(
                "{\"name\":\"", b.header, "\",\"tag\":\"", b.tag, "\",\"flag\":\"",
                b.slug, "\"}"
            ) for b in _AD_BACKENDS
    ]
    return "[" * join(entries, ",") * "]"
end

# The packages the scaffolded `test/ad/setup.jl` `using` line loads, derived
# from `_AD_BACKENDS` (deduplicated, first-seen order) so `setup.jl` can never
# over- or under-load relative to it.
function _ad_backend_packages()
    pkgs = String[]
    for b in _AD_BACKENDS
        b.pkg in pkgs || push!(pkgs, b.pkg)
    end
    return join(pkgs, ", ")
end

# The `ADTypes` constructor call for each `_AD_BACKENDS` tag, matching what
# adopters hand-write in their own `ADFixtures.backends()`.
const _AD_BACKEND_CTORS = Dict(
    "forwarddiff" => "AutoForwardDiff()",
    "reversediff" => "AutoReverseDiff(compile = false)",
    "reversediff_compiled" => "AutoReverseDiff(compile = true)",
    "enzyme_forward" => "AutoEnzyme(mode = Enzyme.set_runtime_activity(Enzyme.Forward))",
    "enzyme_reverse" => "AutoEnzyme(mode = Enzyme.set_runtime_activity(Enzyme.Reverse))",
    "mooncake_reverse" => "AutoMooncake(config = nothing)",
    "mooncake_forward" => "AutoMooncakeForward()"
)

# The seeded `ADFixtures.backends()` body, one entry per `_AD_BACKENDS` entry,
# so a fresh package's AD registry matches every backend
# `test/ad/scenarios.jl` emits a testitem for (#217). A tag with no known
# constructor gets `nothing` with an inline TODO rather than erroring, so
# `scaffold`/`update` still succeeds.
function _ad_backend_entries()
    entries = map(_AD_BACKENDS) do b
        ctor = get(_AD_BACKEND_CTORS, b.tag) do
            "nothing  # TODO: add the ADTypes constructor for \"$(b.header)\""
        end
        string("        (name = \"", b.header, "\", backend = ", ctor, ")")
    end
    return join(entries, ",\n") * ","
end

# The family tag shared by a backend's forward/reverse variants (e.g.
# `:enzyme` for `enzyme_forward`/`enzyme_reverse`), or `nothing` when the
# backend's `tag` has no such split (`forwarddiff`, `reversediff`) or when
# the derived family would collide with another backend's own standalone
# tag (`reversediff_compiled` would derive `reversediff`, already the tape
# entry's tag, so filtering by `:reversediff` would silently also select
# the compiled variant).
function _ad_scenario_family(tag::AbstractString)
    parts = split(tag, '_')
    length(parts) <= 1 && return nothing
    family = first(parts)
    any(b -> b.tag == family, _AD_BACKENDS) && return nothing
    return family
end

# The `tags = ` list for a backend's scenario item. Shared by the scaffolded
# seed and by `_ad_backend_tag_gap`'s worked example, so the tags the warning
# tells an adopter to write are the ones the seed would have written.
function _ad_scenario_tags(b)
    family = _ad_scenario_family(b.tag)
    return family === nothing ? "[:ad, :$(b.tag)]" :
        "[:ad, :$(family), :$(b.tag)]"
end

# The scaffolded `test/ad/scenarios.jl` starter `@testitem` blocks, one per
# `_AD_BACKENDS` entry, so the seed never falls behind as backends are added.
function _ad_scenario_testitems()
    blocks = map(_AD_BACKENDS) do b
        string(
            "@testitem \"", b.header, " gradients (marginal)\" tags = ",
            _ad_scenario_tags(b), " setup = [ADHelpers] begin\n",
            "    test_working_backend(\"", b.header, "\")\n",
            "end"
        )
    end
    return join(blocks, "\n\n")
end

# The per-backend coverage-flag markdown table (header, separator, badge
# lines) from `_AD_BACKENDS`. Shared by the README badge block and the
# AD-backends tutorial page, so the two always show the same table.
function _ad_cov_flag_table(repo::AbstractString)
    cov = "https://codecov.io/gh/" * repo
    headers = "| " * join((b.header for b in _AD_BACKENDS), " | ") * " |"
    sep = "|" * join((":---:" for _ in _AD_BACKENDS), "|") * "|"
    badges = "| " *
        join(
        [
            "[![cov $(b.alt)]($cov/graph/badge.svg?flag=$(b.slug))]" *
                "(https://app.codecov.io/gh/$repo?flags%5B0%5D=" *
                "$(b.slug))" for b in _AD_BACKENDS
        ],
        " | "
    ) * " |"
    return (headers, sep, badges)
end

# The `{{AD_COV_TABLE}}` substitution for the AD-backends tutorial page: the
# three table lines joined, or `nothing` when the repo slug is unknown (then
# `_substitute` errors only if the ad-gated tutorial is actually emitted,
# matching every other `{{REPO}}`-bearing template).
_ad_cov_table(repo::Nothing) = nothing
_ad_cov_table(repo::AbstractString) = join(_ad_cov_flag_table(repo), "\n")

# --- the ad=true docs surface -----------------------------------------------
#
# The managed AD-backends tutorial page and its AD-comparison benchmark
# sibling need three package-owned docs seeds: `docs/docs_config.jl`
# registers each with its own Literate pipeline (`HEAVY_TUTORIALS` for
# `ad-backends.jl`, `HEAVY_BENCHMARKS` for `ad-comparison.jl`),
# `docs/pages.jl` adds their nav entries, and `docs/Project.toml` reaches the
# `ADFixtures` registry by path and carries both pages' execution deps. Each
# helper below renders the fragment substituted into those seeds, empty for
# `ad = false`, mirroring the `BENCHMARKS_NAV` pattern.

# The `HEAVY_TUTORIALS` entry: `ad-backends.jl`'s support-table setup gets
# fresh-subprocess isolation like every other heavy tutorial. Its
# `ad-comparison.jl` sibling is a `HEAVY_BENCHMARKS` entry instead (see
# `_ad_heavy_benchmarks`).
function _ad_heavy_tutorials(ad::Bool)
    ad || return ""
    return "\n    \"ad-backends.jl\",\n"
end

# The fast-build stub, preserving the page's `@id` so cross-references still
# resolve under `--skip-notebooks`.
function _ad_tutorial_stubs(ad::Bool)
    ad || return ""
    return "\n    \"ad-backends.md\" => \"# [Automatic differentiation " *
        "backends](@id ad-backends)\",\n"
end

# The `HEAVY_BENCHMARKS` entry for `ad-comparison.jl` -- it executes DIT
# benchmarks over every registry backend plus CairoMakie plotting, exactly
# the workload the heavy (one fresh subprocess per page) pipeline exists
# for. Rendered under `docs/src/benchmarks/`, not `TUTORIALS_SUBDIR` (#305).
function _ad_heavy_benchmarks(ad::Bool)
    ad || return ""
    return "\n    \"ad-comparison.jl\",\n"
end

# The fast-build stub for `ad-comparison.jl`, same convention as
# `_ad_tutorial_stubs`.
function _ad_benchmark_stubs(ad::Bool)
    ad || return ""
    return "\n    \"ad-comparison.md\" => \"# [AD backend " *
        "comparison](@id ad-comparison)\",\n"
end

# The Getting started nav entry for the AD-backends page. `ad-comparison.md`
# is not listed here: it gets its own top-level Benchmarks nav group instead
# (#299/#305, see `_benchmarks_nav`), which is the entire point of the
# split -- a cost report reads as a how-to guide if left under Tutorials.
function _ad_tutorials_nav(ad::Bool)
    ad || return ""
    return ",\n        \"Tutorials\" => [\n" *
        "            \"Automatic differentiation backends\" =>\n" *
        "                \"getting-started/tutorials/ad-backends.md\",\n" *
        "        ]"
end

# The docs-env `[deps]` block the page executes against: the seeded
# `ADFixtures` registry (same fresh UUID as the AD test env, path-sourced
# below), DifferentiationInterfaceTest (the benchmark driver), Chairmarks
# (DIT 0.11+ needs it loaded explicitly for `benchmark_differentiation`),
# the DataFrames/plotting stack, and the stdlibs the page loads.
function _ad_docs_deps(ad::Bool, adfix_uuid::AbstractString)
    ad || return ""
    return string(
        "ADFixtures = \"", adfix_uuid, "\"\n",
        "CairoMakie = \"13f3f980-e62b-5c42-98c6-ff1f3baf88f0\"\n",
        "Chairmarks = \"0ca39b1e-fe0b-4e98-acfc-b1656634c4de\"\n",
        "DataFramesMeta = \"1313f7d8-7da2-5740-9ea0-a2ca25f37964\"\n",
        "DifferentiationInterfaceTest = ",
        "\"a82114a7-5aa3-49a8-9643-716bb13727a3\"\n",
        "Markdown = \"d6f4376e-aef5-505a-96c1-9c027394607a\"\n",
        "Statistics = \"10745b16-79ce-11e8-11f9-7d13ad32a3b2\"\n"
    )
end

# --- the extensions docs surface --------------------------------------------
#
# A package that ships `[extensions]` gets an "Extensions" nav group, one entry
# per extension, each pointing at a package-owned page under
# `docs/src/extensions/`. The nav block is rendered into `docs/pages.jl` on
# every `scaffold`/`update` (`_apply_pages`), and
# `DocsBuild._strip_extensions_nav` keeps the built site honest when a page
# named there no longer exists (#319).
#
# Detected from the target's Project.toml, not gated by a kwarg: an extension
# is a fact about the package, unlike the benchmark and AD opt-ins.

# One extension's docs page: the `[extensions]` key (the extension module
# name), the nav label, and the page basename under `docs/src/extensions`.
struct ExtensionPage
    name::String
    title::String
    slug::String
end

# The part of an extension module name that identifies it: the package prefix
# and the `Ext` suffix carry no information. Falls back to the full name when
# stripping would leave nothing. Not injective — `WombatPlotsExt` and a bare
# `PlotsExt` both stem to `Plots` — so `_package_extensions` resolves the
# resulting slug collision.
function _extension_stem(name::AbstractString, package::AbstractString)
    stem = String(name)
    startswith(stem, package) && (stem = stem[(ncodeunits(package) + 1):end])
    endswith(stem, "Ext") && (stem = stem[1:(end - 3)])
    return isempty(stem) ? String(name) : stem
end

# The page basename for an extension: its stem in kebab-case
# (`ComposedDistributions` -> `composed-distributions`), so the published URL
# reads like the rest of the site rather than like a module name.
function _extension_slug(stem::AbstractString)
    kebab = replace(String(stem), r"(?<=[a-z0-9])(?=[A-Z])" => "-")
    return lowercase(kebab)
end

# The extensions a package declares, as docs pages, sorted by title so the nav
# order is deterministic (TOML tables are unordered).
#
# The nav label comes from the weakdep(s) the extension loads on rather than
# from the extension module name: a reader recognises "Plots", not
# "CensoredDistributionsPlotsExt". An extension triggered by several weakdeps
# is labelled with all of them. Falls back to the stem for an extension whose
# `[weakdeps]` entry is missing.
#
# Returns empty when there is no Project.toml, no `[extensions]` table, or the
# file does not parse — an unsubstituted template still carrying
# `{{PLACEHOLDER}}` is not valid TOML, and is not worth an error here.
function _package_extensions(target_dir::AbstractString)
    proj = joinpath(target_dir, "Project.toml")
    isfile(proj) || return ExtensionPage[]
    parsed = try
        Pkg.TOML.parsefile(proj)
    catch
        return ExtensionPage[]
    end
    exts = get(parsed, "extensions", nothing)
    exts isa AbstractDict || return ExtensionPage[]
    package = string(get(parsed, "name", ""))
    pages = ExtensionPage[]
    for (name, triggers) in exts
        stem = _extension_stem(name, package)
        # A `[extensions]` value is one weakdep or a list of them.
        weakdeps = triggers isa AbstractVector ?
            String[string(t) for t in triggers] :
            String[string(triggers)]
        filter!(!isempty, weakdeps)
        title = isempty(weakdeps) ? stem : join(sort!(weakdeps), " + ")
        push!(pages, ExtensionPage(String(name), title, _extension_slug(stem)))
    end
    sort!(pages, by = p -> (p.title, p.name))
    # Stemming can map two extensions onto one slug, and the full-name
    # fallback can itself collide, so uniqueness is enforced rather than
    # assumed. Assignment walks the already-sorted pages, so the result
    # depends on the extension set alone, not on TOML order.
    return _uniquify_slugs(pages)
end

# Give every page a slug no other page holds, preferring its stem, then its
# full extension name, then a numbered variant. See `_package_extensions`.
function _uniquify_slugs(pages::Vector{ExtensionPage})
    taken = Set{String}()
    out = ExtensionPage[]
    for p in pages
        candidates = [p.slug, _extension_slug(p.name)]
        slug = nothing
        for c in candidates
            c in taken && continue
            slug = c
            break
        end
        if slug === nothing
            n = 2
            base = _extension_slug(p.name)
            while string(base, "-", n) in taken
                n += 1
            end
            slug = string(base, "-", n)
        end
        push!(taken, slug)
        push!(out, ExtensionPage(p.name, p.title, slug))
    end
    return out
end

# The top-level "Extensions" nav group for `docs/pages.jl`. Empty (no group at
# all) for a package with no extensions, exactly as `BENCHMARKS_NAV` is empty
# without benchmarks.
function _extensions_nav(target_dir::AbstractString)
    pages = _package_extensions(target_dir)
    isempty(pages) && return ""
    entries = [
        string(
                "        \"", p.title, "\" => \"extensions/", p.slug,
                ".md\""
            ) for p in pages
    ]
    return string(
        ",\n    \"Extensions\" => [\n", join(entries, ",\n"),
        ",\n    ]"
    )
end

# The seeded page for one extension. Package-owned: it carries scope prose the
# authors write, so the kit seeds a stub and never returns to it.
#
# The public-API block is seeded inert, inside an outer ````markdown fence. An
# extension module only exists once its weakdeps are loaded, so a live
# `@autodocs` over `Base.get_extension` kills the build of any docs env that
# lacks them — `nothing` makes Documenter's `DocSystem.getmeta` `MethodError`
# outside the `try` that `warnonly = [:autodocs_block]` catches. An HTML
# comment cannot do this job: Documenter parses with the `Markdown` stdlib,
# which has no HTML-block handling, so a fence inside `<!-- -->` is still live
# (the quirk behind #301/#304).
function _render_extension_page(page::ExtensionPage, package::AbstractString)
    return string(
        "# [", page.title, " extension](@id extension-", page.slug, ")\n",
        "\n",
        "`", page.name, "` is loaded automatically when ", page.title,
        " is available alongside ", package, ".\n",
        "\n",
        "## Scope\n",
        "\n",
        "Describe what this extension adds, and what a reader needs to load ",
        "to get it.\n",
        "\n",
        "## Public API\n",
        "\n",
        "Add ", page.title, " to `docs/Project.toml` and the extension ",
        "module to\n",
        "`EXTRA_MODULES` in `docs/docs_config.jl`, then replace this block ",
        "with the\n",
        "one inside it, and the extension's docstrings render here.\n",
        "\n",
        "````markdown\n",
        "```@autodocs\n",
        "Modules = [Base.get_extension(", package, ", :", page.name, ")]\n",
        "```\n",
        "````\n"
    )
end

# Seed the package-owned extension pages under `docs/src/extensions`, one per
# declared extension. Write-once, like LICENSE and CITATION.cff: an existing
# page is never rewritten, so authored scope prose survives every sync.
# Returns `(created, preserved)` destination paths.
function _apply_extension_pages(
        target_dir::AbstractString,
        inputs::NamedTuple; force::Bool
    )
    created = String[]
    preserved = String[]
    pkg = inputs.PACKAGE
    pkg === nothing && return (created, preserved)
    for page in _package_extensions(target_dir)
        dest = _dest_path(
            target_dir,
            string("docs/src/extensions/", page.slug, ".md")
        )
        if isfile(dest) && !force
            push!(preserved, dest)
            continue
        end
        mkpath(dirname(dest))
        _make_writable(dest)
        write(dest, _render_extension_page(page, String(pkg)))
        push!(created, dest)
    end
    return (created, preserved)
end

# The extension pages a package has on disk that nothing in its nav points at.
#
# A managed `docs/pages.jl` (`_apply_pages` already ran by the time this is
# called) always reflects the current `[extensions]` table, so this only ever
# fires for a bespoke, preserved `pages.jl` (#170/#328/#354): package-owned
# and write-once like before this redesign, so a package declaring an
# extension after forking it gets the page seeded but no nav entry, and
# nothing links to it. Name it, with the entry to add, rather than leaving it
# to be noticed on a published site (#319). Returns a message, or `nothing`
# when all are reachable.
#
# Only pages on disk count: `update` never seeds them, so warning there would
# claim a file is unreachable when it was never written, and the remedy would
# be inert anyway since `_strip_extensions_nav` drops entries with no page.
function _extension_pages_unlinked(target_dir::AbstractString)
    pages = _package_extensions(target_dir)
    isempty(pages) && return nothing
    nav = _dest_path(target_dir, "docs/pages.jl")
    isfile(nav) || return nothing
    text = read(nav, String)
    missing_pages = [
        p
            for p in pages
            if isfile(
                _dest_path(
                    target_dir,
                    string("docs/src/extensions/", p.slug, ".md")
                )
            ) &&
            !occursin("extensions/" * p.slug * ".md", text)
    ]
    isempty(missing_pages) && return nothing
    entries = join(
        (
            string(
                    "\"", p.title, "\" => \"extensions/", p.slug,
                    ".md\""
                ) for p in missing_pages
        ), ", "
    )
    return string(
        "docs/pages.jl has no nav entry for ",
        length(missing_pages) == 1 ? "the extension page " : "the extension pages ",
        join(
            (string("extensions/", p.slug, ".md") for p in missing_pages),
            ", "
        ),
        ", so ", length(missing_pages) == 1 ? "it is" : "they are",
        " built but unreachable. `pages.jl` is package-owned and written ",
        "once, so the kit cannot add ", length(missing_pages) == 1 ? "it" :
            "them",
        " on a later run: add ", entries,
        " to the \"Extensions\" group by hand (#319)."
    )
end

# The `[sources]` path pin from the docs env to the registry.
function _ad_docs_sources(ad::Bool)
    ad || return ""
    return "\nADFixtures = {path = \"../test/ADFixtures\"}"
end

# The `[compat]` bounds for the ad-only docs deps (ADFixtures is path-pinned,
# so it carries none). DifferentiationInterfaceTest mirrors the test-env pin.
function _ad_docs_compat(ad::Bool)
    ad || return ""
    return string(
        "CairoMakie = \"0.15\"\n",
        "Chairmarks = \"1\"\n",
        "DataFramesMeta = \"0.15\"\n",
        "DifferentiationInterfaceTest = \"0.9, 0.10, 0.11\"\n",
        "Markdown = \"1\"\n",
        "Statistics = \"1\"\n"
    )
end

# `docs/docs_config.jl` is package-owned, so `update` cannot add the
# `ad-comparison.jl` Literate registration to an existing `ad = true`
# adopter's file: `AD_HEAVY_TUTORIALS`/`AD_TUTORIAL_STUBS`/
# `AD_HEAVY_BENCHMARKS`/`AD_BENCHMARK_STUBS` above only reach a
# package-owned file on first scaffold (#299/#305). An adopter who synced
# before the split still only has `ad-backends.jl` registered (and no
# `HEAVY_BENCHMARKS`/`BENCHMARK_STUBS` consts at all), so the managed
# `ad-comparison.jl` page this sync writes is never Literate-processed or
# stubbed into a `.md` page, and `ad-backends.md`'s cross-references to it
# dangle. Detected the same way as the diverged `test/ad/setup.jl` case:
# scan the destination and warn rather than silently leaving the page
# unbuilt.
function _ad_benchmarks_config_gap(target_dir::AbstractString, ad::Bool)
    ad || return nothing
    cfg = joinpath(target_dir, "docs", "docs_config.jl")
    isfile(cfg) || return nothing
    txt = read(cfg, String)
    occursin("\"ad-backends.jl\"", txt) || return nothing
    occursin("\"ad-comparison.jl\"", txt) && return nothing
    return string(
        "docs/docs_config.jl registers \"ad-backends.jl\" but has no ",
        "HEAVY_BENCHMARKS entry for \"ad-comparison.jl\": the managed ",
        "ad-comparison.jl page (#299/#305) is written but never rendered, ",
        "and ad-backends.md's cross-references to it will not resolve. ",
        "Add \"ad-comparison.jl\" to HEAVY_BENCHMARKS and ",
        "\"ad-comparison.md\" => \"# [AD backend comparison](@id ",
        "ad-comparison)\" to BENCHMARK_STUBS in docs/docs_config.jl (a ",
        "docs_config.jl that predates #305 has neither const yet -- add ",
        "both, mirroring HEAVY_TUTORIALS/TUTORIAL_STUBS above them)."
    )
end

# `docs/Project.toml` is package-owned and write-once, so dropping a dep from
# `_ad_docs_deps`/`_ad_docs_compat` only takes effect on a fresh scaffold
# (#299/#305). `AlgebraOfGraphics` is the case that matters: the AD-comparison
# page's plots were rewritten in plain CairoMakie precisely because AoG's
# `mapping`/`visual` calls pull `DimensionalData` in via Makie, which
# conflicts with FlexiChains' compat range in any package that hard-deps both
# (kit#283). An existing adopter keeps AoG in `[deps]`/`[compat]` after this
# sync, so they keep the exact resolver conflict the removal exists to fix,
# now with nothing in the docs build using it. Warn like the two other
# write-once gaps rather than leaving it to be found as an unrelated-looking
# resolver failure.
const _STALE_AD_DOCS_DEPS = ("AlgebraOfGraphics",)

# The dependency names a rendered `[deps]` fragment declares, read back from
# the fragment itself so the required set cannot drift from what is seeded.
function _declared_dep_names(fragment::AbstractString)
    names = String[]
    for line in split(fragment, '\n')
        m = match(r"^([A-Za-z_][A-Za-z0-9_]*) = \"", line)
        m === nothing || push!(names, m.captures[1])
    end
    return names
end

function _ad_docs_deps_gap(
        target_dir::AbstractString, ad::Bool, adfix_uuid::AbstractString
    )
    ad || return nothing
    proj = joinpath(target_dir, "docs", "Project.toml")
    isfile(proj) || return nothing
    txt = read(proj, String)
    notes = String[]
    stale = filter(d -> occursin(d, txt), collect(_STALE_AD_DOCS_DEPS))
    isempty(stale) || push!(
        notes,
        string(
            "docs/Project.toml still lists ", join(stale, ", "),
            ": the AD-comparison page no longer uses it, and it pulls ",
            "DimensionalData in via Makie, which conflicts with FlexiChains ",
            "in a package that hard-deps both. Remove it from [deps] and ",
            "[compat] in docs/Project.toml."
        )
    )
    # The other direction, and the one an adopter actually hits: a dep the
    # kit seeds for the AD docs pages is missing, because `docs/Project.toml`
    # is package-owned and write-once, so a dep added to the kit after this
    # package was scaffolded never reaches it. The pages are managed, so they
    # `using` it regardless and the build fails on a name the adopter never
    # chose.
    required = _declared_dep_names(_ad_docs_deps(ad, adfix_uuid))
    missing_deps = filter(d -> !occursin(d, txt), required)
    isempty(missing_deps) || push!(
        notes,
        string(
            "docs/Project.toml is missing ", join(missing_deps, ", "),
            ", which the managed AD docs pages load. Add it to [deps] and ",
            "[compat] in docs/Project.toml; the kit cannot, because that ",
            "file is package-owned."
        )
    )
    isempty(notes) && return nothing
    return join(notes, " ")
end

# `test/ad/scenarios.jl` and `test/ADFixtures` are package-owned write-once
# seeds, but `_AD_BACKENDS` drives the managed `ad.yaml` matrix, the
# `codecov.yml` flags and the README badge row. So adding a backend to the kit
# reaches an existing adopter's CI, badges and coverage flags on the next
# sync, and reaches none of the files that make it test anything: the new job
# runs zero tests, reports green, and uploads an empty coverage flag behind a
# public badge (kit#415, seen as `ad-reversediff-compiled` on
# EpiAwareADTools#69). `update` cannot write the test item itself, so scan for
# each managed tag and name the ones with nothing behind them.
#
# Detection is textual because the AD items live in their own environment with
# the heavy backends as deps, which `update` must not have to load. A tag is
# matched with a trailing word boundary so `:reversediff` is not satisfied by
# `:reversediff_compiled`.
function _ad_backend_tag_gap(target_dir::AbstractString, ad::Bool)
    ad || return nothing
    dir = joinpath(target_dir, "test", "ad")
    isdir(dir) || return nothing
    # Walked recursively to match `run_tests(@__DIR__)`'s own discovery, so a
    # package that files its items under `test/ad/scenarios/` is not reported
    # as having none.
    sources = String[]
    for (root, _, files) in walkdir(dir), f in files
        endswith(f, ".jl") && push!(sources, joinpath(root, f))
    end
    isempty(sources) && return nothing
    # Comment lines are dropped before matching. The seeded `scenarios.jl`
    # ends with a commented example item tagged `:forwarddiff`, which would
    # otherwise read as a live item for a backend that has none.
    lines = mapreduce(readlines, vcat, sources)
    text = join(filter(l -> !startswith(lstrip(l), "#"), lines), "\n")
    # No items at all means the package has not seeded its AD suite yet,
    # which is the scaffold's own starting state rather than drift.
    occursin("@testitem", text) || return nothing
    gaps = filter(b -> !occursin(Regex(":$(b.tag)\\b"), text), _AD_BACKENDS)
    isempty(gaps) && return nothing
    example = first(gaps)
    return string(
        "test/ad/ has no @testitem tagged ",
        join((":$(b.tag)" for b in gaps), ", "),
        ", but the managed ad.yaml runs a job per backend: each of those ",
        "jobs runs zero tests, reports green, and uploads an empty ",
        join(("$(b.slug)" for b in gaps), ", "),
        " coverage flag behind a public README badge (kit#415). ",
        "test/ad/scenarios.jl and test/ADFixtures are package-owned seeds ",
        "that update cannot extend. Add a test item per backend, e.g. ",
        "`@testitem \"", example.header, " gradients\" tags = ",
        _ad_scenario_tags(example), " setup = [ADHelpers] begin ",
        "test_working_backend(\"", example.header, "\") end`, and the ",
        "matching (; name, backend) entry to ADFixtures.backends()."
    )
end

# The docs-env `[deps]` fragment the benchmark page's trend plot needs
# (`DocsBuild._write_overall_trend_plot`). Without it the plot degrades to an
# `@info` note, so a freshly scaffolded benchmark page would never render it.
function _bench_docs_deps(benchmarks::Bool)
    benchmarks || return ""
    return "Plots = \"91a5bcdd-55d7-5caf-9e0b-520d859cae80\"\n"
end

# The `[compat]` bound for the benchmark-only docs dep.
function _bench_docs_compat(benchmarks::Bool)
    benchmarks || return ""
    return "Plots = \"1\"\n"
end

# The top-level "Benchmarks" nav entry (#299/#305): its own group, a
# sibling of "Getting started"/"API reference"/"Extensions", never nested
# inside Tutorials -- the shape EpiAwareADTools#28 asked for ("Benchmarks:
# Performance over time, AD comparison"), rather than five one-off per-repo
# nav edits. "Performance over time" appears with `benchmarks = true`, "AD
# comparison" with `ad = true`, both under `docs/src/benchmarks/`. Either
# alone still gets its own single-entry dropdown -- consistent with
# `_extensions_nav`, which never special-cases a lone entry either -- so the
# group reads as its own header drop down regardless of how many pages it
# holds, rather than a bare flat link for the single-page case. A package
# with neither flag gets no entry and no group.
function _benchmarks_nav(benchmarks::Bool, ad::Bool)
    entries = String[]
    benchmarks && push!(
        entries,
        "\"Performance over time\" => \"benchmarks/over-time.md\""
    )
    ad && push!(
        entries,
        "\"AD comparison\" =>\n            \"benchmarks/ad-comparison.md\""
    )
    isempty(entries) && return ""
    return ",\n    \"Benchmarks\" => [\n        " *
        join(entries, ",\n        ") * ",\n    ]"
end

# A managed `docs/pages.jl` carries a current `BENCHMARKS_NAV` on every
# `_apply_pages` run, so this only ever fires for a bespoke, preserved
# `pages.jl` (#170/#328/#354): package-owned and write-once like
# `docs/docs_config.jl` (see `_ad_benchmarks_config_gap` above), so `update`
# cannot add the entry a fresh scaffold seeds to a forked file (#299/#305).
# Two ways an existing adopter's `pages.jl` can now be stale: an `ad = true`
# adopter who synced before the AD-comparison split has no nav entry pointing at
# `benchmarks/ad-comparison.md` at all, and ANY `benchmarks = true` adopter
# (regardless of `ad`) who synced before #305 still has the pre-#305 flat
# `"Benchmarks" => "benchmarks.md"` entry, which now points at a path the
# build no longer writes (the performance-history page moved to
# `benchmarks/over-time.md`). Either gap leaves a page that still builds
# (and, for AD comparison, is still cross-linked from `ad-backends.md`) but
# does not appear in the docs sidebar. NEWS.md documents the fix; warn at
# update time too, so it is not discoverable only by reading NEWS.md.
function _benchmarks_nav_gap(
        target_dir::AbstractString, benchmarks::Bool, ad::Bool
    )
    (benchmarks || ad) || return nothing
    pages = joinpath(target_dir, "docs", "pages.jl")
    isfile(pages) || return nothing
    txt = read(pages, String)
    missing_history = benchmarks && !occursin("benchmarks/over-time.md", txt)
    missing_ad = ad && !occursin("benchmarks/ad-comparison.md", txt)
    (missing_history || missing_ad) || return nothing
    missing = String[]
    missing_history && push!(
        missing,
        "benchmarks/over-time.md (Performance over time)"
    )
    missing_ad && push!(
        missing,
        "benchmarks/ad-comparison.md (AD comparison)"
    )
    entry = lstrip(_benchmarks_nav(benchmarks, ad), [',', '\n', ' '])
    return string(
        "docs/pages.jl has no \"Benchmarks\" nav entry for ",
        join(missing, " or "), " -- a pages.jl that predates #305 may ",
        "still carry a stale flat \"Benchmarks\" => \"benchmarks.md\" ",
        "entry pointing at a path the build no longer writes. Replace any ",
        "existing \"Benchmarks\" entry in the pages array in ",
        "docs/pages.jl with: ", entry
    )
end

# --- the managed docs/pages.jl base + package extension points -------------
# (#170/#328/#354)
#
# `docs/pages.jl` used to be a package-owned skeleton, forked once at
# scaffold time and never touched again -- the direct cause of the drift a
# survey of every adopter turned up: three orphaned AD-backends tutorials, a
# Benchmarks nav stale in every adopter since #305 (`_benchmarks_nav_gap`
# above can only warn about it, because the file is write-once), and label
# drift ("Modules" for "API reference", "Developer" for "Development")
# nothing could self-heal. It is now a MANAGED template like any other:
# `scaffold`/`update` regenerate it in full on every run from the same
# `_ad_tutorials_nav`/`_benchmarks_nav`/`_extensions_nav` fragments used
# above, now spliced in on every sync rather than only the first. A package
# extends it through four optional constants in the package-owned
# `docs/docs_config.jl` (see `templates/docs/docs_config.jl`) instead of
# editing the generated file, read below with the same isdefined-or-default
# fallback `make.jl`'s own `_cfg` applies at docs-build time.
#
# Migration safety is the part that must not be got wrong: overwriting a
# bespoke `pages.jl` would delete real docs navigation -- ten adopters have
# one (EpiAwareADTools' "Tools", ScoringRules' "Guide", ComposedDistributions'
# "Developer", ...). `_apply_pages` writes the managed base only when the
# committed file already carries `_MANAGED_PAGES_MARKER`, or no file exists
# yet, regardless of `force`: unlike every other package-owned skeleton,
# there is no forced reset back to the seeded version, because a forced reset
# here is exactly the clobber this whole redesign exists to prevent.
# Otherwise the file is preserved untouched and a warning names exactly which
# of its existing top-level groups the generated base would not reproduce,
# with the `docs_config.jl` snippet that would carry them across.

# Written into the header of every kit-generated `docs/pages.jl`, so a later
# `update` can tell a managed file (safe to regenerate) from a bespoke one
# (preserve and warn). This is the inverse of `_MANAGED_OVERRIDE_MARKER`:
# there the marker's presence keeps a managed file from resyncing; here the
# marker's absence is what keeps a package-owned file from being overwritten.
const _MANAGED_PAGES_MARKER = "EPIAWARE_MANAGED_PAGES"

# Evaluate a target's `docs/docs_config.jl` in a fresh, throwaway module so
# its constants -- including the four pages.jl extension points -- read back
# as real Julia values rather than being regex-scraped, the way
# `_package_extensions` parses Project.toml structurally instead of with a
# pattern. A real evaluation also resolves an adopter's own indirection (a
# `Vector{Pair}` built through intermediate variables) the same way reading
# `pages` back in `_pages_group_labels` below does. Returns `nothing` when
# the file is absent or fails to evaluate (e.g. an unsubstituted
# `{{PLACEHOLDER}}` template is not valid Julia, tolerated the same way
# `_package_extensions` tolerates a TOML parse failure).
function _read_docs_config(target_dir::AbstractString)
    cfg = _dest_path(target_dir, "docs/docs_config.jl")
    isfile(cfg) || return nothing
    mod = Module(:_EpiAwareDocsConfig)
    try
        Base.include_string(mod, read(cfg, String), cfg)
    catch
        return nothing
    end
    return mod
end

# A module built by `include_string` inside the very call that reads it back
# (as `_read_docs_config`/`_pages_group_labels` do) defines its bindings in a
# world newer than the calling frame's, and Julia 1.12 world-age-guards a
# global binding the same way it already guarded method dispatch -- both
# `isdefined` and `getfield` must run through `Base.invokelatest`, or the read
# warns now and errors on a future Julia. Shared by `_docs_cfg` below and
# `_pages_group_labels`.
_get_binding(mod::Module, sym::Symbol, default) =
    isdefined(mod, sym) ? getfield(mod, sym) : default

# The same isdefined-or-default fallback `make.jl`'s own `_cfg` applies at
# docs-build time, applied here at scaffold/update time instead: `mod` is
# `nothing` (no docs_config.jl, or it failed to evaluate) or lacks `sym` (a
# file written before this constant existed) both default quietly.
function _docs_cfg(mod, sym::Symbol, default)
    return mod === nothing ? default :
        Base.invokelatest(_get_binding, mod, sym, default)
end

# Render an arbitrary nav value -- a page path, or a nested vector of
# `"Title" => value` pairs -- as `pages.jl`-style Julia source, so a
# `PACKAGE_SECTIONS`/`DEVELOPMENT_EXTEND_PAGE` value (already resolved to a
# real Julia value by `_read_docs_config`) comes back out formatted like the
# rest of the managed base, rather than through `repr`, which does not follow
# this file's indentation convention. `indent` is the current entry's own
# indentation, so a nested vector's entries and closing bracket can be
# indented relative to it.
function _render_nav_value(value, indent::AbstractString)
    if value isa AbstractString
        return string("\"", value, "\"")
    elseif value isa Pair
        return string(
            "\"", String(value.first), "\" => ",
            _render_nav_value(value.second, indent)
        )
    elseif value isa AbstractVector
        inner = indent * "    "
        entries = [inner * _render_nav_value(v, inner) for v in value]
        return string("[\n", join(entries, ",\n"), ",\n", indent, "]")
    else
        error(
            "pages.jl nav value must be a String, Pair or Vector, got a " *
                string(typeof(value))
        )
    end
end

# The optional Getting-started FAQ leaf (`GETTING_STARTED_FAQ`), spliced
# right after "Overview". Empty (no entry) when unset, exactly as
# `_ad_tutorials_nav` is empty for `ad = false`.
function _getting_started_faq(faq)
    faq === nothing && return ""
    return string(",\n        \"FAQ\" => \"", faq, "\"")
end

# The package's own Getting-started tutorials (`PACKAGE_TUTORIALS`), spliced
# after Overview/FAQ and before the kit-managed AD tutorial subgroup -- one
# ecosystem-wide placement instead of a per-repo choice (#354).
function _package_tutorials_nav(tutorials)
    isempty(tutorials) && return ""
    return join(
        (
            string(",\n        ", _render_nav_value(t, "        "))
                for t in tutorials
        )
    )
end

# The package's extra top-level nav groups (`PACKAGE_SECTIONS`), spliced
# after "Benchmarks" and before "Development".
function _package_sections_nav(sections)
    isempty(sections) && return ""
    return join(
        (
            string(",\n    ", _render_nav_value(s, "    "))
                for s in sections
        )
    )
end

# The "Development" group: a fixed skeleton (Overview, Contributing, Release
# process, Developer FAQ) around the package's one varying leaf
# (`DEVELOPMENT_EXTEND_PAGE`), matching the shape every adopter with one
# independently converged on. The group appears only when the leaf is set
# (see `templates/docs/docs_config.jl`); `nothing` renders no group at all.
function _development_nav(extend_leaf)
    extend_leaf === nothing && return ""
    leaf = _render_nav_value(extend_leaf, "        ")
    return string(
        ",\n    \"Development\" => [\n",
        "        \"Overview\" => \"developer/index.md\",\n",
        "        \"Contributing\" => \"developer/contributing.md\",\n",
        "        ", leaf, ",\n",
        "        \"Release process\" => \"developer/release-process.md\",\n",
        "        \"Developer FAQ\" => \"developer/faq.md\",\n",
        "    ]"
    )
end

# The top-level nav group labels a `pages.jl` source (on disk, or a freshly
# rendered replacement) declares, read by evaluating the array `pages` binds
# to rather than pattern-matching the source -- real evaluation resolves an
# adopter's own indirection (e.g. `pages = ["Getting started" =>
# getting_started_pages, ...]`, as CensoredDistributions.jl's bespoke file
# does) the same way `_read_docs_config` does for `docs_config.jl`. Returns
# `nothing` when `text` fails to evaluate or does not bind `pages` to a
# vector.
function _pages_group_labels(text::AbstractString)
    mod = Module(:_EpiAwareBespokePages)
    try
        Base.include_string(mod, text)
    catch
        return nothing
    end
    val = Base.invokelatest(_get_binding, mod, :pages, nothing)
    val isa AbstractVector || return nothing
    return String[String(e.first) for e in val if e isa Pair]
end

# `update`'s migration-safety message when a bespoke `pages.jl` (no
# `_MANAGED_PAGES_MARKER`) is preserved rather than regenerated: names
# exactly which of its existing top-level groups the generated managed base
# would not reproduce, together with the `docs_config.jl` snippet
# (`PACKAGE_SECTIONS`) that would carry them across -- turning a silent
# clobber this never performs into an actionable migration instruction
# instead. `nothing` when every existing group would carry over unchanged, or
# when `bespoke_text` fails to evaluate (e.g. it does not even parse) --
# there is nothing specific to say in that case.
function _pages_groups_at_risk(
        bespoke_text::AbstractString,
        generated_text::AbstractString
    )
    bespoke = _pages_group_labels(bespoke_text)
    bespoke === nothing && return nothing
    generated = something(_pages_group_labels(generated_text), String[])
    at_risk = filter(l -> !(l in generated), unique(bespoke))
    isempty(at_risk) && return nothing
    snippet = join(
        (string("\"", l, "\" => [...]") for l in at_risk), ", "
    )
    return string(
        "docs/pages.jl is package-owned (no ", _MANAGED_PAGES_MARKER,
        " header) and was preserved. If it were replaced by the managed ",
        "base, these existing top-level group", length(at_risk) == 1 ? "" : "s",
        " would not be reproduced: ", join(at_risk, ", "),
        ". Add ", length(at_risk) == 1 ? "it" : "them",
        " as PACKAGE_SECTIONS in docs/docs_config.jl, e.g.: ",
        "PACKAGE_SECTIONS = [", snippet, "]."
    )
end

"""
    _apply_pages(target_dir, inputs)

Apply the managed `docs/pages.jl` to `target_dir`.

`docs/pages.jl` is MANAGED, but "managed" means something narrower here than
for any other template: `update`/`scaffold` only regenerate it when the
committed file already carries `_MANAGED_PAGES_MARKER` in its header, or no
file exists yet. A committed file without the marker is preserved untouched
no matter what `force` says -- see the section header above for why. The
regenerated content splices `AD_TUTORIALS_NAV`/`EXTENSIONS_NAV`/
`BENCHMARKS_NAV` from `inputs` (computed in `_apply`, unchanged fragments)
and the four `docs_config.jl` extension points read fresh from disk here, so
a package's docs_config.jl edits and a `force` reset of it (which happens
before this runs) are both reflected.

Returns `(action, warning)`: `action` is `:created` (no prior file),
`:refreshed` (marker present, content changed), `:unchanged` (marker
present, content already current) or `:preserved` (no marker); `warning` is
the migration message from `_pages_groups_at_risk`, or `nothing`.
"""
function _apply_pages(target_dir::AbstractString, inputs::NamedTuple)
    cfg = _read_docs_config(target_dir)
    page_inputs = merge(
        inputs,
        (
            GETTING_STARTED_FAQ = _getting_started_faq(
                _docs_cfg(cfg, :GETTING_STARTED_FAQ, nothing)
            ),
            PACKAGE_TUTORIALS = _package_tutorials_nav(
                _docs_cfg(cfg, :PACKAGE_TUTORIALS, Pair{String, String}[])
            ),
            PACKAGE_SECTIONS = _package_sections_nav(
                _docs_cfg(cfg, :PACKAGE_SECTIONS, Pair{String, Any}[])
            ),
            DEVELOPMENT_NAV = _development_nav(
                _docs_cfg(cfg, :DEVELOPMENT_EXTEND_PAGE, nothing)
            ),
        )
    )
    from = joinpath(_templates_dir(), "docs", "pages.jl")
    isfile(from) || error("missing bundled template docs/pages.jl at $from")
    rendered = _render(from, true, page_inputs)
    to = _dest_path(target_dir, "docs/pages.jl")
    if !isfile(to)
        mkpath(dirname(to))
        write(to, rendered)
        return (:created, nothing)
    end
    existing = read(to, String)
    if occursin(_MANAGED_PAGES_MARKER, existing)
        existing == rendered && return (:unchanged, nothing)
        _make_writable(to)
        write(to, rendered)
        return (:refreshed, nothing)
    end
    return (:preserved, _pages_groups_at_risk(existing, rendered))
end

# The conventional custom-subdomain docs host for a package, e.g.
# `MyPkg` -> `mypkg.epiaware.org`. Only used on the opt-in subdomain path
# (`docs_subdomain = true`); the default project-pages path needs no host.
_docs_host(pkg::AbstractString) = lowercase(pkg) * ".epiaware.org"

# The GitHub Pages domain the org serves project-pages from. A repo without a
# custom domain is reachable at `<this>/<Repo>.jl/`.
const DOCS_PAGES_APEX = "epiaware.org"

"""
    _resolve_docs_subdomain(spec, pkg)

Resolve the `docs_subdomain` input to either `nothing` (project-pages,
the default) or a concrete host string.

`true` selects the conventional `<pkg>.epiaware.org`; a string is taken
verbatim; `nothing`/`false` opt out. The `Bool` and `Nothing` cases dispatch
to their own methods so the `String` conversion only runs on a genuine string
input, which keeps JET type-stable.
"""
_resolve_docs_subdomain(::Nothing, pkg) = nothing
function _resolve_docs_subdomain(spec::Bool, pkg)
    spec || return nothing
    return pkg === nothing ? nothing : _docs_host(pkg)
end
function _resolve_docs_subdomain(spec, pkg)
    s = String(spec)
    return isempty(s) ? nothing : s
end

# The `deploy_url` Julia literal for `docs/make.jl`: a bare `nothing` on the
# project-pages path, else the quoted host with an `https://` scheme. The
# scheme is required — DocumenterVitepress only strips the host to build a
# root base when `deploy_url` starts with `https?://`, and a scheme-less host
# is baked into the base as a path, 404ing every asset. Returned as source
# text so the template substitutes a real literal.
_docs_deploy_url(sub::Nothing) = "nothing"
function _docs_deploy_url(sub::AbstractString)
    host = replace(String(sub), r"^https?://" => "")
    return repr("https://" * host)
end

# The bare host(+path) the docs badges link to. Project-pages packages live at
# `epiaware.org/<Repo>.jl`; a subdomain package at its own host. `nothing` when
# the repo slug is unknown (badges are then skipped upstream).
_docs_url(repo::Nothing, sub) = sub === nothing ? nothing : String(sub)
function _docs_url(repo::AbstractString, sub)
    sub === nothing || return String(sub)
    return DOCS_PAGES_APEX * "/" * last(split(repo, '/'))
end

# The optional `with: timeout_minutes:` override on the managed `document.yaml`
# caller (#154). Empty by default, so the reusable applies its own 45 min. A
# package can equally hand-add the block, which `_preserve_caller_with_inputs`
# keeps across `update()` (#73).
function _docs_timeout_with(docs_timeout::Union{Nothing, Integer})
    docs_timeout === nothing && return ""
    docs_timeout > 0 || error(
        "docs_timeout must be a positive integer (minutes), got " *
            repr(docs_timeout)
    )
    return string("    with:\n      timeout_minutes: ", docs_timeout, "\n")
end

# A license-badge cell for an SPDX identifier (label, shields colour, and the
# opensource.org URL). Falls back to a plain SPDX label for an id without a
# dedicated entry, so the badge always matches the package's actual licence.
function _license_badge(spdx::AbstractString)
    label = replace(spdx, "-" => "--")  # shields escapes a literal dash as `--`
    url, colour = if spdx == "MIT"
        "https://opensource.org/licenses/MIT", "yellow"
    elseif spdx == "Apache-2.0"
        "https://opensource.org/licenses/Apache-2.0", "blue"
    else
        "https://spdx.org/licenses/$spdx.html", "green"
    end
    return "[![License: $spdx](https://img.shields.io/badge/License-" *
        "$label-$colour.svg)]($url)"
end

# The two juliapkgstats download badges (total + monthly). They render once the
# package is in the General registry and are harmless before then.
function _downloads_badges(pkg::AbstractString)
    base = "https://img.shields.io/badge/dynamic/json?url=" *
        "http%3A%2F%2Fjuliapkgstats.com%2Fapi%2Fv1%2F"
    page = "https://juliapkgstats.com/pkg/" * pkg
    total = "[![Downloads](" * base * "total_downloads%2F" * pkg *
        "&query=total_requests&label=Downloads)](" * page * ")"
    monthly = "[![Downloads](" * base * "monthly_downloads%2F" * pkg *
        "&query=total_requests&suffix=%2Fmonth&label=Downloads)](" *
        page * ")"
    return total * " " * monthly
end

"""
    _render_badges(repo, pkg; ad, license = DEFAULT_LICENSE,
        docs_url = nothing, doi = nothing, zenodo_badge = nothing)

Render the standard badge block (without the markers) from resolved
inputs.

`repo` is the `owner/name.jl` slug; `pkg` the package name; `ad` adds the
per-backend AD CI + coverage badge table; `license` is the SPDX id whose badge
is shown. `doi`/`zenodo_badge` add a Zenodo DOI badge when both are given. The
layout is a five-column header table (Documentation, Build Status, Code
Quality, License & DOI, Downloads) plus the per-backend AD table. Every URL is
built from `repo`/`pkg`, so no owner/repo is hardcoded.
"""
function _render_badges(
        repo::AbstractString, pkg::AbstractString; ad::Bool,
        license::AbstractString = DEFAULT_LICENSE,
        docs_url::Union{Nothing, AbstractString} = nothing,
        doi::Union{Nothing, AbstractString} = nothing,
        zenodo_badge::Union{Nothing, AbstractString} = nothing
    )
    gh = "https://github.com/" * repo
    cov = "https://codecov.io/gh/" * repo
    # Default to the project-pages URL (`epiaware.org/<Repo>.jl`); a subdomain
    # package passes its host explicitly.
    host = docs_url === nothing ? _docs_url(repo, nothing) : docs_url
    docs = "[![Stable](https://img.shields.io/badge/docs-stable-blue.svg)]" *
        "(https://" * host * "/stable/) " *
        "[![Dev](https://img.shields.io/badge/docs-dev-blue.svg)]" *
        "(https://" * host * "/dev/)"
    ci = "[![Test](" * gh * "/actions/workflows/test.yaml/badge.svg" *
        "?branch=main)](" * gh * "/actions/workflows/test.yaml) " *
        "[![codecov](" * cov * "/graph/badge.svg)](" * cov * ")"
    # One aggregate `ad.yaml`, so one AD status badge; the per-backend detail
    # lives in the coverage-flag table below.
    if ad
        ci *= " [![AD](" * gh * "/actions/workflows/ad.yaml/badge.svg" *
            "?branch=main)](" * gh * "/actions/workflows/ad.yaml)"
    end
    quality = "[![code style: runic](https://img.shields.io/badge/" *
        "code_style-%E1%9A%B1%E1%9A%A2%E1%9A%BE%E1%9B%81%E1%9A%B2-black)]" *
        "(https://github.com/fredrikekre/Runic.jl) " *
        "[![Aqua QA](https://raw.githubusercontent.com/JuliaTesting/" *
        "Aqua.jl/master/badge.svg)](https://github.com/JuliaTesting/" *
        "Aqua.jl) " *
        "[![JET](https://img.shields.io/badge/" *
        "%E2%9C%88%EF%B8%8F%20tested%20with%20-%20JET.jl%20-%20red)]" *
        "(https://github.com/aviatesk/JET.jl)"
    license_doi = _license_badge(license)
    if doi !== nothing && zenodo_badge !== nothing
        license_doi *= " [![DOI](https://zenodo.org/badge/" * zenodo_badge *
            ".svg)](https://doi.org/" * doi * ")"
    end
    downloads = _downloads_badges(pkg)
    lines = String[
        "| **Documentation** | **Build Status** | **Code Quality** | " * "**License & DOI** | **Downloads** |",
        "|:-----------------:|:----------------:|:----------------:|" * ":-----------------:|:-------------:|",
        "| " * docs * " | " * ci * " | " * quality * " | " * license_doi * " | " * downloads * " |",
    ]
    if ad
        # Coverage flags only: per-backend *status* URLs would 404, since only
        # the aggregate `ad.yaml` exists.
        header_line, sep, cov_line = _ad_cov_flag_table(repo)
        push!(lines, "")
        push!(lines, header_line)
        push!(lines, sep)
        push!(lines, cov_line)
    end
    return join(lines, "\n")
end

# A starter README body for a package that has none yet, in the standard
# EpiAware section order (Why / Getting started / Related packages / Where to
# learn more); `_apply_standard_sections` then appends Contributing / How to
# cite / Code of conduct. Only seeded when no README exists; thereafter the
# body is package-owned.
#
# Every italic `_..._` span is a placeholder `test_readme_placeholders` derives
# its patterns from, so an unfilled skeleton is reported rather than published.
# Add a placeholder in that form. Only a heading and a placeholder are seeded
# for Related packages, whose bullets are package-specific (#292).
function _seed_readme_body(
        repo::AbstractString, pkg::AbstractString,
        docs_url::Union{Nothing, AbstractString}
    )
    host = docs_url === nothing ? _docs_url(repo, nothing) : docs_url
    stable = host === nothing ? nothing : "https://" * host * "/stable/"
    docs_link = stable === nothing ? "the documentation" :
        "[documentation](" * stable * ")"
    return string(
        "_One-line description of $pkg._\n\n",
        "## Why $pkg?\n\n",
        "- _List the package's key features here._\n\n",
        "## Getting started\n\n",
        "See $docs_link for a full walkthrough.\n\n",
        "```julia\nusing $pkg\n```\n\n",
        "## Related packages\n\n",
        "- _One bullet per sibling package with a real relationship to " *
            "$pkg, one sentence each, linked to that package's docs._\n\n",
        "## Where to learn more\n\n",
        "- [GitHub Discussions](https://github.com/$repo/discussions)\n",
        "- [GitHub Repository](https://github.com/$repo)\n"
    )
end

# Inject or refresh the managed badge block in a README. With the markers
# present the content between them is replaced; otherwise the block is
# inserted after the first `# ` H1 title, or at the top when there is none.
# Content outside the markers is never touched. Returns `(action, changed)`.
function _apply_badges(
        readme::AbstractString, repo, pkg; ad::Bool,
        license::AbstractString = DEFAULT_LICENSE,
        docs_url::Union{Nothing, AbstractString} = nothing,
        doi::Union{Nothing, AbstractString} = nothing,
        zenodo_badge::Union{Nothing, AbstractString} = nothing
    )
    badges = _render_badges(
        repo, pkg; ad = ad, license = license,
        docs_url = docs_url, doi = doi, zenodo_badge = zenodo_badge
    )
    block = BADGES_START * "\n" * badges * "\n" * BADGES_END
    if !isfile(readme)
        body = _seed_readme_body(repo, pkg, docs_url)
        write(readme, "# " * pkg * "\n\n" * block * "\n\n" * body)
        return (:created, true)
    end
    text = read(readme, String)
    si = findfirst(BADGES_START, text)
    ei = findfirst(BADGES_END, text)
    if si !== nothing && ei !== nothing && first(ei) > last(si)
        # Refresh: replace everything between (and including) the markers.
        new = text[1:(first(si) - 1)] * block * text[(last(ei) + 1):end]
        new == text && return (:refreshed, false)
        write(readme, new)
        return (:refreshed, true)
    end
    # Inject after the first H1 title, else at the very top.
    m = match(r"^(#[^\n]*\n)"m, text)
    if m !== nothing && m.offset == 1
        new = text[1:(m.offset + lastindex(m.match) - 1)] *
            "\n" * block * "\n" * text[(m.offset + lastindex(m.match)):end]
    else
        new = block * "\n\n" * text
    end
    write(readme, new)
    return (:injected, true)
end

# --- managed README logo title ---------------------------------------------
#
# Once a package has a `docs/src/assets/logo.svg`, the README's `# ` title gets
# an inline `<img>` tag pointing at it. Managed like the badge block, but it
# only ever adds the tag: a title that already references `assets/logo.svg` in
# any form is left as-is.

const _LOGO_REL = "docs/src/assets/logo.svg"

# The standard inline logo tag for a README title.
function _logo_img_tag(pkg::AbstractString)
    return string(
        "<img src=\"", _LOGO_REL, "\" width=\"150\" alt=\"", pkg,
        " logo\" align=\"right\">"
    )
end

# Add the logo `<img>` tag to the README's `# ` title when `docs/src/assets/
# logo.svg` exists and the title does not already reference it. Returns
# `:injected`, `:preserved`, or `:skipped` (no logo file, or no README title to
# amend).
function _apply_logo_title(target_dir::AbstractString, pkg::AbstractString)
    isfile(_dest_path(target_dir, _LOGO_REL)) || return :skipped
    readme = joinpath(target_dir, "README.md")
    isfile(readme) || return :skipped
    text = read(readme, String)
    m = match(r"^#[^\n]*"m, text)
    m === nothing && return :skipped
    title = m.match
    occursin("assets/logo.svg", title) && return :preserved
    write(
        readme, replace(
            text, title => title * " " * _logo_img_tag(pkg);
            count = 1
        )
    )
    return :injected
end

# --- managed README standard sections --------------------------------------
#
# The README body is package-owned, but three sections are managed so their
# wording stays consistent and updates centrally: Contributing, How to cite,
# and Code of conduct. They live between the markers below and are re-rendered
# on every sync, like the badge block. The citation content stays package-owned
# in `CITATION.cff`; the managed section only points at it (#67).

# --- opt-in EpiAware org branding (#242) -----------------------------------
#
# An EpiAware package can advertise that it is part of the org's ecosystem: a
# line in the managed README standard sections, and a logo + org links in the
# docs footer. Opt-in and default off, because the kit is usable by anyone and
# a third-party adopter must never be handed EpiAware branding. The flag is
# package-owned (`const ORG_BRANDING` in `docs/docs_config.jl`); the content it
# turns on is managed, so wording and links update centrally.

# The org's canonical site (`epiaware.github.io` redirects to it).
const _ORG_SITE = "https://epiaware.org"
const _ORG_GITHUB = "https://github.com/EpiAware"

# The bundled org logo, distinct from the package's own
# `docs/src/assets/logo.svg`. Written only when branding is on and removed
# again when it is turned off, so an opted-out repo carries no EpiAware asset.
const _ORG_LOGO_SRC = "docs/epiaware-logo.svg"
# Segments, so the destination is built with the platform separator.
const _ORG_LOGO_SEGMENTS = ("docs", "src", "assets", "epiaware-logo.svg")
const _ORG_LOGO_REL = join(_ORG_LOGO_SEGMENTS, "/")

"""
    _detect_org_branding(target_dir)

Whether the package opted in to EpiAware org branding, via
`const ORG_BRANDING = true` in the package-owned `docs/docs_config.jl` (#242).

Read from the destination rather than passed as a kwarg, the same
detect-from-the-file idempotency as `_detect_benchmarks`, so an `update` (or
the scheduled sync, which passes no kwargs) preserves the package's choice.
Defaults to off for a package with no config, or one predating the key.
"""
function _detect_org_branding(target_dir::AbstractString)
    cfg = joinpath(target_dir, "docs", "docs_config.jl")
    isfile(cfg) || return false
    # Line-anchored: commenting the const out is the obvious way to opt out,
    # and an unanchored match would read that as still on.
    m = match(
        r"(?m)^\s*const\s+ORG_BRANDING\s*=\s*(true|false)\s*$",
        read(cfg, String)
    )
    m === nothing && return false
    return something(m.captures[1]) == "true"
end

# The README line, rendered into the managed standard-sections block when
# branding is on and omitted entirely when it is off.
function _org_branding_section(pkg::AbstractString)
    return string(
        "## Part of the EpiAware ecosystem\n\n",
        pkg, " is part of [EpiAware](", _ORG_SITE, "), a set of composable ",
        "tools for infectious disease modelling. See the [other packages](",
        _ORG_GITHUB, ") in the ecosystem.\n"
    )
end

# The docs footer message spliced into the managed `config.mts`. VitePress
# renders `themeConfig.footer.message` as HTML, so branding is a logo + org
# links prepended to the DocumenterVitepress credit.
#
# The logo goes through the site's own `base`, not a root-absolute path, which
# 404s on a versioned deploy served under `/Package.jl/vX.Y/`. Spliced into a
# backtick template literal in `config.mts` — which is what lets
# `${baseTemp.base}` interpolate — so the HTML uses `"` throughout and must
# contain no backtick of its own.
const _DOCS_CREDIT = string(
    "Made with <a href=\"https://luxdl.github.io/DocumenterVitepress.jl/dev/\" ",
    "target=\"_blank\"><strong>DocumenterVitepress.jl</strong></a><br>"
)

function _org_footer_message(org_branding::Bool)
    org_branding || return _DOCS_CREDIT
    return string(
        "<a href=\"", _ORG_SITE, "\" target=\"_blank\">",
        # `\$` so a literal `\${baseTemp.base}` reaches config.mts, where the
        # backtick template literal interpolates the site base.
        "<img src=\"\${baseTemp.base}epiaware-logo.svg\" alt=\"EpiAware\" ",
        "width=\"48\" height=\"48\" style=\"display:inline-block\"></a><br>",
        "Part of the <a href=\"", _ORG_SITE, "\" target=\"_blank\">",
        "<strong>EpiAware</strong></a> ecosystem &middot; ",
        "<a href=\"", _ORG_GITHUB, "\" target=\"_blank\">GitHub</a><br>",
        _DOCS_CREDIT
    )
end

"""
    _apply_org_branding(target_dir, org_branding)

Write (or remove) the bundled EpiAware org logo asset, following the package's
`ORG_BRANDING` opt-in (#242).

Not a `SCAFFOLD_TEMPLATES` entry, like the `LICENSE` variants: the table is
emitted wholesale, and a third-party adopter must not be handed an EpiAware
logo.

Returns `:created`, `:refreshed` (drifted, rewritten), `:unchanged`,
`:removed` (branding off, the kit's asset withdrawn), or `:skipped` (branding
off, nothing of ours there), so `update` is a fixed point in both states.

Turning branding off deletes the asset only when it is byte-identical to the
one the kit shipped. A file the package put at that path is not the kit's to
remove, so it is left alone with a warning.
"""
function _apply_org_branding(target_dir::AbstractString, org_branding::Bool)
    dest = joinpath(target_dir, _ORG_LOGO_SEGMENTS...)
    from = joinpath(_templates_dir(), _ORG_LOGO_SRC)
    isfile(from) || error("missing bundled org logo at $from")
    content = read(from, String)
    if !org_branding
        isfile(dest) || return :skipped
        if read(dest, String) != content
            @warn "$(_ORG_LOGO_REL) is not the logo this kit ships, so it is " *
                "the package's, not the kit's to delete — leaving it in " *
                "place though ORG_BRANDING is off. Remove it by hand if it " *
                "is a leftover (#242)."
            return :skipped
        end
        rm(dest; force = true)
        return :removed
    end
    exists = isfile(dest)
    exists && read(dest, String) == content && return :unchanged
    mkpath(dirname(dest))
    write(dest, content)
    return exists ? :refreshed : :created
end

const STANDARD_SECTIONS_START = "<!-- standard-sections:start -->"
const STANDARD_SECTIONS_END = "<!-- standard-sections:end -->"

# The managed-block header written just inside the start marker, so it is part
# of the refreshed region (like the `.gitignore` header) and never duplicated on
# the preserved side of the file.
const _STANDARD_SECTIONS_HEADER = string(
    "<!-- MANAGED by EpiAwarePackageTools.scaffold — do not edit between the\n",
    "     markers. These standard sections are re-rendered on every update;\n",
    "     edit the package-owned sections outside them, or CITATION.cff. -->"
)

# The org Code of Conduct URL, served from the org's shared `.github` repo.
function _coc_url(org::AbstractString)
    return "https://github.com/" * org * "/.github/blob/main/CODE_OF_CONDUCT.md"
end

# Render the managed standard sections (Contributing / How to cite / Code of
# conduct) without the markers, parameterised by package/org/repo. `doi` adds a
# version-DOI line to the citation pointer when known (the value persisted in
# the README DOI badge); otherwise the section points only at `CITATION.cff`.
function _render_standard_sections(
        pkg::AbstractString, org::AbstractString,
        repo::AbstractString; doi::Union{Nothing, AbstractString} = nothing,
        org_branding::Bool = false
    )
    doi_line = doi === nothing ? "" :
        string(
            "A version-specific DOI is available at ",
            "[https://doi.org/", doi, "](https://doi.org/", doi, ").\n"
        )
    # Absent entirely when the package did not opt in, so a third-party
    # adopter's README is untouched (#242).
    branding = org_branding ? _org_branding_section(pkg) * "\n" : ""
    return string(
        branding,
        "## Contributing\n\n",
        "We welcome contributions and new contributors! Please open an issue ",
        "or pull request on [GitHub](https://github.com/", repo, "). This ",
        "package follows [ColPrac](https://github.com/SciML/ColPrac) and is ",
        "formatted with [Runic](https://github.com/fredrikekre/Runic.jl).\n\n",
        "## How to cite\n\n",
        "If you use ", pkg, " in your work, please cite it. Citation metadata ",
        "lives in [`CITATION.cff`](https://github.com/", repo,
        "/blob/main/CITATION.cff), which GitHub renders as a ",
        "\"Cite this repository\" button on the repository page.\n",
        doi_line,
        "\n",
        "## Code of conduct\n\n",
        "Please note that the ", pkg, " project is released with a ",
        "[Contributor Code of Conduct](", _coc_url(org), "). By contributing, ",
        "you agree to abide by its terms.\n"
    )
end

# Whether `text` already carries one of the managed standard section headings
# (Contributing / Code of conduct / a citation section), used to leave a
# marker-less README that has bespoke prose alone rather than duplicating them.
function _has_managed_section_heading(text::AbstractString)
    return occursin(r"(?mi)^#{2,6}\s+contributing\b", text) ||
        occursin(r"(?mi)^#{2,6}\s+code of conduct\b", text) ||
        occursin(
        r"(?mi)^#{2,6}\s+(how to cite|citation|citing|supporting)\b", text
    )
end

"""
    _apply_standard_sections(target_dir, inputs)

Inject or refresh the managed README standard-sections block.

Returns `(action, changed)` where action is `:refreshed` (markers present),
`:injected` (appended to a README carrying none of these sections yet), or
`:skipped` (no README, missing inputs, or a marker-less README that already has
bespoke prose for one of them — migrating that is a deliberate per-repo wording
change, #67). As in `_apply_badges`, only the marked region is rewritten.
"""
function _apply_standard_sections(
        target_dir::AbstractString, inputs::NamedTuple;
        org_branding::Bool = false
    )
    readme = joinpath(target_dir, "README.md")
    isfile(readme) || return (:skipped, false)
    pkg = inputs.PACKAGE
    org = inputs.ORG
    repo = inputs.REPO
    (pkg === nothing || org === nothing || repo === nothing) &&
        return (:skipped, false)
    body = _render_standard_sections(
        String(pkg), String(org), String(repo);
        doi = inputs.DOI, org_branding = org_branding
    )
    block = STANDARD_SECTIONS_START * "\n" * _STANDARD_SECTIONS_HEADER *
        "\n\n" * body * STANDARD_SECTIONS_END
    text = read(readme, String)
    si = findfirst(STANDARD_SECTIONS_START, text)
    ei = findlast(STANDARD_SECTIONS_END, text)
    if si !== nothing && ei !== nothing && first(ei) > last(si)
        new = text[1:(first(si) - 1)] * block * text[(last(ei) + 1):end]
        new == text && return (:refreshed, false)
        write(readme, new)
        return (:refreshed, true)
    end
    # No markers: append only to a README with none of these sections yet.
    # Bespoke prose is left untouched (#67).
    _has_managed_section_heading(text) && return (:skipped, false)
    endswith(text, "\n") || (text *= "\n")
    write(readme, text * "\n" * block * "\n")
    return (:injected, true)
end

# --- package-owned CITATION.cff --------------------------------------------
#
# A Citation File Format (https://citation-file-format.github.io) seed so
# GitHub renders a "Cite this repository" widget and the managed "How to cite"
# section has a file to point at. Package-owned and write-once, so a package's
# real author list, DOI and version are preserved (#67). Unlike `LICENSE`, both
# `scaffold` and `update` seed it when absent (#322): the section pointing at
# it is re-rendered by `update` regardless, so an unseeded file would leave a
# pre-CITATION adopter with a dangling link.

# The CFF `authors:` list from the author display names, one `- name:` entity
# entry each — a valid starting point the package refines into person
# `family-names`/`given-names`.
function _cff_authors(authors::Union{Nothing, AbstractString})
    names = authors === nothing ? String[] :
        [
            String(strip(a))
            for a in split(authors, r",|\band\b") if !isempty(strip(a))
        ]
    isempty(names) && (names = ["Author One", "Author Two"])
    return join(("  - name: \"" * n * "\"" for n in names), "\n")
end

# Render a package-owned CITATION.cff seed. `doi` fills the `doi:` field when
# known; otherwise it is omitted entirely, which is valid CFF, rather than
# carrying a placeholder value.
function _render_citation_cff(
        pkg::AbstractString, repo::AbstractString,
        authors::Union{Nothing, AbstractString},
        doi::Union{Nothing, AbstractString}
    )
    doi_line = doi === nothing ? "" : "doi: \"" * doi * "\"\n"
    return string(
        "cff-version: 1.2.0\n",
        "message: \"If you use this software, please cite it using these ",
        "metadata.\"\n",
        "title: \"", pkg, ".jl\"\n",
        "type: software\n",
        "authors:\n", _cff_authors(authors), "\n",
        "repository-code: \"https://github.com/", repo, "\"\n",
        "url: \"https://github.com/", repo, "\"\n",
        doi_line
    )
end

# Seed a package-owned CITATION.cff, write-once (like `_apply_license`): returns
# `:preserved` when one already exists, `:skipped` when the inputs are unknown,
# `:created` when freshly written.
function _apply_citation_cff(target_dir::AbstractString, inputs::NamedTuple)
    dest = joinpath(target_dir, "CITATION.cff")
    isfile(dest) && return :preserved
    pkg = inputs.PACKAGE
    repo = inputs.REPO
    (pkg === nothing || repo === nothing) && return :skipped
    write(
        dest, _render_citation_cff(
            String(pkg), String(repo),
            inputs.AUTHORS, inputs.DOI
        )
    )
    return :created
end

# --- managed [workspace] stanza in the root Project.toml -------------------
#
# The root Project.toml is package-owned, but the `[workspace]` table that
# makes the `test` and `docs` sub-projects share the root manifest is part of
# the standard. Injected once when absent and left alone thereafter, so a
# package may extend `projects` without it being reverted.

const WORKSPACE_PROJECTS = ["test", "docs"]

# Ensure the root Project.toml declares a `[workspace]` table. Returns
# `:injected` when one was appended, `:preserved` when already present, or
# `:skipped` when there is no Project.toml to amend.
function _apply_workspace(target_dir::AbstractString)
    proj = joinpath(target_dir, "Project.toml")
    isfile(proj) || return :skipped
    text = read(proj, String)
    occursin(r"(?m)^\[workspace\]", text) && return :preserved
    projects = join(("\"" * p * "\"" for p in WORKSPACE_PROJECTS), ", ")
    stanza = "\n[workspace]\nprojects = [" * projects * "]\n"
    endswith(text, "\n") || (text *= "\n")
    write(proj, text * stanza)
    return :injected
end

# --- managed .gitignore block (package additions preserved) ----------------
#
# `.gitignore` was once fully managed: `update` copied it verbatim, dropping a
# package's own ignore-rule additions on the next sync (#65). It now follows
# the managed-block pattern of the README badges. Anything outside the markers
# is left untouched, including a legacy marker-less file, which is kept as a
# package-owned tail below the freshly-inserted block.

const GITIGNORE_START = "# managed:start"
const GITIGNORE_END = "# managed:end"

# Render the managed `.gitignore` body (without markers) from the bundled
# template, substituting placeholders (currently `{{TUTORIALS_SUBDIR}}`).
function _render_gitignore(inputs::NamedTuple)
    from = joinpath(_templates_dir(), ".gitignore")
    isfile(from) || error("missing bundled template .gitignore at $from")
    return _substitute(read(from, String), inputs, from)
end

"""
    _apply_gitignore(target_dir, inputs)

Apply the managed `.gitignore` block to `target_dir`.

Returns `(action, changed)` where action is `:created`, `:injected`
(markers added to an existing file, e.g. on first run of a kit version
with this fix), or `:refreshed` (markers already present; only the
marked region is touched). Mirrors `_apply_badges`.
"""
function _apply_gitignore(target_dir::AbstractString, inputs::NamedTuple)
    path = joinpath(target_dir, ".gitignore")
    body = _render_gitignore(inputs)
    # The header lives inside the marker pair so the whole block is replaced as
    # one unit on refresh. Before the start marker it would sit in the
    # preserved prefix and be duplicated on each `update`.
    block = GITIGNORE_START * "\n" *
        "# MANAGED by EpiAwarePackageTools.scaffold — do not edit by hand.\n" *
        "# Standard ignore rules live between the markers below and are\n" *
        "# replaced on every update. Add package-specific rules after the\n" *
        "# closing marker — they are preserved across updates.\n" *
        body * GITIGNORE_END
    if !isfile(path)
        write(path, block * "\n")
        return (:created, true)
    end
    text = read(path, String)
    # `findlast` for the closing marker, so the real terminator is found even
    # if the package-owned tail mentions the marker text.
    si = findfirst(GITIGNORE_START, text)
    ei = findlast(GITIGNORE_END, text)
    if si !== nothing && ei !== nothing && first(ei) > last(si)
        new = text[1:(first(si) - 1)] * block * text[(last(ei) + 1):end]
        new == text && return (:refreshed, false)
        write(path, new)
        return (:refreshed, true)
    end
    # No markers yet (a pre-#65 copy, or hand-written): insert the block at the
    # top and keep what was there as the package-owned tail.
    new = block * "\n\n" * text
    write(path, new)
    return (:injected, true)
end

# --- managed .git-blame-ignore-revs header (per-repo SHAs preserved) -------
#
# A new managed file (the Runic migration): only the explanatory header is
# managed, since each repo's own one-shot reformat commit has its own SHA.
# Follows the same managed-block pattern as `.gitignore` so the header stays
# current while the SHA list below it — package-owned, appended by hand on
# the reformat commit — is never touched by `scaffold`/`update`.

const GIT_BLAME_IGNORE_START = "# managed:start"
const GIT_BLAME_IGNORE_END = "# managed:end"

# Render the managed `.git-blame-ignore-revs` header (without markers) from
# the bundled template.
function _render_git_blame_ignore()
    from = joinpath(_templates_dir(), ".git-blame-ignore-revs")
    isfile(from) || error("missing bundled template .git-blame-ignore-revs at $from")
    return read(from, String)
end

"""
    _apply_git_blame_ignore(target_dir)

Apply the managed `.git-blame-ignore-revs` header block to `target_dir`.

Returns `(action, changed)` where action is `:created`, `:injected` (markers
added to an existing file), or `:refreshed` (markers already present; only
the marked region is touched). Mirrors `_apply_gitignore`.
"""
function _apply_git_blame_ignore(target_dir::AbstractString)
    path = joinpath(target_dir, ".git-blame-ignore-revs")
    body = _render_git_blame_ignore()
    block = GIT_BLAME_IGNORE_START * "\n" *
        "# MANAGED by EpiAwarePackageTools.scaffold — do not edit between\n" *
        "# the markers. Add a reformat commit's SHA after the closing\n" *
        "# marker — it is preserved across updates.\n" *
        body * GIT_BLAME_IGNORE_END
    if !isfile(path)
        write(path, block * "\n")
        return (:created, true)
    end
    text = read(path, String)
    si = findfirst(GIT_BLAME_IGNORE_START, text)
    ei = findlast(GIT_BLAME_IGNORE_END, text)
    if si !== nothing && ei !== nothing && first(ei) > last(si)
        new = text[1:(first(si) - 1)] * block * text[(last(ei) + 1):end]
        new == text && return (:refreshed, false)
        write(path, new)
        return (:refreshed, true)
    end
    # No markers yet (hand-written, or a pre-managed file): insert the block
    # at the top and keep what was there as the package-owned tail.
    new = block * "\n\n" * text
    write(path, new)
    return (:injected, true)
end

# --- managed agent-file blocks (package additions preserved) ---------------
#
# `AGENTS.md` carries links to the docs an agent should read; `CLAUDE.md` just
# points at `AGENTS.md`. Neither restates a standard: a copy drifts from the
# page it was copied from. A package's own notes go after the closing marker
# and are preserved, exactly as with `.gitignore` and the README sections.

# Both files are auto-loaded into an agent's context in every adopting
# package, so every line spent on provenance competes with the links that are
# the point of the file. The whole note is therefore the word MANAGED inside
# the start marker: enough to stop someone editing the block by hand, and the
# rest (which template to edit, that notes below the end marker survive) is on
# the infrastructure docs page, where whoever needs it is already looking.
#
# The marker is matched on its prefix, so a package carrying either older form
# — the bare marker plus a five-line header comment, or the one-line marker
# with the longer note — is rewritten to this one on the next sync.
const AGENTS_START_PREFIX = "<!-- epiaware-standards:start"
const AGENTS_END = "<!-- epiaware-standards:end -->"
const AGENTS_START = AGENTS_START_PREFIX *
    " MANAGED by EpiAwarePackageTools.scaffold -->"

# Render a managed agent-file body (without markers) from the bundled template.
# `{{PACKAGE}}`/`{{DOCS_URL}}` are substituted so the block can point at this
# package's own docs alongside the org-wide ones.
function _render_agent_file(template, inputs)
    from = joinpath(_templates_dir(), template)
    isfile(from) || error("missing bundled template $template at $from")
    return _substitute(read(from, String), inputs, from)
end

"""
    _apply_agent_file(target_dir, template, inputs)

Apply a managed pointer block to `target_dir/\$template`.

`AGENTS.md` points at the human-facing docs; `CLAUDE.md` points at `AGENTS.md`.
Neither restates a standard, so there is one copy of each and it cannot drift.

Returns `(action, changed)` where action is `:created`, `:injected` (markers
added to a file the package already had, whose content is kept below the
block), or `:refreshed` (markers present; only the marked region is touched).
Mirrors `_apply_gitignore`.
"""
function _apply_agent_file(target_dir::AbstractString, template, inputs)
    path = joinpath(target_dir, template)
    block = AGENTS_START * "\n\n" *
        _render_agent_file(template, inputs) * AGENTS_END
    if !isfile(path)
        write(path, block * "\n")
        return (:created, true)
    end
    text = read(path, String)
    # Matched on the prefix, so both the current one-line marker and the older
    # bare `<!-- epiaware-standards:start -->` are found; everything from there
    # to the end marker is replaced, which retires the old header comment.
    si = findfirst(AGENTS_START_PREFIX, text)
    ei = findlast(AGENTS_END, text)
    if si !== nothing && ei !== nothing && first(ei) > last(si)
        new = text[1:(first(si) - 1)] * block * text[(last(ei) + 1):end]
        new == text && return (:refreshed, false)
        write(path, new)
        return (:refreshed, true)
    end
    # No markers: a hand-written file. Put the block on top and keep what was
    # there as the package-owned tail rather than dropping it.
    write(path, block * "\n\n" * text)
    return (:injected, true)
end

# Whether a template is emitted for the requested `ad` value: `:always` always,
# `:ad_only` when `ad = true`, `:noad_only` when `ad = false`.
function _ad_selected(t::Template, ad::Bool)
    t.ad === :always && return true
    t.ad === :ad_only && return ad
    t.ad === :noad_only && return !ad
    error("template $(t.src) has unknown ad mode $(t.ad)")
end

# Whether a template is emitted for the requested `benchmarks` value:
# `:always` always, `:bench_only` only when `benchmarks = true`.
function _bench_selected(t::Template, benchmarks::Bool)
    t.bench === :always && return true
    t.bench === :bench_only && return benchmarks
    error("template $(t.src) has unknown bench mode $(t.bench)")
end

"""
    _detect_benchmarks(target_dir)

Whether a repo already has benchmarks enabled, so a resync (`update` with no
`benchmarks` kwarg) preserves an adopter's opt-in instead of stripping their
benchmark CI/suite/page (the #72 trap).

The scheduled template-sync bakes `benchmarks = {{BENCHMARKS}}` into its
`update` call, but a repo scaffolded before the flag re-passes nothing, so the
state must also be recoverable from the destination. The managed benchmark CI
workflows are the marker. A never-scaffolded target has neither and so
defaults to opt-out.
"""
function _detect_benchmarks(target_dir::AbstractString)
    wf = joinpath(target_dir, ".github", "workflows")
    return isfile(joinpath(wf, "benchmark.yaml")) ||
        isfile(joinpath(wf, "benchmark-history.yaml"))
end

"""
    _detect_downgrade_compat(target_dir)

Whether a repo keeps the opt-in `downgrade-compat` CI job, so a resync
(`update` with no `downgrade_compat` kwarg) does not reintroduce a job the
package deliberately removed (#121).

A package pinned to a Julia floor, or one adopting an unregistered
`[sources]`-pinned dependency, can never resolve `julia-downgrade-compat`, so
it disables the job in its `test.yaml`; regenerating it on every sync would
reintroduce a permanently-red job. The committed `downgrade.yml` caller is the
marker. A target with no `test.yaml` defaults to keeping the job.
"""
function _detect_downgrade_compat(target_dir::AbstractString)
    tf = joinpath(target_dir, ".github", "workflows", "test.yaml")
    isfile(tf) || return true
    return occursin("downgrade.yml", read(tf, String))
end

# The managed AD-harness driver (`test/ad/setup.jl`) and the opt-out marker a
# package writes into its own copy to keep a package-owned driver (#162).
const _AD_SETUP_DEST = "test/ad/setup.jl"
const _AD_SETUP_OWNED_MARKER = "EPIAWARE_AD_SETUP_OWNED"

"""
    _detect_ad_setup_owned(target_dir)

Whether a package has opted its AD-harness driver (`test/ad/setup.jl`) out
of kit management by marking it package-owned (#162).

`test/ad/setup.jl` is force-managed: `update()` overwrites it with the generic
driver, which assumes the package's `ADFixtures` registry satisfies the current
`ADRegistry` contract (its `scenarios` accepts a `category` keyword). A package
whose `ADFixtures` predates that contract would `MethodError` on `category=`,
so it must keep its own driver while it migrates. A comment containing
`$(_AD_SETUP_OWNED_MARKER)` in the committed file tells `update()` to preserve
it. An unmarked file is managed as before.
"""
function _detect_ad_setup_owned(target_dir::AbstractString)
    f = _dest_path(target_dir, _AD_SETUP_DEST)
    isfile(f) || return false
    return occursin(_AD_SETUP_OWNED_MARKER, read(f, String))
end

# The generic ownership marker any managed file may carry to opt out of kit
# management (#224), generalising `test/ad/setup.jl`'s file-specific marker.
const _MANAGED_OVERRIDE_MARKER = "EPIAWARE_MANAGED_OVERRIDE"

"""
    _detect_managed_override(target_dir, dest, rendered)

Whether the template-emitted managed file at `dest` has been marked
package-owned, so `update()` preserves it rather than resyncing it
(#224).

Managed files always resync, which is what keeps an adopter on the current
standard. A package that must keep its own version of one says so in the file,
by putting `$(_MANAGED_OVERRIDE_MARKER)` in a comment. The match is a plain
case-sensitive `occursin`, so a mis-cased marker does nothing.

This governs whole template-emitted files only. The marker-delimited regions
the kit injects into otherwise package-owned files (the `.gitignore` block, the
README badge and standard-sections blocks, `[workspace]`) are refreshed by
their own appliers, which never consult this.

`rendered` is the freshly rendered template for `dest`, required rather than
defaulted: a managed template that itself contained the marker literal would
otherwise hand every adopter a self-preserving copy and the kit would stop
managing its own file everywhere. So a render carrying the marker keeps the
file managed, and the test suite asserts no bundled template renders it.

`test/ad/setup.jl` also still honours its original marker
`$(_AD_SETUP_OWNED_MARKER)` (#162); either opts that file out.

`scaffold`/`scaffold_generate` (`force = true`) ignore the marker, so a new
package always starts managed. The marker opts a file out of resyncing, not of
retirement: a `RETIRED_PATHS` entry is still deleted.
"""
function _detect_managed_override(
        target_dir::AbstractString,
        dest::AbstractString, rendered::AbstractString
    )
    f = _dest_path(target_dir, dest)
    isfile(f) || return false
    occursin(_MANAGED_OVERRIDE_MARKER, rendered) && return false
    occursin(_MANAGED_OVERRIDE_MARKER, read(f, String)) && return true
    return dest == _AD_SETUP_DEST && _detect_ad_setup_owned(target_dir)
end

# The opt-in `downgrade-compat` caller job spliced into `test.yaml` after the
# `test` job's `secrets:` line (#121), empty when a package opts out. Carries
# no trailing newline of its own — the template file keeps the single one the
# pre-commit end-of-file-fixer requires. Built with the org interpolated and
# the seed ref, which `_preserve_reusable_refs` overwrites with the
# destination's Dependabot-bumped ref on every `update`.
function _downgrade_compat_job(org::AbstractString, keep::Bool)
    keep || return ""
    return string(
        "\n\n  downgrade-compat:\n",
        "    uses: ", org, "/.github/.github/workflows/downgrade.yml@",
        _DOWNGRADE_SEED_REF, "\n",
        "    with:\n",
        # The reusable defaults to '1.10', where the `[sources]` kit pin is
        # silently ignored (#246, #115).
        "      julia_version: ", _JULIA_DOWNGRADE_VERSION, "\n",
        "    secrets: inherit  # pragma: allowlist secret"
    )
end

"""
    _detect_benchmark_history_parked(target_dir)

Whether a package has parked `benchmark-history.yaml`'s push/tag triggers, so
a resync (`update`) preserves that state instead of re-enabling a permanently
failing `history` run (#153).

benchpkg installs the package into a temp environment where a `[sources]` pin
does not apply, so an unregistered `[sources]`-pinned dependency — currently
every adopter, via the unregistered kit itself — never resolves there and every
push/tag-triggered `history` run fails. Parking drops the `push`/`tags`
triggers, keeping only `workflow_dispatch`, until the package is registered.
The committed `on:` block is the marker: parked iff it carries no `push:`. A
target with no file defaults to the full triggers.
"""
function _detect_benchmark_history_parked(target_dir::AbstractString)
    f = joinpath(target_dir, ".github", "workflows", "benchmark-history.yaml")
    isfile(f) || return false
    return !occursin(r"(?m)^  push:", read(f, String))
end

# The `benchmark-history.yaml` `on:` trigger block (#153): the full
# push/tags/dispatch triggers by default, or a `workflow_dispatch`-only block
# when the package has parked the workflow. Self-heals to the full triggers
# once the park is removed.
function _benchmark_history_triggers(parked::Bool)
    parked && return string(
        "  # push/tags parked until this package is registered: an\n",
        "  # unregistered `[sources]`-pinned dependency never resolves in\n",
        "  # benchpkg's temp environment, so a push/tag `history` run always\n",
        "  # fails (#153). Restore the push/tags triggers once registered.\n",
        "  workflow_dispatch:"
    )
    return string(
        "  push:\n",
        "    branches: [main]\n",
        "    tags: ['v*']\n",
        "  workflow_dispatch:"
    )
end

"""
    _apply(target_dir; managed_only, force, ad, benchmarks,
        downgrade_compat, inputs)

Shared worker for `scaffold`/`update`.

`managed_only` restricts to managed templates (the `update` path). `force`
overwrites package-owned files too (only meaningful for `scaffold`). `ad`
selects the AD-enabled or AD-disabled standard; `benchmarks` gates the opt-in
benchmark CI/suite/docs page; `downgrade_compat` gates the opt-in
`downgrade-compat` CI job.

Returns a `(created, updated, preserved, removed, warnings)` manifest of
destination paths. `removed` holds the retired managed paths cleaned up (see
`RETIRED_PATHS`); `warnings` the non-fatal issues raised while applying, e.g. a
diverged-but-unmarked `test/ad/setup.jl` about to be overwritten.
"""
function _apply(
        target_dir::AbstractString; managed_only::Bool, force::Bool,
        ad::Bool, benchmarks::Bool, downgrade_compat::Bool, inputs::NamedTuple
    )
    isdir(target_dir) || error("target_dir $target_dir does not exist")
    # The #242 opt-in, read once so every branding surface (README section,
    # docs footer, logo asset) agrees. It must be the value the config holds
    # when this run *finishes*: `docs/docs_config.jl` is package-owned, and
    # `force` re-lays it, resetting the flag to the template default. Reading
    # the destination naively would brand the footer from the old value while
    # `force` reset the flag underneath.
    org_branding = (force && !managed_only) ? false :
        _detect_org_branding(target_dir)
    # The AD/benchmarks/downgrade-compat flags are exposed as substitution
    # values so the scheduled template-sync re-applies the standard with the
    # same choices the package adopted. `BENCHMARKS_NAV` is the top-level
    # "Benchmarks" group, present when either `benchmarks` or `ad` is on.
    bench_nav = _benchmarks_nav(benchmarks, ad)
    # The `benchmark-history.yaml` `on:` triggers preserve a package's parked
    # state across a resync (#153), detected from the committed workflow.
    inputs = merge(
        inputs,
        (
            AD = string(ad), BENCHMARKS = string(benchmarks),
            BENCHMARKS_NAV = bench_nav, BENCHMARK_PAGE = string(benchmarks),
            DOWNGRADE_COMPAT = string(downgrade_compat),
            DOWNGRADE_COMPAT_JOB = _downgrade_compat_job(
                inputs.ORG, downgrade_compat
            ),
            BENCHMARK_HISTORY_TRIGGERS = _benchmark_history_triggers(
                _detect_benchmark_history_parked(target_dir)
            ),
            AD_HEAVY_TUTORIALS = _ad_heavy_tutorials(ad),
            AD_TUTORIAL_STUBS = _ad_tutorial_stubs(ad),
            AD_TUTORIALS_NAV = _ad_tutorials_nav(ad),
            # The AD-comparison page's registration in the sibling
            # `docs/src/benchmarks/` pipeline, not the Tutorials one above;
            # its nav entry is part of `BENCHMARKS_NAV`.
            AD_HEAVY_BENCHMARKS = _ad_heavy_benchmarks(ad),
            AD_BENCHMARK_STUBS = _ad_benchmark_stubs(ad),
            EXTENSIONS_NAV = _extensions_nav(target_dir),
            AD_DOCS_DEPS = _ad_docs_deps(ad, inputs.ADFIXTURES_UUID),
            AD_DOCS_SOURCES = _ad_docs_sources(ad),
            AD_DOCS_COMPAT = _ad_docs_compat(ad),
            BENCH_DOCS_DEPS = _bench_docs_deps(benchmarks),
            BENCH_DOCS_COMPAT = _bench_docs_compat(benchmarks),
            ORG_FOOTER_MESSAGE = _org_footer_message(org_branding),
        )
    )
    src_dir = _templates_dir()
    created = String[]
    updated = String[]
    preserved = String[]
    warnings = String[]
    for t in SCAFFOLD_TEMPLATES
        managed_only && !t.managed && continue
        _ad_selected(t, ad) || continue
        _bench_selected(t, benchmarks) || continue
        from = joinpath(src_dir, t.src)
        isfile(from) || error("missing bundled template $(t.src) at $from")
        to = _dest_path(target_dir, t.dest)
        exists = isfile(to)
        # A committed file carrying an ownership marker is preserved rather
        # than overwritten (#224); `force` still re-lays it. The fresh render
        # is passed in so a template that itself carried the marker literal
        # cannot hand every adopter a self-preserving file — see
        # `_detect_managed_override`.
        rendered = exists && !force && t.managed ?
            _render(from, t.substitute, inputs) : nothing
        if rendered !== nothing &&
                _detect_managed_override(target_dir, t.dest, rendered)
            push!(preserved, to)
            continue
        end
        # An unmarked AD driver that diverges from a fresh render is probably
        # a customisation nobody marked. It is still overwritten, like every
        # managed file, but warns first: this is the one file where a clobber
        # is silently fatal (a `MethodError` in every AD CI job).
        #
        # Deliberately not generalised (#224): divergence is the normal state
        # of a managed file on an adopter running an older kit, so a generic
        # check cannot tell "customised" from "behind" and would warn on every
        # file on every sync.
        if rendered !== nothing && t.dest == _AD_SETUP_DEST
            if read(to, String) != rendered
                msg = string(
                    _AD_SETUP_DEST,
                    " differs from the managed driver but carries no ",
                    "ownership marker — overwriting. If this divergence is ",
                    "intentional, add a comment containing \"",
                    _MANAGED_OVERRIDE_MARKER,
                    "\" to keep it across future update calls."
                )
                push!(warnings, msg)
                @warn msg
            end
        end
        # Package-owned files are written once and never overwritten (unless
        # `force`); managed files are always (re)written to remove drift.
        if exists && !t.managed && !force
            push!(preserved, to)
            continue
        end
        # `_emit` is about to drop the `with:` inputs of any caller job
        # repointed at a repo-local reusable workflow (#325).
        exists && t.managed &&
            _warn_local_caller_override!(warnings, to, t.dest)
        _emit(from, to, t.substitute, inputs)
        push!(exists ? updated : created, to)
    end
    # The managed docs nav base, spliced with the package's own extension
    # points read fresh from `docs/docs_config.jl` (already written above for
    # a fresh/forced scaffold, package-owned and untouched otherwise) --
    # see `_apply_pages`. Reported separately (`pages`), not mixed into
    # `created`/`updated`/`preserved`, as for every bespoke applier below.
    pages_action, pages_warning = _apply_pages(target_dir, inputs)
    if pages_warning !== nothing
        push!(warnings, pages_warning)
        @warn pages_warning
    end
    # The README body is package-owned, but the badge block between the markers
    # is managed. Reported separately (`readme`) so the template manifest stays
    # template-driven, as for every applier below.
    readme = joinpath(target_dir, "README.md")
    repo = inputs.REPO
    pkg = inputs.PACKAGE
    readme_action = :skipped
    if repo !== nothing && pkg !== nothing
        lic = String(inputs.LICENSE)
        readme_action = first(
            _apply_badges(
                readme, repo, pkg; ad = ad, license = lic,
                docs_url = inputs.DOCS_URL, doi = inputs.DOI,
                zenodo_badge = inputs.ZENODO_BADGE
            )
        )
    end
    # The README title's inline logo tag is managed like the badge block:
    # added once a `docs/src/assets/logo.svg` exists, left alone otherwise.
    logo_action = pkg === nothing ? :skipped : _apply_logo_title(target_dir, pkg)
    # Contributing / How to cite / Code of conduct, refreshed within their
    # markers so a package's own body sections are preserved.
    sections_action = first(
        _apply_standard_sections(
            target_dir, inputs;
            org_branding = org_branding
        )
    )
    # CITATION.cff is package-owned and write-once, so a package's real
    # citation metadata is preserved. Unlike LICENSE, `update` seeds it too
    # (#322): the managed "How to cite" section links to it on every sync, so
    # an adopter predating citation seeding would otherwise carry a dangling
    # link no `update` could ever resolve.
    citation_action = _apply_citation_cff(target_dir, inputs)
    # The per-extension docs pages are package-owned and write-once. Unlike
    # CITATION.cff, `update` does not seed them, only `scaffold` does. Since
    # `_apply_pages` now writes the `Extensions` nav group from the current
    # `[extensions]` table on every sync, a package that declares one between
    # scaffolds gets the nav entry from `update` before the page exists; the
    # docs build's `_strip_extensions_nav` drops any such entry until the page
    # is written, the same graceful handling any missing page gets (#319).
    ext_created, ext_preserved = managed_only ? (String[], String[]) :
        _apply_extension_pages(
            target_dir, inputs; force = force
        )
    ext_unlinked = _extension_pages_unlinked(target_dir)
    ext_unlinked === nothing || push!(warnings, ext_unlinked)
    # LICENSE is package-owned and write-once: `update` never touches it, so a
    # deliberate licence stands.
    license_action = managed_only ? :skipped : _apply_license(target_dir, inputs)
    # Injected into the package-owned root Project.toml when absent, on both
    # scaffold and update, and preserved thereafter.
    workspace_action = _apply_workspace(target_dir)
    # A package's `[compat] julia` is package-owned, but the managed test
    # infrastructure needs 1.11 (#246), so a package still claiming 1.10 is
    # claiming support the standard cannot deliver. Better said here than
    # discovered as an `UndefVarError` on a runner, or as a green LTS job
    # quietly testing a stale kit resolved from the registry.
    proj_path = joinpath(target_dir, "Project.toml")
    if isfile(proj_path)
        m = match(r"(?m)^julia\s*=\s*\"([^\"]*)\"", read(proj_path, String))
        if m !== nothing
            below = _julia_compat_below_floor(String(something(m.captures[1])))
            if below !== nothing
                push!(
                    warnings,
                    string(
                        "Project.toml claims julia = \"",
                        something(m.captures[1]), "\", which admits ", below,
                        ", but the managed standard needs ", _JULIA_FLOOR,
                        ": `[sources]` (how test/Project.toml pins the kit) is ",
                        "silently ignored before 1.11, so the tests resolve ",
                        "the registered kit instead of the pinned rev. Set ",
                        "julia = \"", _JULIA_COMPAT, "\" (#246)."
                    )
                )
            end
        end
    end
    # A package may pick its own Julia matrix (#73) and the kit does not
    # overwrite it, but a leg below the floor tests a kit resolved from the
    # registry rather than the pinned rev. Scanned across every managed caller,
    # not just `test.yaml`: `codecoverage.yaml` names a version of its own.
    wf_dir = joinpath(target_dir, ".github", "workflows")
    if isdir(wf_dir)
        for f in sort(readdir(wf_dir))
            endswith(f, ".yaml") || endswith(f, ".yml") || continue
            legs = _julia_versions_below_floor(read(joinpath(wf_dir, f), String))
            isempty(legs) || push!(
                warnings,
                string(
                    ".github/workflows/", f, " tests Julia ",
                    join(legs, ", "), ", below the ", _JULIA_FLOOR,
                    " the managed standard needs: `[sources]` is ignored there, ",
                    "so that leg resolves the registered kit rather than the ",
                    "pinned rev and tests a stale kit while appearing to test ",
                    "this one. Drop it (#246)."
                )
            )
        end
    end
    # A Julia stdlib is not implicitly available in a test environment: it
    # needs declaring as a dep, or reaching transitively. A `using <stdlib>`
    # added without one makes the whole env fail to resolve with an opaque
    # error, invisible until CI reds (#263). test/Project.toml is
    # package-owned, so a warning naming the exact stdlib is the durable fix.
    stdlibs = _undeclared_test_stdlibs(target_dir)
    isempty(stdlibs) || push!(
        warnings,
        string(
            "test/ uses the standard librar",
            length(stdlibs) == 1 ? "y " : "ies ", join(stdlibs, ", "),
            " but ", length(stdlibs) == 1 ? "it is" : "they are",
            " declared in neither test/Project.toml nor Project.toml. A Julia ",
            "stdlib must be an explicit dep to load in the test environment, ",
            "so the whole env fails to resolve on every platform with an ",
            "opaque error. Add ", length(stdlibs) == 1 ? "it" : "them",
            " to test/Project.toml `[deps]` (#263)."
        )
    )
    # An existing `ad = true` adopter's package-owned `docs/docs_config.jl`
    # may predate the `ad-comparison.jl` split (#299/#305): `update` cannot
    # add the missing HEAVY_BENCHMARKS/BENCHMARK_STUBS registration itself,
    # so surface the gap instead of leaving the new page silently unbuilt.
    gap = _ad_benchmarks_config_gap(target_dir, ad)
    if gap !== nothing
        push!(warnings, gap)
        @warn gap
    end
    # A bespoke, preserved `docs/pages.jl` has the same gap for the
    # `{{BENCHMARKS_NAV}}` entry — see `_benchmarks_nav_gap`. A managed one
    # already carries it fresh from `_apply_pages`, above.
    nav_gap = _benchmarks_nav_gap(target_dir, benchmarks, ad)
    if nav_gap !== nothing
        push!(warnings, nav_gap)
        @warn nav_gap
    end
    # `docs/Project.toml` is write-once too, so a dep this kit version drops
    # from `_ad_docs_deps` stays in an existing adopter's env — see
    # `_ad_docs_deps_gap`.
    deps_gap = _ad_docs_deps_gap(target_dir, ad, inputs.ADFIXTURES_UUID)
    if deps_gap !== nothing
        push!(warnings, deps_gap)
        @warn deps_gap
    end
    # A backend added to `_AD_BACKENDS` since the package was scaffolded
    # reaches the managed ad.yaml matrix but not the package-owned test items,
    # so its CI job would report green on zero tests — see
    # `_ad_backend_tag_gap`.
    tag_gap = _ad_backend_tag_gap(target_dir, ad)
    if tag_gap !== nothing
        push!(warnings, tag_gap)
        @warn tag_gap
    end
    # The managed files converge on the current standard; the package's own
    # prose about that standard does not, and nothing else reports it — see
    # `_stale_prose_gap`.
    prose_gap = _stale_prose_gap(target_dir)
    if prose_gap !== nothing
        push!(warnings, prose_gap)
        @warn prose_gap
    end
    # Managed between markers so package-owned additions below the block
    # survive `update` (#65).
    gitignore_action = first(_apply_gitignore(target_dir, inputs))
    # Only the header is managed; the SHA list below it is package-owned, one
    # entry per repo's own Runic reformat commit.
    git_blame_ignore_action = first(_apply_git_blame_ignore(target_dir))
    # `AGENTS.md` is managed the same way: the docs pointers live between the
    # markers, a package's own notes below them. `CLAUDE.md` just points at
    # `AGENTS.md`.
    agents_action = first(_apply_agent_file(target_dir, "AGENTS.md", inputs))
    _apply_agent_file(target_dir, "CLAUDE.md", inputs)
    # Retired files are deleted, not just left unwritten, so a sync converges
    # on the current standard rather than accreting dead infra (#185).
    removed = _remove_retired(target_dir)
    # Written when branding is on, removed when off, so a package that opts out
    # carries no EpiAware asset (#242).
    org_branding_action = _apply_org_branding(target_dir, org_branding)
    return (
        created = created, updated = updated, preserved = preserved,
        removed = removed, readme = readme_action, license = license_action,
        workspace = workspace_action, gitignore = gitignore_action,
        git_blame_ignore = git_blame_ignore_action,
        agents = agents_action,
        logo = logo_action, standard_sections = sections_action,
        citation = citation_action, org_branding = org_branding_action,
        extension_pages = (created = ext_created, preserved = ext_preserved),
        pages = pages_action, warnings = warnings,
    )
end

# The non-JLL standard libraries shipped with the running Julia, read from
# `Sys.STDLIB` so the set tracks the Julia version rather than a hand-kept
# list. JLL wrappers are excluded: they arrive as transitive artefact deps and
# are never `using`d directly in a test.
function _julia_stdlibs()
    dir = Sys.STDLIB
    (dir isa AbstractString && isdir(dir)) || return Set{String}()
    entries = filter(readdir(dir)) do n
        !endswith(n, "_jll") && isdir(joinpath(dir, n))
    end
    return Set{String}(entries)
end

# Dep names in a Project.toml `[deps]` table. Empty when the file is absent or
# unparseable (an unsubstituted template is not valid TOML). A line scan rather
# than a TOML parse, matching how the rest of this file reads Project.toml.
function _declared_deps(path::AbstractString)
    isfile(path) || return Set{String}()
    names = Set{String}()
    in_deps = false
    for line in eachline(path)
        s = strip(line)
        if startswith(s, "[")
            in_deps = s == "[deps]"
            continue
        end
        in_deps || continue
        m = match(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=", s)
        m === nothing || push!(names, String(something(m.captures[1])))
    end
    return names
end

# Top-level module names introduced by `using`/`import` lines in Julia source.
# A line-level heuristic, not a full parse: it drops a trailing comment, a
# `: names` selection and an `as alias`, splits comma clauses, and takes the
# head of a dotted path (`A.B` -> `A`). It only ever feeds the known-stdlib
# filter, so an over-broad match cannot invent a warning for a non-stdlib name.
function _used_module_names(src::AbstractString)
    names = Set{String}()
    for line in eachline(IOBuffer(src))
        m = match(r"^\s*(?:using|import)\s+(.+)$", line)
        m === nothing && continue
        body = split(String(something(m.captures[1])), '#')[1]  # drop comment
        clause = split(body, ':')[1]                            # drop `: sel`
        for part in split(clause, ',')
            tok = strip(String(first(split(strip(part), r"\s+as\s+"))))
            head = String(first(split(tok, '.')))               # dotted head
            occursin(r"^[A-Za-z_]", head) && push!(names, head)
        end
    end
    return names
end

# Every package named in a resolved Manifest.toml — the full transitive set, so
# a stdlib pulled in by a declared dependency (never named in a `[deps]` line)
# still reads as available. Header lines are `[[deps.Name]]` (manifest format
# 2) or `[[Name]]` (format 1). Empty when the file is absent. A line scan, like
# `_declared_deps`, to stay dependency-free.
function _manifest_packages(path::AbstractString)
    isfile(path) || return Set{String}()
    names = Set{String}()
    for line in eachline(path)
        m = match(r"^\[\[(?:deps\.)?([A-Za-z_][A-Za-z0-9_]*)\]\]", strip(line))
        m === nothing || push!(names, String(something(m.captures[1])))
    end
    return names
end

# Standard libraries `using`d in a package's committed test sources but not
# available in the resolved test environment. Sorted; empty when test/ is
# absent. Drives the #263 scaffold/sync warning.
#
# Availability is judged against the resolved test/Manifest.toml, not the
# `[deps]` lines alone: a stdlib pulled in transitively (e.g. LinearAlgebra via
# Aqua/JET) is genuinely loadable and must not be flagged. A Manifest is
# gitignored, so it exists only in an instantiated env, which is where the
# warning is actionable anyway. Without one, no warning: a missed hint in a
# bare CI checkout buys zero false positives.
function _undeclared_test_stdlibs(target_dir::AbstractString)
    test_dir = joinpath(target_dir, "test")
    isdir(test_dir) || return String[]
    stdlibs = _julia_stdlibs()
    isempty(stdlibs) && return String[]
    available = _manifest_packages(joinpath(test_dir, "Manifest.toml"))
    isempty(available) && return String[]
    # `[deps]` names too, so a declared-but-not-yet-resolved dep is not flagged.
    available = union(
        available,
        _declared_deps(joinpath(test_dir, "Project.toml")),
        _declared_deps(joinpath(target_dir, "Project.toml"))
    )
    used = Set{String}()
    for (root, _, files) in walkdir(test_dir)
        for f in files
            endswith(f, ".jl") || continue
            for name in _used_module_names(read(joinpath(root, f), String))
                name in stdlibs && push!(used, name)
            end
        end
    end
    return sort!(collect(setdiff(used, available)))
end

"""
    scaffold(target_dir; force = false, ad = true, benchmarks = nothing,
        kwargs...)

Adopt the standard EpiAware package tooling in `target_dir` (a package root).

Writes the shipped standard configuration and test infrastructure so a package
adopts the whole kit in one call. Two kinds of file are written:

  - managed standard infra — always written (overwriting any existing copy):
    root dev config (`Taskfile.yml`, `.pre-commit-config.yaml`,
    `.gitattributes`, `.secrets.baseline`, `codecov.yml`), CI
    caller workflows + `.github/dependabot.yml` (which invoke the org reusables,
    including the opt-in per-backend `ad.yaml` matrix), and the test-infra
    drivers and
    isolated-env manifests (`test/package/quality.jl`, `test/jet/runtests.jl` +
    `test/jet/Project.toml`, `test/formatter/runtests.jl` +
    `test/formatter/Project.toml`, `test/ad/setup.jl`, `test/ad/runtests.jl`,
    `benchmark/run.jl`, `benchmark/compare.jl`).
  - package-owned skeletons — written only when absent, never overwritten:
    `test/runtests.jl`, `test/Project.toml` (the test env), `test/package/
    qa_config.jl` (the QA config values the managed testset reads), `LICENSE`
    (the `license`-selected licence text — see below),
    `docs/src/assets/logo.svg` (a placeholder logo —
    see the `logo` return value below), `test/ad/scenarios.jl` +
    `test/ad/Project.toml`, an `ADFixtures` registry skeleton implementing the
    `ADRegistry` contract (`test/ADFixtures/Project.toml` +
    `src/ADFixtures.jl`), `benchmark/benchmarks.jl` (the `SUITE`), and
    `CITATION.cff` (the citation metadata the managed "How to cite" README
    section points at — see the `citation` return value below). These
    are where a package's own unit tests, AD scenarios, registry, citation, and
    config values live.

Placeholders (`{{PACKAGE}}`, `{{AUTHORS}}`, `{{HOLDER}}`, `{{ORG}}`, `{{REPO}}`,
`{{REVIEWER}}`, `{{YEAR}}`) are filled by [`scaffold_inputs`](@ref): each
defaults from the target `Project.toml` or a sensible org default and is
overridable by keyword (e.g. `scaffold(dir; org = "MyOrg")`). No person, org, or
repo name is hardcoded in any template.

`LICENSE` is package-owned and write-once: the `license` keyword (an SPDX id,
one of `$(join(SUPPORTED_LICENSES, ", "))`, default `$(repr(DEFAULT_LICENSE))`)
selects the bundled licence text, written with `{{YEAR}}`/`{{HOLDER}}` filled
only when no `LICENSE` exists. [`update`](@ref) never rewrites it, so a package
that deliberately changes its licence is not reverted on a sync.

The managed `.github/workflows/Register.yml` triggers General Registry
registration from a `/register` comment or a `workflow_dispatch` run, gated on
the actor having write access. See [`setup_checklist`](@ref) for the rest of
the one-off manual setup a fresh repo needs.

`ad` controls whether the AD CI caller and AD test infrastructure are
scaffolded, so a numerical package opts in and a tooling package opts out. It
defaults to `true`. When `ad = true` two managed docs pages are written: the
AD-backends tutorial page, which reports which backends work and how to
configure and debug them, and its AD-comparison sibling under
`docs/src/benchmarks/`, which benchmarks what each backend costs. Both bodies
stay kit-current across syncs, while the scenarios, backends and broken/skip
declarations they report are read at docs-build time from the package-owned
`test/ADFixtures` registry (via [`ad_backend_support_table`](@ref)), and their
registration plus docs-env deps are seeded into the package-owned docs seeds.
When `ad = false` none of the AD infra is written, and the files whose content
depends on AD (`Taskfile.yml`, `codecov.yml`, `test/Project.toml`, the docs
seeds) are emitted in their no-AD variants. Pass the same `ad` value to
[`update`](@ref).

`benchmarks` controls the opt-in benchmark suite: the benchmark CI callers,
the `benchmark/` suite + compare script, and the docs performance-over-time
page (`docs/src/benchmarks/over-time.md`) with its nav entry and the two
package-owned prose hooks. It defaults to `nothing`, which detects the
target's current state from the benchmark workflows so re-scaffolding
preserves an opt-in; a fresh package has none, so the default is opt-out.
[`update`](@ref) detects and preserves the state.

`downgrade_compat` controls the opt-in `downgrade-compat` CI job in
`test.yaml`, which resolves the oldest compatible dep versions. A package
pinned to a Julia floor, or one depending on an unregistered
`[sources]`-pinned package the downgrade resolver cannot see, can never pass
it. It defaults to `nothing`, detecting the state from the committed
`test.yaml` so a resync preserves the choice; a fresh package keeps the job.
The `julia_versions` inputs are separately preserved as a package-owned
`with:` override (#121, see `_preserve_caller_with_inputs`).

The README body is package-owned, but the standard badge set is managed: a block
between `$(BADGES_START)` / `$(BADGES_END)` markers carries the docs/CI/coverage/
quality/license badges (plus per-backend AD CI + coverage badges when
`ad = true`), parameterised from `{{REPO}}`/`{{PACKAGE}}` (no owner/repo
hardcoded). The block is injected after the README's `# ` title when the markers
are absent and refreshed in place when present; nothing outside the markers is
touched. A missing README is created with a title and the block.

`.gitignore` follows the same managed-block pattern: the standard ignore rules
live between `$(GITIGNORE_START)` / `$(GITIGNORE_END)` markers and are
(re)rendered on every scaffold/update, but anything after the end marker is a
package-owned tail that is never touched — add your own ignore rules there. A
pre-existing `.gitignore` with no markers (e.g. one written by a kit version
before this behaviour existed) is treated the same way a legacy README is:
the managed block is inserted at the top and the whole existing file is kept
below as the tail, so nothing a package added is ever silently dropped.

`.git-blame-ignore-revs` follows the same managed-block pattern between
`$(GIT_BLAME_IGNORE_START)` / `$(GIT_BLAME_IGNORE_END)`, but only the
explanatory header is managed: the SHA list below the closing marker is
package-owned, one entry per repo's own formatting-only reformat commit
(e.g. the Runic migration's `style:` commit), so it is never rendered or
touched by `scaffold`/`update`.

`AGENTS.md` works the same way. The managed block between `$(AGENTS_START)`
and `$(AGENTS_END)` points at the human-facing docs rather than restating
them, and `CLAUDE.md` points at `AGENTS.md`. Both files reach an agent's
context in full on every session, so the block spends one word on saying it is
managed and leaves the rest to the infrastructure docs page. Package-specific
notes go after the end marker and survive every sync.

`docs_subdomain` selects how the docs site is hosted. The default (`nothing`)
is a project-pages deploy: `deploy_url = nothing`, so DocumenterVitepress
derives the base from the repo name and the site renders at
`epiaware.org/<Repo>.jl/` with no DNS to wire. Pass `docs_subdomain = true` for
the conventional `<pkg>.epiaware.org`, or a host string for a bespoke domain,
which also needs a DNS record and the repo's Pages custom domain set; until
both exist the site will not resolve. With no explicit choice the hosting is
recovered from the repo's existing `deploy_url`, so [`update`](@ref) preserves
a subdomain-hosted package and self-heals a drifted one (#123). Only a
never-scaffolded target falls back to the default, and the kit itself dogfoods
the opt-in path.

The three managed README sections (Contributing, How to cite, Code of conduct)
follow the same managed-block pattern between `$(STANDARD_SECTIONS_START)` /
`$(STANDARD_SECTIONS_END)`: appended to a freshly seeded README and refreshed
in place thereafter. A marker-less README that already carries bespoke prose
for one of them is left untouched (#67). `CITATION.cff` is package-owned and
write-once, seeded when absent by both `scaffold` and [`update`](@ref) and
never rewritten, so the real author list and DOI stand (#322).

`docs/pages.jl` (the docs nav tree) is a MANAGED base, not a package-owned
skeleton: it is regenerated in full on every `scaffold`/`update`, owning
group labels, ordering and placement, with four optional extension points a
package fills in via `docs/docs_config.jl` (`PACKAGE_TUTORIALS`,
`PACKAGE_SECTIONS`, `DEVELOPMENT_EXTEND_PAGE`, `GETTING_STARTED_FAQ`) rather
than editing the generated file (#170/#328/#354). The one exception in the
whole kit: unlike every other managed file, this is never reset by
`force` either. A committed file is only ever regenerated when it already
carries `_MANAGED_PAGES_MARKER` in its header (what a kit-generated file
always has) or does not exist yet; otherwise — a bespoke, forked `pages.jl`
from before this redesign — it is preserved untouched and a warning names
which of its existing top-level nav groups the generated base would not
reproduce, with the `PACKAGE_SECTIONS` snippet to carry them across. See
[`update`](@ref) for the same rule on a resync.

`force = true` overwrites the package-owned skeletons too, and lays every
managed file down fresh regardless of any `$(_MANAGED_OVERRIDE_MARKER)` marker
(see [`update`](@ref)), so a new package always starts fully managed.
`docs/pages.jl` is the one file `force` does not reset — see above.
`target_dir` must exist. Use [`update`](@ref) to re-apply only the managed
files later.

Returns a `(created, updated, preserved, removed, readme, license, workspace,
gitignore, git_blame_ignore, logo, standard_sections, citation, org_branding,
extension_pages, pages, warnings)` named tuple: destination paths newly
written, managed files overwritten, package-owned files left in place,
retired managed paths deleted (`RETIRED_PATHS`, #185), then the action taken
by each of the region appliers
(`:created`/`:injected`/`:refreshed`/`:preserved`/`:skipped`, as each
docstring records), the seeded per-extension docs pages as a
`(created, preserved)` pair of path vectors (#319), the `docs/pages.jl`
action (`:created`/`:refreshed`/`:unchanged`/`:preserved`, see above), and
non-fatal `warnings`.
"""
function scaffold(
        target_dir::AbstractString; force::Bool = false,
        ad::Bool = true, benchmarks::Union{Nothing, Bool} = nothing,
        downgrade_compat::Union{Nothing, Bool} = nothing,
        kwargs...
    )
    inputs = scaffold_inputs(target_dir; kwargs...)
    bench = benchmarks === nothing ? _detect_benchmarks(target_dir) : benchmarks
    dg = downgrade_compat === nothing ?
        _detect_downgrade_compat(target_dir) : downgrade_compat
    return _apply(
        target_dir; managed_only = false, force = force, ad = ad,
        benchmarks = bench, downgrade_compat = dg, inputs = inputs
    )
end

"""
    update(target_dir; ad = true, benchmarks = nothing,
        downgrade_compat = nothing, kwargs...)

Re-apply only the managed standard files to an already-adopted package and
report the drift.

`update` is `public`, not `export`ed (#294): call it qualified
(`EpiAwarePackageTools.update(...)`) or with an explicit
`using EpiAwarePackageTools: update`. An `export`ed generic verb collides with
a package's own same-named export (#173), and a `public`-not-`export`ed name is
never brought into scope by a bare `using`, so it cannot. The old name is kept
reachable as [`scaffold_update`](@ref).

This is the entry point the scheduled template-sync workflow calls: it rewrites
every managed standard file from the bundled templates, leaving package-owned
files (unit tests, `qa_config.jl`, AD scenarios, `benchmarks.jl`, `LICENSE`)
untouched, so a deliberate licence change is never reverted. `CITATION.cff` is
the one exception: it is seeded when absent, because the managed "How to cite"
section links to it on every sync and an adopter predating citation seeding
would otherwise carry a link `update` could never make resolve (#322).
Placeholder inputs resolve exactly as in [`scaffold`](@ref); pass the same
overrides to keep substitution stable across a sync.

`ad` must match the value the package was scaffolded with (default `true`).
`benchmarks` and `downgrade_compat` both default to `nothing`, detecting the
package's current state from the committed workflows so a resync preserves an
adopter's opt-in rather than stripping it, or reintroducing a job the package
deliberately removed (#121). Pass `true`/`false` to force either.

The README badge block, the managed `.gitignore` block, the
`.git-blame-ignore-revs` header, the standard-sections block and the README
logo title are all refreshed as in [`scaffold`](@ref), without the
package-owned parts of those files being touched.

Every managed file written from a template has a package-owned opt-out (#224):
`$(_MANAGED_OVERRIDE_MARKER)` in a comment tells `update()` to preserve it
(reporting it in `preserved`) instead of resyncing. Remove the marker to hand
management back. Use it sparingly — an overridden file no longer tracks the
standard, which is the point of the kit. Three deliberate limits:

  - It covers whole template-emitted files, not the marker-delimited regions
    the kit injects into package-owned files. Those are refreshed regardless;
    customise them by editing outside their markers.
  - It opts a file out of resyncing, not of retirement: a marked file on a
    retired path (`RETIRED_PATHS`) is still deleted.
  - It must appear in a comment, so the two managed JSON files
    (`docs/package.json`, `.secrets.baseline`) cannot carry it. The match is
    case-sensitive.

The AD-harness driver `test/ad/setup.jl` is where this began (#162) and still
honours its original marker `$(_AD_SETUP_OWNED_MARKER)` as well; either
preserves it. A committed driver that has diverged but carries no marker is
still overwritten, with a message in `warnings`, rather than clobbered
silently. That warning is scoped to this one file, whose clobber is silently
fatal: divergence is the normal state of a managed file on an adopter running
an older kit, so a generic check would fire on every sync and mean nothing.

Managed files the kit has retired (`RETIRED_PATHS`) are deleted, so a sync
converges on the current standard instead of leaving dead infra behind (#185).

`docs/pages.jl` is regenerated here too, in full, from the same managed base
plus the package's `docs/docs_config.jl` extension points as `scaffold`
(#170/#328/#354) — the fix for docs nav that used to only ever apply at first
scaffold (three orphaned AD-backends tutorials, a Benchmarks nav stale since
#305, `_extensions_nav` unreachable after the fact). The migration-safety
rule applies here too, unweakened by anything `update` normally does more
freely than `scaffold`: a committed `pages.jl` without `_MANAGED_PAGES_MARKER`
in its header is preserved untouched and warned about rather than
regenerated, exactly as under [`scaffold`](@ref).

Returns the same named tuple as [`scaffold`](@ref). `license` is always
`:skipped` here, `citation` is `:created` or `:preserved` (#322), and
`extension_pages` is always empty: those pages are package-owned and only
`scaffold` seeds them (#319). `pages` can still be `:created` here: a
missing `docs/pages.jl` (e.g. deleted by hand) is written fresh rather than
left absent, self-healing rather than requiring a full `scaffold` re-run.
"""
function update(
        target_dir::AbstractString; ad::Bool = true,
        benchmarks::Union{Nothing, Bool} = nothing,
        downgrade_compat::Union{Nothing, Bool} = nothing, kwargs...
    )
    inputs = scaffold_inputs(target_dir; kwargs...)
    bench = benchmarks === nothing ? _detect_benchmarks(target_dir) : benchmarks
    dg = downgrade_compat === nothing ?
        _detect_downgrade_compat(target_dir) : downgrade_compat
    return _apply(
        target_dir; managed_only = true, force = false, ad = ad,
        benchmarks = bench, downgrade_compat = dg, inputs = inputs
    )
end

"""
    scaffold_update

Transitional alias for [`update`](@ref), which was called `scaffold_update`
until #294, so an existing qualified caller keeps working across the rename.
`public` like `update` itself, so neither can cause a `Main`-binding
collision. New code should call `update`; this alias is removed in a future
cleanup once adopters have moved off it.
"""
const scaffold_update = update

# Write a minimal package skeleton (Project.toml + src/<Package>.jl) into
# `target_dir`, so a fresh package has the source files `scaffold` needs to
# substitute placeholders from. Returns nothing.
function _emit_package_skeleton(
        target_dir::AbstractString, package::AbstractString,
        uuid::AbstractString, authors_array::AbstractString
    )
    mkpath(joinpath(target_dir, "src"))
    proj = joinpath(target_dir, "Project.toml")
    write(
        proj, """
        name = "$package"
        uuid = "$uuid"
        authors = $authors_array
        version = "0.1.0"

        [deps]
        DocStringExtensions = "ffbed154-4ef7-542d-bbb7-c09d3a79fcae"

        [compat]
        DocStringExtensions = "0.9.5"
        julia = "$(_JULIA_COMPAT)"
        """
    )
    write(
        joinpath(target_dir, "src", "$package.jl"), """
        \"\"\"
            $package

        A fresh EpiAware package. Replace this skeleton with the package's API.

        # Example

        ```@example
        using $package
        ```
        \"\"\"
        module $package

        # All genuine module-scope `using`/`import` statements live here, in
        # the main module file, rather than scattered across included files.
        using DocStringExtensions: @template, DOCSTRING, EXPORTS, IMPORTS,
                                   TYPEDEF, TYPEDFIELDS, TYPEDSIGNATURES

        # Register the standard EpiAware docstring conventions before any
        # docstrings are defined (see src/docstrings.jl).
        include("docstrings.jl")

        end # module $package
        """
    )
    return nothing
end

"""
    scaffold_generate(target_dir, package; authors = String[], uuid = <fresh>,
        ad = true, benchmarks = false, kwargs...)

Generate a fresh package at `target_dir` and adopt the standard tooling.

Creates the target directory if needed, writes a minimal package skeleton (a
`Project.toml` naming `package` with a fresh UUID, and a `src/<package>.jl`
module stub), then runs [`scaffold`](@ref) over it so the new package starts
fully managed. Unlike [`scaffold`](@ref), which adopts the tooling into an
existing package, this also lays down the package's own `Project.toml` and
source module, so it works from an empty or non-existent directory.

  - `package` — the package name (no `.jl` suffix).
  - `authors` — author entries (a `Vector{String}`); written to the new
    `Project.toml` and used for `{{AUTHORS}}`/`{{HOLDER}}` substitution.
  - `uuid` — the package UUID; a fresh `uuid4()` by default.
  - `ad` — forwarded to [`scaffold`](@ref): `true` (default) scaffolds the AD
    infra, `false` opts out. See [`scaffold`](@ref) for the full AD-opt-in
    behaviour.
  - `benchmarks` — forwarded to [`scaffold`](@ref): opt into the benchmark CI +
    suite + docs page. A fresh package has no benchmark workflows to detect, so
    this defaults to `false` (opt-out); pass `benchmarks = true` to enable.

Remaining keyword arguments (`org`, `repo`, `reviewer`, `year`, `license`, ...)
are forwarded to [`scaffold_inputs`](@ref); e.g. `license = "Apache-2.0"` writes
the Apache licence. Returns the `scaffold` manifest.
"""
function scaffold_generate(
        target_dir::AbstractString, package::AbstractString;
        authors::AbstractVector{<:AbstractString} = String[],
        uuid::AbstractString = string(UUIDs.uuid4()),
        ad::Bool = true, benchmarks::Bool = false, kwargs...
    )
    mkpath(target_dir)
    authors_array = "[" * join(("\"" * a * "\"" for a in authors), ", ") * "]"
    _emit_package_skeleton(target_dir, package, uuid, authors_array)
    return scaffold(target_dir; ad = ad, benchmarks = benchmarks, kwargs...)
end
