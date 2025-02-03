module XfaEngine

include("karabo_bridge.jl")
include("context.jl")
include("protocol.jl")
include("webproxy.jl")

import TOML
import Sockets: listen, close, @ip_str
import DistributedNext: @everywhere, @fetchfrom, workers, procs
using Serialization

import HTTP
import HTTP: WebSockets
import Revise

using .Protocol
import .WebProxy
import .Context: XfaContext


"""Find the closest available port to `port_hint`."""
function getavailableport(port_hint; interface=ip"0.0.0.0")
    port_range_end = min(65535, port_hint + 5000)
    available_port = -1

    for port in port_hint:port_range_end
        try
            s = listen(interface, port)
            close(s)
            return port
        catch
            continue
        end
    end

    error("Could not find an available port between $(port_hint) and $(port_range_end)")
end

# function heartbeat(state::ClientState)
#     while !WebSockets.isclosed(state.websocket)
#         WebSockets.send(state.websocket, "ping")
#         sleep(5)
#     end
# end

@kwdef mutable struct ClientState
    websocket::WebSockets.WebSocket
    last_heartbeat::Float64
    handler_task::Union{Task, Nothing} = nothing
    # heartbeat_task::Task
end

@kwdef mutable struct EngineState
    websocket_port::Int
    karabo_bridge_port::Int = -1
    websocket_listener_task::Union{Task, Nothing} = nothing
    clients::Dict{String, ClientState} = Dict()

    ctx::Union{XfaContext, Nothing} = nothing

    halt_and_catch_fire::Base.Event = Base.Event()
end

wip_state::Dict{Symbol, Any} = Dict()

function Base.getproperty(state::EngineState, sym::Symbol)
    if sym in fieldnames(EngineState)
        return getfield(state, sym)
    else
        return wip_state[sym]
    end
end

function Base.setproperty!(state::EngineState, sym::Symbol, value)
    if sym in fieldnames(EngineState)
        setfield!(state, sym, value)
    else
        wip_state[sym] = value
    end
end

function forward_output(state::EngineState, stream_output)
    for data in stream_output
        for client in values(state.clients)
            Protocol.send(client.websocket, TrainData([data]))
        end
    end
end

"""Close connections to all clients and optionally the websocket listener."""
function shutdown(state::EngineState, ws_server=nothing)
    if ws_server != nothing
        close(ws_server)
    end

    for client in values(state.clients)
        close(client.websocket)
    end
end

function handle_message(msg::AbstractMessage, state::EngineState, id)
    client_state = state.clients[id]
    ws = client_state.websocket

    if msg isa Ping
        client_state.last_heartbeat = time()
        Protocol.send(ws, Pong())
    elseif msg isa Shutdown
        @info "Received shutdown request from client $(id)"
        shutdown(state)
        notify(state.halt_and_catch_fire)
    elseif msg isa GetDevices
        try
            devices = WebProxy.get_devices(msg.webproxy_endpoint)
            Protocol.send(ws, Devices(devices))
            @info "Responded to 'GetDevices' from $(id)"
        catch ex
            @error "Error in 'GetDevices', requested by $(id)" exception=(ex, catch_backtrace())
            Protocol.send(ws, Devices(ex))
        end
    elseif msg isa LoadContext
        path = abspath(expanduser(msg.path))
        state.ctx = Context.load_from_file(path)
        Protocol.send(ws, ContextInfo(Context.to_dict(state.ctx)))
        @info "Loaded context file $(path): $(state.ctx)"
    elseif msg isa ReviseCode
        @everywhere Revise.retry()
        @info "Revised source code"
    elseif msg isa ChangeParameter
        param = msg.parameter
        @info "ChangeParameter of $(param.name) to $(param.value)"
    elseif msg isa Start
        @info "Starting pipeline"
        Context.start_pipeline(state.ctx; forwarder=Base.Fix1(forward_output, state))
    elseif msg isa Stop
        @info "Stopping pipeline"
        Context.stop_pipeline(state.ctx)
    else
        @error "Received unsupported message: $(typeof(msg))"
    end
end

"""Handle a single client."""
function handle_client(state::EngineState, id)
    client_state = state.clients[id]
    ws = client_state.websocket

    # Start by sending their identifier
    WebSockets.send(ws, id)
    @info "Connected to new client: $(id) 🙋"

    for msg_bytes in ws
        buffer = IOBuffer(msg_bytes)
        msg = deserialize(buffer)

        try
            @invokelatest handle_message(msg, state, id)
        catch ex
            @error "Caught exception when handling message from $(id)" exception=(ex, catch_backtrace())
        end
    end

    delete!(state.clients, id)
    @info "Disconnected from client $(id)"
end

# Helper variables/functions to create amusing client IDs
const ID_PREFIXES = ["bothersome", "droopy", "deleterious", "morbid", "snobbish", "mirthful", "joyous", "blithe", "euphoric", "frolicsome"]
const ID_SUFFIXES = ["elf", "balrog", "wizard", "hobbit", "dwarf", "ent", "troll", "goblin", "tom", "dragon"]
create_id() = "$(rand(ID_PREFIXES))-$(rand(ID_SUFFIXES))"

function main(halt_and_catch_fire=Base.Event(); info_path=nothing)
    websocket_port = getavailableport(1331)
    state = EngineState(; websocket_port, halt_and_catch_fire)

    ws_server = WebSockets.listen!("0.0.0.0", state.websocket_port) do ws
        id = create_id()
        try
            # Select their identifier
            while id in keys(state.clients)
                id = create_id()
            end

            # Create a client
            client = ClientState(; websocket=ws, last_heartbeat=time())
            state.clients[id] = client
            handle_client(state, id)
        catch ex
            if ex isa EOFError
                @info "Client $(id) disconnected"
            else
                @error "Error while handling client connecton" exception=(ex, catch_backtrace())
            end
        end
    end

    @info "Started listening on ws://$(gethostname()):$(websocket_port)"

    state.karabo_bridge_port = getavailableport(1332)

    # Write configuration
    worker_info = [(string(p), @fetchfrom p Dict("pid"      => getpid(),
                                                 "hostname" => gethostname()))
                   for p in procs()]
    worker_info = Dict(worker_info)
    worker_info["1"]["websocket-port"] = websocket_port
    worker_info["1"]["karabo-bridge-port"] = state.karabo_bridge_port

    if isnothing(info_path)
        info_path = abspath("worker-info.toml")
    else
        info_path = abspath(expanduser(info_path))
    end

    open(info_path, "w") do io
        TOML.print(io, worker_info)
    end

    @info "Wrote worker information to $(info_path)"

    try
        wait(state.halt_and_catch_fire)
    catch ex
        if ex isa InterruptException
            @info "Shutdown requested, shutting down..."
        else
            @error "Exception thrown in main loop: $(ex)"
        end
    finally
        shutdown(state, ws_server)
        if isopen(ws_server)
            HTTP.forceclose(ws_server)
        end
    end
end

end # module XfelAnalyserEngine
