@enum RemoteStatus begin
    RemoteStatus_Unconnected
    RemoteStatus_Initializing
    RemoteStatus_Connecting
    RemoteStatus_Connected
    RemoteStatus_Disconnecting
    RemoteStatus_Error
end

@enum WebproxyStatus begin
    WebproxyStatus_Idle
    WebproxyStatus_WaitingForDevices
    WebproxyStatus_Error
end

@enum SshStatus begin
    SshStatus_Unconnected
    SshStatus_Connecting
    SshStatus_NeedsAuth
    SshStatus_Error
end

@enum PipelineStatus begin
    PipelineStatus_Starting
    PipelineStatus_Started
    PipelineStatus_LoadingContext
    PipelineStatus_Stopping
    PipelineStatus_Stopped
end

@enum RemoteReplStatus begin
    RemoteReplStatus_Running
    RemoteReplStatus_Changing
    RemoteReplStatus_Stopped
end

mutable struct KbdintPromptState
    msg::String
    display::Bool
    answer::String
end

mutable struct PasswordStore
    const buf::Base.SecretBuffer

    function PasswordStore(password=nothing)
        buf = Base.SecretBuffer()
        if !isnothing(password)
            write(buf, password)
        end

        finalizer(new(buf)) do x
            Base.shred!(x.buf)
        end
    end
end

function Base.getindex(x::PasswordStore)
    str = read(x.buf, String)
    seekstart(x.buf)
    str
end

function Base.setindex!(x::PasswordStore, value::String)
    Base.shred!(x.buf)
    write(x.buf, value)
    seekstart(x.buf)
end

@kwdef mutable struct SshState
    address::String
    port::Int = 22

    auth_state::Any = nothing
    auth_method::Maybe{ssh.AuthMethod} = nothing
    session::Maybe{ssh.Session} = nothing
    forwarder::Maybe{ssh.Forwarder} = nothing

    password::PasswordStore = PasswordStore()
    kbdint_prompts::Vector{KbdintPromptState} = KbdintPromptState[]

    lock::ReentrantLock = ReentrantLock()
end

Base.lock(state::SshState) = lock(state.lock)
Base.unlock(state::SshState) = unlock(state.lock)

function Base.close(state::SshState)
    if !isnothing(state.forwarder)
        close(state.forwarder)
    end
    if !isnothing(state.session)
        close(state.session)
    end

    state.password = PasswordStore()
    empty!(state.kbdint_prompts)
end

# This enum tracks the original type of the variables. We need to distinguish
# this from how they're stored because both scalars and vectors are stored as
# vectors.
@enum VariableType begin
    VariableType_Scalar
    VariableType_Vector
    VariableType_Array
    VariableType_Unknown
end

mutable struct VariableStore
    const updates::Channel
    data::Union{Vector, Matrix, DimVector, DimMatrix}
    type::VariableType

    # This field is only used for non-scalar data. Scalar data is stored as a
    # DimArray with a train ID.
    trainId::Int
end

VariableStore(data) = VariableStore(Channel(100), data, VariableType_Unknown, -1)

@kwdef mutable struct ContextState
    context_state::Dict{String, Any} = Dict()
    context_path::String = ""
    node_positions::Dict{String, Point2d} = Dict()
    pipeline_status::PipelineStatus = PipelineStatus_Stopped

    lock::ReentrantLock = ReentrantLock()
end

function ContextState(settings::Dict; kwargs...)
    client_settings = get(settings, "ClientState", Dict{String, Any}())
    context_path = get(client_settings, "context_path", "")

    node_positions = Dict{String, Point2d}()
    contexts = get(client_settings, "contexts", Dict())
    if haskey(contexts, context_path)
        saved_positions = get(contexts[context_path], "node_positions", Dict())
        for (name, pos) in saved_positions
            node_positions[name] = Point2d(pos[1], pos[2])
        end
    end

    ContextState(; context_path, node_positions, kwargs...)
end

Base.lock(ctx::ContextState) = lock(ctx.lock)
Base.unlock(ctx::ContextState) = unlock(ctx.lock)

function Base.setproperty!(ctx::ContextState, sym::Symbol, x)
    @lock ctx setfield!(ctx, sym, x)
end

@kwdef mutable struct ClientState
    client_id::String = ""
    worker_info::Dict = Dict()

    debug_mode::Ref{Bool} = Ref(false)
    syncing::Bool = false
    status::RemoteStatus = RemoteStatus_Unconnected
    websocket::Maybe{WebSockets.WebSocket} = nothing
    ssh_hops::Vector{SshState} = SshState[]
    sftp::Maybe{ssh.SftpSession} = nothing
    ws_forwarder::Maybe{ssh.Forwarder} = nothing
    remote_engine_dir::String = ""

    cmd_output::String = ""
    last_error::String = ""

    embedded_engine::Bool = false
    engine::Maybe{EngineState} = nothing

    default_topic_idx::Ref{Cint} = Ref(Cint(0))
    available_topics::Vector{String} = String[]
    webproxy_status::WebproxyStatus = WebproxyStatus_Idle
    remoterepl_mode::Ref{Bool} = Ref(false)
    remoterepl_status::RemoteReplStatus = RemoteReplStatus_Stopped

    # Context file and pipeline
    context_path::String = ""
    context_path_valid::Bool = false
    context::ContextState = ContextState()

    # Karabo status
    trainmatchers::Dict{String, Any} = Dict()
    karabo_devices::Dict{String, Any} = Dict()

    # Variables and plots
    variable_data::Dict{String, VariableStore} = Dict()
    plot_counter::Int = 0
    plots::Vector{Union{Plot, CorrelationPlot}} = Union{Plot, CorrelationPlot}[]

    lock::ReentrantLock = ReentrantLock()
end

function ClientState(settings::Dict; kwargs...)
    client_settings = get(settings, "ClientState", Dict{String, Any}())
    context_path = get(client_settings, "context_path", "")
    context = ContextState(settings)

    ClientState(; context_path, context, kwargs...)
end

function Base.lock(state::ClientState)
    lock(state.lock)
    lock(state.context)
end

function Base.unlock(state::ClientState)
    unlock(state.context)
    unlock(state.lock)
end

function Base.setproperty!(state::ClientState, sym::Symbol, x)
    @lock state setfield!(state, sym, x)
    save_settings(state, sym)
end

function Base.show(io::IO, client::ClientState)
    print(io, ClientState, "(client_id=$(client.client_id), $(client.status), $(length(client.ssh_hops)) SSH hops)")
end

function Base.close(client::ClientState)
    if !isnothing(client.websocket)
        close(client.websocket)
    end

    # Kill the SSH connections
    if !isnothing(client.sftp)
        close(client.sftp)
    end
    if !isnothing(client.ws_forwarder)
        close(client.ws_forwarder)
    end

    for ssh_state in Iterators.reverse(client.ssh_hops)
        close(ssh_state)
    end

    # Kill any local engine
    if !isnothing(client.engine)
        notify(client.engine.stop_event)
        wait(client.engine.stop_task)
    end

    # Delete any cached values
    empty!(ImGuiHelpers.safe_input_text_cache)
    empty!(client.variable_data)
end

@kwdef mutable struct GuiState
    disable_rendering::Bool = false

    # Showing external tool windows
    show_imgui_demo::Bool = false
    show_imgui_metrics::Bool = false
    show_implot_metrics::Bool = false
    show_implot_demo::Bool = false
    show_stacktool::Bool = false
    show_debug_log::Bool = false
    show_state_inspector::Bool = false

    # Connections to remote things
    address::String = "wrigleyj@exflonc202.desy.de"
    client::ClientState = ClientState()
    engine_environment::String = "@xfa-default"
    client_type_current_item::Cint = Cint(0)

    # Plot layout persistence, keyed by context path
    saved_contexts::Dict{String, Dict{String, Any}} = Dict()

    lock::ReentrantLock = ReentrantLock()
end

function GuiState(settings::Dict; kwargs...)
    gui = get(settings, "GuiState", Dict{String, Any}())
    client_settings = get(settings, "ClientState", Dict{String, Any}())

    address = get(gui, "address", "wrigleyj@exflonc202.desy.de")
    engine_environment = get(gui, "engine_environment", "@xfa-default")
    client_type_current_item = Cint(get(gui, "client_type", 0))
    saved_contexts = Dict{String, Dict{String, Any}}(
        k => Dict{String, Any}(v) for (k, v)
            in get(client_settings, "contexts", Dict()))

    client = ClientState(settings; embedded_engine = client_type_current_item == 1)

    GuiState(; address, engine_environment, client_type_current_item,
             saved_contexts, client, kwargs...)
end

function Base.setproperty!(state::GuiState, sym::Symbol, x)
    @lock state setfield!(state, sym, x)
    save_settings(state, sym)
end

function Base.show(io::IO, state::GuiState)
    print(io, GuiState, "(engine_environment=\"$(state.engine_environment)\")")
end

function Base.close(state::GuiState)
    close(state.client)
end

function Base.lock(state::GuiState)
    lock(state.lock)
    lock(state.client.lock)
end

function Base.unlock(state::GuiState)
    unlock(state.client.lock)
    unlock(state.lock)
end
