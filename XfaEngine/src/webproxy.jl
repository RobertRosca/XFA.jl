import HTTP
import JSON3

# @sum_type WebProxyClientStatus :hidden begin
#     UNCONNECTED
#     CONNECTING
#     CONNECTED
#     ERROR
# end

const DEFAULT_WEBPROXY_ADDRESSES = Dict(
    "SA1" => "sa1-br-sys-con-gui1:8484",
    "FXE" => "fxe-rr-sys-con-gui1:8484",
    "SPB" => "spb-rr-sys-con-gui1:8484",

    "SA2" => "sa2-br-sys-con-gui1:8484",
    "MID" => "mid-rr-sys-con-gui1:8484",
    "HED" => "hed-rr-sys-con-gui1:8484",

    "SA3" => "sa3-br-sys-con-gui1:8484",
    "SCS" => "scs-rr-sys-con-gui1:8484",
    "SQS" => "sqs-rr-sys-con-gui1:8484",
    "SXP" => "sxp-rr-sys-con-gui1:8484"
)


const TimestampedResponse = @NamedTuple{timestamp::Float64, value::Dict}
mutable struct WebProxy
    address::String

    topology_cache::TimestampedResponse
    devices_cache::TimestampedResponse
end

function Base.show(io::IO, wp::WebProxy)
    print(io, WebProxy, "(\"$(wp.address)\")")
end

function WebProxy(address)
    if !startswith(address, "http://")
        address = "http://" * address
    end

    default_cache = (timestamp=-1.0, value=Dict())
    return WebProxy(address, default_cache, default_cache)
end

function get_webproxy()
    if isnothing(current_engine_state)
        error("Engine is not initialized, cannot get a WebProxy")
    elseif isempty(current_engine_state.webproxies)
        error("No WebProxy's are available to connect to")
    end

    return current_engine_state.webproxies[current_engine_state.default_topic]
end

# Flatten the returned dict a bit by removing timestamp and tid entries for each
# node.
function strip_metadata!(x)
    for key in keys(x)
        if x[key] isa Dict && keys(x[key]) == Set(["value", "timestamp", "tid"])
            x[key] = x[key]["value"]
        end

        if x[key] isa Dict || x[key] isa Vector
            strip_metadata!(x[key])
        end
    end
end

function get_json(wp, path; timeout=5)
    res = HTTP.get(wp.address * path;
                   connect_timeout=timeout, readtimeout=timeout)
    return JSON3.read(res.body, Dict{String, Any})
end

function get_topology(wp; timeout=5, max_age=10)
    if time() - wp.topology_cache.timestamp > max_age
        value = get_json(wp, "/topology.json"; timeout)
        wp.topology_cache = (; timestamp=time(), value)
    end

    return wp.topology_cache.value
end

function get_devices(wp; timeout=5, max_age=10)
    if time() - wp.devices_cache.timestamp > max_age
        value = get_json(wp, "/devices.json"; timeout)["devices"]
        wp.devices_cache = (; timestamp=time(), value)
    end

    return wp.devices_cache.value
end

function get_config(wp, device; timeout=5)
    config = get_json(wp, "/devices/$(device)/config.json"; timeout)
    strip_metadata!(config)
    return config
end

function call_slot(wp, device, slot, params=HTTP.nobody; timeout=5)
    url = wp.address * "/devices/$(device)/slot/$(slot).json"
    body = params isa Dict ? JSON3.write(params) : params
    res = HTTP.put(url, nothing, body; connect_timeout=timeout, readtimeout=timeout)
    return JSON3.read(res.body, Dict{String, Any})
end

function get_trainmatcher_address(address, device::String; index=1)
    config = get_config(address, "/devices/$(device)/config.json")

    config["zmqOutputs"]["value"][index]["address"]["value"]
end
