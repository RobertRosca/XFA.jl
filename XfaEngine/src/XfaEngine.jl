module XfaEngine

include("karabo_bridge.jl")
include("context.jl")
include("protocol.jl")

using .Context: KaraboDevice
include("webproxy.jl")

import TOML
import Sockets
import Sockets: listen, close, @ip_str, TCPServer
import DistributedNext: @everywhere, @fetchfrom, workers, procs
using Serialization

import HTTP
import HTTP: WebSockets
import Revise
import RemoteREPL
using DimensionalData: DimArray

using .Protocol
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
    websocket_port::Int = -1
    karabo_bridge_port::Int = -1
    websocket_listener_task::Union{Task, Nothing} = nothing
    clients::Dict{String, ClientState} = Dict()

    webproxies::Dict{String, WebProxy} = Dict()
    default_trainmatchers::Dict{String, String} = Dict()

    remoterepl_server::TCPServer = TCPServer()
    remoterepl_task::Union{Task, Nothing} = nothing

    ctx::XfaContext = XfaContext()

    stop_event::Base.Event = Base.Event()
    stop_task::Union{Task, Nothing} = nothing
end

current_engine_state::Union{EngineState, Nothing} = nothing

function forward_output(state::EngineState, stream_output)
    for data in stream_output
        for client in values(state.clients)
            Protocol.server_send(client.websocket, TrainData([data]))
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

function handle_message(msg::AbstractMessage, state::EngineState, id, request_id::Union{MessageId, Nothing})
    client_state = state.clients[id]
    ws = client_state.websocket
    reply_to = request_id

    if msg isa Ping
        client_state.last_heartbeat = time()
        Protocol.server_send(ws, Pong(); reply_to)
    elseif msg isa Shutdown
        @info "Received shutdown request from client $(id)"
        shutdown(state)
        notify(state.stop_event)
    elseif msg isa SetTopicTrainmatcher
        state.default_trainmatchers[msg.topic] = msg.trainmatcher
        @info "Set default trainmatcher for topic '$(msg.topic)' to: $(msg.trainmatcher)"
        Protocol.server_send(ws, Ack(); reply_to)
    elseif msg isa GetDevices
        try
            devices = if isnothing(msg.topic)
                get_all_devices(state.webproxies)
            else
                Dict(msg.topic => get_devices(state.webproxies[msg.topic]))
            end
            Protocol.server_send(ws, Devices(devices); reply_to)
            @info "Responded to 'GetDevices' from $(id)"
        catch ex
            @error "Error in 'GetDevices', requested by $(id)" exception=(ex, catch_backtrace())
            Protocol.server_send(ws, Devices(ex); reply_to)
        end
    elseif msg isa GetDeviceSchema
        schema = get_schema(KaraboDevice(msg.topic, msg.name))
        Protocol.server_send(ws, DeviceSchema(msg.topic, msg.name, schema); reply_to)
        @info "Responded to 'GetDeviceSchema' from $(id)"
    elseif msg isa GetDeviceProperty
        try
            wp = get_webproxy(KaraboDevice(msg.topic, msg.device))
            value = get_property(wp, msg.device, msg.property)
            Protocol.server_send(ws, DeviceProperty(msg.topic, msg.device, msg.property, value); reply_to)
            @info "Responded to 'GetDeviceProperty' ($(msg.device).$(msg.property)) from $(id)"
        catch ex
            @error "Error in 'GetDeviceProperty', requested by $(id)" exception=(ex, catch_backtrace())
            Protocol.server_send(ws, DeviceProperty(msg.topic, msg.device, msg.property, ex); reply_to)
        end
    elseif msg isa GetTrainmatchers
        trainmatchers = get_all_trainmatchers(state.webproxies)
        Protocol.server_send(ws, AvailableTrainmatchers(trainmatchers, state.default_trainmatchers); reply_to)
    elseif msg isa LoadContext
        path = abspath(expanduser(msg.path))

        was_running = state.ctx.is_running[]
        if was_running
            Context.stop_pipeline(state.ctx)
        end

        new_ctx_or_ex = try
            ctx = Context.load_from_file(path)
            ctx.forwarder = Base.Fix1(forward_output, state)
            ctx
        catch ex
            ex
        end

        if new_ctx_or_ex isa XfaContext
            state.ctx = new_ctx_or_ex
            if was_running
                @invokelatest Context.start_pipeline(state.ctx)
            end

            @info "Loaded context file $(path): $(state.ctx)"
            source = read(path, String)
            Protocol.server_send(ws, ContextInfo(state.ctx, source); reply_to)
        else
            @error "Loading context file at $(path) failed" exception=new_ctx_or_ex
            Protocol.server_send(ws, ContextInfo(new_ctx_or_ex, state.ctx.is_running[], ""); reply_to)
        end
    elseif msg isa ReviseCode
        @everywhere Revise.revise()
        @info "Revised source code"
        Protocol.server_send(ws, Ack(); reply_to)
    elseif msg isa ChangeParameter
        param = msg.parameter
        Context.change_parameter(param)
        @info "ChangeParameter of $(param.name) to $(param.value)"
        Protocol.server_send(ws, Ack(); reply_to)
    elseif msg isa Start
        @info "Starting pipeline..."
        try
            Context.start_pipeline(state.ctx)
            Protocol.server_send(ws, Ack(); reply_to)
        catch ex
                @error "Failed to start pipeline" exception=(ex, catch_backtrace())
            Protocol.server_send(ws, Ack(ex); reply_to)
        end
        @info "Started"
    elseif msg isa Stop
        @info "Stopping pipeline..."
        Context.stop_pipeline(state.ctx)
        Protocol.server_send(ws, Stopped(); reply_to)
        @info "Stopped"
    elseif msg isa SetDebugMode
        @info "Setting debug mode: $(msg.enable)"
        if msg.enable
            ENV["JULIA_DEBUG"] = "XfaEngine"
        else
            delete!(ENV, "JULIA_DEBUG")
        end

        Protocol.server_send(ws, Ack(); reply_to)
    elseif msg isa SetRemoteRepl
        if msg.enable
            @info "Starting RemoteREPL"
            port, state.remoterepl_server = Sockets.listenany(27754)
            state.remoterepl_task = Threads.@spawn RemoteREPL.serve_repl(state.remoterepl_server)
            Protocol.server_send(ws, RemoteReplState(true, Int(port)); reply_to)
        else
            @info "Stopping RemoteREPL"
            close(state.remoterepl_server)
            wait(state.remoterepl_task)
            Protocol.server_send(ws, RemoteReplState(false, -1); reply_to)
        end
    else
        @error "Received unsupported message: $(typeof(msg))"
    end
end

"""Handle a single client."""
function handle_client(state::EngineState, id)
    client_state = state.clients[id]
    ws = client_state.websocket

    # Start by sending their identifier and engine directory
    WebSockets.send(ws, id)
    WebSockets.send(ws, pkgdir(XfaEngine))
    @info "Connected to new client: $(id) 🙋"

    # Send available trainmatchers with defaults
    trainmatchers = if !isempty(state.webproxies)
        try
            get_all_trainmatchers(state.webproxies)
        catch ex
            @warn "Failed to query trainmatchers for client $(id)" exception=(ex, catch_backtrace())
            Dict{String, Vector{String}}()
        end
    else
        Dict{String, Vector{String}}()
    end
    Protocol.server_send(ws, AvailableTrainmatchers(trainmatchers, state.default_trainmatchers))

    # If a context is already loaded, send it to the new client
    if !isempty(state.ctx.path)
        Protocol.server_send(ws, ContextInfo(state.ctx, read(state.ctx.path, String)))
    end

    for msg_bytes in ws
        buffer = IOBuffer(msg_bytes)
        envelope = deserialize(buffer)::Envelope

        try
            @invokelatest handle_message(envelope.msg, state, id, envelope.id)
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

function main(stop_event=Base.Event(); info_path=nothing, wait=true)
    websocket_port = getavailableport(1331)
    state = EngineState(; websocket_port, stop_event)
    global current_engine_state = state

    if haskey(ENV, "SASE")
        merge!(state.webproxies, Dict(instrument => WebProxy(address)
                                      for (instrument, address) in DEFAULT_WEBPROXY_ADDRESSES))
    elseif !endswith(gethostname(), ".desy.de")
        state.webproxies["localhost"] = WebProxy("localhost:8484")
    end

    # Query trainmatchers and assign defaults
    if !isempty(state.webproxies)
        try
            all_trainmatchers = get_all_trainmatchers(state.webproxies)
            for (topic, matchers) in all_trainmatchers
                if !isempty(matchers)
                    state.default_trainmatchers[topic] = first(matchers)[1]
                end
            end
            @info "Initialized default trainmatchers" defaults=state.default_trainmatchers
        catch ex
            @warn "Failed to query trainmatchers on startup" exception=(ex, catch_backtrace())
        end
    end

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

    state.stop_task = Threads.@spawn try
        Base.wait(state.stop_event)
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

    if wait
        Base.wait(state.stop_task)
    end

    return state
end

end # module XfelAnalyserEngine
