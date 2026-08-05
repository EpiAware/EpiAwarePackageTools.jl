<!-- PACKAGE-OWNED — your benchmark narrative. scaffold writes this once and
never overwrites it. The managed build splices this file verbatim into the
generated `docs/src/benchmarks/over-time.md`, at the FOOT of the page under an
"## About these benchmarks" heading. The page itself is a presentation of
results — a summary across the package, then one section per suite — so this
is the supporting material a reader wants after the numbers, not before them:
what the suite covers, how to run it locally, and anything needed to read the
history correctly. Add your own `## ...` subsections freely. Keep it short;
setup and CI plumbing belongs in the repo, not on a results page. -->

`{{PACKAGE}}` benchmarks its core operations to track performance over time.

Describe here what the suite covers (the operations measured, any analytical
vs numerical comparisons) and anything needed to read the results above
correctly.
