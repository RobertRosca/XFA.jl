module WebProxy

export WebProxyClient, WebProxyClientStatus

import HTTP
import JSON3
import SumTypes: @sum_type

@sum_type WebProxyClientStatus :hidden begin
    UNCONNECTED
    CONNECTING
    CONNECTED
    ERROR
end

mutable struct WebProxyClient
    endpoint::String
    status::WebProxyClientStatus

    # These fields are only usable if the client is CONNECTED

    # This field only has meaning if the status is currently ERROR
    last_error::String
end

function json3_to_dict(data::JSON3.Object, data_dict=Dict{String, Any}())
    for (key_sym, value) in data
        key = String(key_sym)

        if value isa JSON3.Object
            data_dict[key] = json3_to_dict(value)
        else
            data_dict[key] = value
        end
    end

    return data_dict
end

function get_json(wp::WebProxyClient, path; per_stage_timeout=5)
    endpoint = wp.endpoint
    if !startswith(endpoint, "http://")
        endpoint = "http://" * endpoint
    end

    res = HTTP.get(endpoint * path;
                   connect_timeout=per_stage_timeout, readtimeout=per_stage_timeout)
    topology = JSON3.read(res.body)
    return json3_to_dict(topology)
end

get_topology(wp::WebProxyClient; per_stage_timeout=5) = get_json(wp, "/topology.json"; per_stage_timeout)
get_devices(wp::WebProxyClient; per_stage_timeout=5) = get_json(wp, "/devices.json"; per_stage_timeout)["devices"]

end
