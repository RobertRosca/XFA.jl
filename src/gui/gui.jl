module GUI

include("imnodes.jl")
include("imgui_helpers.jl")
include("states.jl")
include("client.jl")

import CImGui as ig
import CImGui: ImVec2, ImVec4, Begin, End
import CImGui.CSyntax: @c
import GLFW
import ModernGL

import Revise
import HTTP: WebSockets
import LibSSH as ssh

import XfaEngine.Context: KaraboDependency, Parameter
using XfaEngine.Protocol
import XfaEngine.Protocol: send

import .ImNodes
using .ImGuiHelpers
using .States
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
#     client.status = WebProxyClientStatus_Connecting

#     try
#         devices = WebProxy.get_devices(state.webproxy_client)
#         state.karabo_devices = keys(devices)
#         client.status = WebProxyClientStatus_Connected
#     catch ex
#         client.status = WebProxyClientStatus_Error
#         client.last_error = Util.exception2str(ex, catch_backtrace())
#     end
# end

function draw_revise(state)
    can_revise = length(Revise.revision_queue) > 0
    @Disabled !can_revise begin
        if ig.Button(can_revise ? "Revise*" : "Revise")
            Revise.retry()

            client = state.client
            if client.status == RemoteStatus_Connected
                Client.revise_engine(state)
            end
        end
    end
end

function draw_main_menubar(state)
    if ig.BeginMenuBar()
        draw_revise(state)

        @Disabled state.client.status != RemoteStatus_Connected || !state.context_path_valid begin
            if ig.Button("Load context")
                Client.load_context(state)
            end
        end

        if ig.BeginMenu("Tools")
            if ig.BeginMenu("Demos")
                @c MenuItem("ImGui demo", &state.show_imgui_demo)
                ig.EndMenu()
            end

            @c MenuItem("ImGui metrics", &state.show_imgui_metrics)
            @c MenuItem("Stack tool", &state.show_stacktool)
            @c MenuItem("Debug log", &state.show_debug_log)

            ig.EndMenu()
        end

        ig.EndMenuBar()
    end
end

function draw_parameter(name, param::Parameter{Float64})
    @c ig.InputDouble(name, &param.value)

    return false, nothing
end

function draw_parameter(name, param::Parameter{Int})
    int32_value = Int32(param.value)
    @c ig.InputInt(name, &int32_value)
    param.value = Int(int32_value)

    return false, nothing
end

function draw_parameter(name, param::Parameter{String})
    SafeInputText(name; current_text=param.value)
end

function draw_parameter(name, param::Parameter{Vector{String}})
    ig.Text("Vector{String}")

    return false, nothing
end

function draw_dag(state)
    ctx_state = state.context_state

    ig.Dummy(0, 10)
    if ig.Button(" Start ")
        Client.start(state)
    end
    ig.SameLine()
    if ig.Button(" Stop ")
        Client.stop(state)
    end
    ig.Dummy(0, 10)

    ImNodes.BeginNodeEditor()

    for (name, var_data) in ctx_state
        min_node_width = 150
        node_id = var_data["id"]

        # Draw titlebar
        ImNodes.BeginNode(node_id)
        ImNodes.BeginNodeTitleBar()
        ig.Text(name)
        ImNodes.EndNodeTitleBar()

        # Draw parameters
        if haskey(var_data, "parameters")
            ig.Text("Parameters:")
            for (param_name, param) in var_data["parameters"]
                ig.SetNextItemWidth(round(Int, min_node_width * 1.5))
                modified, new_value = draw_parameter(param_name, param)
                if modified
                    Client.change_parameter(state, Parameter(param.name, new_value))
                end
            end
        end

        ig.Dummy(min_node_width, 20)

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
            ig.Text(arg_name)
            if dep isa KaraboDependency
                ig.SameLine()
                InfoMarker(string(dep), "Karabo")
            end
            ImNodes.EndInputAttribute()
        end

        ig.Dummy(min_node_width, 10)

        # Draw outputs
        for (output_id, output) in var_data["outputs"]
            label = string(output)
            ImNodes.BeginOutputAttribute(output_id, ImNodes.ImNodesPinShape_CircleFilled)
            ig.Indent(min_node_width - ig.CalcTextSize(label).x)
            ig.Text(label)
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
            ig.BulletText("Successfully authenticated to $(ssh_state.address)")
            continue
        elseif isnothing(ssh_state.session)
            if ssh_state.auth_state == :connecting
                ig.BulletText("Connecting to $(ssh_state.address) ")
                ig.SameLine()
                Spinner()
            else
                ig.BulletText("Next hop: $(ssh_state.address)")
            end
            continue
        end

        host = if isnothing(ssh_state.session) || !isopen(ssh_state.session)
            ssh_state.address
        else
            "$(ssh_state.session.user)@$(ssh_state.address)"
        end

        ig.BulletText("Connecting to $host:")

        # Only continue if we're connected
        if isnothing(ssh_state.session)
            continue
        end

        ig.Indent()

        auth_state = ssh_state.auth_state
        auth_method = ssh_state.auth_method

        can_authenticate = false

        if auth_method == ssh.AuthMethod_Password
            ig.Text("Password: ")
            ig.SameLine()
            edited, new_password = SafeInputText("##password"; password=true, max_len=127,
                                                 current_text=ssh_state.password)
            if edited
                ssh_state.password = new_password
            end

            can_authenticate = !isempty(ssh_state.password)
        elseif auth_method == ssh.AuthMethod_Interactive
            all_answers_filled = true

            for prompt in ssh_state.kbdint_prompts
                ig.Text(prompt.msg)
                ig.SameLine()
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
        elseif ssh_state.auth_state == ssh.KnownHosts_Unknown
            ig.Text("The host is unrecognized, would you like to add it to the known hosts file?")
            ig.SameLine()
            if ig.Button("Yes")
                ssh.update_known_hosts(ssh_state.session)
                @guiasync Client.ssh_authenticate_hop(state, hop_idx)
                can_authenticate = true
            end
            ig.SameLine()
            ig.Text("/")
            ig.SameLine()
            if ig.Button("No")
                # If they refuse to recognize the host then we can't do anything
                @guiasync Client.disconnect(state, false)
            end
        else
            can_authenticate = true
        end
        can_authenticate &= auth_state != :authenticating

        ig.Spacing()

        @Disabled !can_authenticate begin
            if ig.Button(auth_state == :authenticating ? "Authenticating" : "Authenticate")
                @guiasync Client.ssh_authenticate_hop(state, hop_idx)
            end
        end

        if auth_state == :authenticating
            ig.SameLine()
            Spinner()
        elseif auth_state isa ssh.AuthStatus && auth_state != ssh.AuthStatus_Success
            status_str = split(string(auth_state), "_")[2]

            ig.SameLine()
            ig.PushStyleColor(ig.ImGuiCol_Text, ig.IM_COL32(245, 80, 81, 255))
            ig.Text("Error, please try again: '$(status_str)'")
            ig.PopStyleColor()
        end

        ig.Unindent()
    end
end

## Main GUI function

default(value, default="") = isnothing(value) ? default : value

function draw_gui(state)
    # Dock the main window by default
    viewport = ig.igGetMainViewport()
    central_dock_id = ig.DockSpaceOverViewport(ig.GetWindowDockID(), viewport, ig.ImGuiDockNodeFlags_PassthruCentralNode)

    ig.SetNextWindowDockID(central_dock_id, ig.ImGuiCond_Once)

    main_window_flags = ig.ImGuiWindowFlags_NoCollapse
    main_window_flags |= ig.ImGuiWindowFlags_MenuBar
    main_window_flags |= ig.ImGuiWindowFlags_HorizontalScrollbar

    client = state.client
    fully_authenticated = Client.ssh_fully_authenticated(client)

    # Draw the main window
    if Begin("Main window", C_NULL, main_window_flags)
        # Draw the menubar
        draw_main_menubar(state)

        ig.BeginTabBar("main-tab-bar")
        if ig.BeginTabItem("Setup")
            ig.EndTabItem()

            can_connect = (client.status != RemoteStatus_Connecting
                           && !fully_authenticated)
            @Disabled !can_connect begin
                ig.Text("Connect to node:")

                ig.SameLine()

                edited, new_address = SafeInputText("##client"; hint="exflonc24.desy.de",
                                                    current_text=default(state.address))

                ig.Text("Use environment:")
                ig.SameLine()
                env_edited, new_environment = SafeInputText("##engine-environment";
                                                            current_text=default(state.engine_environment))
            end

            if edited
                state.address = new_address
            end
            if env_edited
                state.engine_environment = new_environment
            end

            ig.Spacing()

            disable_connect = !can_connect || length(state.address) == 0
            @Disabled disable_connect begin
                if ig.Button("Connect")
                    client.cmd_output = ""
                    client.last_error = ""
                    @guiasync Client.ssh_initialize(state)
                end
            end
            ig.SameLine()

            @Disabled can_connect begin
                if ig.Button("Disconnect")
                    @guiasync Client.disconnect(state, false)
                end

                ig.SameLine()

                if ig.Button("Disconnect & shutdown")
                    @guiasync Client.disconnect(state, true)
                end
            end

            ig.Dummy(0, 20)
            if client.status == RemoteStatus_Connecting && !fully_authenticated
                draw_ssh_auth(state)
            elseif client.status == RemoteStatus_Connecting && fully_authenticated
                Spinner("Starting engine...")
                BoxedText("##client_cmd_output", state.client.cmd_output)
            elseif client.status == RemoteStatus_Error
                @Disabled !fully_authenticated begin
                    if ig.Button("Restart engine")
                        @guiasync Client.initialize_engine(state)
                    end
                end

                ig.Spacing()

                ig.Text(fully_authenticated ? "Error starting engine:" : "Error connecting to node:")
                BoxedText("##client_last_error", client.last_error)
            elseif client.status == RemoteStatus_Connected
                ig.Text("Connected with client ID: $(client.client_id)")

                ig.Dummy(0, 2)
                ig.Separator()
                ig.Dummy(0, 2)

                ig.Text("Use context file:")
                ig.SameLine()
                edited, new_context_path = SafeInputText("##context-file";
                                                         current_text=default(state.context_path))
                if edited
                    state.context_path = new_context_path
                    state.context_path_valid = true
                end

                if !state.context_path_valid
                    ig.TextColored(ImVec4(1, 0.2, 0.5, 1), "Path does not point to a valid file!")
                end

                # Get the webproxy address
                ig.Text("Use webproxy:")
                ig.SameLine()
                edited, new_webproxy_addr = EditableComboBox("##webproxy-address",
                                                             state.webproxy, WEBPROXY_COMPLETIONS)
                if edited
                    state.webproxy = new_webproxy_addr
                end

                # Update the list of devices
                if ig.Button("Update device list")
                    Client.get_devices(state)
                end
                ig.SameLine()
                if state.webproxy_status == WebproxyStatus_Idle
                    ig.Text("Found $(length(state.karabo_devices)) Karabo devices")
                elseif state.webproxy_status == WebproxyStatus_WaitingForDevices
                    Spinner("")
                elseif state.webproxy_status == WebproxyStatus_Error
                    ig.Text("Error! Check backend logs.")
                end

                ig.Dummy(0, 10)

                # Show a list of trainmatchers
                ig.Text("Found $(length(state.trainmatchers)) matchers:")
                if ig.BeginListBox("")
                    for matcher in sort(collect(keys(state.trainmatchers)))
                        ig.Selectable(matcher)
                    end
                    ig.EndListBox()
                end
            end
        end

        @Disabled client.status != RemoteStatus_Connected || isempty(state.context_state) begin
            if ig.BeginTabItem("Analysis pipeline")
                draw_dag(state)
                ig.EndTabItem()
            end
        end

        ig.EndTabBar()

        End()
    end

    # Display tooling windows
    for (window_sym, window_func) in [(:show_imgui_demo,     ig.ShowDemoWindow),
                                      (:show_imgui_metrics,  ig.ShowMetricsWindow),
                                      (:show_stacktool,      ig.ShowIDStackToolWindow),
                                      (:show_debug_log,      ig.ShowDebugLogWindow)]
        do_show = getproperty(state, window_sym)
        if do_show
            @c window_func(&do_show)
            setproperty!(state, window_sym, do_show)
        end
    end
end

"""Start the XFA GUI."""
function main()
    state::GuiState = GuiState(; disable_rendering=false, webproxy=WEBPROXY_COMPLETIONS[1])

    # Setup Dear ImGui context
    ig.set_backend(:GlfwOpenGL3)
    imgui_ctx = ig.CreateContext()
    ig.SetCurrentContext(imgui_ctx)

    # Setup ImNodes
    imnodes_ctx = ImNodes.CreateContext()

    # Setup Dear ImGui style
    ig.StyleColorsDark()
    style = ig.GetStyle()
    style.FrameBorderSize = 1

    # Load fonts
    font_atlas = unsafe_load(ig.GetIO().Fonts)
    font_dir = joinpath(@__DIR__, "fonts")
    fonts=[
        (joinpath(font_dir, "Atkinson_Hyperlegible", "AtkinsonHyperlegible-Regular.ttf"), 20),
        (joinpath(font_dir, "Inter-Regular.otf"), 17),
        (joinpath(font_dir, "JuliaMono-Regular.ttf"), 15),
        (joinpath(font_dir, "JuliaMono-Regular.ttf"), 16),
    ]
    for (font, font_size) in fonts
        ig.AddFontFromFileTTF(font_atlas, font, font_size)
    end

    # Enable docking and viewports by default
    io = ig.GetIO()
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_DockingEnable
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_ViewportsEnable

    # # Disable INI file
    # io.WantSaveIniSettings = false
    # io.IniFilename = C_NULL

    on_exit = () -> begin
        ImNodes.DestroyContext(imnodes_ctx)
        empty!(ImGuiHelpers.safe_input_text_cache)
        close(state)
    end
    t = ig.render(imgui_ctx; on_exit, window_title="XFA", wait=false) do
        if state.disable_rendering
            # Occasionally an exception will occur in the middle of a disabled
            # section, which helpfully also disables the continue button
            # below. So here we check if we're currently disabled and end it if
            # so.
            if IsItemDisabled()
                ig.igEndDisabled()
            end

            ig.Text("Render loop crashed, continue when ready:")
            draw_revise(state)
            ig.SameLine()
            state.disable_rendering = !ig.Button("Continue")
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
