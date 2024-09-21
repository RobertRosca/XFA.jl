module States

import LibSSH as ssh
import HTTP.WebSockets as ws

import XfaEngine.Protocol: Message, send
import ...Maybe

export GuiState

macro exportinstances(enum)
    eval = GlobalRef(Core, :eval)
    return :($eval($__module__, Expr(:export, map(Symbol, instances($enum))...)))
end


@enum RemoteStatus begin
    RemoteStatus_Unconnected
    RemoteStatus_Connecting
    RemoteStatus_Connected
    RemoteStatus_Error
end
@exportinstances RemoteStatus

@enum WebproxyStatus begin
    WebproxyStatus_Idle
    WebproxyStatus_WaitingForDevices
    WebproxyStatus_Error
end
@exportinstances WebproxyStatus

@enum SshStatus begin
    SshStatus_Unconnected
    SshStatus_Connecting
    SshStatus_NeedsAuth
    SshStatus_Error
end
@exportinstances SshStatus

"""
A type to help with implementing thread-safe revise-able states.

TL;DR:
- An ExtendableState must have a extras::Dict field to store extra properties
  dynamically, and a lock::AbstractLock field to lock the state object during
  modification.
- To add/remove properties dynamically the extras_defaults(T) method must
  return a Dict of all extra properties and their default value.
"""
abstract type ExtendableState end

extras_defaults(::ExtendableState) = Dict()

function update_extras(state::T) where T <: ExtendableState
    defaults = extras_defaults(state)
    extras = getfield(state, :extras)

    # Fast path
    if keys(defaults) == keys(extras)
        return
    end

    for (key, value) in defaults
        if !haskey(extras, key)
            extras[key] = value
        end
    end

    for key in collect(keys(extras))
        if !haskey(defaults, key)
            pop!(extras, key)
        end
    end
end

function Base.getproperty(state::T, sym::Symbol) where T <: ExtendableState
    update_extras(state)

    if hasfield(T, sym)
        getfield(state, sym)
    elseif haskey(state.extras, sym)
        state.extras[sym]
    else
        error("Type $(T) has no field '$(sym)'")
    end
end

Base.lock(state::ExtendableState) = lock(state.lock)
Base.unlock(state::ExtendableState) = unlock(state.lock)

function _state_setproperty!(state::T, sym, x) where T <: ExtendableState
    if hasfield(T, sym)
        setfield!(state, sym, x)
    elseif haskey(state.extras, sym)
        state.extras[sym] = x
    else
        error("Type $(T) has no field '$(sym)'")
    end
end

function Base.setproperty!(state::T, sym::Symbol, x) where T <: ExtendableState
    update_extras(state)

    if getproperty(state, sym) isa ExtendableState
        _state_setproperty!(state, sym, x)
    else
        @lock state begin
            _state_setproperty!(state, sym, x)
        end
    end
end

mutable struct KbdintPromptState
    msg::String
    display::Bool
    answer::String
end

@kwdef mutable struct SshState <: ExtendableState
    address::String
    port::Int = 22

    auth_state::Any = nothing
    auth_method::Maybe{ssh.AuthMethod} = nothing
    session::Maybe{ssh.Session} = nothing
    forwarder::Maybe{ssh.Forwarder} = nothing

    password::String = ""
    kbdint_prompts::Vector{KbdintPromptState} = KbdintPromptState[]

    extras::Dict{Symbol, Any} = Dict{Symbol, Any}()
    lock::ReentrantLock = ReentrantLock()
end

extras_defaults(::SshState) = Dict(
)

function Base.close(state::SshState)
    if !isnothing(state.forwarder)
        close(state.forwarder)
    end
    if !isnothing(state.session)
        close(state.session)
    end
end

@kwdef mutable struct ClientState <: ExtendableState
    client_id::String = ""
    worker_info::Dict = Dict()

    status::RemoteStatus = RemoteStatus_Unconnected
    websocket::Maybe{ws.WebSocket} = nothing
    ssh_hops::Vector{SshState} = SshState[]
    ws_forwarder::Maybe{ssh.Forwarder} = nothing

    cmd_output::String = ""
    last_error::String = ""

    extras::Dict{Symbol, Any} = Dict{Symbol, Any}()
    lock::ReentrantLock = ReentrantLock()
end

extras_defaults(::ClientState) = Dict(
)

function Base.show(io::IO, client::ClientState)
    print(io, ClientState, "(client_id=$(client.client_id), $(client.status), $(length(client.ssh_hops)) SSH hops)")
end

function Base.close(client::ClientState)
    if !isnothing(client.websocket)
        close(client.websocket)
    end

    # Kill the SSH connections
    if !isnothing(client.ws_forwarder)
        close(client.ws_forwarder)
    end

    for ssh_state in Iterators.reverse(client.ssh_hops)
        close(ssh_state)
    end
end

@kwdef mutable struct GuiState <: ExtendableState
    disable_rendering::Bool = false

    # Showing external tool windows
    show_imgui_demo::Bool = false
    show_imgui_metrics::Bool = false
    show_implot_metrics::Bool = false
    show_implot_demo::Bool = false
    show_stacktool::Bool = false
    show_debug_log::Bool = false

    # Connections to remote things
    address::String = "wrigleyj@exflonc26.desy.de"
    client::ClientState = ClientState()
    webproxy::String = ""
    webproxy_status::WebproxyStatus = WebproxyStatus_Idle

    # Context file
    context_state::Dict{String, Any} = Dict()
    context_path::String = ""
    context_path_valid::Bool = false
    engine_environment::String = "@xfa-default"

    # Karabo status
    trainmatchers::Dict{String, Any} = Dict()
    karabo_devices::Dict{String, Any} = Dict()

    extras::Dict{Any, Any} = Dict()
    lock::ReentrantLock = ReentrantLock()
end

function Base.show(io::IO, state::GuiState)
    print(io, GuiState, "(context_path=\"$(state.context_path)\", engine_environment=\"$(state.engine_environment)\")")
end

Base.close(state::GuiState) = close(state.client)

function Base.lock(state::GuiState)
    lock(state.lock)
    lock(state.client.lock)
end

function Base.unlock(state::GuiState)
    unlock(state.client.lock)
    unlock(state.lock)
end

end
