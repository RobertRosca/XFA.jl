module Protocol

export AbstractMessage, Ping, Shutdown,
    GetDevices, GetTrainmatchers, LoadContext, ReviseCode,
    ChangeParameter, SetDefaultTopic, Start, Stop,
    SetDebugMode, SetRemoteRepl,
    Pong, AvailableTopics, AvailableTrainmatchers,
    Started, Stopped, Devices,
    ContextInfo, ParameterChanged, TrainData, RemoteReplState,
    Ack, Envelope, MessageId, client_send, server_send

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

struct GetTrainmatchers <: AbstractMessage end

# Messages that the server can send
struct Pong <: AbstractMessage end

struct AvailableTopics <: AbstractMessage
    topics::Vector{String}
end

struct AvailableTrainmatchers <: AbstractMessage
    topic_trainmatchers::Dict{String, Vector{String}}
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

struct Ack <: AbstractMessage
    error::Union{Exception, Nothing}
end
Ack() = Ack(nothing)

const MessageId = Int

struct Envelope
    id::MessageId
    reply_to::Union{MessageId, Nothing}
    msg::AbstractMessage
end

const _client_counter = Threads.Atomic{Int}(1)
const _server_counter = Threads.Atomic{Int}(-1)
next_client_id() = Threads.atomic_add!(_client_counter, 1)
next_server_id() = Threads.atomic_add!(_server_counter, -1)

function _send(ws::WebSockets.WebSocket, id::MessageId, msg::AbstractMessage;
               reply_to::Union{MessageId, Nothing}=nothing)
    envelope = Envelope(id, reply_to, msg)
    buffer = IOBuffer()
    serialize(buffer, envelope)
    WebSockets.send(ws, take!(buffer))
    return envelope.id
end

function client_send(ws::WebSockets.WebSocket, msg::AbstractMessage;
                     reply_to::Union{MessageId, Nothing}=nothing)
    _send(ws, next_client_id(), msg; reply_to)
end

function server_send(ws::WebSockets.WebSocket, msg::AbstractMessage;
                     reply_to::Union{MessageId, Nothing}=nothing)
    _send(ws, next_server_id(), msg; reply_to)
end

function receive(ws::WebSockets.WebSocket)::Envelope
    buffer = IOBuffer(WebSockets.receive(ws))
    return deserialize(buffer)
end

end
