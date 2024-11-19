module XfaEngineTests

__revise_mode__ = :eval

import Sockets
import Sockets: @ip_str
import Statistics: mean
import Test: with_logger, TestLogger
import ReTest: @testset, @test, @test_throws

import OrderedCollections: OrderedDict as OD

import XfaEngine.Context
import XfaEngine.Context: @Variable, @karabo_str, Dependency, KaraboDependency,
    GroupDependency, SubvariableDependency, XfaContextException, Parameter, FunctionArgument
import XfaEngine.KaraboBridge
import XfaEngine.KaraboBridge: KaraboBridgeClient, KaraboBridgeServer


@testset "Engine" begin
    launcher_script = joinpath(dirname(dirname(@__FILE__)), "src/launcher.jl")
    executable = Base.julia_cmd()[1]
    environment = dirname(Base.active_project())

    # mktempdir() do
    #     engine = run(`$(executable) --project=$(environment) --startup-file=no --color=no $(launcher_script)`; wait=false)
    # end
end

function getavailableport(port_hint; interface=ip"127.0.0.1")
    port_range_end = min(65535, port_hint + 100)
    available_port = -1

    for port in port_hint:port_range_end
        try
            s = Sockets.listen(interface, port)
            close(s)
            return port
        catch ex
            continue
        end
    end

    error("Could not find an available port between $(port_hint) and $(port_range_end)")
end

function karabo_bridge_test_state(f::Function, endpoint)
    server = KaraboBridgeServer(endpoint)
    client = KaraboBridgeClient(endpoint)

    try
        f(client, server)
    finally
        close(client)
        close(server)
    end
end

@testset "Karabo bridge" begin
    # Create server and client
    port = getavailableport(42000)
    endpoint = "tcp://127.0.0.1:$(port)"

    karabo_bridge_test_state(endpoint) do client, server
        # Start the server
        KaraboBridge.startbridge(server)
        @test isopen(server.channel)

        # The server should now be bound to the port
        @test_throws Base.IOError Sockets.listen(ip"127.0.0.1", port)

        # Trying to start it twice should fail
        @test_throws ErrorException KaraboBridge.startbridge(server)

        # Stop the server
        KaraboBridge.stopbridge(server)
        @test timedwait(() -> !server.is_running, 5) == :ok

        # Create some test data
        dummy_data = Dict("foo" => Dict(
            "string" => "hello world!",
            "scalar" => 42.314,
            "boolean" => true,
            "list" => ["foo", "bar", 42, 3.14],
        ))
        for type in [Bool,
                     Float16, Float32, Float64,
                     Int8, Int16, Int32, Int64,
                     UInt8, UInt16, UInt32, UInt64]
            # These arrays should use zero-copy transfer
            dummy_data["foo"]["big_$(lowercase(string(type)))_array"] = rand(type, 1000)
            # These arrays should be serialized, except for Float16 since MsgPack
            # doesn't support Float16.
            dummy_data["foo"]["small_$(lowercase(string(type)))_array"] = rand(type, 10)
        end

        # Send the test data and ensure it's received by the client
        KaraboBridge.startbridge(server)
        put!(server, dummy_data)
        data, metadata = KaraboBridge.next(client)
        @test dummy_data == data

        # # Trying to get more data should timeout
        # @test_throws ErrorException next(client)

        # # But now there's an outstanding request, so the next put!()/next() cycle should still send data
        # put!(server, dummy_data)
        # data, metadata = next(client)
        # @test dummy_data == data

        # stopbridge(server)
        # @test timedwait(() -> istaskdone(t), 1) == :ok
    end
end

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
    ctx = Context.load_from_string("""
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

    @test ctx.dag["cam4"] == OD("data" => karabo"MID_EXP_SAM/CAM/CAM4:output[data.image.pixels]")
    @test ctx.dag["xgm"] == OD("intensity" => karabo"SA2_XTD1_XGM/XGM/DOOCS:output[data.intensityTD]")

    # Test generating variables dynamically
    ctx = Context.load_from_string(raw"""
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
        @test ctx.dag[name] == OD("data" => KaraboDependency(name, "data"))
    end
    @test Context.external_dependencies(ctx) == Set([karabo"foo.data", karabo"bar.data", karabo"baz.data"])

    # Test variables depending on each other
    ctx = Context.load_from_string(raw"""
    @Variable foo -> karabo"foo.bar"

    @Variable function bar(data -> foo)
        data
    end
    """)

    @test ctx.dag["bar"] == OD("data" => Dependency("foo"))
    @test ctx.dag["foo"] == OD("data" => karabo"foo.bar")

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
    ctx = Context.load_from_string(raw"""
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
    @test ctx.dag["quux"] == OD("data" => SubvariableDependency("foo", "bar"))

    # Test loading from a file
    ctx_code = raw"""
    @Variable foo -> karabo"foo.bar"
    """
    ctx_from_str = Context.load_from_string(ctx_code)
    path, io = mktemp()
    write(io, ctx_code)
    close(io)
    @test Context.load_from_file(path).dag == ctx_from_str.dag
end

@testset "@Parameter" begin
    @test_throws ArgumentError Context._parameter(@__MODULE__, 10, false)

    ctx = Context.load_from_string(raw"""
    @Parameter photon_energy::Int -> 0
    @Parameter device::String -> "foo"
    """)
    @test ctx.parameters == Dict("photon_energy" => Parameter("photon_energy", 0),
                                 "device" => Parameter("device", "foo"))

    # Don't allow variables and parameters with the same name
    @test_throws XfaContextException Context.load_from_string(raw"""
    @Parameter foo::Int -> 0
    @Variable foo -> karabo"foo.bar"
    """)

    # Don't allow duplicate parameters
    @test_throws XfaContextException Context.load_from_string(raw"""
    @Parameter foo::Int -> 0
    @Parameter foo::Float64 -> 2π
    """)

    # Allow parameters as dependencies of variables
    ctx = Context.load_from_string(raw"""
    @Parameter period::Float64 -> 2π
    @Variable function foo(period -> period)
        period * 2
    end
    """)

    @test ctx.parameters == Dict("period" => Parameter("period", 2π))
    @test ctx.dag["foo"] == OD("period" => Parameter("period", 2π))
end

@testset "@Input" begin
    @test_throws ArgumentError Context._input(@__MODULE__, "foo", false)
    @test_throws ArgumentError Context._input(@__MODULE__, :(1 + 1), false)

    # Test a standalone input function
    ctx = Context.load_from_string(raw"""
    @Input function bridge(output::Channel)
        put!(output, 42)
    end
    """)
    @test isempty(ctx.dag)
    @test ctx.inputs["bridge"] == Dict("output" => FunctionArgument("output", Channel))

    # And a input function that's part of a group
    ctx = Context.load_from_string(raw"""
    @Group struct Foo end
    @Input function bridge(::Foo, output::Channel{Int})
        put!(output, 42)
    end

    foo = Foo()
    """)
    @test haskey(ctx.inputs, "foo.bridge")
    @test ctx.inputs == Dict("foo.bridge" => OD(nothing => GroupDependency("foo"),
                                                         "output" => FunctionArgument("output", Channel{Int})))

    # But not one with arbitrary arguments
    @test_throws XfaContextException Context._input(@__MODULE__,
                                                    quote
                                                        function foo(output, bar)
                                                            42
                                                        end
                                                    end, false)
end

@testset "@Group" begin
    @test_throws ArgumentError Context._group(@__MODULE__, "foo", false)
    @test_throws ArgumentError Context._group(@__MODULE__, :(1 + 1), false)

    ctx = Context.load_from_string(raw"""
    @Group struct Foo end

    @Variable function foo(::Foo)
        42
    end
    """)
    # Creating a group should add it to the group definitions
    @test haskey(ctx.group_types, "Foo")
    @test ctx.group_types["Foo"].variables == ["foo"]
    # But it shouldn't actually schedule anything
    @test isempty(ctx.dag)

    # Test instantiating and executing a group
    ctx = Context.load_from_string(raw"""
    @Group struct Foo
        @Parameter bar::Int
    end
    @Variable function foo(data::Foo)
        data.bar
    end

    foo_group = Foo(42)
    """)

    @test ctx.dag == Dict("foo_group.foo" => OD("data" => Context.GroupDependency("foo_group")))
    @test ctx.parameters == Dict("foo_group.bar" => Context.Parameter("foo_group.bar", 42))
    @test Context.execute_variables(ctx, Dict()) == Dict("foo_group.foo" => 42)

    # Test that the struct can be used as a dependency
    ctx = Context.load_from_string(raw"""
    @Group struct Foo
        value::Float64
    end
    @Variable function foo(data::Foo)
        data.value
    end

    foo_group = Foo(2π)

    @Variable function bar(data -> foo_group.foo)
        data
    end
    """)
    @test Context.execute_variables(ctx, Dict()) == Dict("foo_group.foo" => 2π, "bar" => 2π)
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

    ctx = Context.load_from_string(raw"""
    @Variable camera -> karabo"camera.data"
    """)
    # Variables shouldn't be execute_variablesd unless they have all their dependencies
    @test length(Context.execute_variables(ctx, Dict())) == 0
    @test Context.execute_variables(ctx, Dict("camera.data" => 1)) == Dict("camera" => 1)

    # Variables that throw shouldn't cause execution of the other variables to
    # fail.
    ctx = Context.load_from_string(raw"""
    @Variable function foo()
        error("foo")
    end

    @Variable function bar()
        42
    end
    """)
    log = TestLogger()
    with_logger(log) do
        @test Context.execute_variables(ctx, Dict()) == Dict("bar" => 42)
    end
    @test length(log.logs) == 1
    @test occursin("Error executing", log.logs[1].message)

    # Test that dependencies are passed correctly
    ctx = Context.load_from_string(raw"""
    @Parameter norm::Int -> 1
    @Variable foo -> karabo"foo.bar"
    @Variable function bar(data -> foo, norm -> norm)
        return (2 * data, norm)
    end
    """)
    @test Context.execute_variables(ctx, Dict("foo.bar" => 1)) == Dict("foo" => 1, "bar" => (2, 1))

    # Test executing inputs
    input_str = """
    @Input function fakecamera(output)
        tid = 0
        data = Dict("camera.data" => rand(100, 100))
        while true
            put!(output, (tid, data))
            tid += 1
        end
    end
    """

    ctx = Context.load_from_string(input_str)
    Context.run(ctx) do
        @test length(ctx.input_channels) == 1
        @test timedwait(() -> isready(ctx.input_channels["fakecamera"]), 10) == :ok
    end
    @test istaskdone(ctx.input_dtasks["fakecamera"])

    ctx = Context.load_from_string("""
    @Input function fakecamera(output)
        put!(output, (0, Dict("camera.data" => 42)))
    end

    @Variable foo -> karabo"camera.data"
    """)
    Context.run(ctx) do
        @test only(keys(ctx.variable_dtasks)) == "foo"
    end
end

@testset "Serialization" begin
    ctx = Context.load_from_string(raw"""
    @Parameter period::Float64 -> 2π
    @Variable xgm -> karabo"xgm.intensity"
    @Variable function foo() 42 end
    @Variable function bar(data -> xgm)
        max_data = @Variable(max(data))

        mean(data)
    end
    """)

    @test Context.to_dict(ctx) == Dict("dag" =>          Dict("xgm" => OD("data" => karabo"xgm.intensity"),
                                                              "foo" => OD(),
                                                              "bar" => OD("data" => Dependency("xgm"))),
                                       "subvariables" => Dict("xgm" => [],
                                                              "foo" => [],
                                                              "bar" => ["bar.max_data"]),
                                       "parameters" => Dict("period" => Parameter("period", 2π)))
end

end
