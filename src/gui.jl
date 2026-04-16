import Base.ScopedValues: ScopedValue, @with

using CImGui: CImGui as ig, ImVec2, ImVec4, IM_COL32
using CImGui.CSyntax: @c
using ImPlot: ImPlot
using GLFW: GLFW
using ModernGL

include("imnodes.jl")

using NaNStatistics: nanmean, nanmaximum, nanminimum, nanpctile
using DimensionalData: DimensionalData as DD, DimVector, DimMatrix, DimArray, At, lookup
using DataStructures: CircularBuffer
include("plotting.jl")

using LibSSH: LibSSH as ssh
using HTTP: HTTP, WebSockets
using XfaEngine: EngineState, getavailableport
using Dates: Dates, unix2datetime, @dateformat_str
include("states.jl")

using Printf: @sprintf
using TOML: TOML
using Sockets: Sockets
using CRC32c: crc32c
using Serialization
using XfaEngine.Protocol
using XfaEngine: XfaEngine, Protocol
using XfaEngine.Context: Dependency, DependencyKind, DepKind_Variable, DepKind_Karabo, DepKind_Group,
    karabo_dependency, Parameter, KaraboDevice, VariableData

include("imgui_helpers.jl")
include("state_inspector.jl")
include("client.jl")
include("context_edit.jl")
include("variable_widgets.jl")

import Revise

import .ImNodes

const state = ScopedValue{GuiState}()

## Helper functions for the GUI

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
            @c MenuItem("State inspector", &state[].show_state_inspector)
            if @c MenuItem("Engine logs", &state[].show_engine_logs)
                state[].select_engine_logs = true
            end

            ig.EndMenu()
        end

        ig.EndMenuBar()
    end
end

function draw_parameter_widget(name, param::Parameter{Float64})
    ret = @c ig.InputDouble(name, &param.value, 0.0, 0.0, "%.3f0", ig.ImGuiInputTextFlags_EnterReturnsTrue)

    return ret, param.value
end

function draw_parameter_widget(name, param::Parameter{Int})
    int32_value = Int32(param.value)
    @c ig.InputInt("##$(name)", &int32_value)
    param.value = Int(int32_value)

    return false, nothing
end

function draw_parameter_widget(name, param::Parameter{String})
    SafeInputText(name; current_text=param.value)
end

function draw_parameter_widget(name, param::Parameter{Vector{String}})
    ig.Text("Vector{String}")

    return false, nothing
end

function draw_parameter_widget(name, param::Parameter{KaraboDevice})
    client = state[].client
    dep_key = node_hash(param.name)
    dep_state = get!(client.karabo_dep_states, dep_key, KaraboDepTextState())
    device_props = if isnothing(dep_state.device)
        DeviceProperties()
    else
        get_source_properties(client, dep_state.device)
    end

    device = param.value
    text = "$(device.topic)//$(device.name)"
    edited, new_text = KaraboDepText("param-$(param.name)", text, dep_state,
                                     client.source_list, device_props; device_only=true)
    if edited
        new_device = KaraboDevice(new_text)
        if isempty(new_device.topic)
            idx = findfirst(s -> s.name == new_device.name, client.source_list)
            if !isnothing(idx)
                new_device = KaraboDevice(client.source_list[idx].topic, new_device.name)
            end
        end
        return true, new_device
    end

    return false, nothing
end

# Draw a dependency editor (type selector + autocomplete text field).
# Returns (edited::Bool, new_dep::Dependency). Used for both dependency pins
# and Parameter{Dependency} widgets.
function draw_dep_editor(label, dep::Dependency, dep_id::Integer;
                         device_only::Bool=false, variable_name::String="")
    client = state[].client
    dep_state = get!(client.dep_text_states, Int(dep_id)) do
        DepTextState(dep.kind == DepKind_Karabo)
    end
    device_props = if isnothing(dep_state.karabo_state.device)
        DeviceProperties()
    else
        get_source_properties(client, dep_state.karabo_state.device)
    end
    DepText(label, dep, dep_state, client.source_list, device_props,
            client.variable_names; device_only, variable_name)
end

function draw_parameter_widget(name, param::Parameter{Dependency})
    dep = param.value
    dep_id = node_hash(param.name)
    edited, new_dep = draw_dep_editor("param-dep-$(param.name)", dep, dep_id)
    if edited
        return true, new_dep
    end
    return false, nothing
end

function draw_parameter_widget(name, param::Parameter{Bool})
    @c ig.Checkbox("", &param.value)

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
        if !isnothing(store.scalar_tids)
            empty!(store.scalar_tids)
        end
    end

    for plot in client.plots
        clear_plot(plot)
    end
end

function draw_device_tree(device_tree)
    if isempty(device_tree)
        ig.TextDisabled("No devices loaded")
        return
    end

    n_devices = sum(length(devs) for (_, devs) in device_tree)
    n_topics = length(device_tree)
    if ig.TreeNode("Devices ($n_devices across $n_topics topics)##device-tree")
        for (topic, devices) in device_tree
            if ig.TreeNode("$topic ($(length(devices)))##topic-$topic")
                for (name, info_pairs) in devices
                    class_id_pair = findfirst(p -> p.first == "classId", info_pairs)
                    class_id = isnothing(class_id_pair) ? "" : info_pairs[class_id_pair].second
                    if ig.TreeNode("$name##dev-$name")
                        for (key, value) in info_pairs
                            ig.Text("$key: $value")
                        end
                        ig.TreePop()
                    else
                        ig.SameLine()
                        ig.TextDisabled(class_id)
                    end
                end
                ig.TreePop()
            end
        end
        ig.TreePop()
    end
end

function get_source_properties(client, device_name)
    idx = findfirst(s -> s.name == device_name, client.source_list)
    isnothing(idx) && return DeviceProperties()

    topic = client.source_list[idx].topic
    key = (topic, device_name)
    return get!(client.source_properties, key) do
        id = send(client, GetDeviceSchema(topic, device_name))
        client.device_schema_requests[key] = id
        DeviceProperties()
    end
end

# Draw a single parameter with appropriate width, and send a change message
# if modified.
function draw_parameter(name, param; min_node_width=150)
    ig.Text(name * ":")
    ig.SameLine()
    ig.SetNextItemWidth(round(Int, min_node_width * 1.5))
    modified, new_value = draw_parameter_widget(name, param)
    if modified
        change_parameter(Parameter(param.name, new_value))
    end
end

# Draw the parameters section of a variable node. Can be called from custom
# draw_variable_content() methods to include the default parameter UI.
function draw_parameters(var_data)
    if haskey(var_data, "parameters")
        ig.Text("Parameters:")
        for (param_name, param) in var_data["parameters"]
            draw_parameter(param_name, param)
        end
    end
end

# Specialize on Val{Symbol("ModulePath.function_name")} to draw custom content
# inside a variable node. Called after the titlebar and before parameters.
# Return a gui state object to persist custom state across frames, or nothing.
draw_variable_content(::Val, name, var_data, gui_state) = nothing

# Draws a variable node. The node shell (titlebar, dependencies, outputs) is
# always the same, but draw_variable_content() is called inside to allow
# custom rendering for specific variables.
function draw_variable(name, var_data)
    client = state[].client
    min_node_width = 150
    variable_store = get(client.variable_data, name, nothing)

    ig.PushID(name)
    ImNodes.BeginNode(var_data["id"])

    disable_node = client.context.pipeline_status ∉ (PipelineStatus_Stopped, PipelineStatus_Started)
    @Disabled disable_node begin
        # Draw titlebar
        ImNodes.BeginNodeTitleBar()
        edited, new_name = ElidedText("var-name-$(name)", name; editable=true)
        if edited
            @guiasync rename_variable(state[], name, new_name)
        end
        ImNodes.EndNodeTitleBar()
        # Draw custom content
        origin = var_data["origin"]
        gui_state = get(client.variable_gui_states, name, nothing)
        new_gui_state = draw_variable_content(Val(Symbol(origin)), name, var_data, gui_state)
        if !isnothing(new_gui_state) && !haskey(client.variable_gui_states, name)
            client.variable_gui_states[name] = new_gui_state
        end

        if var_data["draw_parameters"]
            draw_parameters(var_data)
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

            dep_ts = get!(client.dep_text_states, dep_id) do
                DepTextState(dep isa Dependency && dep.kind == DepKind_Karabo)
            end
            pin_shape = dep_ts.is_karabo ? ImNodes.ImNodesPinShape_TriangleFilled : ImNodes.ImNodesPinShape_CircleFilled

            ImNodes.BeginInputAttribute(dep_id, pin_shape)
            if var_data["type"] == :group
                ig.Text(arg_name * ":")
                ig.SameLine()
            end
            edited, new_dep = draw_dep_editor("dep-$(dep_id)", dep, dep_id; variable_name=name)
            if edited
                @guiasync rename_dep(state[], name, arg_name, dep, new_dep)
            end
            ImNodes.EndInputAttribute()
        end
    end # @Disabled

    ig.Dummy(min_node_width, 10)

    ig.TextDisabled("Outputs")
    if !isnothing(variable_store)
        ig.SameLine()
        ig.TextDisabled(@sprintf "%.2f Hz" variable_store.update_rate)
    end
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

        typestr = get_variable_typeinfo(output_name)
        if !isempty(typestr)
            label = isempty(label) ? typestr : "$(label) - $(typestr)"
        end

        if !isempty(label)
            if haskey(client.variable_data, output_name)
                if ig.Button("$(label)###plot_button")
                    push!(client.plots, Plot(output_name, client.plot_counter))
                    client.plot_counter += 1
                end
            else
                ig.Text(label)
            end
        end

        ImNodes.EndOutputAttribute()
    end

    ImNodes.EndNode()
    ig.PopID()
end

function draw_dag()
    client = state[].client
    context = client.context
    ctx_state = context.context_state

    ig.Dummy(0, 10)
    @Disabled isempty(ctx_state) || context.pipeline_status != PipelineStatus_Stopped begin
        if ig.Button(" Start ")
            start(state[])
        end
    end

    ig.SameLine()

    @Disabled context.pipeline_status != PipelineStatus_Started begin
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
    @Disabled context.pipeline_status in changing_states begin
        if ig.Button("Load context")
            load_context(state[])
            restore_plots(state[])
        end
    end

    ig.SameLine()
    @Disabled isempty(client.variable_data) begin
        if ig.Button("Correlate")
            push!(client.plots, CorrelationPlot(client.plot_counter))
            client.plot_counter += 1
        end
    end

    if context.pipeline_status in changing_states
        ig.SameLine()
        Spinner()
    end

    ig.SameLine()
    ig.SetCursorPosX(ig.GetCursorPos().x + ig.GetContentRegionAvail().x - 100)
    if ig.Button("Add variable")
        ig.OpenPopup("add_variable_popup")
    end
    if ig.BeginPopup("add_variable_popup")
        if ig.Selectable("Karabo source")
        end
        ig.EndPopup()
    end

    ig.Dummy(0, 10)

    ImNodes.BeginNodeEditor()

    for (name, var_data) in ctx_state
        ig.PushID(name)

        draw_variable(name, var_data)

        pos = context.node_positions[name]
        if pos != Point2d(-1, -1)
            ImNodes.SetNodeGridSpacePos(var_data["id"], (pos.x, pos.y))
            context.node_positions[name] = Point2d(-1, -1)
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

    # Timer to save the current settings periodically. Mostly useful for the
    # node positions.
    framerate = round(Int, unsafe_load(ig.GetIO().Framerate))
    if ig.GetFrameCount() % (5 * framerate) == 0
        if !isempty(ctx_state)
            save_settings(client)
        end
    end
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
                                                 current_text=ssh_state.password[])
            if edited
                ssh_state.password[] = new_password
            end

            can_authenticate = !isempty(ssh_state.password[])
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

function restore_plots(state::GuiState)
    client = state.client
    ctx_path = client.context_path
    if !haskey(state.saved_contexts, ctx_path)
        return
    end

    ctx = state.saved_contexts[ctx_path]

    context = client.context
    if haskey(ctx, "node_positions") && isempty(context.node_positions)
        saved_positions = ctx["node_positions"]
        for (name, pos) in saved_positions
            context.node_positions[name] = Point2d(pos[1], pos[2])
        end
    end

    ## Code to restore plots is buggy, so it's disabled for now

    # # Close existing plots before restoring
    # for plot in gui_state.client.plots
    #     close(plot)
    # end
    # empty!(gui_state.client.plots)

    # for p in get(ctx, "plots", [])
    #     dock_id = UInt32(get(p, "dock_id", 0))
    #     if p["type"] == "Plot"
    #         push!(gui_state.client.plots, Plot(p["name"], p["id"], dock_id))
    #     else
    #         push!(gui_state.client.plots, CorrelationPlot(p["id"], dock_id))
    #     end
    # end

    # gui_state.plot_counter = Int(get(ctx, "plot_counter", 0))

    # layout = get(ctx, "saved_layout", "")
    # if !isempty(layout)
    #     # Load the INI to restore dock node topology, then explicitly assign
    #     # each window to its saved dock node. DockBuilderDockWindow stores the
    #     # assignment in ImGui's window settings; it takes effect on the next
    #     # frame once the dock nodes are recreated from the INI.
    #     ig.LoadIniSettingsFromMemory(layout)
    #     # for plot in gui_state.client.plots
    #     #     if plot.dock_id != 0
    #     #         ig.DockBuilderDockWindow(plot.id, plot.dock_id)
    #     #     end
    #     # end
    # end
end

function draw_plots()
    client = state[].client

    # Update all the observables
    updated_variables = Dict{String, Set{Int}}()
    for (name, store) in client.variable_data
        if !isready(store.updates)
            continue
        end

        array = store.data
        new_tids = Set{Int}()
        while isready(store.updates)
            tid, x, type = take!(store.updates)
            push!(new_tids, tid)
            store.type = type
            if x isa Number
                push!(array, x)
                push!(store.scalar_tids, tid)
            elseif x isa AbstractArray
                store.data = x
                store.trainId = tid
            end
        end

        # Update contiguous caches for scalar data so plotting doesn't allocate
        if !isnothing(store.scalar_tids)
            n = length(store.data)
            resize!(store.scalar_data_cache, n)
            resize!(store.scalar_tids_cache, n)
            copyto!(store.scalar_data_cache, store.data)
            copyto!(store.scalar_tids_cache, store.scalar_tids)
        end

        updated_variables[name] = new_tids
    end

    # Draw plot windows
    for plot in client.plots
        if plot isa CorrelationPlot
            draw_plot(plot, client.variable_data, updated_variables)
        else
            store = get(client.variable_data, plot.name, nothing)
            draw_plot(plot, store, !isnothing(store) && haskey(updated_variables, plot.name))
        end
    end

    # Remove closed plots
    n = length(client.plots)
    for i in reverse(eachindex(client.plots))
        if !client.plots[i].open[]
            close(client.plots[i])
            deleteat!(client.plots, i)
        end
    end
    if length(client.plots) != n
        save_settings(client)
    end
end

function draw_engine_logs()
    client = state[].client

    ig.Dummy(0, 5)
    if ig.Button("Clear all logs")
        empty!(client.engine_logs)
    end

    ig.Dummy(0, 5)
    ig.Separator()

    for (i, log) in enumerate(client.engine_logs)
        ig.PushID(i)

        timestamp = Dates.format(unix2datetime(log.timestamp), client.log_dateformat)
        ig.Text(timestamp)
        ig.SameLine(ig.CalcTextSize("0000-00-00 00:00:00  ").x)

        if !isnothing(log.extra_details)
            if ig.TreeNode(log.message)
                ig.TextUnformatted(log.extra_details)
                ig.TreePop()
            end
        else
            ig.BulletText(log.message)
        end

        ig.PopID()
    end
end

## Main GUI function

default(value, default="") = something(value, default)

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

        if Threads.threadid() == 1
            BorderedText("Warning: GUI is running on thread 1, this may cause performance issues. Start Julia with e.g. `julia -t auto,2` instead.")
        end

        ig.BeginTabBar("main-tab-bar")
        if ig.BeginTabItem("Setup")
            ig.EndTabItem()

            initializing = client.status == RemoteStatus_Initializing
            disconnecting = client.status == RemoteStatus_Disconnecting
            can_connect = if client.embedded_engine
                client.status != RemoteStatus_Connecting && client.status != RemoteStatus_Connected
            else
                client.status != RemoteStatus_Connecting && !fully_authenticated
            end
            can_connect = can_connect && !initializing && !disconnecting

            @Disabled !can_connect begin
                @c ig.Combo("##client-type", &state[].client_type_current_item,
                           ["Connect to remote", "Create local engine"])
                client.embedded_engine = state[].client_type_current_item == 1

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
                    client.status = RemoteStatus_Initializing
                    @guiasync connect_engine()
                end
            end
            ig.SameLine()

            @Disabled can_connect || initializing || disconnecting begin
                if ig.Button("Disconnect")
                    @guiasync disconnect_engine(state[], false)
                end
            end

            ig.SameLine()

            @Disabled client.status != RemoteStatus_Connected begin
                if ig.Button("Disconnect & shutdown")
                    @guiasync disconnect_engine(state[], true)
                end
            end

            ig.Dummy(0, 20)
            if client.status == RemoteStatus_Disconnecting
                Spinner("Disconnecting...")
            elseif client.status == RemoteStatus_Initializing
                Spinner("Initializing...")
            elseif client.status == RemoteStatus_Connecting && !fully_authenticated
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

                @Disabled is_pending(client, client.debug_mode_request) begin
                    ig.Text("Debug mode")
                    ig.SameLine()
                    if ig.Checkbox("##debug-mode", client.debug_mode)
                        set_debug_mode(state[])
                    end

                    if is_pending(client, client.debug_mode_request)
                        ig.SameLine()
                        Spinner()
                    end
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
                end

                if !client.context_path_valid
                    ig.TextColored(ImVec4(1, 0.2, 0.5, 1), "Path does not point to a valid file!")
                end

                ig.Dummy(0, 10)

                trainmatcher_request_pending = is_pending(client, client.trainmatcher_set_request)
                @Disabled trainmatcher_request_pending begin
                    if ig.Button("Update trainmatchers")
                        get_trainmatchers(client)
                    end
                    if trainmatcher_request_pending
                        ig.SameLine()
                        Spinner()
                    end

                    # Show trainmatchers as a table
                    if client.trainmatchers_request_status == RequestStatus_Waiting
                        Spinner("Waiting for trainmatcher list")
                    else
                        ig.BeginTable("##trainmatchers", 2, ig.ImGuiTableFlags_Borders | ig.ImGuiTableFlags_RowBg)
                        ig.TableSetupColumn("Topic")
                        ig.TableSetupColumn("Default trainmatcher")
                        ig.TableHeadersRow()

                        for topic in sort(collect(keys(client.trainmatchers)))
                            matchers = client.trainmatchers[topic]
                            names = [m[1] for m in matchers]
                            ig.TableNextRow()
                            ig.TableNextColumn()
                            ig.Text(topic)
                            ig.TableNextColumn()

                            if !isempty(matchers)
                                if !haskey(client.trainmatcher_selected_idx, topic)
                                    client.trainmatcher_selected_idx[topic] = Ref(Cint(0))
                                end

                                if CopyableCombo("matcher-$topic", names, client.trainmatcher_selected_idx[topic])
                                    idx = client.trainmatcher_selected_idx[topic][] + 1
                                    set_topic_trainmatcher(client, topic, names[idx])
                                end

                                # Warn if the selected trainmatcher is not configurable
                                sel_idx = client.trainmatcher_selected_idx[topic][] + 1
                                if 1 <= sel_idx <= length(matchers) && !matchers[sel_idx][2]
                                    ig.SameLine()
                                    ig.TextColored(ImVec4(1.0, 0.6, 0.0, 1.0), "(not in webproxy whitelist)")
                                end
                            end
                        end

                        ig.EndTable()
                    end
                end

                ig.Dummy(0, 10)

                @Disabled is_pending(client, client.devices_request) begin
                    if ig.Button("Get devices")
                        get_devices(client)
                    end

                    draw_device_tree(client.device_tree)
                end
            end
        end

        @Disabled client.status != RemoteStatus_Connected || isempty(client.context_path) begin
            if ig.BeginTabItem("Analysis pipeline")
                draw_dag()
                ig.EndTabItem()
            end
        end

        if state[].show_engine_logs
            engine_log_flags = ig.ImGuiTabItemFlags_None
            if state[].select_engine_logs
                engine_log_flags |= ig.ImGuiTabItemFlags_SetSelected
                state[].select_engine_logs = false
            end
            if @c ig.BeginTabItem("Engine logs", &state[].show_engine_logs, engine_log_flags)
                draw_engine_logs()
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
                                      (:show_debug_log,      ig.ShowDebugLogWindow),
                                      (:show_state_inspector, draw_state_inspector)]
        do_show = getproperty(state[], window_sym)
        if do_show
            @c window_func(&do_show)
            setproperty!(state[], window_sym, do_show)
        end
    end

    # Save layout when ImGui signals changes
    io = ig.GetIO()
    if unsafe_load(io.WantSaveIniSettings) && !isempty(state[].client.plots)
        save_settings(client)
        io.WantSaveIniSettings = false
    end
end

"""Start the XFA GUI."""
function main(; test_engine=nothing)
    gui_state = GuiState(load_settings())

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
    font_config = ig.ImFontConfig()
    font_config.MergeMode = true
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
        ig.AddFontFromFileTTF(font_atlas, joinpath(font_dir, "fa-regular-400.otf"), 20, font_config)
    end

    # Setup ImPlot context
    implot_ctx = ImPlot.CreateContext()

    # Enable docking and viewports by default
    io = ig.GetIO()
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_DockingEnable
    io.ConfigFlags = unsafe_load(io.ConfigFlags) | ig.ImGuiConfigFlags_ViewportsEnable

    # Disable built-in INI file — we manage layout persistence ourselves
    io.IniFilename = C_NULL

    on_exit = () -> begin
        client = gui_state.client

        # Save layout and node positions before tearing down
        if !isempty(client.plots) || !isempty(client.context.context_state)
            save_settings(client)
        end

        # Disconnect from engine if connected
        if client.status == RemoteStatus_Connected && !isnothing(client.websocket)
            if !WebSockets.isclosed(client.websocket)
                try
                    send(client.websocket, Shutdown())
                    timedwait(() -> WebSockets.isclosed(client.websocket), 5)
                catch
                end
            end
        end

        # Clean up GPU heatmap resources before destroying contexts
        for plot in client.plots
            close(plot)
        end
        destroy_heatmap_context!()

        ImPlot.DestroyContext(implot_ctx)
        ImNodes.DestroyContext(imnodes_ctx)
        empty!(safe_input_text_cache)
        close(gui_state)
    end
    t = ig.render(imgui_ctx; on_exit, window_title="XFA", wait=false, spawn=true, engine=test_engine) do
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

# precompile(main, ())
# precompile(draw_gui, ())
