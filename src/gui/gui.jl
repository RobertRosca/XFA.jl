module GUI

include("imnodes.jl")
include("renderer.jl")
include("imgui_helpers.jl")
include("states.jl")
include("client.jl")

import SumTypes: @cases

import Revise
import ImPlot as PLT
import CImGui as IG
import CImGui: ImVec2, ImVec4, Begin, End
import CImGui.CSyntax: @c
import HTTP: WebSockets

import XfaEngine.Context: KaraboDependency
import XfaEngine.Protocol: Message, send

import .ImNodes
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

function draw_revise(state)
    can_revise = length(Revise.revision_queue) > 0
    @Disabled !can_revise begin
        if IG.Button(can_revise ? "Revise*" : "Revise")
            Revise.retry()

            headnode = state.headnode
            if headnode.status == RemoteStatus'.CONNECTED
                Client.revise_engine(state)
            end
        end
    end
end

function draw_main_menubar(state)
    if IG.BeginMenuBar()
        draw_revise(state)

        @Disabled !state.context_path_valid begin
            if IG.Button("Apply context")
                Client.load_context(state)
            end
        end

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

function draw_dag(state)
    ImNodes.BeginNodeEditor()

    ctx_state = state.context_state
    for (name, var_data) in ctx_state
        min_node_width = 150
        node_id = var_data["id"]

        ImNodes.BeginNode(node_id)
        ImNodes.BeginNodeTitleBar()
        IG.Text(name)
        ImNodes.EndNodeTitleBar()

        for (dep_id, dep) in var_data["dependencies"]
            pin_shape = dep isa KaraboDependency ? ImNodes.ImNodesPinShape_TriangleFilled : ImNodes.ImNodesPinShape_CircleFilled

            ImNodes.BeginInputAttribute(dep_id, pin_shape)
            IG.Text(string(dep))
            ImNodes.EndInputAttribute()
        end

        IG.Dummy(min_node_width, 10)

        for (output_id, output) in var_data["outputs"]
            label = string(output)
            ImNodes.BeginOutputAttribute(output_id, ImNodes.ImNodesPinShape_CircleFilled)
            IG.Indent(min_node_width - IG.CalcTextSize(label).x)
            IG.Text(label)
            ImNodes.EndOutputAttribute()
        end

        ImNodes.EndNode()
    end

    for var_data in values(ctx_state)
        for (link_id, start_id, end_id) in var_data["links"]
            ImNodes.Link(link_id, start_id, end_id)
        end
    end

    ImNodes.MiniMap()
    ImNodes.EndNodeEditor()
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

    headnode = state.headnode

    # Draw the main window
    if Begin("Main window", C_NULL, main_window_flags)
        # Draw the menubar
        draw_main_menubar(state)

        IG.BeginTabBar("main-tab-bar")
        if IG.BeginTabItem("Setup")
            IG.EndTabItem()

            can_connect = (headnode.status != RemoteStatus'.CONNECTING &&
                headnode.status != RemoteStatus'.CONNECTED)
            @Disabled !can_connect begin
                @c IG.Checkbox("Connect to cluster node:", &state.connect_to_cluster)
            end
            IG.SameLine()
            @Disabled !state.connect_to_cluster || !can_connect begin
                edited, new_address = SafeInputText("##headnode"; hint="exflonc24.desy.de",
                                                    current_text=default(headnode.address))

                IG.Text("Use environment:")
                IG.SameLine()
                env_edited, new_environment = SafeInputText("##engine-environment";
                                                            current_text=default(state.engine_environment))
            end

            if edited
                headnode.address = new_address
            end
            if env_edited
                state.engine_environment = new_environment
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

                IG.Dummy(0, 2)
                IG.Separator()
                IG.Dummy(0, 2)

                IG.Text("Use context file:")
                IG.SameLine()
                edited, new_context_path = SafeInputText("##context-file";
                                                         current_text=default(state.context_path))
                if edited
                    state.context_path = expanduser(new_context_path)
                    state.context_path_valid = isfile(state.context_path)
                end

                if !state.context_path_valid
                    IG.TextColored(ImVec4(1, 0.2, 0.5, 1), "Path does not point to a valid file!")
                end
            end
        end

        @Disabled headnode.status != RemoteStatus'.CONNECTED || isempty(state.context_state) begin
            if IG.BeginTabItem("Analysis pipeline")
                draw_dag(state)
                IG.EndTabItem()
            end
        end

        IG.EndTabBar()

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
function main()
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
    state.context_path = ""
    state.context_path_valid = false
    state.engine_environment = "@xfa-default"
    state.context_state = Dict{String, Any}()

    function on_exit()
        ws = state.headnode.websocket
        if ws != nothing && !WebSockets.isclosed(ws)
            close(ws)
        end
    end

    Renderer.render(app; on_exit) do
        if state.disable_rendering
            # Occasionally an exception will occur in the middle of a disabled
            # section, which helpfully also disables the continue button
            # below. So here we check if we're currently disabled and end it if
            # so.
            if IsItemDisabled()
                IG.igEndDisabled()
            end

            IG.Text("Render loop crashed, continue when ready:")
            draw_revise(state)
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
