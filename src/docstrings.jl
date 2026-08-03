# Standard EpiAware docstring conventions. DocStringExtensions `@template`
# blocks give every function, type, and the module a consistent docstring
# layout: a signature header, the authored prose, and — for types — an
# auto-generated field list.
#
# package-owned: scaffold writes this once and never overwrites it.
# `include` it near the top of the package module, before any docstrings
# are defined (a `@template` only applies to docstrings written after it):
#
#     module MyPackage
#     include("docstrings.jl")   # registers the @template conventions
#     # ... the rest of the package, with docstrings ...
#     end
#
# Add DocStringExtensions to the package `[deps]`. `scaffold_generate`
# wires both for a fresh package automatically. Pairs with
# `test_docstring_format` and the docs build in `docs/make.jl`.

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
