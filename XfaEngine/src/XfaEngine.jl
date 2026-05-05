module XfaEngine

include("karabo_bridge.jl")
include("context.jl")

import TOML
import Glob
include("settings.jl")
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
import .Context: XfaContext, VariableData, ArrayMetadata


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

    # Fully-qualified names of array-valued variables this client wants
    # forwarded. Updated via `SetVariableSubscriptions`.
    subscriptions::Set{String} = Set{String}()
end

@kwdef mutable struct EngineState
    websocket_port::Int = -1
    karabo_bridge_port::Int = -1
    websocket_listener_task::Union{Task, Nothing} = nothing
    clients::Dict{String, ClientState} = Dict()

    webproxies::Dict{String, WebProxy} = Dict()
    routing_rules::Vector{RoutingRule} = RoutingRule[]

    remoterepl_server::TCPServer = TCPServer()
    remoterepl_task::Union{Task, Nothing} = nothing

    ctx::XfaContext = XfaContext()

    channel_stats_task::Union{Task, Nothing} = nothing

    stop_event::Base.Event = Base.Event()
    stop_task::Union{Task, Nothing} = nothing
end

current_engine_state::Union{EngineState, Nothing} = nothing

# 0-D values (numbers, strings, scalar arrays) are cheap to ship and always
# forwarded; multi-element arrays must be opted into via subscription.
is_scalar_data(x) = !(x isa AbstractArray) || ndims(x) == 0

# Strip a non-subscribed variable down to identity + shape. The client only
# needs this much to render plot buttons / type labels; the heavy fields
# (title, axis labels, etc.) are dropped to save bandwidth.
function metadata_only(variable::VariableData; subvariables=variable.subvariables)
    VariableData(; tid=variable.tid, name=variable.name,
                 data=ArrayMetadata(eltype(variable.data), collect(size(variable.data))),
                 subvariables, update_rate=variable.update_rate)
end

# Build a per-client view of a variable: parent and subvariables that are
# scalar or subscribed pass through unchanged; non-subscribed array payloads
# are replaced with `ArrayMetadata`.
function filter_subscriptions(variable::VariableData, subscriptions::Set{String})
    parent_keep = is_scalar_data(variable.data) || variable.name in subscriptions

    new_subvars = if isempty(variable.subvariables)
        variable.subvariables
    else
        kept = Dict{String, Any}()
        for (subname, subvar) in variable.subvariables
            qualified = "$(variable.name).$(subname)"
            if is_scalar_data(subvar.data) || qualified in subscriptions
                kept[subname] = subvar
            else
                kept[subname] = metadata_only(subvar)
            end
        end
        kept
    end

    if parent_keep && new_subvars === variable.subvariables
        return variable
    end

    if !parent_keep
        return metadata_only(variable; subvariables=new_subvars)
    end

    return VariableData(; tid=variable.tid, name=variable.name, data=variable.data,
                        subvariables=new_subvars,
                        title=variable.title, x_axis=variable.x_axis, y_axis=variable.y_axis,
                        xlabel=variable.xlabel, ylabel=variable.ylabel, unit=variable.unit,
                        fixed_aspect=variable.fixed_aspect, update_rate=variable.update_rate)
end

function forward_output(state::EngineState, stream_output)
    for data in stream_output
        for (id, client) in state.clients
            filtered = filter_subscriptions(data, client.subscriptions)
            try
                Protocol.server_send(client.websocket, TrainData([filtered]))
            catch ex
                @warn "Couldn't forward data to client '$(id)'" exception=ex
            end
        end
    end
end

# Periodically broadcast a snapshot of every variable channel's drop count,
# fill level, and capacity to all connected clients. Used by the GUI to color
# pipeline edges by load.
function broadcast_channel_stats(state::EngineState; period=1.0)
    stats = Dict{Tuple{String, String}, Context.ChannelStat}()

    while !state.stop_event.set
        sleep(period)
        # Re-read state.ctx each iteration — LoadContext swaps it for a fresh
        # XfaContext, so capturing it outside the loop would leave us pinned
        # to the never-running default context.
        ctx = state.ctx
        if !ctx.is_running[] || isempty(state.clients)
            continue
        end

        empty!(stats)
        try
            # Karabo edges are served by a two-stage channel chain
            # (input -> extractor -> consumer). Drops may land on either
            # stage, so sum both into a single edge entry keyed by
            # (dep_name, consumer); size reflects the downstream stage
            # since that's what the consumer actually sees queued.
            for (dep_name, downstream) in ctx.external_dependency_channels
                input_name = ctx.dep_to_input[dep_name]
                up = Context.channel_stat(ctx.input_variable_channels[input_name][dep_name])
                for (consumer, channel) in downstream
                    ds = Context.channel_stat(channel)
                    stats[(dep_name, consumer)] = Context.ChannelStat(up.drops + ds.drops, ds.size, ds.capacity)
                end
            end
            for (producer, downstream) in ctx.variable_channels
                for (consumer, channel) in downstream
                    stats[(producer, consumer)] = Context.channel_stat(channel)
                end
            end
        catch ex
            @warn "Failed to gather channel stats" exception=(ex, catch_backtrace())
            continue
        end

        msg = Protocol.ChannelStats(stats)
        for client in values(state.clients)
            try
                Protocol.server_send(client.websocket, msg)
            catch ex
                @debug "Failed to send ChannelStats to client" exception=(ex, catch_backtrace())
            end
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
    elseif msg isa GetRoutingRules
        Protocol.server_send(ws, RoutingRules(state.routing_rules); reply_to)
    elseif msg isa SetRoutingRules
        state.routing_rules = msg.rules
        write_routing_rules(msg.rules)
        @info "Updated routing rules" n=length(msg.rules) path=engine_settings_path()
        Protocol.server_send(ws, Ack(); reply_to)

        # Broadcast to all clients so concurrent editors stay in sync.
        broadcast = RoutingRules(state.routing_rules)
        for (other_id, other) in state.clients
            if other_id == id
                continue
            end
            try
                Protocol.server_send(other.websocket, broadcast)
            catch ex
                @warn "Failed to broadcast routing rules to client '$(other_id)'" exception=ex
            end
        end
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
    elseif msg isa GetEngineDir
        Protocol.server_send(ws, EngineDir(pkgdir(XfaEngine)); reply_to)
    elseif msg isa GetTrainmatchers
        trainmatchers = get_all_trainmatchers(state.webproxies)
        Protocol.server_send(ws, AvailableTrainmatchers(trainmatchers); reply_to)
    elseif msg isa LoadContext
        path = abspath(expanduser(msg.path))

        was_running = state.ctx.is_running[]
        if was_running
            Context.stop_pipeline(state.ctx)
        end

        new_ctx_or_ex = try
            ctx = Context.load_from_file(path; routing_rules=state.routing_rules)
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
        Context.change_parameter(state.ctx, param)
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
    elseif msg isa SetVariableSubscriptions
        client_state.subscriptions = msg.variables
        Protocol.server_send(ws, Ack(); reply_to)
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

    # Start by sending their identifier
    WebSockets.send(ws, id)
    @info "Connected to new client: $(id) 🙋"

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

    loaded = load_routing_rules()
    if isnothing(loaded)
        # First run: seed one {topic, "*", first_matcher} rule per discovered
        # topic and persist, so subsequent runs read the file verbatim.
        rules = RoutingRule[]
        if !isempty(state.webproxies)
            try
                for (topic, matchers) in get_all_trainmatchers(state.webproxies)
                    if !isempty(matchers)
                        push!(rules, RoutingRule(topic, "*", first(matchers)[1]))
                    end
                end
            catch ex
                @warn "Failed to query trainmatchers while seeding routing rules" exception=(ex, catch_backtrace())
            end
        end
        write_routing_rules(rules)
        state.routing_rules = rules
        @info "Seeded routing rules" n=length(rules) path=engine_settings_path()
    else
        state.routing_rules = loaded
        @info "Loaded routing rules" n=length(loaded) path=engine_settings_path()
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

    state.channel_stats_task = Threads.@spawn broadcast_channel_stats(state)
    errormonitor(state.channel_stats_task)

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
        Base.wait(state.channel_stats_task)
    end

    return state
end

end # module XfelAnalyserEngine
