module XFATests

__revise_mode__ = :eval

using XFA
using Printf
using ReTest

using Sockets


function getavailableport(port_hint; interface=ip"127.0.0.1")
    port_range_end = min(65535, port_hint + 5000)
    available_port = -1

    for port in port_hint:port_range_end
        try
            s = listen(interface, port)
            close(s)
            return port
        catch
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

@testset "karabo_bridge.jl" begin
    # Create server and client
    port = getavailableport(42000)
    endpoint = "tcp://127.0.0.1:$(port)"

    karabo_bridge_test_state(endpoint) do client, server
        # The server should already be bound to the port
        @test_throws Base.IOError listen(ip"127.0.0.1", port)

        # Start the server
        t = startbridge(server)
        @test istaskstarted(t)

        # Trying to start it twice should fail
        @test_throws ErrorException startbridge(server)

        # Stop the server
        stopbridge(server)
        @test timedwait(() -> istaskdone(t), 1) == :ok

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
        t = startbridge(server)
        put!(server, dummy_data)
        data, metadata = next(client)
        @test dummy_data == data

        # Trying to get more data should timeout
        @test_throws ErrorException next(client)

        # But now there's an outstanding request, so the next put!()/next() cycle should still send data
        put!(server, dummy_data)
        data, metadata = next(client)
        @test dummy_data == data

        stopbridge(server)
        @test timedwait(() -> istaskdone(t), 1) == :ok
    end
end

function sim_onc_test_state(f::Function, devices, ports)
    onc = OnlineCluster(devices, ports)

    # Attach a client to the bridge server
    endpoint = first(keys(onc.servers))
    client = KaraboBridgeClient(endpoint)

    try
        f(onc, client)
    finally
        close(client)
        close(onc)
    end
end

@testset "sim_onc.jl" begin
    # Create some devices
    devices = []
    epix = Device("MID_EXP_EPIX-1/DET/RECEIVER",
                  ":foo" => (
                      "bar" => Float16[100, 100],
                      "baz" => Int),
                  ":daqOutput" => (
                      "data.image.pixels" => Float32[704, 768],
                      "data.backTemp" => Float32),
                  "rxConf" => (
                      "rxLane" => Int,
                      "rxVc" => Int,
                      "save" => Bool),
                  "relHumidity" => Float32)
    motor = Device("MID_EXP_UPP/MOTOR/R1",
                   "actualPosition" => Float32,
                   "targetPosition" => Float32)
    push!(devices, epix)

    agipd = makeagipd("MID")
    @test length(agipd) == 16
    push!(devices, agipd)

    # Find an available port
    port = getavailableport(42000)

    # Creating a cluster with the wrong number of bridges should fail
    @test_throws ArgumentError OnlineCluster(devices, Int[])
    @test_throws ArgumentError OnlineCluster(devices, [port, port + 1])

    # Create a mock online cluster with a single trainmatcher
    sim_onc_test_state(devices, [port]) do onc, client
        # Start it
        t = startonc(onc)
        @test istaskstarted(t)

        # Stop it and check that it stops within a certain timeout
        stoponc(onc)
        @test timedwait(() -> istaskdone(t), 1) == :ok

        # The number of trains sent depends on the size of the servers buffers, but
        # it ought to be at least 1.
        @test onc.sent_trains > 0

        # Start it again
        t = startonc(onc)

        # Get some data
        data, metadata = next(client)

        # Check that all the slow data properties are present
        @test epix.name ∈ keys(data)
        control_properties = [x[1][length(epix.name) + 2:end] for x in epix if ':' ∉ x[1]]
        @test length(control_properties) == 4
        for prop in control_properties
            @test prop ∈ keys(data[epix.name])
        end

        # And the instrument sources
        instrument_sources = unique([split(x[1], "[")[1] for x in epix if ':' ∈ x[1]])
        @test length(instrument_sources) == 2
        for source in instrument_sources
            @test source ∈ keys(data)

            source_properties = Dict(x for x in epix if startswith(x[1], source))
            @test length(source_properties) > 0
            for (key, prop_type) in pairs(source_properties)
                # Check that the property is present
                prop_name = split(key, '[')[2][1:end - 1]
                @test prop_name ∈ keys(data[source])

                # And that arrays have the right shape
                if prop_type isa Array && eltype(prop_type) <: Real
                    # Note: the bridge client currently assumes that all arrays are
                    # row-major (Python/numpy default), so the axis order will be
                    # swapped to represent the array as a column-major Julia array.
                    shape = Tuple(Int.(prop_type))
                    @test size(data[source][prop_name]) == reverse(shape)
                end
            end
        end

        # Stop the mock cluster
        stoponc(onc)
        @test timedwait(() -> istaskdone(t), 1) == :ok
    end
end

end
