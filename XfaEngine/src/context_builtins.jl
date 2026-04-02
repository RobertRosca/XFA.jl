@Group struct MockInput end

update_sources(::MockInput, _) = nothing

struct KaraboDevice
    topic::String
    name::String
end

@Group struct KaraboBridge
    manual_configuration::Parameter{Bool}
    trainmatcher::Parameter{KaraboDevice}
    hostname::Parameter{String}
    port::Parameter{Int}

    sources::Vector{String}
end

function KaraboBridge(hostname, port, sources=String[])
    KaraboBridge(Parameter(false), Parameter(KaraboDevice("", "")),
                 Parameter(hostname), Parameter(port), sources)
end

KaraboBridge(trainmatcher) = KaraboBridge(Parameter(false), Parameter(trainmatcher),
                                          Parameter(""), Parameter(-1), String[])


function get_sources(bridge::KaraboBridge)
    wp = XfaEngine.get_webproxy(bridge.trainmatcher[])
    devices = XfaEngine.get_devices(wp)
    return collect(keys(devices))
end

function update_sources(bridge::KaraboBridge, sources)
    if bridge.manual_configuration[]
        @warn "KaraboBridge is in manual configuration mode, cannot automatically configure a trainmatcher"
        return
    end

    XfaEngine.put_property(bridge.trainmatcher[], "sources", [Dict("source" => s) for s in sources])
end

@Input function stream(bridge::KaraboBridge, output)
    address = ""
    if bridge.manual_configuration[]
        address = "tcp://$(bridge.hostname[]):$(bridge.port[])"
    else
        declare_sources(Meta.name[], get_sources(bridge))

        # Get the output list
        config = XfaEngine.get_config(bridge.trainmatcher[])
        address = config["zmqOutputs"][1]["address"]
    end

    client = KaraboBridgeClient(address)

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
