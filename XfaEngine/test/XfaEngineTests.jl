module XfaEngineTests

__revise_mode__ = :eval

using Logging: Logging
using Sockets: Sockets, @ip_str, send, recv
using Statistics: mean
using Test: with_logger, TestLogger
using ReTest: @testset, @test, @test_throws, @test_logs

using ZMQ: ZMQ
using HTTP: HTTP, WebSockets
using OrderedCollections: OrderedDict as OD

using XfaEngine: XfaEngine, Context, KaraboBridge, Protocol
using XfaEngine.Context: @Variable, @karabo_str, VariableData, Dependency, KaraboDependency,
    GroupDependency, GroupParameterDependency, SubvariableDependency, XfaContextException, Parameter, FunctionArgument, KaraboDevice
using XfaEngine.KaraboBridge: KaraboBridgeClient, KaraboBridgeServer, ThreadsafeSocket


keyset(dict) = Set(keys(dict))

function test_connect(port=1331)
    client = Client()

    t = Threads.@spawn WebSockets.open(address) do ws
        client.websocket = ws

        id = WebSockets.receive(ws)
        client.client_id = id
        WebSockets.receive(ws) # engine directory

        for msg_bytes in ws
            buffer = IOBuffer(msg_bytes)
            msg::AbstractMessage = deserialize(buffer)
            @show msg
        end

        @info "Connection to $(address) closed"
    end

    return client, errormonitor(t)
end

function server_exists(port)
    try
        sock = Sockets.connect(port)
        close(sock)
        return true
    catch
        return false
    end
end

function mock_webproxy(f::Function, port, bridge_port=-1)
    server = HTTP.serve!(Sockets.localhost, port) do request
        if request.target == "/devices.json"
            return HTTP.Response(read(joinpath(@__DIR__, "mid-devices.json"), String))
        elseif endswith(request.target, "/set_sources.json")
            return HTTP.Response("""{"status": "ok"}""")
        elseif endswith(request.target, "/config.json")
            return HTTP.Response("""{"zmqOutputs": [{"address": "tcp://localhost:$(bridge_port)"}]}""")
        else
            return HTTP.Response(404, "Path not supported")
        end
    end

    try
        f()
    finally
        close(server)
    end
end

function temp_engine(f::Function; log=Logging.global_logger())
    mktemp() do info_path, io
        stop_event = Base.Event()
        state = with_logger(log) do
            XfaEngine.main(stop_event; info_path, wait=false)
        end
        port = state.websocket_port
        @test server_exists(port)

        address = "ws://localhost:$(port)"
        try
            f(address, stop_event, info_path)
        finally
            notify(state.stop_event)
            wait(state.stop_task)
        end
    end
end

@testset "Engine" begin
    # Smoke test
    event = Base.Event()
    mktemp() do info_path, io
        # Run the engine within a TestLogger so we don't see the logs
        log = TestLogger()
        t = Threads.@spawn with_logger(log) do
            XfaEngine.main(event; info_path)
        end

        @test timedwait(() -> isfile(info_path), 10) == :ok

        notify(event)
        @test timedwait(() -> istaskdone(t), 10) == :ok

        @test occursin("[1]", read(info_path, String))
    end

    log = TestLogger()
    temp_engine(; log) do address, stop_event, info_path
        WebSockets.open(address) do ws
            # Test that we get a valid ID and initial trainmatchers
            id = WebSockets.receive(ws)
            @test id isa String
            @test length(id) > 5
            engine_dir = WebSockets.receive(ws)
            @test engine_dir isa String
            @test engine_dir == pkgdir(XfaEngine)
            @test Protocol.receive(ws).msg isa Protocol.AvailableTrainmatchers

            # Test Ping
            Protocol.client_send(ws, Protocol.Ping())
            @test Protocol.receive(ws).msg isa Protocol.Pong

            # Test GetDevices
            webproxy_port = XfaEngine.getavailableport(8484)
            mock_webproxy(webproxy_port) do
                Protocol.client_send(ws, Protocol.GetDevices())
                @test Protocol.receive(ws).msg isa Protocol.Devices
            end

            # Test LoadContext
            mktemp() do path, io
                # Test loading an invalid context
                # write(path, "@Variable x -> foo")
                # Protocol.client_send(ws, Protocol.LoadContext(path))
                # msg = Protocol.receive(ws).msg
                # @test msg isa Protocol.ContextInfo
                # @test msg.info isa Exception

                # Test loading a valid context
                write(path, """
                            p = Parameter(0)
                            @Variable x -> karabo"foo.bar"
                            """)
                Protocol.client_send(ws, Protocol.LoadContext(path))
                msg = Protocol.receive(ws).msg
                @test msg isa Protocol.ContextInfo
                @test msg.info isa Dict
                @test haskey(msg.info["dag"], "x")
            end

            # Test ChangeParameter
            Protocol.client_send(ws, Protocol.ChangeParameter(Parameter("p", 1)))
            @test Protocol.receive(ws).msg isa Protocol.Ack

            # Test ReviseCode
            Protocol.client_send(ws, Protocol.ReviseCode())
            @test Protocol.receive(ws).msg isa Protocol.Ack
        end
    end

    change_param_logs = [x.message for x in log.logs if occursin("ChangeParameter of p", x.message)]
    @test length(change_param_logs) == 1

    # launcher_script = joinpath(dirname(dirname(@__FILE__)), "src/launcher.jl")
    # executable = Base.julia_cmd()
    # environment = Base.active_project()

    # mktempdir() do tmpdir
    #     cd(tmpdir) do
    #         run(`$(executable) --project=$(environment) --startup-file=no --color=no $(launcher_script)`)
    #     end
    # end
end

@testset "Message tracking" begin
    log = TestLogger()
    temp_engine(; log) do address, stop_event, info_path
        WebSockets.open(address) do ws
            # Consume the client ID, engine dir, and initial trainmatchers
            WebSockets.receive(ws)
            WebSockets.receive(ws)
            Protocol.receive(ws)

            # Test that send always assigns an ID and the server
            # echoes it back as reply_to
            id = Protocol.client_send(ws, Protocol.Ping())
            @test id > 0
            envelope = Protocol.receive(ws)
            @test envelope isa Protocol.Envelope
            @test envelope.id < 0
            @test envelope.reply_to == id
            @test envelope.msg isa Protocol.Pong

            # Test that Ack messages carry reply_to for fire-and-forget
            # messages
            id1 = Protocol.client_send(ws, Protocol.SetTopicTrainmatcher("localhost", "tm1"))
            id2 = Protocol.client_send(ws, Protocol.SetTopicTrainmatcher("localhost", "tm2"))
            env1 = Protocol.receive(ws)
            env2 = Protocol.receive(ws)
            @test env1.msg isa Protocol.Ack
            @test env2.msg isa Protocol.Ack
            @test Set([env1.reply_to, env2.reply_to]) == Set([id1, id2])
        end
    end
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

@testset "ThreadsafeSocket" begin
    s1 = ZMQ.Socket(ZMQ.PUSH)
    s2 = ZMQ.Socket(ZMQ.PULL)

    try
        ZMQ.bind(s1, "tcp://*:5555")
        ZMQ.connect(s2, "tcp://localhost:5555")

        ts1 = ThreadsafeSocket(s1)
        ts2 = ThreadsafeSocket(s2)
        ts1.sndhwm = 100

        # Smoke test
        send(ts1, "foo")
        @test recv(ts2, String) == "foo"

        # Multi-threaded test. Spawn many tasks simultaneously reading and
        # writing to the sockets.
        n_msgs = s1.sndhwm ÷ 2
        msgs = Channel{Int}(n_msgs)
        for i in 1:n_msgs
            Threads.@spawn send(ts1, i)
        end
        @sync for i in 1:n_msgs
            Threads.@spawn put!(msgs, recv(ts2, Int))
        end
        close(msgs)
        msgs = collect(msgs)

        @test sort(msgs) == 1:n_msgs

        @test isopen(ts1)
        close(ts1)
        @test !isopen(ts1)
        @test istaskdone(ts1.handler)
    finally
        close(s1)
        close(s2)
    end
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

    @testset "Basic tests" begin
        karabo_bridge_test_state(endpoint) do client, server
            # Start the server
            KaraboBridge.startbridge(server)
            @test isopen(server.channel)

            # The server should now be bound to the port
            @test_throws Base.IOError Sockets.listen(ip"127.0.0.1", port)

            # Trying to start it twice should fail
            @test_throws ErrorException KaraboBridge.startbridge(server)

            # Stop the server
            close(server)
            @test timedwait(() -> !server.is_running, 5) == :ok
        end

        karabo_bridge_test_state(endpoint) do client, server
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
                dummy_data["foo"]["big_$(lowercase(string(type)))_array"] = rand(type, 1000, 1000)
                # These arrays should be serialized, except for Float16 since MsgPack
                # doesn't support Float16.
                dummy_data["foo"]["small_$(lowercase(string(type)))_array"] = rand(type, 10)
            end

            # Send the test data and ensure it's received by the client
            KaraboBridge.startbridge(server)
            put!(server, dummy_data)
            data, metadata = take!(client)
            @test dummy_data == data
        end
    end
end

@testset "Trainmatching" begin
    # Initialize the matcher to look for one source
    tm = Context.Trainmatcher(["foo.bar"], 2)
    data = VariableData(1, "foo.bar", 1)

    matched_trains = Context.match_train(tm, data)
    @test length(matched_trains) == 1
    @test only(keys(matched_trains[1])) == "foo.bar"

    # And multiple sources
    tm = Context.Trainmatcher(["foo.bar", "foo.baz"], 2)
    @test isempty(Context.match_train(tm, VariableData(1, "foo.bar", 1)))
    matched_trains = Context.match_train(tm, VariableData(1, "foo.baz", 1))
    @test length(matched_trains) == 1
    @test Set(keys(matched_trains[1])) == Set(["foo.bar", "foo.baz"])

    # Test the max train latency
    tm = Context.Trainmatcher(["foo.bar", "foo.baz"], 1)
    @test isempty(Context.match_train(tm, VariableData(1, "foo.bar", 1)))
    @test isempty(Context.match_train(tm, VariableData(3, "foo.bar", 1)))
    @test isempty(Context.match_train(tm, VariableData(1, "foo.baz", 1)))
    @test length(Context.match_train(tm, VariableData(3, "foo.baz", 1))) == 1
end

@testset "KaraboDependency" begin
    @test karabo"foo.bar" == KaraboDependency("foo", "bar")
    @test karabo"foo.bar.baz" == KaraboDependency("foo", "bar.baz")
    @test karabo"foo:output[bar]" == KaraboDependency("foo:output", "bar")
    @test karabo"foo:channel_1.output[bar]" == KaraboDependency("foo:channel_1.output", "bar")

    @test_throws ArgumentError KaraboDependency("foo")
    @test_throws ArgumentError KaraboDependency("foo.bar[]")
    @test_throws ArgumentError KaraboDependency("foo:[bar]")

    # Topic macros
    @test karabo"MID//foo.bar" == KaraboDependency("MID", "foo", "bar")
    @test karabo"SA2//foo:output[bar]" == KaraboDependency("SA2", "foo:output", "bar")

    # Parsing from string with topic
    @test KaraboDependency("MID//foo.bar") == KaraboDependency("MID", "foo", "bar")
    @test KaraboDependency("SA2//foo:output[bar]") == KaraboDependency("SA2", "foo:output", "bar")

    # Round trip
    @test KaraboDependency(string(karabo"MID//foo.bar")) == karabo"MID//foo.bar"
    @test KaraboDependency(string(karabo"SA2//foo:output[bar]")) == karabo"SA2//foo:output[bar]"
end

# Helper module that defines variables for reference tests, defined in
# Main so that load_from_string's context modules can access it.
@eval Main module VariableLibrary
    using XfaEngine.Context
    @Variable function normalize(data -> karabo"camera.pixels")
        return data ./ maximum(data)
    end

    @Variable function with_subvar(data -> karabo"device.property")
        @add_subvariable("half", data / 2)
        return data
    end
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
    invokelatest() do
        @test ctx.functions["cam4"](10) == 10
        @test ctx.functions["xgm"](1:10) == mean(1:10)
    end

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
    @test Context.external_dependencies(ctx; per_variable=true) == Dict("foo" => [karabo"foo.data"],
                                                                        "bar" => [karabo"bar.data"],
                                                                        "baz" => [karabo"baz.data"])

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

    # Using an unrecognized macro as a dependency should fail
    @test_throws ArgumentError Context._variable(@__MODULE__, :(function foo(data -> bar"baz") data end), false)

    # We should not be able to create a subvariable that isn't defined at the
    # top level of a function.
    @test_throws "defined at the toplevel" Context._variable(@__MODULE__, quote
                                                                 function foo()
                                                                     if true
                                                                         @add_subvariable("data", 42)
                                                                     end
                                                                 end
                                                             end,
                                                             false)

    # Test creating a subvariable
    ctx = Context.load_from_string(raw"""
    @Variable function foo(data -> karabo"device.property")
        @add_subvariable("bar", mean(data))

        return data
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

    @testset "@Variable references" begin
        # Test bare reference: @Variable VariableLibrary.normalize
        ctx = Context.load_from_string("""
        using Main: VariableLibrary
        @Variable VariableLibrary.normalize
        """)
        @test keyset(ctx.functions) == Set(["normalize"])
        @test ctx.dag["normalize"] == OD("data" => karabo"camera.pixels")

        # Test renamed reference: @Variable my_norm -> VariableLibrary.normalize
        ctx = Context.load_from_string("""
        using Main: VariableLibrary
        using .VariableLibrary: normalize
        @Variable my_norm -> normalize
        """)
        @test keyset(ctx.functions) == Set(["my_norm"])
        @test ctx.dag["my_norm"] == OD("data" => karabo"camera.pixels")

        # Test reference with dependency override
        ctx = Context.load_from_string("""
        using Main: VariableLibrary
        @Variable VariableLibrary.normalize(data -> karabo"other_camera.data")
        """)
        @test ctx.dag["normalize"] == OD("data" => karabo"other_camera.data")

        # Test renamed reference with dependency override
        ctx = Context.load_from_string("""
        using Main: VariableLibrary
        @Variable my_norm -> VariableLibrary.normalize(data -> karabo"other_camera.data")
        """)
        @test keyset(ctx.functions) == Set(["my_norm"])
        @test ctx.dag["my_norm"] == OD("data" => karabo"other_camera.data")

        # Test that the wrapper function delegates to the original
        invokelatest() do
            @test ctx.functions["my_norm"]([2, 4, 6]) == Main.VariableLibrary.normalize([2, 4, 6])
        end

        # Test that variable_origin points to the original
        invokelatest() do
            my_norm_func = ctx.functions["my_norm"]
            @test Context.variable_origin(my_norm_func) === Main.VariableLibrary.normalize
        end

        # Test subvariable remapping on rename
        ctx = Context.load_from_string("""
        using Main: VariableLibrary
        @Variable renamed -> VariableLibrary.with_subvar
        """)
        @test ctx.subvariables["renamed"] == ["renamed.half"]

        # Test that the original variable is excluded from the context when referenced
        ctx = Context.load_from_string("""
        using Main: VariableLibrary
        @Variable my_norm -> VariableLibrary.normalize
        @Variable foo -> karabo"foo.bar"
        """)
        @test Set(keys(ctx.functions)) == Set(["my_norm", "foo"])
    end
end

@testset "Parameter" begin
    # Smoke tests for constructors
    @test Parameter(0) isa Parameter
    @test_throws ArgumentError Parameter(() -> 1, 0)
    @test Parameter(Returns(nothing), 0) isa Parameter
    @test Parameter("foo", 1) isa Parameter

    # Test creating top-level parameters
    ctx = Context.load_from_string(raw"""
    photon_energy = Parameter(0)
    device = Parameter("foo")
    """)
    @test ctx.parameters == Dict("photon_energy" => Parameter("photon_energy", 0),
                                 "device" => Parameter("device", "foo"))

    # Test assigning parameters
    ctx = Context.load_from_string(raw"""
    photon_energy = Parameter(0.0)

    @Input function input(_::Context.MockInput, output)
        put!(output, (0, Dict("camera" => Dict("data" => 42))))
    end

    x = Context.MockInput()

    @Variable function foo(data -> karabo"camera.data")
        tryset(photon_energy, 9)
        return data
    end
    """)
    log = TestLogger()
    with_logger(log) do
        Context.run(ctx) do
            @test timedwait(() -> isready(ctx.stream_output), 5) == :ok
        end
    end
    # Waiting for the log message to come in is necessary because `tryset()`
    # uses `remote_do()` internally, which does not wait for the remotecall.
    @test timedwait(() -> length(log.logs) == 1, 5) == :ok
    @test occursin("Setting parameter", log.logs[1].message)

    # Variables and parameters with the same name doesn't work
    @test_throws ErrorException Context.load_from_string(raw"""
    foo = Parameter(0)

    @Variable foo -> karabo"foo.bar"
    """)
end

@testset "@Input" begin
    @test_throws ArgumentError Context._input(@__MODULE__, "foo", false)
    @test_throws ArgumentError Context._input(@__MODULE__, :(1 + 1), false)

    # Test a standalone input function
    ctx = Context.load_from_string(raw"""
    @Input function bridge(_::Context.MockInput, output)
        put!(output, 42)
    end

    x = Context.MockInput()
    """)
    @test isempty(ctx.dag)
    @test ctx.inputs["x.bridge"] == Dict("_" => GroupDependency("x", Context.MockInput))

    # And a input function that's part of a group
    ctx = Context.load_from_string(raw"""
    @Group struct Foo end
    @Input function bridge(::Foo, output)
        put!(output, 42)
    end

    foo = Foo()
    """)
    @test haskey(ctx.inputs, "foo.bridge")

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

    # Creating a group variable should add it to the group definitions
    @test length(ctx.group_types) > 1
    group_key = only(filter(x -> nameof(x) == :Foo, keys(ctx.group_types)))
    @test nameof.(ctx.group_types[group_key].variables) == [:foo]
    # But because a group object hasn't been created it shouldn't actually
    # schedule anything.
    @test isempty(ctx.dag)

    # Test instantiating a group
    ctx = Context.load_from_string(raw"""
    @Group struct Foo
        bar::Parameter{Int}
    end

    @Variable function foo(data::Foo)
        data.bar
    end

    foo_group = Foo(Parameter(42))
    """)
    group_type = only(filter(x -> nameof(x) == :Foo, keys(ctx.group_types)))
    @test ctx.dag == Dict("foo_group.foo" => OD("data" => Context.GroupDependency("foo_group", group_type)))
    @test ctx.parameters == Dict("foo_group.bar" => Parameter("foo_group.bar", 42))

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
    @test ctx.dag["bar"] == OD("data" => Context.Dependency("foo_group.foo"))

    # Test that group variable dependencies must reference group parameters
    @test_throws ArgumentError Context._variable(@__MODULE__, :(function bar(::Foo, data -> karabo"motor1.pos") data end), false)
    @test_throws ArgumentError Context._variable(@__MODULE__, :(function bar(::Foo, data -> some_var) data end), false)

    # Test GroupParameterDependency resolution
    ctx = Context.load_from_string(raw"""
    @Group mutable struct Foo
        source::Parameter{Context.KaraboDependency}
    end

    @Variable function foo(group::Foo, data -> Foo.source)
        data
    end

    foo_group = Foo(Parameter(karabo"motor1.pos"))
    """)
    @test ctx.dag["foo_group.foo"] == OD("group" => GroupDependency("foo_group", only(filter(x -> nameof(x) == :Foo, keys(ctx.group_types)))),
                                         "data" => karabo"motor1.pos")

    # Test that referencing a non-existent parameter throws
    @test_throws XfaContextException Context.load_from_string(raw"""
    @Group mutable struct Foo end

    @Variable function foo(group::Foo, data -> Foo.nonexistent)
        data
    end

    foo_group = Foo()
    """)

    # Test instantiating groups from other modules
    helper_file_path = joinpath(@__DIR__, "dummy_variables.jl")
    ctx = Context.load_from_string("""
    Base.include(@__MODULE__, "$(helper_file_path)")

    bridge = KaraboBridge(KaraboDevice("MATCHER"))

    foo = DummyVariables.Foo(Parameter(1))
    """)
    @test haskey(ctx.inputs, "bridge.stream")
    @test ctx.functions["bridge.stream"] === Context.stream
    @test haskey(ctx.dag, "foo.compute")
end

@testset "Scheduler" begin
    @testset "Topological sort" begin
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

    @testset "Execution" begin
        ctx = Context.load_from_string(raw"""
        @Variable camera -> karabo"camera.data"
        """)
        # Variables shouldn't be executed unless they have all their dependencies
        @test length(Context.execute_variables(ctx, Dict())) == 0
        @test Context.execute_variables(ctx, Dict("camera.data" => 1)) == Dict("camera" => 1)

        # Test that dependencies are passed correctly
        ctx = Context.load_from_string(raw"""
        norm = Parameter(1)
        @Variable foo -> karabo"foo.bar"
        @Variable function bar(data -> foo)
            return (2 * data, norm[])
        end
        """)
        @test Context.execute_variables(ctx, Dict("foo.bar" => 1)) == Dict("foo" => 1, "bar" => (2, 1))

        # Test executing inputs
        ctx = Context.load_from_string("""
        @Input function fakecamera(::Context.MockInput, output)
            tid = 0
            data = Dict("camera" => Dict("data" => rand(100, 100)))
            while true
                put!(output, (tid, data))
                tid += 1
            end
        end

        x = Context.MockInput()
        """)
        Context.run(ctx) do
            @test length(ctx.input_channels) == 1
            @test timedwait(() -> isready(ctx.input_channels["x.fakecamera"]), 10) == :ok

            @test isempty(ctx.input_variable_channels["x.fakecamera"])
        end
        @test istaskdone(ctx.input_tasks["x.fakecamera"])
        @test istaskdone(ctx.input_variables_tasks["x.fakecamera"])

        # Stopping execution should close all tasks/channels
        @test !isopen(ctx.stream_output)

        # Test executing external dependency variables
        ctx = Context.load_from_string("""
        @Input function fakecamera(::Context.MockInput, output)
            put!(output, (0, Dict("camera" => Dict("data" => 42))))
        end

        @Variable foo -> karabo"camera.data"

        x = Context.MockInput()
        """)
        Context.run(ctx) do
            @test only(keys(ctx.external_dependency_tasks)) == "camera.data"
            @test only(keys(ctx.external_dependency_channels["camera.data"])) == "foo"
            @test only(keys(ctx.variable_tasks)) == "foo"

            @test timedwait(() -> isready(ctx.stream_output), 5) == :ok
        end
        @test istaskdone(ctx.external_dependency_tasks["camera.data"])
        @test take!(ctx.stream_output) == VariableData(0, "foo", 42)

        # Test executing variables
        ctx = Context.load_from_string("""
        @Input function input(::Context.MockInput, output)
            put!(output, (0, Dict("motor1" => Dict("pos" => 1), "motor2" => Dict("pos" => 2))))
        end
        x = Context.MockInput()

        @Variable motor1 -> karabo"motor1.pos"

        @Variable function bar(motor1 -> motor1, motor2 -> karabo"motor2.pos")
            return motor1 + motor2
        end
        """)
        Context.run(ctx) do
            @test keys(ctx.variable_tasks) == Set(["motor1", "bar"])
            @test timedwait(() -> istaskdone(ctx.variable_tasks["bar"]), 5) == :ok
        end
        @test take!(ctx.stream_output) == VariableData(0, "motor1", 1)
        @test take!(ctx.stream_output) == VariableData(0, "bar", 3)

        # Variables that throw shouldn't cause execution of the other variables to
        # fail.
        ctx = Context.load_from_string(raw"""
        @Input function input(::Context.MockInput, output)
            put!(output, (0, Dict("motor1" => Dict("pos" => 1))))
        end
        x = Context.MockInput()

        @Variable function foo(data -> karabo"motor1.pos")
            error("foo")
        end

        @Variable function bar(data -> karabo"motor1.pos")
            return data
        end
        """)
        log = TestLogger()
        with_logger(log) do
            Context.run(ctx) do
                @test timedwait(() -> isready(ctx.stream_output), 5) == :ok
            end
        end
        @test length(log.logs) == 1
        @test occursin("Execution of variable 'foo' failed", log.logs[1].message)
        @test take!(ctx.stream_output) == VariableData(0, "bar", 1)

        # Variables that fail should block downstream dependencies from running
        ctx = Context.load_from_string(raw"""
        @Input function input(::Context.MockInput, output)
            put!(output, (0, Dict("motor1" => Dict("pos" => 1))))
        end
        x = Context.MockInput()

        @Variable function foo(data -> karabo"motor1.pos")
            error("foo")
        end

        @Variable function bar(data -> foo)
            return data
        end
        """)
        log = TestLogger()
        with_logger(log) do
            Context.run(ctx) do
                @test timedwait(() -> istaskdone(ctx.variable_tasks["bar"]), 5) == :ok
            end
        end
        @test length(log.logs) == 1
        @test !isready(ctx.stream_output)

        # Slightly more complicated DAG to test that everything is wired up correctly
        ctx = Context.load_from_string(raw"""
        @Input function input(::Context.MockInput, output)
            put!(output, (0, Dict("motor1" => Dict("pos" => 1), "motor2" => Dict("pos" => 1))))
        end
        i = Context.MockInput()

        @Variable function x(data -> karabo"motor1.pos")
            return data
        end

        @Variable function y(data -> karabo"motor2.pos")
            return data
        end

        @Variable function z(x -> x, y -> y)
            return x + y
        end
        """)
        Context.run(ctx) do
            @test timedwait(() -> !isopen(ctx.stream_output), 5) == :ok
        end

        # Take all the outputs
        results = VariableData[]
        while isready(ctx.stream_output)
            push!(results, take!(ctx.stream_output))
        end

        # Check that we have results from each variable
        @test length(results) == 3
        @test Set(results) == Set([VariableData(0, "x", 1),
                                   VariableData(0, "y", 1),
                                   VariableData(0, "z", 2)])

        # Test scheduling with groups and parameters
        ctx = Context.load_from_string(raw"""
        @Input function input(::Context.MockInput, output)
            put!(output, (0, Dict("motor1" => Dict("pos" => 1))))
        end
        x = Context.MockInput()

        @Group struct Foo
            x::Parameter{Int}
            source::Parameter{Context.KaraboDependency}
        end

        @Variable function bar(group::Foo, data -> Foo.source)
            return group.x[] + data
        end

        foo = Foo(Parameter(1), Parameter(karabo"motor1.pos"))
        """)
        @test "foo.x" ∈ keys(ctx.parameters)
        @test "foo.source" ∈ keys(ctx.parameters)
        Context.run(ctx) do
            @test timedwait(() -> !isopen(ctx.stream_output), 5) == :ok
        end
        @test isready(ctx.stream_output)
        @test take!(ctx.stream_output) == VariableData(0, "foo.bar", 2)

        # Test subvariable execution
        ctx = Context.load_from_string(raw"""
        @Input function input(::Context.MockInput, output)
            put!(output, (0, Dict("motor1" => Dict("pos" => 10))))
        end
        x = Context.MockInput()

        @Variable function foo(data -> karabo"motor1.pos")
            @add_subvariable("half", data / 2)
            return data
        end

        @Variable function bar(data -> foo.half)
            return data + 1
        end
        """)
        Context.run(ctx) do
            @test timedwait(() -> !isopen(ctx.stream_output), 5) == :ok
        end

        results = VariableData[]
        while isready(ctx.stream_output)
            push!(results, take!(ctx.stream_output))
        end
        @test length(results) == 2
        @test results[1] == VariableData(0, "foo", 10, Dict{String, Any}("foo.half" => 5.0))
        @test results[2] == VariableData(0, "bar", 6.0)

        # Test input groups
        ctx = Context.load_from_string(raw"""
        @Group struct Foo
            x::Int
        end
        Context.update_sources(::Foo, _) = nothing

        @Input function input(foo::Foo, output)
            put!(output, (0, Dict("foo" => Dict("x" => foo.x))))
        end

        foo = Foo(42)

        @Variable bar -> karabo"foo.x"
        """)
        @test only(keys(ctx.inputs)) == "foo.input"
        Context.run(ctx) do
            @test timedwait(() -> !isopen(ctx.stream_output), 2) == :ok
        end
        @test take!(ctx.stream_output) == VariableData(0, "bar", 42)

        # Test the Meta module
        ctx = Context.load_from_string(raw"""
        @Input function input(::Context.MockInput, output)
            put!(output, (42, Dict("motor1" => Dict("pos" => 1))))
        end
        x = Context.MockInput()

        @Variable function foo(data -> karabo"motor1.pos")
            scratch = Meta.scratch[]

            return (; tid=Meta.tid[], scratch_dict=scratch isa Dict)
        end
        """)
        Context.run(ctx) do
            @test timedwait(() -> !isopen(ctx.stream_output), 5) == :ok
        end
        result = take!(ctx.stream_output)
        @test result == VariableData(42, "foo", (; tid=42, scratch_dict=true))

        # Test changing parameters
        ctx = Context.load_from_string(raw"""
        next_input = Base.Event()

        @Input function input(::Context.MockInput, output)
            put!(output, (42, Dict("motor1" => Dict("pos" => 1))))
            wait(next_input)
            put!(output, (42, Dict("motor1" => Dict("pos" => 1))))
        end
        i = Context.MockInput()

        x_side_effect = 0
        x = Parameter(0) do x
            global x_side_effect = x
        end

        @Variable function foo(data -> karabo"motor1.pos")
            return x[]
        end
        """)
        Context.run(ctx) do
            @test take!(ctx.stream_output).data == 0
            Context.change_parameter(Parameter("x", 1))
            notify(Context.worker_state.current_ctx_module.next_input)
            @test take!(ctx.stream_output).data == 1
            @test Context.worker_state.current_ctx_module.x_side_effect == 1
        end
    end

    @testset "Multiple inputs" begin
        # Two inputs with different topics, deps routed by topic
        ctx = Context.load_from_string(raw"""
        @Group struct TopicA end
        Context.update_sources(::TopicA, _) = nothing
        Context.input_topic(::TopicA) = "SA2"

        @Group struct TopicB end
        Context.update_sources(::TopicB, _) = nothing
        Context.input_topic(::TopicB) = "MID"

        @Input function sa2_input(::TopicA, output)
            put!(output, (0, Dict("SA2_DEVICE" => Dict("val" => 10))))
        end

        @Input function mid_input(::TopicB, output)
            put!(output, (0, Dict("MID_DEVICE" => Dict("val" => 20))))
        end

        a = TopicA()
        b = TopicB()

        @Variable sa2_data -> karabo"SA2//SA2_DEVICE.val"
        @Variable mid_data -> karabo"MID//MID_DEVICE.val"
        """)
        @test ctx.dep_to_input["SA2//SA2_DEVICE.val"] == "a.sa2_input"
        @test ctx.dep_to_input["MID//MID_DEVICE.val"] == "b.mid_input"

        Context.run(ctx) do
            @test timedwait(() -> !isopen(ctx.stream_output), 5) == :ok
        end
        results = Dict{String, Any}()
        while isready(ctx.stream_output)
            r = take!(ctx.stream_output)
            results[r.name] = r.data
        end
        @test results["sa2_data"] == 10
        @test results["mid_data"] == 20

        # Two inputs with topics, dep without a topic should error
        @test_throws XfaContextException Context.load_from_string(raw"""
        @Group struct TopicA2 end
        Context.update_sources(::TopicA2, _) = nothing
        Context.input_topic(::TopicA2) = "SA2"

        @Group struct TopicB2 end
        Context.update_sources(::TopicB2, _) = nothing
        Context.input_topic(::TopicB2) = "MID"

        @Input function sa2_input(::TopicA2, output) end
        @Input function mid_input(::TopicB2, output) end

        a = TopicA2()
        b = TopicB2()

        @Variable foo -> karabo"unknown_device.val"
        """)

        # Test that single-input contexts still work without topics
        ctx = Context.load_from_string(raw"""
        @Input function input(::Context.MockInput, output)
            put!(output, (0, Dict("motor" => Dict("pos" => 42))))
        end
        x = Context.MockInput()

        @Variable motor_pos -> karabo"motor.pos"
        """)
        @test only(values(ctx.dep_to_input)) == "x.input"
        Context.run(ctx) do
            @test timedwait(() -> !isopen(ctx.stream_output), 5) == :ok
        end
        @test take!(ctx.stream_output) == VariableData(0, "motor_pos", 42)
    end
end

@testset "Context builtins" begin
    @testset "KaraboBridge" begin
        port = getavailableport(42000)
        address = "tcp://localhost:$(port)"
        bridge_server = KaraboBridgeServer(address)
        KaraboBridge.startbridge(bridge_server)

        ctx = Context.load_from_string("""
        bridge = KaraboBridge(KaraboDevice("MATCHER"); sources=["foo.x"])
        bridge._mock_sources = String[]
        bridge.manual_configuration[] = true
        bridge.address[] = "$(address)"

        @Variable foo -> karabo"foo.x"
        """)

        # Make a mock engine so we can use the mock webproxy
        webproxies = Dict("localhost" => XfaEngine.WebProxy("localhost:8484"))
        XfaEngine.current_engine_state = XfaEngine.EngineState(; webproxies)

        # Simple example with two trains of data
        put!(bridge_server, Dict("foo" => Dict("x" => 42.0)))
        put!(bridge_server, Dict("foo" => Dict("x" => 40.0)))
        mock_webproxy(8484, port) do
            Context.run(ctx) do
                @test timedwait(() -> isready(ctx.stream_output), 5) == :ok
                @test take!(ctx.stream_output) == VariableData(0, "foo", 42.0)

                @test timedwait(() -> isready(ctx.stream_output), 5) == :ok
                @test take!(ctx.stream_output) == VariableData(1, "foo", 40.0)
            end
        end
        close(bridge_server)

        # Stopping the pipeline again shouldn't do anything
        Context.stop_pipeline(ctx)

        # We should be able to start the same context again
        bridge_server = KaraboBridgeServer("tcp://localhost:$(port)")
        KaraboBridge.startbridge(bridge_server)
        put!(bridge_server, Dict("foo" => Dict("x" => 38.0)))
        mock_webproxy(8484, port) do
            Context.run(ctx) do
                @test timedwait(() -> isready(ctx.stream_output), 5) == :ok
                @test take!(ctx.stream_output) == VariableData(0, "foo", 38.0)
            end
        end

        close(bridge_server)
    end
end

@testset "Serialization" begin
    ctx = Context.load_from_string(raw"""
        bridge = KaraboBridge(KaraboDevice(""))
        bridge._mock_sources = String[]

        period = Parameter(2π)

        @Variable xgm -> karabo"xgm.intensity"

        @Variable function foo() 42 end

        @Variable function bar(data -> xgm)
            @add_subvariable("max_data", max(data))
            mean(data)
        end
        """)

    @test Context.to_dict(ctx) == Dict("inputs" => Dict("bridge.stream" => ["bridge"]),
                                       "groups" => ["bridge"],
                                       "dag" =>          Dict("xgm" => OD("data" => karabo"xgm.intensity"),
                                                              "foo" => OD(),
                                                              "bar" => OD("data" => Dependency("xgm"))),
                                       "subvariables" => Dict("xgm" => [],
                                                              "foo" => [],
                                                              "bar" => ["bar.max_data"]),
                                       "origins" => Dict("xgm" => "xgm",
                                                         "foo" => "foo",
                                                         "bar" => "bar",
                                                         "bridge" => "XfaEngine.Context.KaraboBridge",
                                                         "bridge.stream" => "XfaEngine.Context.stream"),
                                       "parameters" => Dict("period" => Parameter("period", 2π),
                                                            "bridge.address" => Parameter("bridge.address", ""),
                                                            "bridge.trainmatcher" => Parameter("bridge.trainmatcher", KaraboDevice("", "")),
                                                            "bridge.manual_configuration" => Parameter("bridge.manual_configuration", false)),
                                       "dep_to_input" => Dict("xgm.intensity" => "bridge.stream"),
                                       "path" => "")
end

end
