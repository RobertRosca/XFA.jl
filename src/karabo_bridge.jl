using ZMQ
using MsgPack
using Sockets

export KaraboBridgeClient, KaraboBridgeServer, startbridge, stopbridge, next


"""
    KaraboBridgeClient("tcp://127.0.0.1:1234", timeout::Real=0.5)

Connect to the Karabo bridge at the given endpoint.
"""
mutable struct KaraboBridgeClient
    socket::Socket
    ready::Bool

    function KaraboBridgeClient(endpoint::String; timeout::Real=0.5)
        socket = Socket(REQ)
        socket.rcvtimeo = Int(timeout * 1000)
        connect(socket, endpoint)

        new_client = new(socket, false)
        return finalizer(new_client) do client
            close(client)
        end
    end
end

"""
    KaraboBridgeServer("tcp://127.0.0.1:45454", timeout::Real=0.5, buffer_size=10)

Create a Karabo bridge server.
"""
mutable struct KaraboBridgeServer
    socket::Socket
    channel::Channel
    running::Bool

    function KaraboBridgeServer(endpoint::String; timeout::Real=0.5, buffer_size::Integer=10)
        socket = Socket(REP)
        socket.linger = 0
        socket.rcvhwm = 1
        socket.sndhwm = 2
        socket.rcvtimeo = Int(timeout * 1000)
        bind(socket, endpoint)

        new_server = new(socket, Channel(buffer_size), false)
        return finalizer(new_server) do server
            close(server)
        end
    end
end

function Base.show(io::IO, server::KaraboBridgeServer)
    # Skip the trailing null terminator
    addr = server.socket.last_endpoint[1:end - 1]
    buffer_capacity = server.channel.sz_max
    print(io, """KaraboBridgeServer("$(addr)", Channel($(buffer_capacity)))""")
end

function Base.show(io::IO, client::KaraboBridgeClient)
    # Skip the trailing null terminator
    addr = client.socket.last_endpoint[1:end - 1]
    print(io, """KaraboBridgeClient("$(addr)")""")
end

"""
    close(server::KaraboBridgeServer)

Close a Karabo bridge server (unbind its socket).
"""
Base.close(server::KaraboBridgeServer) = close(server.socket)

"""
    close(client::KaraboBridgeClient)

Close a Karabo bridge client (disconnect its socket).
"""
Base.close(client::KaraboBridgeClient) = close(client.socket)

"""
    startbridge(server::KaraboBridgeServer)

Start a bridge server. It returns the task running the main server
loop. This function guarantees that the server task is started before returning.
"""
function startbridge(server::KaraboBridgeServer)
    # Ensure that only one task at a time is running the server
    if server.running
        error("Karabo bridge server is already running")
    end

    timeout = server.socket.rcvtimeo / 1000

    # This condition is notified when the server loop begins. We wait on it to
    # guarantee the caller that the server loop has started by the time this
    # function returns.
    start_condition = Condition()

    # Start the server loop in a task
    server.running = true
    t = errormonitor(
        @async begin
            notify(start_condition)

            # Keep track of the current value to send to the client
            value = nothing
            while server.running
                # Wait for some data
                if value === nothing
                    if wait_timeout(server.channel, timeout) === :timed_out
                        continue
                    end

                    value = take!(server.channel)
                end

                # Wait for the client to request some data
                try
                    msg = recv(server.socket, String)
                    if msg != "next"
                        error("Unexpected message from Karabo bridge client: '$(msg)'. Expected 'next'.")
                    end
                catch e
                    # If it times out keep going, otherwise rethrow the exception
                    if e isa ErrorException
                        continue
                    else
                        rethrow(e)
                    end
                end

                # Now we can serialize the data and send it to the client
                data, metadata = value
                msgs = serialize(data, metadata)
                send_multipart(server.socket, msgs)
                value = nothing
            end
       end
    )

    wait(start_condition)
    return t
end

stopbridge(server::KaraboBridgeServer) = server.running = false
Base.put!(server::KaraboBridgeServer, data, metadata=nothing) = put!(server.channel, (data, metadata))

"""
    next(client)

Get the next message from a bridge client.
"""
function next(client::KaraboBridgeClient)
    if !client.ready
        send(client.socket, Vector{UInt8}("next"))
        client.ready = true
    end

    msgs = recv_multipart(client.socket)

    client.ready = false

    return deserialize(msgs)
end

"""
    serialize(data, metadata=nothing)

Serialize a Dict of data into a list of messages for ZMQ in the Karabo bridge
protocol.
"""
function serialize(data, metadata=nothing)
    if metadata == nothing
        metadata = Dict(src => get(value, "metadata", Dict())
                        for (src, value) in pairs(data))
    end

    msgs = []
    for (src, props) in pairs(data)
        src_meta = copy(metadata[src])
        main_data = Dict()
        arrays = Dict()

        for (key, value) in pairs(props)
            # Only treat an array as an 'array' (i.e. to be serialized in
            # zero-copy mode in separate ZMQ messages) if it's of a concrete and
            # numeric type, it's larger than 500 elements (to avoid the overhead
            # of another ZMQ message), and it's not Float16 (because MsgPack
            # doesn't support that).
            if (value isa AbstractArray && isconcretetype(eltype(value)) &&
                eltype(value) <: Number && (length(value) > 500 || eltype(value) == Float16))

                arrays[key] = value
            else
                main_data[key] = value
            end
        end

        # Serialize the non-array data
        push!(msgs, pack(Dict(
            "source" => src,
            "content" => "msgpack",
            "metadata" => src_meta
        )))
        push!(msgs, pack(main_data))

        # Serialize the arrays
        for (key, array) in arrays
            if !(array isa DenseArray)
                array = Array(array)
            end

            push!(msgs, pack(Dict(
                "source" => src,
                "content" => "array",
                "path" => key,
                "dtype" => lowercase(string(eltype(array))),
                "shape" => size(array)
            )))
            push!(msgs, Message(array))
        end
    end

    return msgs
end

"""
    deserialize(msgs::Vector{Message})

Deserialize ZMQ messages in the Karabo bridge protocol to a Dict of data.
"""
function deserialize(msgs::Vector{Message})
    data = Dict()
    meta = Dict()

    for piece in Iterators.partition(msgs, 2)
        header = unpack(piece[1])
        payload = piece[2]

        source = header["source"]
        content = header["content"]

        if content == "msgpack"
            data[source] = unpack(payload)
            meta[source] = get(header, "metadata", Dict())
        elseif content == "array"
            shape = tuple(Int.(header["shape"])...)
            dtype = dtype_str_to_type(header["dtype"])

            array = let rank = length(shape)
                if rank == 1
                    reinterpret(dtype, payload)
                elseif rank >= 2
                    # The data coming over the wire is row-major, so at first we
                    # load it into an array with reversed dimensions.
                    reshape(reinterpret(dtype, payload), reverse(shape))

                    # Then we permute it into a special column-major layout:
                    # - The last two dimensions of `shape` are assumed
                    #   to be the X and Y dimensions of an image, and these
                    #   dimensions are placed at the beginning of the new arrays
                    #   dimensions so that they are contiguous in memory.
                    # - The remaining dimensions we don't care so much about, so
                    #   they are reversed in an attempt to match the array stride of
                    #   the original row-major data.
                    # array = permutedims(row_major_raw_data, [2, 1, 3:rank...])
                end
            end

            data[source][header["path"]] = array
        else
            error("Unknown header type of Karabo bridge message: '$(content)'. Expected either 'msgpack' or 'array'")
        end
    end

    return data, meta
end

"""
    recv_multipart(socket)

Receives a multipart message from a ZMQ socket.
"""
function recv_multipart(socket::Socket)
    msgs = Message[]

    while true
        push!(msgs, recv(socket))

        if !socket.rcvmore
            break
        end
    end

    return msgs
end

"""
    send_multipart(socket)

Sends a multipart message from a ZMQ socket.
"""
function send_multipart(socket::Socket, msgs)
    for msg in msgs
        send(socket, msg, more=msg !== msgs[end])
    end
end
