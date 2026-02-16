module Protocol

export AbstractMessage, Ping, Shutdown,
    GetDevices, LoadContext, ReviseCode,
    ChangeParameter, SetDefaultTopic, Start, Stop,
    SetDebugMode, SetRemoteRepl,
    Pong, AvailableTopics, Started, Stopped, Devices,
    ContextInfo, ParameterChanged, TrainData, RemoteReplState

import Serialization: serialize, deserialize

import HTTP: WebSockets

import ..Context
import ..Context: XfaContext, VariableData, Parameter


abstract type AbstractMessage end

# Messages that a client can send
struct Ping <: AbstractMessage end
struct Shutdown <: AbstractMessage end

struct GetDevices <: AbstractMessage
end

struct LoadContext <: AbstractMessage
    path::String
end

struct ReviseCode <: AbstractMessage end

struct ChangeParameter <: AbstractMessage
    parameter::Parameter
end

struct SetDefaultTopic <: AbstractMessage
    topic::String
end

struct Start <: AbstractMessage end
struct Stop <: AbstractMessage end

struct SetDebugMode <: AbstractMessage
    enable::Bool
end

struct SetRemoteRepl <: AbstractMessage
    enable::Bool
end

# Messages that the server can send
struct Pong <: AbstractMessage end

struct AvailableTopics <: AbstractMessage
    topics::Vector{String}
end

struct Started <: AbstractMessage end
struct Stopped <: AbstractMessage end

struct Devices <: AbstractMessage
    device_names::Union{Dict{String, Any}, Exception}
end

struct ContextInfo <: AbstractMessage
    info::Union{Dict, Exception}
    is_running::Bool
end

ContextInfo(ctx::XfaContext) = ContextInfo(Context.to_dict(ctx), ctx.is_running[])

struct ParameterChanged <: AbstractMessage
    parameter::Parameter
end

struct TrainData <: AbstractMessage
    variables::Vector{VariableData}
end

struct RemoteReplState <: AbstractMessage
    enabled::Bool
    port::Int
end

function send(ws::WebSockets.WebSocket, msg::AbstractMessage)
    buffer = IOBuffer()
    serialize(buffer, msg)
    WebSockets.send(ws, take!(buffer))
end

function receive(ws::WebSockets.WebSocket)::AbstractMessage
    buffer = IOBuffer(WebSockets.receive(ws))
    return deserialize(buffer)
end

end
