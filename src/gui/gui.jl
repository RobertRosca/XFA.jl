module GUI

include("renderer.jl")
include("imgui_helpers.jl")
include("states.jl")
include("client.jl")

import SumTypes: @cases

import Revise
import ImPlot as PLT
import CImGui as IG
import CImGui: ImVec2, Begin, End
import CImGui.CSyntax: @c
import XfaEngine.Protocol: Message, send

import .Renderer
using .ImGuiHelpers
import .States: HeadNode, RemoteStatus, WebproxyStatus
import .Client
import ..Util

const WEBPROXY_COMPLETIONS::Vector{String} = [
    "localhost:8484",
    "fxe-rr-sys-con-gui1:8484",
    "spb-rr-sys-con-gui1:8484",
    "mid-rr-sys-con-gui1:8484",
    "hed-rr-sys-con-gui1:8484",
    "scs-rr-sys-con-gui1:8484",
    "sqs-rr-sys-con-gui1:8484",
    "sxp-rr-sys-con-gui1:8484"
]

## Store the state of the GUI between a struct and dict for easy modification
## without having to restart Julia.

@kwdef mutable struct GuiState
    app::Renderer.ImGuiApp
    disable_rendering::Bool = false

    # Showing external tool windows
    show_imgui_demo::Bool = false
    show_imgui_metrics::Bool = false
    show_implot_metrics::Bool = false
    show_implot_demo::Bool = false
    show_stacktool::Bool = false
    show_debug_log::Bool = false

    # Connections to remote things
    headnode::HeadNode = HeadNode()
    connect_to_cluster::Bool = true
    webproxy::String = WEBPROXY_COMPLETIONS[1]
    webproxy_status::WebproxyStatus = WebproxyStatus'.IDLE

    # Karabo status
    karabo_devices::Dict{String, Any} = Dict()
end

wip_state::Dict{Symbol, Any} = Dict()

function Base.getproperty(state::GuiState, sym::Symbol)
    if sym in fieldnames(GuiState)
        return getfield(state, sym)
    else
        return wip_state[sym]
    end
end

function Base.setproperty!(state::GuiState, sym::Symbol, value)
    if sym in fieldnames(GuiState)
        setfield!(state, sym, value)
    else
        wip_state[sym] = value
    end
end

## Helper functions for the GUI

# function update_device_list(state)
#     client = state.webproxy_client
#     client.status = WebProxyClientStatus'.CONNECTING

#     try
#         devices = WebProxy.get_devices(state.webproxy_client)
#         state.karabo_devices = keys(devices)
#         client.status = WebProxyClientStatus'.CONNECTED
#     catch ex
#         client.status = WebProxyClientStatus'.ERROR
#         client.last_error = Util.exception2str(ex, catch_backtrace())
#     end
# end

function draw_revise()
    can_revise = length(Revise.revision_queue) > 0
    @Disabled !can_revise begin
        if IG.Button(can_revise ? "Revise*" : "Revise")
            Revise.retry()
        end
    end
end

function draw_main_menubar(state)
    if IG.BeginMenuBar()
        draw_revise()

        if IG.BeginMenu("Tools")
            if IG.BeginMenu("Demos")
                @c MenuItem("ImGui demo", &state.show_imgui_demo)
                @c MenuItem("ImPlot demo", &state.show_implot_demo)
                IG.EndMenu()
            end

            @c MenuItem("ImGui metrics", &state.show_imgui_metrics)
            @c MenuItem("ImPlot metrics", &state.show_implot_metrics)
            @c MenuItem("Stack tool", &state.show_stacktool)
            @c MenuItem("Debug log", &state.show_debug_log)

            IG.EndMenu()
        end

        IG.EndMenuBar()
    end
end

function draw_webproxy_connection(state)
    # Set up connection to a Karabo WebProxy
    IG.Text("Select a default web proxy:")
    IG.SameLine()

    @Disabled state.webproxy_status == WebproxyStatus'.WAITING_FOR_DEVICES begin
        edited, new_endpoint = EditableComboBox("##select_webproxy",
                                                state.webproxy,
                                                WEBPROXY_COMPLETIONS)
        IG.SameLine()
        if IG.Button("Reload")
            Client.get_devices(state)
            state.current_trainmatcher = Cint(0)
        end
    end

    # Connect immediately if changed
    endpoint_changed = edited && new_endpoint != state.webproxy
    if endpoint_changed
        state.webproxy = new_endpoint
        Client.get_devices(state)
        state.current_trainmatcher = Cint(0)
    end

    # Display webproxy status
    IG.Dummy(0, 10)
    if state.webproxy_status == WebproxyStatus'.IDLE
        trainmatchers = sort([name for (name, properties) in state.karabo_devices
                                  if properties["classId"] ∈ ("TrainMatcher", "ShmemTrainMatcher")])

        if length(trainmatchers) > 0
            IG.Text("Selected trainmatcher: $(trainmatchers[state.current_trainmatcher + 1])")
            @c IG.ListBox("$(length(trainmatchers)) trainmatchers available", &state.current_trainmatcher,
                          trainmatchers, length(trainmatchers), 10)
        else
            IG.Text("No trainmatchers found out of $(length(state.karabo_devices)) devices 😞")
        end
    elseif state.webproxy_status == WebproxyStatus'.WAITING_FOR_DEVICES
        Spinner("Waiting for device list")
    elseif state.webproxy_status == WebproxyStatus'.ERROR
        IG.Text("Error connecting to the webproxy:")
        IG.SameLine()
        if IG.SmallButton("Copy to clipboard")
            # IG.SetClipboardText(webproxy.last_error)
        end

        BoxedText("##webproxy_last_error", "Foo")
    end
end

## Main GUI function

default(value, default="") = isnothing(value) ? default : value

function draw_gui(state)
    # Dock the main window by default
    viewport = IG.igGetMainViewport()
    central_dock_id = IG.igDockSpaceOverViewport(viewport, IG.ImGuiDockNodeFlags_PassthruCentralNode, C_NULL)

    IG.igSetNextWindowDockID(central_dock_id, IG.ImGuiCond_Once)

    main_window_flags = IG.ImGuiWindowFlags_NoCollapse
    main_window_flags |= IG.ImGuiWindowFlags_MenuBar
    main_window_flags |= IG.ImGuiWindowFlags_HorizontalScrollbar

    # Draw the main window
    if Begin("Main window", C_NULL, main_window_flags)
        # Draw the menubar
        draw_main_menubar(state)

        headnode = state.headnode

        can_connect = (headnode.status != RemoteStatus'.CONNECTING &&
            headnode.status != RemoteStatus'.CONNECTED)
        @Disabled !can_connect begin
            @c IG.Checkbox("Connect to cluster node:", &state.connect_to_cluster)
        end
        IG.SameLine()
        @Disabled !state.connect_to_cluster || !can_connect begin
            edited, new_address = SafeInputText("##headnode"; hint="exflonc24.desy.de",
                                                current_text=default(headnode.address))
        end

        if edited
            @info "New address: $(new_address)"
            headnode.address = new_address
        end

        IG.Spacing()
        disable_connect = (headnode.status == RemoteStatus'.CONNECTED
                           || headnode.status == RemoteStatus'.CONNECTING
                           || !state.connect_to_cluster
                           || length(headnode.address) == 0)
        @Disabled disable_connect begin
            if IG.Button("Connect")
                @guiasync Client.initialize_engine(state)
            end
        end
        IG.SameLine()
        @Disabled headnode.status != RemoteStatus'.CONNECTED begin
            if IG.Button("Disconnect & shutdown")
                Client.shutdown_server(state)
            end
        end

        IG.Dummy(0, 10)
        if headnode.status == RemoteStatus'.CONNECTING
            Spinner("Connecting to cluster...")
            BoxedText("##headnode_cmd_output", String(take!(copy(state.headnode_cmd_output))))
        elseif headnode.status == RemoteStatus'.ERROR
            IG.Text("Error connecting to node:")
            BoxedText("##headnode_last_error", headnode.last_error)
        elseif headnode.status == RemoteStatus'.CONNECTED
            IG.Text("Connected with client ID: $(headnode.client_id)")
        end

        if headnode.status == RemoteStatus'.CONNECTED
            IG.Spacing()
            draw_webproxy_connection(state)
        end

        End()
    end

    # Display tooling windows
    for (window_sym, window_func) in [(:show_imgui_demo,     IG.ShowDemoWindow),
                                      (:show_imgui_metrics,  IG.ShowMetricsWindow),
                                      (:show_implot_demo,    PLT.ShowDemoWindow),
                                      (:show_implot_metrics, PLT.ShowMetricsWindow),
                                      (:show_stacktool,      IG.igShowStackToolWindow),
                                      (:show_debug_log,      IG.igShowDebugLogWindow)]
        do_show = getproperty(state, window_sym)
        if do_show
            @c window_func(&do_show)
            setproperty!(state, window_sym, do_show)
        end
    end
end

"""Start the XFA GUI."""
function start_gui()
    app = Renderer.ImGuiApp(; title="XFA", fonts=[
        (joinpath(@__DIR__, "fonts", "Inter-Regular.otf"), 17),
        (joinpath(@__DIR__, "fonts", "JuliaMono-Regular.ttf"), 15),
        (joinpath(@__DIR__, "fonts", "JuliaMono-Regular.ttf"), 16)
    ])

    # Enable docking and viewports by default
    io = IG.GetIO()
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | IG.ImGuiConfigFlags_DockingEnable
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | IG.ImGuiConfigFlags_ViewportsEnable

    # # Disable INI file
    # io.WantSaveIniSettings = false
    # io.IniFilename = C_NULL

    state::GuiState = GuiState(; app)
    state.disable_rendering = false

    empty!(wip_state)
    state.headnode_cmd_output = IOBuffer()
    state.current_trainmatcher = Cint(0)

    Renderer.render(app) do
        if state.disable_rendering
            # Occasionally an exception will occur in the middle of a disabled
            # section, which helpfully also disables the continue button
            # below. So here we check if we're currently disabled and end it if
            # so.
            if IsItemDisabled()
                IG.igEndDisabled()
            end

            IG.Text("Render loop crashed, continue when ready:")
            draw_revise()
            IG.SameLine()
            state.disable_rendering = !IG.Button("Continue")
            return
        end

        try
            @invokelatest draw_gui(state)
        catch ex
            @error "Error while rendering:" exception=(ex, catch_backtrace())
            state.disable_rendering = true
        end
    end
end

end
