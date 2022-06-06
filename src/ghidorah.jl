using Printf

export Ghidorah, startghidorah, stopghidorah, generatemockdata, generatetrain

mutable struct Ghidorah
    servers::Dict{String, KaraboBridgeServer}
    devices::Vector{Device}
    running::Bool
    trainid::Int

    function Ghidorah(devices::Vector{Device}, bridge_ports::Vector{Int})
        if length(bridge_ports) == 0
            throw(ArgumentError("At least 1 bridge port must be specified"))
        end

        servers = Dict{String, KaraboBridgeServer}()
        for port in bridge_ports
            if port < 0
                throw(ArgumentError("Invalid port number: $(port)"))
            end

            endpoint = "tcp://127.0.0.1:$(port)"
            servers[endpoint] = KaraboBridgeServer(endpoint, 1)
        end

        new(servers, devices, false, 1_000_000_000)
    end
end

Device("MID_EXP_EPIX-1/DET/RECEIVER", Dict(
    ":foo" => Dict(
        "bar" => Float16[100, 100],
        "baz" => Int),
    ":daqOutput" => Dict(
        "data.image.pixels" => Float32[704, 768],
        "data.backTemp" => Float32),
    "rxConf" => Dict(
        "rxLane" => Int,
        "rxVc" => Int,
        "save" => Bool),
    "relHumidity" => Float32
))

function generatemockdata(type)
    is_integer(dtype) = supertype(supertype(dtype)) == Integer
    reasonable_rand(dtype) = is_integer(dtype) ? rand(Vector{type}(0:100)) : rand(type)
    reasonable_rand(dtype, dims) = is_integer(dtype) ? rand(Vector{dtype}(0:100), dims) : rand(dtype, dims)

    if type isa DataType
        return reasonable_rand(type)
    elseif type isa Array
        dtype = typeof(type[1])
        dims = Tuple(Int(x) for x in type)
        return reasonable_rand(dtype, dims)
    elseif type isa Function
        return type()
    end
end

function generatetrain(devices::Vector{Device}, trainid=0)
    data = Dict()
    metadata = Dict()

    timestamp = time()
    timestamp_str = @sprintf("%f", time())

    # Generate the fake data
    for device in devices
        for (prop_id, prop_type) in device
            # Extract the source name and property name
            (source_name, prop_name) = let is_instrument_data = ':' ∈ prop_id
                if is_instrument_data
                    split(prop_id, ['[', ']'])
                else
                    split(prop_id, '.', limit=2)
                end
            end

            source_dict = get!(data, source_name, Dict())
            source_dict[prop_name] = generatemockdata(prop_type)

            # Add metadata
            if source_name ∉ keys(metadata)
                source_meta = Dict()
                source_meta["timestamp"] = timestamp
                source_meta["timestamp.sec"] = split(timestamp_str, '.')[1]
                source_meta["timestamp.frac"] = rpad(split(timestamp_str, '.')[2], 18, '0')
                source_meta["timestamp.tid"] = trainid
                metadata[source_name] = source_meta
            end
        end
    end

    return (data, metadata)
end

function startghidorah(ghidorah::Ghidorah, rate)
    train_delay = 1 / rate
    ghidorah.running = true

    server = first(values(ghidorah.servers))
    server_task = @async startbridge(server, train_delay)
    println("Server running: $(istaskstarted(server_task))")

    while ghidorah.running
        # Check if we can write to the channel before writing to it. This is so
        # that if the channel is full we don't get blocked forever and can
        # respond to stopghidorah() calls.
        if timedwait(() -> !isready(server.channel), 0.5) == :timed_out
            continue
        end

        data, metadata = generatetrain(ghidorah.devices, ghidorah.trainid)

        # Send the data
        put!(server, data, metadata)
        println("Put")

        ghidorah.trainid += 1
        sleep(train_delay)
    end

    println("Server stopped: $(istaskdone(server_task))")
    wait(server_task)
end

stopghidorah(ghidorah::Ghidorah) = ghidorah.running = false
