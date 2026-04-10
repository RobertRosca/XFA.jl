@Group struct MockInput end

update_sources(::MockInput, _) = nothing

struct KaraboDevice
    topic::String
    name::String
end

# Parse a KaraboDevice from a string, which may contain a topic prefix
# (e.g. "TOPIC//device_name").
function KaraboDevice(str::AbstractString)
    m = match(Context.topic_prefix_re, str)
    if !isnothing(m)
        return KaraboDevice(m.captures[1], m.captures[2])
    end
    return KaraboDevice("", str)
end

@Group mutable struct KaraboBridge
    manual_configuration::Parameter{Bool}
    trainmatcher::Parameter{KaraboDevice}
    address::Parameter{String}

    sources::Vector{String}

    # Internal field for testing: when set, get_sources() returns this
    # instead of querying the WebProxy.
    _mock_sources::Union{Vector{String}, Nothing}
end

function KaraboBridge(device::KaraboDevice; sources=String[], address="")
    KaraboBridge(Parameter(false), Parameter(device),
                 Parameter(address), sources, nothing)
end

input_topic(bridge::KaraboBridge) = let t = bridge.trainmatcher[].topic; isempty(t) ? nothing : t end

function get_sources(bridge::KaraboBridge)
    if !isnothing(bridge._mock_sources)
        return bridge._mock_sources
    end

    try
        wp = XfaEngine.get_webproxy(bridge.trainmatcher[])
        devices = XfaEngine.get_devices(wp)
        return collect(keys(devices))
    catch ex
        @error "Failed to get sources from KaraboBridge" exception=(ex, catch_backtrace())
        return String[]
    end
end

function update_sources(bridge::KaraboBridge, sources)
    if bridge.manual_configuration[]
        @warn "KaraboBridge is in manual configuration mode, cannot automatically configure a trainmatcher"
        return
    end

    XfaEngine.put_property(bridge.trainmatcher[], "sources", [Dict("source" => s) for s in sources])
end

@Input function stream(bridge::KaraboBridge, output)
    if !bridge.manual_configuration[]
        declare_sources(Meta.name[], get_sources(bridge))

        # If no address is set, pick the first available one from the trainmatcher
        if isempty(bridge.address[])
            config = XfaEngine.get_config(bridge.trainmatcher[])
            outputs = config["zmqOutputs"]
            isempty(outputs) && error("No ZMQ outputs available from trainmatcher")
            bridge.address.value = outputs[1]["address"]

            # Notify clients of the new address
            engine_state = XfaEngine.current_engine_state
            if !isnothing(engine_state)
                for client in values(engine_state.clients)
                    XfaEngine.Protocol.server_send(client.websocket,
                                                   XfaEngine.ParameterChanged(bridge.address))
                end
            end
        end
    end

    if isempty(bridge.address[])
        error("No address configured for KaraboBridge")
    end
    client = KaraboBridgeClient(bridge.address[])

    # Start a task just to read from the bridge. Note that this is separate from
    # the task to put it into the output channel to avoid a race condition where
    # the output channel is closed while we're stuck waiting for the next bridge
    # message.
    bridge_msgs = Channel(10)
    input_task = Threads.@spawn try
        while isopen(bridge_msgs)
            # take!() may throw an exception when the client is closed
            local msg
            try
                msg = take!(client)
            catch
                break
            end

            # If the channel is full we drop the train data
            if Base.n_avail(bridge_msgs) ≥ bridge_msgs.sz_max
                @warn "Input buffer for $(Meta.name[]) is full, dropping train"
                continue
            else
                put!(bridge_msgs, msg)
            end
        end
    finally
        close(output)
    end
    errormonitor(input_task)
    bind(bridge_msgs, input_task)

    output_task = Threads.@spawn for msg in bridge_msgs
        data, metadata = msg
        tid = first(values(metadata))["timestamp.tid"]

        # put!() may throw when the channel is closed
        try
            put!(output, (tid, data))
        catch
        end
    end

    try
        while isopen(output)
            sleep(0.1)
        end
    catch ex
        if !(ex isa InvalidStateException)
            rethrow()
        end
    finally
        close(client)
        close(bridge_msgs)
        wait(input_task)
        wait(output_task)
    end
end
