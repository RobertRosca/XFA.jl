module Protocol

using Serialization

import HTTP: WebSockets
import SumTypes: @sum_type


@sum_type Message :hidden begin
    # Messages that a client can send
    PING
    HCF
    GET_DEVICES(::String) # Holds webproxy endpoint
    REVISE

    # Messages that the server can send
    PONG
    DEVICES(::Union{Dict{String, Any}, Exception}) # Holds list of device names
end

function send(ws::WebSockets.WebSocket, msg::Message)
    buffer = IOBuffer()
    serialize(buffer, msg)
    WebSockets.send(ws, take!(buffer))
end

end
