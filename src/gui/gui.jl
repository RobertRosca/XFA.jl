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
import LibSSH as ssh

import XfaEngine.Context: KaraboDependency, Parameter
import XfaEngine.Protocol: Message, send

import .ImNodes
import .Renderer
using .ImGuiHelpers
import .States: GuiState, ClientState, RemoteStatus
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

            client = state.client
            if client.status == RemoteStatus'.CONNECTED
                Client.revise_engine(state)
            end
        end
    end
end

function draw_main_menubar(state)
    if IG.BeginMenuBar()
        draw_revise(state)

        @Disabled state.client.status != RemoteStatus'.CONNECTED || !state.context_path_valid begin
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

function draw_parameter(param::Parameter{Float64})
    @c IG.InputDouble(param.name, &param.value)
end

function draw_parameter(param::Parameter{Int})
    int32_value = Int32(param.value)
    @c IG.InputInt(param.name, &int32_value)
    param.value = Int(int32_value)
end

function draw_dag(state)
    ImNodes.BeginNodeEditor()

    ctx_state = state.context_state
    for (name, var_data) in ctx_state
        min_node_width = 150
        node_id = var_data["id"]

        # Draw titlebar
        ImNodes.BeginNode(node_id)
        ImNodes.BeginNodeTitleBar()
        IG.Text(name)
        ImNodes.EndNodeTitleBar()

        # Draw parameters
        if !isempty(var_data["parameters"])
            IG.Text("Parameters:")
        end
        for param in values(var_data["parameters"])
            draw_parameter(param)
        end

        IG.Dummy(min_node_width, 10)

        # Draw dependencies
        deps = var_data["dependencies"]
        for (dep_id, dep_pair) in deps
            arg_name, dep = dep_pair
            # Don't draw pins for parameters
            if dep isa Parameter
                continue
            end

            pin_shape = dep isa KaraboDependency ? ImNodes.ImNodesPinShape_TriangleFilled : ImNodes.ImNodesPinShape_CircleFilled

            ImNodes.BeginInputAttribute(dep_id, pin_shape)
            IG.Text(arg_name)
            if dep isa KaraboDependency
                IG.SameLine()
                InfoMarker(string(dep), "Karabo")
            end
            ImNodes.EndInputAttribute()
        end

        IG.Dummy(min_node_width, 10)

        # Draw outputs
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

function draw_ssh_auth(state)
    client = state.client

    for (hop_idx, ssh_state) in enumerate(client.ssh_hops)
        if ssh_state.auth_state == ssh.AuthStatus_Success
            IG.BulletText("Successfully authenticated to $(ssh_state.address)")
            continue
        elseif isnothing(ssh_state.session)
            if ssh_state.auth_state == :connecting
                IG.BulletText("Connecting to $(ssh_state.address) ")
                IG.SameLine()
                Spinner()
            else
                IG.BulletText("Next hop: $(ssh_state.address)")
            end
            continue
        end

        host = if isnothing(ssh_state.session) || !isopen(ssh_state.session)
            ssh_state.address
        else
            "$(ssh_state.session.user)@$(ssh_state.address)"
        end

        IG.BulletText("Connecting to $host:")

        # Only continue if we're connected
        if isnothing(ssh_state.session)
            continue
        end

        IG.Indent()

        auth_state = ssh_state.auth_state
        auth_method = ssh_state.auth_method

        can_authenticate = false

        if auth_method == ssh.AuthMethod_Password
            IG.Text("Password: ")
            IG.SameLine()
            edited, new_password = SafeInputText("##password"; password=true, max_len=127,
                                                 current_text=ssh_state.password)
            if edited
                ssh_state.password = new_password
            end

            can_authenticate = !isempty(ssh_state.password)
        elseif auth_method == ssh.AuthMethod_Interactive
            all_answers_filled = true

            for prompt in ssh_state.kbdint_prompts
                IG.Text(prompt.msg)
                IG.SameLine()
                edited, new_answer = SafeInputText("##$prompt"; password=!prompt.display, max_len=127,
                                                   current_text=prompt.answer)
                if edited
                    prompt.answer = new_answer
                end

                if isempty(prompt.answer)
                    all_answers_filled = false
                end
            end

            can_authenticate = all_answers_filled
        else
            can_authenticate = true
        end
        can_authenticate &= auth_state != :authenticating

        IG.Spacing()

        @Disabled !can_authenticate begin
            if IG.Button(auth_state == :authenticating ? "Authenticating" : "Authenticate")
                @guiasync Client.ssh_authenticate_hop(state, hop_idx)
            end
        end

        if auth_state == :authenticating
            IG.SameLine()
            Spinner()
        elseif auth_state isa ssh.AuthStatus && auth_state != ssh.AuthStatus_Success
            status_str = split(string(auth_state), "_")[2]

            IG.SameLine()
            IG.PushStyleColor(IG.ImGuiCol_Text, IG.IM_COL32(245, 80, 81, 255))
            IG.Text("Error, please try again: '$(status_str)'")
            IG.PopStyleColor()
        end

        IG.Unindent()
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

    client = state.client
    fully_authenticated = Client.ssh_fully_authenticated(client)

    # Draw the main window
    if Begin("Main window", C_NULL, main_window_flags)
        # Draw the menubar
        draw_main_menubar(state)

        IG.BeginTabBar("main-tab-bar")
        if IG.BeginTabItem("Setup")
            IG.EndTabItem()

            can_connect = (client.status != RemoteStatus'.CONNECTING
                           && !fully_authenticated)
            @Disabled !can_connect begin
                IG.Text("Connect to node:")

                IG.SameLine()

                edited, new_address = SafeInputText("##client"; hint="exflonc24.desy.de",
                                                    current_text=default(state.address))

                IG.Text("Use environment:")
                IG.SameLine()
                env_edited, new_environment = SafeInputText("##engine-environment";
                                                            current_text=default(state.engine_environment))
            end

            if edited
                state.address = new_address
            end
            if env_edited
                state.engine_environment = new_environment
            end

            IG.Spacing()

            disable_connect = !can_connect || length(state.address) == 0
            @Disabled disable_connect begin
                if IG.Button("Connect")
                    client.cmd_output = ""
                    client.last_error = ""
                    @guiasync Client.ssh_initialize(state)
                end
            end
            IG.SameLine()

            @Disabled can_connect begin
                if IG.Button("Disconnect")
                    @guiasync Client.disconnect(state, false)
                end

                IG.SameLine()

                if IG.Button("Disconnect & shutdown")
                    @guiasync Client.disconnect(state, true)
                end
            end

            IG.Dummy(0, 20)
            if client.status == RemoteStatus'.CONNECTING && !fully_authenticated
                draw_ssh_auth(state)
            elseif client.status == RemoteStatus'.CONNECTING && fully_authenticated
                Spinner("Starting engine...")
                BoxedText("##client_cmd_output", state.client.cmd_output)
            elseif client.status == RemoteStatus'.ERROR
                @Disabled !fully_authenticated begin
                    if IG.Button("Restart engine")
                        @guiasync Client.initialize_engine(state)
                    end
                end

                IG.Spacing()

                IG.Text(fully_authenticated ? "Error starting engine:" : "Error connecting to node:")
                BoxedText("##client_last_error", client.last_error)
            elseif client.status == RemoteStatus'.CONNECTED
                IG.Text("Connected with client ID: $(client.client_id)")

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

                # Get the webproxy address
                IG.Text("Use webproxy:")
                IG.SameLine()
                edited, new_webproxy_addr = EditableComboBox("##webproxy-address",
                                                             state.webproxy, WEBPROXY_COMPLETIONS)
                if edited
                    state.webproxy = new_webproxy_addr
                end

                # Update the list of devices
                if IG.Button("Update device list")
                    Client.get_devices(state)
                end
                IG.SameLine()
                @cases state.webproxy_status begin
                    IDLE => IG.Text("Found $(length(state.karabo_devices)) Karabo devices")
                    WAITING_FOR_DEVICES => Spinner("")
                    ERROR => IG.Text("Error! Check backend logs.")
                end

                IG.Dummy(0, 10)

                # Show a list of trainmatchers
                IG.Text("Found $(length(state.trainmatchers)) matchers:")
                if IG.BeginListBox("")
                    for matcher in sort(collect(keys(state.trainmatchers)))
                        IG.Selectable(matcher)
                    end
                    IG.EndListBox()
                end
            end
        end

        @Disabled client.status != RemoteStatus'.CONNECTED || isempty(state.context_state) begin
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

function on_exit(state::GuiState)
    close(state)
    # ws = state.client.websocket
    # if ws != nothing && !WebSockets.isclosed(ws)
    #     close(ws)
    # end
end

"""Start the XFA GUI."""
function main()
    state::GuiState = GuiState(; disable_rendering=false, webproxy=WEBPROXY_COMPLETIONS[1])
    app = Renderer.ImGuiApp(state; title="XFA", fonts=[
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

    t = Renderer.render(app; on_exit) do state
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
            @lock state begin
                @invokelatest draw_gui(state)
            end
        catch ex
            @error "Error while rendering:" exception=(ex, catch_backtrace())
            state.disable_rendering = true
        end
    end

    return t, state
end

end
