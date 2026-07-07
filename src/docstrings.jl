# Standard EpiAware docstring conventions (recreates CensoredDistributions.jl
# `src/docstrings.jl`). DocStringExtensions `@template` blocks give every
# function, type, and the module a consistent docstring layout: a signature
# header, the authored prose, and — for types — an auto-generated field list.
#
# package-owned: scaffold writes this once and never overwrites it. To activate
# it, `include` this file near the top of the package module, before any
# docstrings are defined (a `@template` only applies to docstrings written after
# it in the same module):
#
#     module MyPackage
#     include("docstrings.jl")   # registers the @template conventions
#     # ... the rest of the package, with docstrings ...
#     end
#
# Add DocStringExtensions to the package `[deps]` (this file imports from it,
# via the `using` centralised in the main module file). `scaffold_generate` wires both
# for a fresh package automatically. It pairs with `test_docstring_format`
# (which checks the rendered docstrings) and the Documenter +
# DocumenterVitepress build in `docs/make.jl`.

@template (FUNCTIONS, METHODS, MACROS) = """
                                         $(TYPEDSIGNATURES)
                                         $(DOCSTRING)
                                         """

@template TYPES = """
                  $(TYPEDEF)
                  $(DOCSTRING)

                  ---
                  ## Fields
                  $(TYPEDFIELDS)
                  """

@template MODULES = """
                    $(DOCSTRING)

                    ---
                    ## Exports
                    $(EXPORTS)
                    ---
                    ## Imports
                    $(IMPORTS)
                    """
