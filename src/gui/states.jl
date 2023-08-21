module States

import HTTP: WebSockets
import SumTypes: @sum_type


@sum_type RemoteStatus :hidden begin
    UNCONNECTED
    CONNECTING
    CONNECTED
    ERROR
end

@kwdef mutable struct HeadNode
    address::String = ""
    client_id::String = ""
    worker_info::Dict = Dict()

    status::RemoteStatus = RemoteStatus'.UNCONNECTED
    websocket::Union{WebSockets.WebSocket, Nothing} = nothing
    last_error::String = ""
end

end
