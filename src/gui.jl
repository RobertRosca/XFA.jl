import Base.ScopedValues: ScopedValue, @with

import CImGui as ig
import CImGui: ImVec2, ImVec4
import CImGui.CSyntax: @c
import ImPlot
import GLFW
using ModernGL

include("imnodes.jl")
include("imgui_helpers.jl")

using NaNStatistics: nanmaximum, nanminimum
using DimensionalData: DimensionalData as DD, DimVector, DimMatrix, DimArray
import GeometryBasics: Point2d
include("plotting.jl")

import LibSSH as ssh
import HTTP: WebSockets
import XfaEngine: EngineState, getavailableport
include("states.jl")

import TOML
import Sockets
import CRC32c: crc32c
using Serialization
import HTTP
import XfaEngine
import XfaEngine.Context: KaraboDependency, Dependency, Parameter
using XfaEngine.Protocol
import XfaEngine.Protocol: send
using .ImGuiHelpers
include("client.jl")

import Revise

import .ImNodes

const state = ScopedValue{GuiState}()

## Helper functions for the GUI

# function update_device_list(state)
#     client = state.client.webproxy_client
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

function draw_revise()
    can_revise = length(Revise.revision_queue) > 0
    @Disabled !can_revise begin
        if ig.Button(can_revise ? "Revise*" : "Revise")
            Revise.retry()

            client = state[].client
            if client.status == RemoteStatus_Connected
                revise_engine(state[])
            end
        end
    end
end

function draw_main_menubar()
    client = state[].client

    if ig.BeginMenuBar()
        draw_revise()

        can_sync = client.status == RemoteStatus_Connected && !client.syncing
        @Disabled !can_sync begin
            if ig.Button("Sync")
                @guiasync sync_files()
            end
            if client.syncing
                Spinner()
            end
        end

        if ig.BeginMenu("Tools")
            if ig.BeginMenu("Demos")
                @c MenuItem("ImGui demo", &state[].show_imgui_demo)
                ig.EndMenu()
            end

            @c MenuItem("ImGui metrics", &state[].show_imgui_metrics)
            @c MenuItem("Stack tool", &state[].show_stacktool)
            @c MenuItem("Debug log", &state[].show_debug_log)

            ig.EndMenu()
        end

        ig.EndMenuBar()
    end
end

function draw_parameter(name, param::Parameter{Float64})
    ret = @c ig.InputDouble(name, &param.value, 0.0, 0.0, "%.3f0", ig.ImGuiInputTextFlags_EnterReturnsTrue)

    return ret, param.value
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

function draw_parameter(name, param::Parameter{Bool})
    @c ig.Checkbox(name, &param.value)

    return false, nothing
end

function get_variable_typeinfo(name)
    variable_data = state[].client.variable_data
    if haskey(variable_data, name)
        data = variable_data[name].data
        T = eltype(data)
        return "$T$(size(data))"
    else
        return ""
    end
end

function clear_variables()
    client = state[].client

    for store in values(client.variable_data)
        if store.data isa AbstractVector
            empty!(store.data)
        end
    end

    # empty!(client.variable_data)

    # for plot in client.plots
    #     plot.open[] = false
    # end
end

function draw_dag()
    ctx_state = state[].client.context_state
    client = state[].client

    ig.Dummy(0, 10)
    @Disabled isempty(client.context_state) || client.pipeline_status != PipelineStatus_Stopped begin
        if ig.Button(" Start ")
            start(state[])
        end
    end

    ig.SameLine()

    @Disabled client.pipeline_status != PipelineStatus_Started begin
        if ig.Button(" Stop ")
            stop(state[])
        end
    end

    ig.SameLine()
    @Disabled isempty(client.variable_data) begin
        if ig.Button("Clear all")
            clear_variables()
        end
    end

    ig.SameLine()
    changing_states = (PipelineStatus_Starting, PipelineStatus_Stopping, PipelineStatus_LoadingContext)
    @Disabled client.pipeline_status in changing_states begin
        if ig.Button("Load context")
            load_context(state[])
        end
    end

    if client.pipeline_status in changing_states
        ig.SameLine()
        Spinner()
    end

    ig.Dummy(0, 10)

    ImNodes.BeginNodeEditor()

    for (name, var_data) in ctx_state
        ig.PushID(name)

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
                    change_parameter(Parameter(param.name, new_value))
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

        ig.TextDisabled("Outputs")
        draw_list = ig.GetWindowDrawList()
        start_pos = ig.GetCursorScreenPos()
        gray = ig.IM_COL32(100, 100, 100, 255)
        ig.AddLine(draw_list, start_pos, (start_pos.x + min_node_width / 2f0, start_pos.y), gray, 2)
        ig.Dummy(min_node_width, 2)

        # Draw outputs
        for (output_id, output) in var_data["outputs"]
            label = string(output)
            output_name = isempty(label) ? name : "$(name).$(label)"
            ImNodes.BeginOutputAttribute(output_id, ImNodes.ImNodesPinShape_CircleFilled)

            ig.Indent(min_node_width - ig.CalcTextSize(label).x)
            typestr = get_variable_typeinfo(output_name)
            if !isempty(typestr)
                label = isempty(label) ? typestr : "$(label) - $(typestr)"
            end

            if !isempty(label)
                if haskey(client.variable_data, output_name)
                    if ig.Button("$(label)###plot_button")
                        push!(client.plots, Plot(output_name))
                    end
                else
                    ig.Text(label)
                end
            end

            ImNodes.EndOutputAttribute()
        end

        ImNodes.EndNode()

        pos = client.node_positions[name]
        if pos != Point2d(-1, -1)
            ImNodes.SetNodeGridSpacePos(node_id, (pos[1], pos[2]))
            client.node_positions[name] = Point2d(-1, -1)
        end

        ig.PopID()
    end

    for var_data in values(ctx_state)
        for (link_id, start_id, end_id) in var_data["links"]
            ImNodes.Link(link_id, start_id, end_id)
        end
    end

    ImNodes.MiniMap()
    ImNodes.EndNodeEditor()
end

function draw_ssh_auth()
    client = state[].client

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
                @guiasync ssh_authenticate_hop(state[], hop_idx)
                can_authenticate = true
            end
            ig.SameLine()
            ig.Text("/")
            ig.SameLine()
            if ig.Button("No")
                # If they refuse to recognize the host then we can't do anything
                @guiasync disconnect_engine(state[], false)
            end
        else
            can_authenticate = true
        end
        can_authenticate &= auth_state != :authenticating

        ig.Spacing()

        @Disabled !can_authenticate begin
            if ig.Button(auth_state == :authenticating ? "Authenticating" : "Authenticate")
                @guiasync ssh_authenticate_hop(state[], hop_idx)
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

function draw_plots()
    client = state[].client

    # Update all the observables
    updated_variables = String[]
    for (name, store) in client.variable_data
        if !isready(store.updates)
            continue
        end

        array = store.data
        while isready(store.updates)
            tid, x = take!(store.updates)
            if x isa Number
                push!(array, x, (; trainId=tid))
            elseif x isa AbstractArray
                store.data = x
            end
        end

        push!(updated_variables, name)
    end

    # Draw plot windows
    for plot in client.plots
        draw_plot(plot, client.variable_data[plot.name].data, plot.name in updated_variables)
    end

    # Remove closed plots
    for i in reverse(eachindex(client.plots))
        if !client.plots[i].open[]
            close(client.plots[i])
            deleteat!(client.plots, i)
        end
    end
end

## Main GUI function

default(value, default="") = isnothing(value) ? default : value

function draw_gui()
    # Dock the main window by default
    viewport = ig.igGetMainViewport()
    central_dock_id = ig.DockSpaceOverViewport(ig.GetWindowDockID(), viewport, ig.ImGuiDockNodeFlags_PassthruCentralNode)

    ig.SetNextWindowDockID(central_dock_id, ig.ImGuiCond_Once)

    main_window_flags = ig.ImGuiWindowFlags_NoCollapse
    main_window_flags |= ig.ImGuiWindowFlags_MenuBar
    main_window_flags |= ig.ImGuiWindowFlags_HorizontalScrollbar

    client = state[].client
    fully_authenticated = ssh_fully_authenticated(client)

    # Draw the main window
    if ig.Begin("Main window", C_NULL, main_window_flags)
        # Draw the menubar
        draw_main_menubar()

        ig.BeginTabBar("main-tab-bar")
        if ig.BeginTabItem("Setup")
            ig.EndTabItem()

            can_connect = if client.embedded_engine
                client.status != RemoteStatus_Connecting && client.status != RemoteStatus_Connected
            else
                client.status != RemoteStatus_Connecting && !fully_authenticated
            end

            @Disabled !can_connect begin
                ig.Combo("##client-type", state[].client_type_current_item,
                         ["Connect to remote", "Create local engine"])
                client.embedded_engine = state[].client_type_current_item[] == 1

                ig.Spacing()

                if !state[].client.embedded_engine
                    ig.Text("Connect to node:")

                    ig.SameLine()

                    edited, new_address = SafeInputText("##client"; hint="exflonc24.desy.de",
                                                        current_text=default(state[].address))

                    ig.Text("Use environment:")
                    ig.SameLine()
                    env_edited, new_environment = SafeInputText("##engine-environment";
                                                                current_text=default(state[].engine_environment))

                    if edited
                        state[].address = new_address
                    end
                    if env_edited
                        state[].engine_environment = new_environment
                    end
                end
            end

            ig.Spacing()

            disable_connect = !can_connect || length(state[].address) == 0
            @Disabled disable_connect begin
                if ig.Button("Connect")
                    client.cmd_output = ""
                    client.last_error = ""
                    @guiasync connect_engine()
                end
            end
            ig.SameLine()

            @Disabled can_connect begin
                if ig.Button("Disconnect")
                    @guiasync disconnect_engine(state[], false)
                end

                ig.SameLine()

                if ig.Button("Disconnect & shutdown")
                    @guiasync disconnect_engine(state[], true)
                end
            end

            ig.Dummy(0, 20)
            if client.status == RemoteStatus_Connecting && !fully_authenticated
                draw_ssh_auth()
            elseif client.status == RemoteStatus_Connecting && fully_authenticated
                Spinner("Starting engine...")
                BoxedText("##client_cmd_output", state[].client.cmd_output)
            elseif client.status == RemoteStatus_Error
                @Disabled !fully_authenticated begin
                    if ig.Button("Restart engine")
                        @guiasync initialize_engine(state[])
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

                ig.Text("Debug mode")
                ig.SameLine()
                if ig.Checkbox("##debug-mode", client.debug_mode)
                    set_debug_mode(state[])
                end

                @Disabled client.remoterepl_status == RemoteReplStatus_Changing begin
                    ig.Text("Remote REPL")
                    ig.SameLine()
                    if client.remoterepl_status == RemoteReplStatus_Changing
                        Spinner()
                    elseif ig.Checkbox("##remoterepl-mode", client.remoterepl_mode)
                        set_remoterepl(state[])
                    end
                end

                ig.Text("Use context file:")
                ig.SameLine()
                edited, new_context_path = SafeInputText("##context-file";
                                                         current_text=default(client.context_path))
                if edited
                    client.context_path = new_context_path
                    client.context_path_valid = true
                end

                if !client.context_path_valid
                    ig.TextColored(ImVec4(1, 0.2, 0.5, 1), "Path does not point to a valid file!")
                end

                # Get the default topic
                ig.Text("Default topic:")
                ig.SameLine()
                if ig.Combo("##default-topic", client.default_topic_idx, client.available_topics)
                    set_default_topic(state[])
                end

                # # Update the list of devices
                # if ig.Button("Update device list")
                #     get_devices(state[])
                # end
                # ig.SameLine()
                # if client.webproxy_status == WebproxyStatus_Idle
                #     ig.Text("Found $(length(client.karabo_devices)) Karabo devices")
                # elseif client.webproxy_status == WebproxyStatus_WaitingForDevices
                #     Spinner("")
                # elseif client.webproxy_status == WebproxyStatus_Error
                #     ig.Text("Error! Check backend logs.")
                # end

                # ig.Dummy(0, 10)

                # # Show a list of trainmatchers
                # ig.Text("Found $(length(client.trainmatchers)) matchers:")
                # if ig.BeginListBox("")
                #     for matcher in sort(collect(keys(client.trainmatchers)))
                #         ig.Selectable(matcher)
                #     end
                #     ig.EndListBox()
                # end
            end
        end

        @Disabled client.status != RemoteStatus_Connected || isempty(client.context_path) begin
            if ig.BeginTabItem("Analysis pipeline")
                draw_dag()
                ig.EndTabItem()
            end
        end

        ig.EndTabBar()

        draw_plots()

        ig.End()
    end

    # Display tooling windows
    for (window_sym, window_func) in [(:show_imgui_demo,     ig.ShowDemoWindow),
                                      (:show_imgui_metrics,  ig.ShowMetricsWindow),
                                      (:show_stacktool,      ig.ShowIDStackToolWindow),
                                      (:show_debug_log,      ig.ShowDebugLogWindow)]
        do_show = getproperty(state[], window_sym)
        if do_show
            @c window_func(&do_show)
            setproperty!(state[], window_sym, do_show)
        end
    end
end

"""Start the XFA GUI."""
function main()
    gui_state = GuiState(; disable_rendering=false)

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

    # Setup ImPlot context
    implot_ctx = ImPlot.CreateContext()

    # Enable docking and viewports by default
    io = ig.GetIO()
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_DockingEnable
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_ViewportsEnable

    # # Disable INI file
    # io.WantSaveIniSettings = false
    # io.IniFilename = C_NULL

    on_exit = () -> begin
        # Clean up GPU heatmap resources before destroying contexts
        for plot in gui_state.client.plots
            close(plot)
        end
        destroy_heatmap_context!()

        ImPlot.DestroyContext(implot_ctx)
        ImNodes.DestroyContext(imnodes_ctx)
        empty!(ImGuiHelpers.safe_input_text_cache)
        close(gui_state)
    end
    t = ig.render(imgui_ctx; on_exit, window_title="XFA", wait=false, spawn=true) do
        if gui_state.disable_rendering
            # Occasionally an exception will occur in the middle of a disabled
            # section, which helpfully also disables the continue button
            # below. So here we check if we're currently disabled and end it if
            # so.
            if IsItemDisabled()
                ig.igEndDisabled()
            end

            ig.Text("Render loop crashed, continue when ready:")
            @with state => gui_state draw_revise()
            ig.SameLine()
            gui_state.disable_rendering = !ig.Button("Continue")
            return
        end

        try
            @lock gui_state begin
                @with state => gui_state @invokelatest draw_gui()
            end
        catch ex
            @error "Error while rendering:" exception=(ex, catch_backtrace())
            gui_state.disable_rendering = true
        end
    end

    return t, gui_state
end
