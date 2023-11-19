module KaraboBridge

import ZMQ
import MsgPack
import Sockets

export next

# Sneakily copied from ThreadPinning.jl
macro tspawnat(thrdid, expr)
    # Copied from ThreadPools.jl with the change task.sticky = false -> true
    # https://github.com/tro3/ThreadPools.jl/blob/c2c99a260277c918e2a9289819106dd38625f418/src/macros.jl#L244
    letargs = Base._lift_one_interp!(expr)

    thunk = esc(:(() -> ($expr)))
    var = esc(Base.sync_varname)
    tid = esc(thrdid)
    nt = :(Threads.maxthreadid())
    quote
        if $tid < 1 || $tid > $nt
            throw(ArgumentError("Invalid thread id ($($tid)). Must be between in " *
                                "1:(total number of threads), i.e. $(1:$nt)."))
        end
        let $(letargs...)
            local task = Task($thunk)
            task.sticky = true
            ccall(:jl_set_task_tid, Cvoid, (Any, Cint), task, $tid - 1)
            if $(Expr(:islocal, var))
                put!($var, task)
            end
            schedule(task)
            task
        end
    end
end


"""
    KaraboBridgeClient("tcp://127.0.0.1:1234")

Connect to the Karabo bridge at the given endpoint.
"""
mutable struct KaraboBridgeClient
    socket::ZMQ.Socket
    context::ZMQ.Context
    ready::Bool

    function KaraboBridgeClient(endpoint::String)
        context = ZMQ.Context()
        socket = _zmq_threadsafe() do
            socket = ZMQ.Socket(context, ZMQ.REQ)
            socket.linger = 1
            socket.rcvhwm = 10
            socket.sndhwm = 10
            Sockets.connect(socket, endpoint)
            return socket
        end

        new_client = new(socket, context, false)
        return finalizer(new_client) do client
            @async close(client)
            close(client.context)
        end
    end
end

"""
    KaraboBridgeServer("tcp://127.0.0.1:45454", buffer_size=10)

Create a Karabo bridge server.
"""
mutable struct KaraboBridgeServer
    socket::ZMQ.Socket
    context::ZMQ.Context
    endpoint::String
    lock::ReentrantLock
    is_running::Bool
    channel::Channel
    buffer_size::Int
    server_task::Union{Task, Nothing}

    function KaraboBridgeServer(endpoint::String; buffer_size::Int=10)
        context = ZMQ.Context()
        socket = _zmq_threadsafe() do
            socket = ZMQ.Socket(context, ZMQ.REP)
            socket.linger = 1
            socket.rcvhwm = 10
            socket.sndhwm = 10
            return socket
        end

        ch = Channel()
        close(ch)

        new_server = new(socket, context, endpoint, ReentrantLock(), false, ch, buffer_size, nothing)
        return finalizer(new_server) do server
            @async close(server)
            close(server.context)
        end
    end
end

function _zmq_threadsafe(f; sync=true)
    t = @tspawnat 1 f()

    return sync ? fetch(t) : t
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
function Base.close(server::KaraboBridgeServer)
    @lock server.lock begin
        _zmq_threadsafe(() -> close(server.socket))
        close(server.channel)
    end
end

"""
    close(client::KaraboBridgeClient)

Close a Karabo bridge client (disconnect its socket).
"""
function Base.close(client::KaraboBridgeClient)
    _zmq_threadsafe(() -> close(client.socket))
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

    _zmq_threadsafe(() -> bind(server.socket, server.endpoint))
    server.channel = Channel(server.buffer_size)

    # This condition is notified when the server loop begins. We wait on it to
    # guarantee the caller that the server loop has started by the time this
    # function returns.
    start_condition = Threads.Condition()
    timeout_timer = Timer(5) do _
        close(server)
        @lock start_condition notify(start_condition,
                                     ErrorException("Timeout when starting server on $(server.endpoint)");
                                     error=true)
    end

    lock(start_condition)
    server.server_task = errormonitor(
        _zmq_threadsafe(; sync=false) do
            @lock start_condition notify(start_condition)

            try
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
                    send_multipart(server.socket, msgs)
                end
            finally
                stopbridge(server)
            end
        end)

    @lock start_condition wait(start_condition)
    close(timeout_timer)

    return
end

function stopbridge(server::KaraboBridgeServer)
    @lock server.lock begin
        if !isopen(server.channel)
            return
        end

        _zmq_threadsafe(() -> unbind(server.socket, server.endpoint))
        close(server.channel)
    end
end
Base.put!(server::KaraboBridgeServer, data, metadata=nothing) = put!(server.channel, (data, metadata))

"""
    next(client)

Get the next message from a bridge client.
"""
function next(client::KaraboBridgeClient)
    if !client.ready
        _zmq_threadsafe(() -> Sockets.send(client.socket, Vector{UInt8}("next")))
        client.ready = true
    end

    msgs = _zmq_threadsafe(() -> recv_multipart(client.socket))
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
            push!(msgs, ZMQ.Message(array))
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
function recv_multipart(socket::ZMQ.Socket)
    msgs = ZMQ.Message[]

    while true
        push!(msgs, Sockets.recv(socket))

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
function send_multipart(socket::ZMQ.Socket, msgs)
    for msg in msgs
        Sockets.send(socket, msg, more=msg !== msgs[end])
    end
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
