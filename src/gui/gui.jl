module GUI

include("renderer.jl")
include("imgui_helpers.jl")
include("states.jl")

import Distributed: addprocs, @fetchfrom

import SumTypes: @cases

import ImPlot as PLT
import CImGui as IG
import CImGui: ImVec2, Begin, End
import CImGui.CSyntax: @c

import .Renderer
using .ImGuiHelpers
using ..WebProxy
import .States: HeadNode, RemoteStatus


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
    connect_to_cluster::Bool = true
    head_node::HeadNode
    webproxy_client::WebProxyClient

    # Karabo status
    karabo_devices::Vector{String} = String[]
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

function exception2str(ex, bt)
    buf = IOBuffer()

    # Note: this three-argument method is undocumented
    showerror(buf, ex, bt)

    # Skip the last character because showerror() inserts a \0, which causes
    # problems with unsafe_convert() when converting to a Cstring.
    return String(take!(buf))[1:end - 1]
end

function update_device_list(state)
    client = state.webproxy_client
    client.status = WebProxyClientStatus'.CONNECTING

    try
        devices = WebProxy.get_devices(state.webproxy_client)
        state.karabo_devices = keys(devices)
        client.status = WebProxyClientStatus'.CONNECTED
    catch ex
        client.status = WebProxyClientStatus'.ERROR
        client.last_error = exception2str(ex, catch_backtrace())
    end
end

function draw_main_menubar(state)
    if IG.BeginMenuBar()
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
    webproxy = state.webproxy_client
    webproxy_is_connecting = webproxy.status == WebProxyClientStatus'.CONNECTING
    IG.Text("Select a web proxy:")
    IG.SameLine()

    @Disabled webproxy_is_connecting begin
        edited, new_endpoint = EditableComboBox("##select_webproxy",
                                                webproxy.endpoint,
                                                WEBPROXY_COMPLETIONS)
        IG.SameLine()
        if IG.Button("Reload")
            @guiasync update_device_list(state)
        end
    end

    # Connect immediately if changed
    endpoint_changed = edited && new_endpoint != webproxy.endpoint
    if endpoint_changed || webproxy.status == WebProxyClientStatus'.UNCONNECTED
        webproxy.endpoint = new_endpoint
        @guiasync update_device_list(state)
    end

    # Display webproxy status
    if webproxy.status == WebProxyClientStatus'.ERROR
        IG.Dummy(0, 10)
        IG.Text("Error connecting to the webproxy:")
        IG.SameLine()
        if IG.SmallButton("Copy to clipboard")
            IG.SetClipboardText(webproxy.last_error)
        end

        BoxedText("##webproxy_last_error", webproxy.last_error)
    elseif webproxy.status == WebProxyClientStatus'.CONNECTED
        IG.Spacing()
        IG.Text("Found $(length(state.karabo_devices)) devices!")
    else
        Spinner("Connecting to WebProxy")
    end
end

function setup_head_node(state)
    head_node = state.head_node
    head_node.status = RemoteStatus'.CONNECTING

    try
        # id = withenv("JULIA_WORKER_TIMEOUT" => 20) do
        #     addprocs([head_node.address]; tunnel=true, dir="/tmp", exename="julia")
        # end
        # id = id[1]
        id = 2

        @fetchfrom id myid()

        head_node.workerid = id
        head_node.status = RemoteStatus'.CONNECTED
    catch ex
        head_node.last_error = exception2str(ex, catch_backtrace())
        head_node.status = RemoteStatus'.ERROR
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

        @c IG.Checkbox("Connect to cluster node:", &state.connect_to_cluster)
        IG.SameLine()

        head_node = state.head_node
        @Disabled !state.connect_to_cluster begin
            edited, new_address = SafeInputText("##head_node"; hint="exflonc24.desy.de",
                                                current_text=default(head_node.address))
        end

        if edited && new_address != ""
            head_node.address = new_address
        end

        IG.Spacing()
        disable_connect = head_node.status == RemoteStatus'.CONNECTED || !state.connect_to_cluster || length(head_node.address) == 0
        @Disabled disable_connect begin
            if IG.Button("Connect")
                @guiasync setup_head_node(state)
            end
        end
        IG.SameLine()
        @Disabled head_node.status != RemoteStatus'.CONNECTED begin
            if IG.Button("Disconnect")
                println("Disconnecting")
            end
        end

        if head_node.status == RemoteStatus'.CONNECTING
            Spinner("Connecting to cluster...")
        elseif head_node.status == RemoteStatus'.ERROR
            IG.Dummy(0, 10)
            IG.Text("Error connecting to $(head_node.address):")
            BoxedText("##head_node_last_error", head_node.last_error)
        elseif head_node.status == RemoteStatus'.CONNECTED
            IG.Text("Connected with workerid $(head_node.workerid)")
        end

        # draw_webproxy_connection(state)

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

    webproxy_client = WebProxyClient(WEBPROXY_COMPLETIONS[1],
                                     WebProxyClientStatus'.UNCONNECTED, "")
    head_node = HeadNode()
    state::GuiState = GuiState(; app, webproxy_client, head_node)
    state.disable_rendering = false

    Renderer.render(app) do
        if state.disable_rendering
            IG.Text("Render loop crashed, continue when ready:")
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
