module XfaEngineTests

__revise_mode__ = :eval

import Statistics: mean
import ReTest: @testset, @test, @test_throws

import XfaEngine.Context
import XfaEngine.Context: @Variable, @karabo_str, Dependency, KaraboDependency, SubvariableDependency, XfaContextException


@testset "KaraboDependency" begin
    @test karabo"foo.bar" == KaraboDependency("foo", "bar")
    @test karabo"foo.bar.baz" == KaraboDependency("foo", "bar.baz")
    @test karabo"foo:output[bar]" == KaraboDependency("foo:output", "bar")
    @test karabo"foo:channel_1.output[bar]" == KaraboDependency("foo:channel_1.output", "bar")

    @test_throws ArgumentError KaraboDependency("foo")
    @test_throws ArgumentError KaraboDependency("foo.bar[]")
    @test_throws ArgumentError KaraboDependency("foo:[bar]")
end

@testset "@Variable" begin
    # Smoke test for basic functionality
    ctx = Context.load_context("""
    using Statistics

    @Variable cam4 -> karabo"MID_EXP_SAM/CAM/CAM4:output[data.image.pixels]"

    @Variable function xgm(intensity -> karabo"SA2_XTD1_XGM/XGM/DOOCS:output[data.intensityTD]")
        return mean(intensity)
    end
    """)
    expected_variables = Set(["cam4", "xgm"])
    @test Set(keys(ctx.functions)) == expected_variables
    @test ctx.functions["cam4"](10) == 10
    @test ctx.functions["xgm"](1:10) == mean(1:10)

    @test Set(keys(ctx.dag)) == expected_variables

    @test ctx.dag["cam4"] == [KaraboDependency("MID_EXP_SAM/CAM/CAM4:output", "data.image.pixels")]
    @test ctx.dag["xgm"] == [KaraboDependency("SA2_XTD1_XGM/XGM/DOOCS:output", "data.intensityTD")]

    # Test generating variables dynamically
    ctx = Context.load_context(raw"""
    function xgm()
        for x in [:foo, :bar, :baz]
            @eval @Variable $x -> $(karabo"$x.data")
        end
    end

    xgm()
    """)

    # All the variables should have been generated
    expected_variables = Set(["foo", "bar", "baz"])
    @test Set(keys(ctx.functions)) == expected_variables

    # And their dependencies should have been marked
    for name in expected_variables
        @test ctx.dag[name] == [KaraboDependency(name, "data")]
    end
    @test Context.external_dependencies(ctx) == Set([karabo"foo.data", karabo"bar.data", karabo"baz.data"])

    # Test variables depending on each other
    ctx = Context.load_context(raw"""
    @Variable foo -> karabo"foo.bar"

    @Variable function bar(data -> foo)
        data
    end
    """)

    @test ctx.dag["bar"] == [Dependency("foo")]
    @test ctx.dag["foo"] == [karabo"foo.bar"]

    # Creating a short-hand variable pointing to anything other than a proper
    # dependency should fail. We test the internal function here because it's
    # easier to test than the macro evaluated at parse time.
    @test_throws ArgumentError Context._variable(@__MODULE__, :(foo -> 42), false)
    @test_throws ArgumentError Context._variable(@__MODULE__, :(foo -> "foo.bar"), false)

    # We should not be able to create a subvariable that isn't defined at the
    # top level of a function.
    @test_throws "defined at the toplevel" Context._variable(@__MODULE__, quote
                                                                 function foo()
                                                                     if true
                                                                         data = @Variable(42)
                                                                     end
                                                                 end
                                                             end,
                                                             false)

    # Test creating a subvariable
    ctx = Context.load_context(raw"""
    @Variable function foo(data -> karabo"device.property")
        bar = @Variable(mean(data))

        return data, bar
    end

    @Variable function quux(data -> foo.bar)
        42
    end
    """)
    @test Set(keys(ctx.functions)) == Set(["foo", "quux"])
    @test ctx.subvariables["foo"] == ["foo.bar"]
    @test ctx.dag["quux"] == [SubvariableDependency("foo", "bar")]
end

@testset "Scheduler" begin
    # Test sorting a DAG with a cycle
    dag = Dict("foo" => ["bar"], "bar" => ["foo"])
    @test_throws XfaContextException Context.topological_sort(dag)

    # Sort an empty DAG
    @test Context.topological_sort(Dict("foo" => [])) == ["foo"]

    # Test that external dependencies aren't considered during sorting
    dag = Dict("camera" => [karabo"foo.bar", karabo"baz.quux"])
    @test Context.topological_sort(dag) == ["camera"]

    # Subvariables should be ignored too
    dag = Dict("camera" => [], "foo" => [SubvariableDependency("camera", "bar")])
    @test Context.topological_sort(dag) == ["camera", "foo"]

    # Test that sorting actually works
    dag = Dict("camera" => [karabo"foo.bar"], "foo" => ["camera"], "bar" => ["foo"])
    @test Context.topological_sort(dag) == ["camera", "foo", "bar"]
end

end
