module Protocol

export AbstractMessage, Ping, Shutdown,
    GetDevices, LoadContext, ReviseCode,
    ChangeParameter, Start, Stop,
    Pong, Devices, ContextInfo, ParameterChanged, TrainData

import Serialization: serialize

import HTTP: WebSockets

import ..Context: VariableData, Parameter


abstract type AbstractMessage end

# Messages that a client can send
struct Ping <: AbstractMessage end
struct Shutdown <: AbstractMessage end

struct GetDevices <: AbstractMessage
    webproxy_endpoint::String
end

struct LoadContext <: AbstractMessage
    path::String
end

struct ReviseCode <: AbstractMessage end

struct ChangeParameter <: AbstractMessage
    parameter::Parameter
end

struct Start <: AbstractMessage end
struct Stop <: AbstractMessage end

# Messages that the server can send
struct Pong <: AbstractMessage end

struct Devices <: AbstractMessage
    device_names::Union{Dict{String, Any}, Exception}
end

struct ContextInfo <: AbstractMessage
    info::Union{Dict, Exception}
end

struct ParameterChanged <: AbstractMessage
    parameter::Parameter
end

struct TrainData <: AbstractMessage
    variables::Vector{VariableData}
end

function send(ws::WebSockets.WebSocket, msg::AbstractMessage)
    buffer = IOBuffer()
    serialize(buffer, msg)
    WebSockets.send(ws, take!(buffer))
end

end
