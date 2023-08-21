module XfelAnalyserEngine

import TOML
import Sockets: listen, close, @ip_str
import Distributed: @fetchfrom, workers, procs

import HTTP
import HTTP: WebSockets


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
    karabo_bridge_port::Int
    websocket_listener_task::Union{Task, Nothing} = nothing
    clients::Dict{String, ClientState} = Dict()

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

"""Close connections to all clients and optionally the websocket listener."""
function teardown(state::EngineState, ws_server=nothing)
    if ws_server != nothing
        close(ws_server)
    end

    for client in values(state.clients)
        close(client.websocket)
    end
end

"""Handle communication of a single client."""
function client_handler(state::EngineState, id)
    client_state = state.clients[id]
    ws = client_state.websocket

    # Start by sending their identifier
    WebSockets.send(ws, id)
    @info "Connected to new client: $(id) 🙋"

    for msg in ws
        if msg == "ping"
            client_state.last_heartbeat = time()
            WebSockets.send(ws, "pong")
        elseif msg == "hcf"
            @info "Received shutdown request from client $(id)"
            teardown(state)
            notify(state.halt_and_catch_fire)
        else
            @info "Message from client $(id): $(msg)"
        end
    end

    delete!(state.clients, id)
    @info "Disconnected from client $(id)"
end

# Helper variables/functions to create amusing client IDs
const ID_PREFIXES = ["bothersome", "droopy", "deleterious", "morbid", "snobbish", "mirthful", "joyous", "blithe", "euphoric", "frolicsome"]
const ID_SUFFIXES = ["elf", "balrog", "wizard", "hobbit", "dwarf", "ent", "troll", "goblin", "tom", "dragon"]
create_id() = "$(rand(ID_PREFIXES))-$(rand(ID_SUFFIXES))"

function main()
    websocket_port = getavailableport(1331)
    karabo_bridge_port = getavailableport(1332)
    state = EngineState(; websocket_port, karabo_bridge_port)

    ws_server = WebSockets.listen!("0.0.0.0", state.websocket_port) do ws
        try
            # Select their identifier
            id = create_id()
            while id in keys(state.clients)
                id = create_id()
            end

            # Create a client
            client = ClientState(; websocket=ws, last_heartbeat=time())
            state.clients[id] = client
            client_handler(state, id)
        catch ex
            @error "Error while handling client connecton: $(ex)"
        end
    end

    @info "Started listening on ws://$(gethostname()):$(websocket_port)"

    # Write configuration
    worker_info = [(string(p), @fetchfrom p Dict("pid"      => getpid(),
                                                 "hostname" => gethostname()))
                   for p in procs()]
    worker_info = Dict(worker_info)
    worker_info["1"]["websocket-port"] = websocket_port
    worker_info["1"]["karabo-bridge-port"] = karabo_bridge_port

    info_path = abspath("worker-info.toml")
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
        teardown(state, ws_server)
        if isopen(ws_server)
            HTTP.forceclose(ws_server)
        end
    end
end

end # module XfelAnalyserEngine
