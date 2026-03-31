module KaraboBridge

import ZMQ
import MsgPack
import Sockets
import Sockets

@kwdef mutable struct IORequest
    type::Symbol
    args::Any
    kwargs::Any
    result::Any = nothing
    event::Threads.Event = Threads.Event()
end

mutable struct ThreadsafeSocket
    socket::ZMQ.Socket
    io_channel::Channel{IORequest}
    handler::Task

    function ThreadsafeSocket(socket; buffer_size=100)
        self = new(socket, Channel{IORequest}(buffer_size))
        handler = Threads.@spawn handle_threadsafesocket(self)
        self.handler = handler
        errormonitor(handler)

        return self
    end
end

function Base.getproperty(tsock::ThreadsafeSocket, name::Symbol)
    if name in fieldnames(ThreadsafeSocket)
        getfield(tsock, name)
    else
        getproperty(tsock.socket, name)
    end
end

function Base.setproperty!(tsock::ThreadsafeSocket, name::Symbol, x)
    if name in fieldnames(ThreadsafeSocket)
        setfield!(tsock, name, x)
    else
        setproperty!(tsock.socket, name, x)
    end
end

Base.isopen(tsock::ThreadsafeSocket) = isopen(tsock.socket)
Base.wait(tsock::ThreadsafeSocket) = wait(tsock.socket)
Sockets.bind(tsock::ThreadsafeSocket, args...; kwargs...) = Sockets.bind(tsock.socket, args...; kwargs...)

function Base.close(tsock::ThreadsafeSocket)
    close(tsock.io_channel)
    close(tsock.socket)
    wait(tsock.handler)
end

function handle_threadsafesocket(tsock::ThreadsafeSocket)
    while isopen(tsock) || isready(tsock.io_channel)
        local io_request
        try
            io_request = take!(tsock.io_channel)
        catch ex
            if !(ex isa InvalidStateException)
                rethrow()
            else
                break
            end
        end

        try
            io_request.result = if io_request.type === :send
                Sockets.send(tsock.socket, io_request.args...; io_request.kwargs...)
            elseif io_request.type === :recv
                Sockets.recv(tsock.socket, io_request.args...; io_request.kwargs...)
            end
        catch ex
            io_request.result = ex
        finally
            notify(io_request.event)
        end
    end
end

function _do_io(tsock::ThreadsafeSocket, io_request::IORequest)
    put!(tsock.io_channel, io_request)
    wait(io_request.event)

    if io_request.result isa Exception
        throw(io_request.result)
    else
        return io_request.result
    end
end

function Sockets.send(tsock::ThreadsafeSocket, args...; kwargs...)
    io_request = IORequest(; type=:send, args, kwargs)
    return _do_io(tsock, io_request)
end

function Sockets.recv(tsock::ThreadsafeSocket, args...; kwargs...)
    io_request = IORequest(; type=:recv, args, kwargs)
    return _do_io(tsock, io_request)
end

function ZMQ.send_multipart(socket::ThreadsafeSocket, parts)
    for i in eachindex(parts)
        is_last = i == lastindex(parts)
        Sockets.send(socket, parts[i]; more=!is_last)
    end
end

Sockets.recv(socket::ThreadsafeSocket, ::Type{ZMQ.Message}) = Sockets.recv(socket)
function ZMQ.recv_multipart(socket::ThreadsafeSocket, ::Type{T}) where {T}
    parts = T[Sockets.recv(socket, T)]
    while socket.rcvmore
        push!(parts, Sockets.recv(socket, T))
    end

    return parts
end

ZMQ.recv_multipart(socket::ThreadsafeSocket) = ZMQ.recv_multipart(socket, ZMQ.Message)

"""
    KaraboBridgeClient("tcp://127.0.0.1:1234")

Connect to the Karabo bridge at the given endpoint.
"""
mutable struct KaraboBridgeClient
    socket::ThreadsafeSocket
    context::ZMQ.Context
    ready::Bool

    function KaraboBridgeClient(endpoint::String)
        context = ZMQ.Context()
        socket = ZMQ.Socket(context, ZMQ.REQ)
        socket.linger = 1
        socket.rcvhwm = 10
        socket.sndhwm = 10
        Sockets.connect(socket, endpoint)

        new_client = new(ThreadsafeSocket(socket), context, false)
    end
end

"""
    KaraboBridgeServer("tcp://127.0.0.1:45454", buffer_size=10)

Create a Karabo bridge server.
"""
mutable struct KaraboBridgeServer
    socket::ThreadsafeSocket
    context::ZMQ.Context
    endpoint::String
    is_running::Bool
    channel::Channel
    buffer_size::Int
    server_task::Union{Task, Nothing}

    function KaraboBridgeServer(endpoint::String; buffer_size::Int=10)
        context = ZMQ.Context()
        socket = ZMQ.Socket(context, ZMQ.REP)
        socket.linger = 1
        socket.rcvhwm = 10
        socket.sndhwm = 10

        ch = Channel()
        close(ch)

        new_server = new(ThreadsafeSocket(socket), context, endpoint, false, ch, buffer_size, nothing)
    end
end

function Base.show(io::IO, server::KaraboBridgeServer)
    # Skip the trailing null terminator
    addr = server.endpoint
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
function Base.close(server::KaraboBridgeServer; wait=true)
    close(server.channel)

    if isopen(server.context)
        ZMQ.lib.zmq_ctx_shutdown(server.context)
    end

    if wait
        Base.wait(server.server_task)
    end
    close(server.socket)
    close(server.context)
end

"""
    close(client::KaraboBridgeClient)

Close a Karabo bridge client (disconnect its socket).
"""
function Base.close(client::KaraboBridgeClient)
    if isopen(client.context)
        ZMQ.lib.zmq_ctx_shutdown(client.context)
    end

    close(client.socket)
    close(client.context)
end

"""
    startbridge(server::KaraboBridgeServer)

Start a bridge server. It returns the task running the main server
loop. This function guarantees that the server task is started before returning.
"""
function startbridge(server::KaraboBridgeServer)
    # Ensure that only one task at a time is running the server
    if isopen(server.channel)
        error("Karabo bridge server is already running")
    end

    bind(server.socket, server.endpoint)
    server.channel = Channel(server.buffer_size)

    # This condition is notified when the server loop begins. We wait on it to
    # guarantee the caller that the server loop has started by the time this
    # function returns.
    start_condition = Threads.Condition()
    timeout_timer = Timer(10) do _
        close(server; wait=false)
        @lock start_condition notify(start_condition,
                                     ErrorException("Timeout when starting server on $(server.endpoint)");
                                     error=true)
    end

    lock(start_condition)
    server.server_task = Threads.@spawn begin
        @lock start_condition notify(start_condition)

        fake_tid = 0

        while true
            # Wait for some data to send
            data, metadata = nothing, nothing
            try
                data, metadata = take!(server.channel)
            catch ex
                if ex isa InvalidStateException
                    # If the channel has been closed, exit the loop
                    break
                else
                    rethrow()
                end
            end

            if isnothing(metadata)
                metadata = Dict{String, Any}()
                for source in keys(data)
                    metadata[source] = Dict{String, Any}()
                    metadata[source]["source"] = source
                    metadata[source]["timestamp"] = time()
                    metadata[source]["timestamp.sec"] = ""
                    metadata[source]["timestamp.frac"] = ""
                    metadata[source]["timestamp.tid"] = fake_tid
                end

                fake_tid += 1
            end

            # Wait for the client to request some data
            msg = nothing
            try
                msg = Sockets.recv(server.socket, String)
            catch ex
                if ex isa ZMQ.StateError || ex isa EOFError
                    # If the socket was closed or is somehow corrupted,
                    # exit the loop.
                    break
                else
                    rethrow()
                end
            end

            if msg != "next"
                @error "Unexpected message from Karabo bridge client: '$(msg)'. Expected 'next'."
                continue
            end

            # Serialize the data and send it to the client
            msgs = serialize(data, metadata)
            ZMQ.send_multipart(server.socket, msgs)
            @debug "Sent data from $(server)"
        end
    end
    errormonitor(server.server_task)

    @lock start_condition wait(start_condition)
    close(timeout_timer)
end

Base.put!(server::KaraboBridgeServer, data, metadata=nothing) = put!(server.channel, (data, metadata))

"""
    take!(client)

Get the next message from a bridge client.
"""
function Base.take!(client::KaraboBridgeClient)
    if !client.ready
        ZMQ.send(client.socket, "next")
        client.ready = true
    end

    msgs = ZMQ.recv_multipart(client.socket)
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
            # numeric type.
            if (value isa AbstractArray && isconcretetype(eltype(value)) && eltype(value) <: Number)
                arrays[key] = value
            else
                main_data[key] = value
            end
        end

        # Serialize the non-array data
        push!(msgs, MsgPack.pack(Dict(
            "source" => src,
            "content" => "msgpack",
            "metadata" => src_meta
        )))
        push!(msgs, MsgPack.pack(main_data))

        # Serialize the arrays
        for (key, array) in arrays
            if !(array isa DenseArray)
                array = Array(array)
            end

            push!(msgs, MsgPack.pack(Dict(
                "source" => src,
                "content" => "array",
                "path" => key,
                "dtype" => lowercase(string(eltype(array))),
                "shape" => size(array)
            )))
            push!(msgs, ZMQ.Message(vec(array)))
        end
    end

    return msgs
end

"""
    deserialize(msgs::Vector{ZMQ.Message})

Deserialize ZMQ messages in the Karabo bridge protocol to a Dict of data.
"""
function deserialize(msgs::Vector{ZMQ.Message})
    data = Dict()
    meta = Dict()

    for piece in Iterators.partition(msgs, 2)
        header = MsgPack.unpack(piece[1])
        payload = piece[2]

        source = header["source"]
        content = header["content"]

        if content == "msgpack"
            data[source] = MsgPack.unpack(payload)
            for (name, value) in data[source]
                if value isa Vector{Any} && !isempty(value)
                    T = mapreduce(typeof, promote_type, value)
                    if T !== Any
                        data[source][name] = Vector{T}(value)
                    end
                end
            end
            meta[source] = get(header, "metadata", Dict())
        elseif content == "array"
            shape = tuple(Int.(header["shape"])...)
            dtype = dtype_str_to_type(header["dtype"])

            array = let rank = length(shape)
                if rank == 1
                    reinterpret(dtype, payload)
                else
                    # The data coming over the wire is row-major, so at first we
                    # load it into an array with reversed dimensions.
                    reshape(reinterpret(dtype, payload), reverse(shape))
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
Unbind a socket without closing it.
"""
function unbind(socket::ZMQ.Socket, endpoint::AbstractString)
    rc = ccall((:zmq_unbind, ZMQ.libzmq), Cint, (Ptr{Cvoid}, Ptr{UInt8}), socket, endpoint)
    if rc != 0
        throw(ZMQ.StateError(ZMQ.jl_zmq_error_str()))
    end
end

function dtype_str_to_type(dtype::String)
    if dtype == "float16"
        Float16
    elseif dtype == "float32"
        Float32
    elseif dtype == "float64"
        Float64
    elseif dtype == "int8"
        Int8
    elseif dtype == "int16"
        Int16
    elseif dtype == "int32"
        Int32
    elseif dtype == "int64"
        Int64
    elseif dtype == "uint8"
        UInt8
    elseif dtype == "uint16"
        UInt16
    elseif dtype == "uint32"
        UInt32
    elseif dtype == "uint64"
        UInt64
    elseif dtype == "bool"
        Bool
    else
        error("Unsupported dtype: '$dtype'")
    end
end

end
