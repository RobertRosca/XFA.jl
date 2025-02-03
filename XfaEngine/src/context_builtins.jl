@Group struct KaraboBridge
    hostname::Parameter{String}
    port::Parameter{Int}
    sources::Parameter{Vector{String}}

    function KaraboBridge(hostname="", port=45000, sources=String[])
        new(Parameter(hostname), Parameter(port), Parameter(sources))
    end
end

@Input function stream(bridge::KaraboBridge, output)
    client = KaraboBridgeClient("tcp://$(bridge.hostname[]):$(bridge.port[])")

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
