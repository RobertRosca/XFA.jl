module XFATests

__revise_mode__ = :eval

using XFA
using ReTest

using Sockets


function getavailableport(port_hint; interface=ip"127.0.0.1")
    port_range_end = min(65535, port_hint + 5000)
    available_port = -1

    for port ∈ port_hint:port_range_end
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
    @test timedwait(() -> istaskstarted(t), 1) == :ok

    # Stop the server
    stopbridge(server)
    @test timedwait(() -> istaskdone(t), 1) == :ok

    # Start the server and send some data.
    t = startbridge(server)
    dummy_data = Dict("foo" => Dict(
        "string" => "hello world!",
        "scalar" => 42.314,
        "boolean" => true
    ))
    for type in [Float16, Float32, Float64, Int8, Int16, Int32, Int64, UInt8, UInt16, UInt32, UInt64]
        dummy_data["foo"]["$(lowercase(string(type)))_array"] = rand(type, 10)
    end

    put!(server, dummy_data)

    data, metadata = next(client)
    @test dummy_data == data

    stopbridge(server)
    @test timedwait(() -> istaskdone(t), 1) == :ok
end

end
