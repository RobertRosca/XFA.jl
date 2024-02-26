module Protocol

using Serialization

import HTTP: WebSockets
import SumTypes: @sum_type


@sum_type Message :hidden begin
    # Messages that a client can send
    PING
    HCF
    GET_DEVICES(::String) # Holds webproxy endpoint
    LOAD_CONTEXT(::String) # Holds the path to the context file
    REVISE

    # Messages that the server can send
    PONG
    DEVICES(::Union{Dict{String, Any}, Exception}) # Holds list of device names
    CONTEXT_INFO(::Union{Dict{String}, Exception})
end

function send(ws::WebSockets.WebSocket, msg::Message)
    buffer = IOBuffer()
    serialize(buffer, msg)
    WebSockets.send(ws, take!(buffer))
end

end
