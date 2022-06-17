module XFATests

__revise_mode__ = :eval

using Printf
using Sockets
using Distributed

using XFA
using ReTest
using InterProcessCommunication

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

# Helper function that reads from/writes to an array in shared memory
function access_shmem(id, dtype, dims)
    handle = SharedMemory(id)
    array = unsafe_wrap(Array, reinterpret(Ptr{dtype}, pointer(handle)), dims)

    # Modify the array
    array[end] = array[1] * 2

    return array[1]
end

# Helper function to handle setup/teardown. The main purpose of this is to
# test ShmemHandle, so all other args/kwargs are forwarded to the
# ShmemHandle constructor.
function shmem_fixture(f::Function, name="foo", shape=(10, 10), args...; mkproc=false, kwargs...)
    handle = ShmemHandle(name, shape, args...; kwargs...)
    module_path = dirname(@__DIR__)
    if mkproc
        pid = addprocs(1; exeflags="--project=$(module_path)")[1]
    end

    try
        if mkproc
            f(handle, pid)
        else
            f(handle)
        end
    finally
        finalize(handle)
        if mkproc
            rmprocs(pid)
        end
    end
end

@testset "devices.jl" begin
    @testset "ShmemHandle" begin
        shmem_fixture() do handle
            # Test the default pipeline name
            @test shmid(handle.buffer) == "/foo:dataOutput"

            # Check that the finalizer actually frees the shared memory
            finalize(handle)
            @test_throws SystemError SharedMemory(shmid(handle.buffer))
        end

        test_shape = (128, 512)
        dtype = UInt8
        num_slots = 20
        shmem_fixture("foo", test_shape; mkproc=true, output_pipeline="bar", dtype, num_slots) do handle, pid
            # Check the shared mem ID
            @test shmid(handle.buffer) == "/foo:bar"

            # Check the size of the buffer
            @test sizeof(handle.buffer) == prod(test_shape) * sizeof(dtype) * num_slots

            # Check that we can open the buffer from another process
            handle.array[1] = 42
            @everywhere pid include(@__FILE__)

            remote_value = remotecall_fetch(access_shmem, pid,
                                            shmid(handle.buffer), dtype, test_shape)

            # Check that that the other process can read from and write to the array
            @test remote_value == handle.array[1]
            @test handle.array[end] == handle.array[1] * 2
        end
    end

    @testset "Device" begin
        test_device = Device("Foo",
                             "slithy" => "toves",
                             ":bar" => (
                                 "baz" => 1,
                                 "quux" => 2
                             ))

        # Test get_control_properties() and get_instrument_sources()
        @test length(get_control_properties(test_device)) == 1
        @test length(get_instrument_sources(test_device)) == 1

        # Test indexing by source and property names
        @test test_device["slithy"] == "toves"
        @test test_device[":bar"] isa Dict
        @test test_device[":bar"]["baz"] == 1
        @test test_device[":bar", "quux"] == 2

        @test_throws ErrorException test_device["foo"]
        @test_throws ErrorException test_device[":bar", "bars"]

        # Test the Device finalizer
        shmem_fixture() do handle
            device_with_shmem = Device("Foo", "bar" => handle)
            finalize(device_with_shmem)

            @test_throws SystemError SharedMemory(shmid(handle.buffer))
        end
    end

    @testset "DeviceGroup" begin
        agipd = makeagipd("MID")
        try
            # Test that we generate the right number of modules
            @test length(agipd) == 16

            # Test the finalizer
            finalize(agipd)
            handle_ids = [shmid(d[":dataOutput", "image.data"].buffer) for d in agipd.devices]
            for id in handle_ids
                @test_throws SystemError SharedMemory(id)
            end
        catch e
            finalize(agipd)
            rethrow(e)
        end
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

    function sim_onc_fixture(f::Function, devices, ports)
        onc = OnlineCluster(devices, ports)

        # Attach a client to the bridge server
        endpoint = first(keys(onc.servers))
        client = KaraboBridgeClient(endpoint; timeout=2)

        try
            f(onc, client)
        finally
            close(client)
            finalize(onc)
        end
    end

    # Test finalizer of OnlineCluster
    shmem_fixture() do handle
        test_device = Device("Foo", "bar" => handle)

        sim_onc_fixture([test_device], [port]) do onc, client
            # Sanity check that the buffer is created
            @test_nowarn SharedMemory(shmid(handle.buffer))
        end

        # After the above block ends the OnlineCluster should be finalized,
        # deleting the buffer.
        @test_throws SystemError SharedMemory(shmid(handle.buffer))
    end

    # Create a mock online cluster with a single trainmatcher
    sim_onc_fixture(devices, [port]) do onc, client
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
        for device in get_all_devices(devices)
            control_properties = get_control_properties(device)
            if !isempty(control_properties)
                @test device.name ∈ keys(data)

                for prop in control_properties
                    @test prop ∈ keys(data[device.name])
                end
            end

            # And the instrument sources
            instrument_sources = get_instrument_sources(device)
            for source in instrument_sources
                @test source ∈ keys(data)

                source_properties = Dict(x for x in device if startswith(x[1], source))
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
        end

        # Stop the mock cluster
        stoponc(onc)
        @test timedwait(() -> istaskdone(t), 1) == :ok
    end
end

end
