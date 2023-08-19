module States

import SumTypes: @sum_type


@sum_type RemoteStatus :hidden begin
    UNCONNECTED
    CONNECTING
    CONNECTED
    ERROR
end

@kwdef mutable struct HeadNode
    address::String = ""
    workerid::Int = -1
    status::RemoteStatus = RemoteStatus'.UNCONNECTED
    last_error::String = ""
end

end
