# Exercise the quality wrappers over EpiAwarePackageTools itself: a clean module
# should pass each check, which both tests the wrappers and keeps the package
# itself conformant.

@testset "quality wrappers" begin
    @testset "test_aqua over self" begin
        # Piracy is disabled: `ADRegistry` is an abstract marker type and the
        # harness duck-types, so there is nothing to pirate, but Aqua's piracy
        # check is the one most sensitive to unusual exports, so keep it on.
        test_aqua(EpiAwarePackageTools)
    end

    @testset "test_explicit_imports over self" begin
        test_explicit_imports(EpiAwarePackageTools)
    end

    @testset "test_jet over self" begin
        # Run in-process: JET coexists with the lightweight test deps here.
        test_jet(EpiAwarePackageTools)
    end
end
