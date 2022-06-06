module XFATests

__revise_mode__ = :eval

using XFA
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

@testset "karabo_bridge.jl" begin
    # Create server and client
    port = getavailableport(42000)
    endpoint = "tcp://127.0.0.1:$(port)"
    server = KaraboBridgeServer(endpoint)
    client = KaraboBridgeClient(endpoint)

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
        "boolean" => true
    ))
    for type in [Float16, Float32, Float64,
                 Int8, Int16, Int32, Int64,
                 UInt8, UInt16, UInt32, UInt64]
        dummy_data["foo"]["$(lowercase(string(type)))_array"] = rand(type, 10)
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

    # Close the client and server
    close(client)
    close(server)
end

@testset "multibridge.jl" begin
end

end
