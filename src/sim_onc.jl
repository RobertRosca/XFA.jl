using Printf

export OnlineCluster, startonc, stoponc, generatemockdata, generatetrain

mutable struct OnlineCluster
    servers::Dict{String, KaraboBridgeServer}
    all_devices::Vector{Device}
    single_devices::Vector{Device}
    device_groups::Vector{DeviceGroup}
    cal_machines::Int
    running::Bool
    trainid::Int
    sent_trains::Int

    function OnlineCluster(devices_and_groups::Vector, bridge_ports::Vector{Int}, cal_machines::Int=0)
        if length(bridge_ports) != 1
            throw(ArgumentError("Only 1 bridge server is currently supported, but $(length(bridge_ports)) were requested"))
        end

        if cal_machines < 0
            throw(ArgumentError("cal_machines must not be negative, is actually: $(cal_machines)"))
        end

        servers = Dict{String, KaraboBridgeServer}()
        for port in bridge_ports
            if port < 0
                throw(ArgumentError("Invalid port number: $(port)"))
            end

            endpoint = "tcp://127.0.0.1:$(port)"
            servers[endpoint] = KaraboBridgeServer(endpoint)
        end

        single_devices = [d for d in devices_and_groups if d isa Device]
        device_groups = [d for d in devices_and_groups if d isa DeviceGroup]

        all_devices = copy(single_devices)
        for group in device_groups
            append!(all_devices, group.devices)
        end

        new_onc = new(servers, all_devices, single_devices, device_groups, cal_machines, false, 1_000_000_000, 0)
        return finalizer(new_onc) do onc
            close(new_onc)
        end
    end
end

function Base.close(onc::OnlineCluster)
    for server in values(onc.servers)
        close(server)
    end
end

function generateproperty(type)
    is_integer(dtype) = supertype(supertype(dtype)) == Integer
    reasonable_rand(dtype) = is_integer(dtype) ? rand(Vector{type}(0:100)) : rand(type)
    reasonable_rand(dtype, dims) = is_integer(dtype) ? rand(Vector{dtype}(0:100), dims) : rand(dtype, dims)

    if type isa DataType
        return reasonable_rand(type)
    elseif type isa Array
        if isconcretetype(eltype(type)) && eltype(type) <: Number
            dims = Tuple(Int(x) for x in type)
            return reasonable_rand(eltype(type), dims)
        else
            return type
        end
    elseif type isa Function
        return type()
    end
end

function generatedevice(device::Device; timestamp=-1, trainid=0)
    if timestamp == -1
        timestamp = time()
    end
    timestamp_str = @sprintf("%f", timestamp)

    data = Dict()
    metadata = Dict()

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
        source_dict[prop_name] = generateproperty(prop_type)

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

    return data, metadata
end

function generatetrain(single_devices::Vector{Device}, device_groups::Vector{DeviceGroup}, trainid=0)
    data = Dict()
    metadata = Dict()

    timestamp = time()

    # Generate the fake data
    for device in single_devices
        device_data, device_metadata = generatedevice(device; timestamp)
        merge!(data, device_data)
        merge!(metadata, device_metadata)
    end

    return (data, metadata)
end

function startonc(onc::OnlineCluster, rate_hz::Real=10)
    train_delay = 1 / rate_hz
    onc.running = true

    start_condition = Condition()
    t = errormonitor(
        @async begin
            server = first(values(onc.servers))
            server_task = startbridge(server)

            notify(start_condition)

            while onc.running
                # Check if we can write to the channel before writing to it. This is so
                # that if the channel is full we don't get blocked forever and can
                # respond to stoponc() calls.
                if timedwait(() -> !isfull(server.channel), 0.5) === :timed_out
                    continue
                end

                data, metadata = generatetrain(onc.single_devices, onc.device_groups, onc.trainid)

                # Send the data
                put!(server, data, metadata)

                onc.trainid += 1
                onc.sent_trains += 1
                sleep(train_delay)
            end

            stopbridge(server)
            wait(server_task)
        end
    )

    wait(start_condition)
    return t
end

stoponc(onc::OnlineCluster) = onc.running = false
