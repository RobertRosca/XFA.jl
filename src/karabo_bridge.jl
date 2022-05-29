using ZMQ
using MsgPack
using Sockets

export KaraboBridgeClient, KaraboBridgeServer, startbridge, stopbridge, next


"""
    KaraboBridgeClient("tcp://127.0.0.1:1234", timeout=0.5)

Connect to the Karabo bridge at the given endpoint.
"""
mutable struct KaraboBridgeClient
    socket::Socket
    ready::Bool

    function KaraboBridgeClient(endpoint::String, timeout::Real=0.5)
        socket = Socket(REQ)
        socket.rcvtimeo = Int(timeout * 1000)
        connect(socket, endpoint)

        return new(socket, false)
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

    function KaraboBridgeServer(endpoint::String, timeout::Real=0.5, buffer_size::Integer=10)
        socket = Socket(REP)
        socket.linger = 0
        socket.rcvhwm = 1
        socket.sndhwm = 1
        socket.rcvtimeo = Int(timeout * 1000)
        bind(socket, endpoint)

        return new(socket, Channel(buffer_size), false)
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
    bridge.running = true
    t = errormonitor(
        @async begin
            notify(start_condition)
            value = nothing
            while bridge.running
                if value == nothing
                    if timedwait(() -> isready(bridge.channel), timeout) == :timed_out
                        continue
                    end

                    value = take!(bridge.channel)
                end

                try
                    msg = recv(bridge.socket)
                catch e
                    if e isa ErrorException
                        continue
                    else
                        rethrow(e)
                    end
                end

                data, metadata = value
                msgs = serialize(data, metadata)
                send_multipart(bridge.socket, msgs)
            end
       end
    )

    wait(start_condition)
    return t
end

stopbridge(bridge::KaraboBridgeServer) = bridge.running = false
Base.put!(bridge::KaraboBridgeServer, data, metadata=nothing) = put!(bridge.channel, (data, metadata))

"""
    next(bridge)

Get the next message from this bridge.
"""
function next(bridge::KaraboBridgeClient)
    if !bridge.ready
        send(bridge.socket, Vector{UInt8}("next"))
        bridge.ready = true
    end

    msgs = recv_multipart(bridge.socket)

    bridge.ready = false

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
                        for (src, value) ∈ pairs(data))
    end

    msgs = []
    for (src, props) ∈ pairs(data)
        src_meta = copy(metadata[src])
        main_data = Dict()
        arrays = Dict()

        for (key, value) ∈ pairs(props)
            if value isa AbstractArray
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
        for (key, array) ∈ arrays
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

    for piece ∈ Iterators.partition(msgs, 2)
        header = unpack(piece[1])
        payload = piece[2]

        source = header["source"]
        content = header["content"]

        if content == "msgpack"
            data[source] = unpack(payload)
            meta[source] = get(header, "metadata", Dict())
        elseif content == "array"
            shape = tuple(Int.(header["shape"])...)
            dtype = let type = header["dtype"]
                if type == "float16"
                    Float16
                elseif type == "float32"
                    Float32
                elseif type == "float64"
                    Float64
                elseif type == "int8"
                    Int8
                elseif type == "int16"
                    Int16
                elseif type == "int32"
                    Int32
                elseif type == "int64"
                    Int64
                elseif type == "uint8"
                    UInt8
                elseif type == "uint16"
                    UInt16
                elseif type == "uint32"
                    UInt32
                elseif type == "uint64"
                    UInt64
                else
                    error("Unsupported dtype for Karabo bridge: '$type'")
                end
            end

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
    for msg ∈ msgs
        send(socket, msg, more=msg !== msgs[end])
    end
end
