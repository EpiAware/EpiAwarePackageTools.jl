## Unreleased

**Breaking**: `scaffold_update` is now `public`, not `export`ed (#294).
It keeps its name (the #178 rename away from bare `update` stays), but a
bare `using EpiAwarePackageTools` no longer brings it into scope — call it
as `EpiAwarePackageTools.scaffold_update(...)` or
`using EpiAwarePackageTools: scaffold_update`.
This removes the last case where the kit's own exports could collide with
a managed package's same-named export in `Main` (the failure mode #173
originally fixed by renaming `update` to `scaffold_update`); `public`
closes it unilaterally, without depending on every adopted package also
moving its own generic verbs off `export`.
Every template-sync/self-drift caller shipped by the kit has been updated
to call it qualified; an adopter on an older scaffolded
`.github/workflows/template-sync.yaml` needs a one-line fix (`scaffold_update(...)`
→ `EpiAwarePackageTools.scaffold_update(...)`) before their first sync on
this kit version, or the sync run itself fails.
