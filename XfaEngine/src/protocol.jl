module Protocol

export Message, Ping, Shutdown, GetDevices, LoadContext, ReviseCode, Pong, Devices, ContextInfo

import Serialization: serialize

import HTTP: WebSockets


abstract type Message end

# Messages that a client can send
struct Ping <: Message end
struct Shutdown <: Message end

struct GetDevices <: Message
    webproxy_endpoint::String
end

struct LoadContext
    path::String
end

struct ReviseCode <: Message end


# Messages that the server can send
struct Pong <: Message end

struct Devices <: Message
    device_names::Union{Dict{String, Any}, Exception}
end

struct ContextInfo <: Message
    info::Union{Dict{String, Any}, Exception}
end

function send(ws::WebSockets.WebSocket, msg::Message)
    buffer = IOBuffer()
    serialize(buffer, msg)
    WebSockets.send(ws, take!(buffer))
end

end
