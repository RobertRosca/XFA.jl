const BASTION = "bastion.desy.de"
const GATEWAY = "exflgateway.desy.de"

function log_engine_error(state::GuiState, message::String, extra_details::Maybe{String}=nothing)
    push!(state.client.engine_logs, EngineLog(message, extra_details))
    state.show_engine_logs = true
    state.select_engine_logs = true
end

function send(client::ClientState, msg::AbstractMessage)
    id = Protocol.client_send(client.websocket, msg)
    client.pending_requests[id] = PendingRequest(typeof(msg), time())
    return id
end

function is_pending(client::ClientState, id::Union{MessageId, Nothing})
    !isnothing(id) && haskey(client.pending_requests, id)
end

# Send a request to the engine with a callback that will be executed when the
# response arrives. Returns the message ID.
function send_with_callback(client::ClientState, msg::AbstractMessage, callback::Function)
    id = send(client, msg)
    client.engine_request_callbacks[id] = callback
    return id
end

function peekall(buffer::IOBuffer)
    return String(take!(copy(buffer)))
end

function ssh_initialize(state::GuiState)
    client = state.client
    client.status = RemoteStatus_Connecting
    address = state.address
    user = nothing
    if occursin("@", address)
        user, address = split(address, "@")
    end

    if endswith(address, ".desy.de") && address != GATEWAY && address != BASTION
        push!(client.ssh_hops, SshState(; address=BASTION))
        push!(client.ssh_hops, SshState(; address=GATEWAY))
    end

    # This is the blocking SSH session used for SFTP
    push!(client.ssh_hops, SshState(; address))
    # And this is the regular, non-blocking SSH session
    push!(client.ssh_hops, SshState(; address))

    # Start by initializing the first hop
    ssh_initialize_hop(state, 1, user)
end

function ssh_initialize_hop(state, hop_idx, user)
    client = state.client
    ssh_state = client.ssh_hops[hop_idx]
    forwarder_idx = findlast(x -> !isnothing(x.forwarder), client.ssh_hops)

    if !isnothing(forwarder_idx) # hop_idx > firstindex(client.ssh_hops)
        # Connect to the forwarded port 22
        forwarder = client.ssh_hops[forwarder_idx].forwarder
        session = ssh.Session(forwarder.localinterface, forwarder.localport; user)

        # Reset the host so that GSSAPI auth works
        session.host = ssh_state.address

        ssh_state.session = session
    else
        ssh_state.session = ssh.Session(ssh_state.address, ssh_state.port; user)
    end

    ssh_authenticate_hop(state, hop_idx)
end

function ssh_fully_authenticated(client::ClientState)
    hops = client.ssh_hops
    return !isempty(hops) && all([hop.auth_state == ssh.AuthStatus_Success for hop in hops])
end

function ssh_authenticate_hop(state::GuiState, hop_idx)
    client = state.client
    ssh_state = client.ssh_hops[hop_idx]
    session = ssh_state.session
    auth_method = ssh_state.auth_method

    ssh_state.auth_state = :authenticating

    new_auth_state = if auth_method == ssh.AuthMethod_Password
        ssh.authenticate(session; password=ssh_state.password[], throw=false)
    elseif auth_method == ssh.AuthMethod_Interactive
        kbdint_answers = [prompt.answer for prompt in ssh_state.kbdint_prompts]

        ssh.authenticate(session; kbdint_answers, throw=false)
    else
        ssh.authenticate(session; throw=false)
    end

    # If we're doing interactive auth and the server asks more questions then we
    # update the prompts.
    if new_auth_state == ssh.AuthMethod_Interactive
        update_auth_prompts(ssh_state)
    end

    # At this point we're done handling the response from the server so update
    # the state for the GUI.
    if new_auth_state isa ssh.AuthMethod
        ssh_state.auth_method = new_auth_state
        ssh_state.auth_state = nothing
    elseif new_auth_state isa ssh.AuthStatus
        ssh_state.auth_state = new_auth_state
    elseif new_auth_state isa ssh.KnownHosts
        ssh_state.auth_state = new_auth_state
    else
        @error "Unsupported result from ssh.authenticate(): $(new_auth_state)"
    end

    if new_auth_state == ssh.AuthStatus_Success
        last_idx = lastindex(client.ssh_hops)
        sftp_idx = last_idx - 1

        if hop_idx == last_idx
            # If we're the last hop in the SSH chain and authentication succeeded, start
            # the engine too.
            initialize_engine(state)
        else
            next_hop = client.ssh_hops[hop_idx + 1]
            next_hop.auth_state = :connecting

            if hop_idx < sftp_idx
                # If we haven't gotten to the final node yet, create a forwarder
                localport = getavailableport(1332; interface=Sockets.localhost)
                ssh_state.forwarder = ssh.Forwarder(session, localport,
                                                    next_hop.address, next_hop.port;
                                                    localinterface=Sockets.localhost)
            elseif hop_idx == sftp_idx
                # If we're at the SFTP hop then we can create an SFTP session
                client.sftp = ssh.SftpSession(session)
            end

            ssh_initialize_hop(state, hop_idx + 1, session.user)
        end
    end
end

function update_auth_prompts(ssh_state)
    session = ssh_state.session
    prompts = ssh.userauth_kbdint_getprompts(session)

    ssh_state.kbdint_prompts = [KbdintPromptState(prompt.msg, prompt.display, "") for prompt in prompts]
end

function auth_supported(auth_method)
    if auth_method in (ssh.AuthMethod_Password, ssh.AuthMethod_Interactive)
        true
    elseif auth_method == ssh.AuthMethod_GSSAPI_MIC
        ssh.Gssapi.isavailable()
    else
        false
    end
end

function sync_files()
    client = state[].client
    if client.embedded_engine
        return
    end

    client.syncing = true
    try
        engine_dir = joinpath(pkgdir(XfaEngine), "src")
        git_diff = readchomp(`git diff --name-only $(engine_dir)`)
        if isempty(git_diff)
            @info "No files to sync"
            return
        end

        changed_files = split(git_diff, "\n")

        for path in changed_files
            local_path = joinpath(engine_dir, basename(path))
            remote_path = joinpath(client.remote_engine_dir, "src", basename(path))

            # Note that we read `local_path` before opening `remote_path`. This to
            # avoid the file getting truncated by `open(; write=true)` if we're
            # SSH'ing locally.
            data = read(local_path)
            open(remote_path, client.sftp; write=true) do f
                write(f, data)
            end
        end
    finally
        client.syncing = false
    end
end


function initialize_engine(state)
    client = state.client
    client.status = RemoteStatus_Connecting
    is_local = client.embedded_engine || state.address == "localhost"

    julia_module_prefix = if is_local
        "true"
    else
        "source /etc/profile.d/modules.sh; SASE=0 module load exfel julia/202502 > /dev/null 2>&1"
    end

    bootstrap_process = nothing

    try
        if client.embedded_engine
            client.engine = XfaEngine.main(; wait=false)
        else
            address = state.address
            ssh_state = client.ssh_hops[end]
            session = ssh_state.session

            working_dir = is_local ? pwd() : "/scratch/xfa"
            bootstrap_jl = joinpath(working_dir, "bootstrap.jl")
            code = read(joinpath(@__DIR__, "bootstrap.jl"))

            mkpath(dirname(bootstrap_jl), client.sftp)
            open(bootstrap_jl, client.sftp; write=true) do f
                write(f, code)
            end

            bootstrap_env = Dict("XFA_ENVIRONMENT" => state.engine_environment,
                                 "XFA_WORKING_DIR" => working_dir)
            bootstrap_env_str = join(["$(key)=$(value)" for (key, value) in bootstrap_env], " ")
            bootstrap_cmd = "$(bootstrap_env_str) bash -c '$(julia_module_prefix); julia --project=$(state.engine_environment) --color=no $(bootstrap_jl)'"
            bootstrap_process = run(bootstrap_cmd, session; wait=false)

            while !process_exited(bootstrap_process)
                client.cmd_output = String(copy(bootstrap_process.out))
                sleep(0.5)
            end
            client.cmd_output = String(copy(bootstrap_process.out))

            # Read the worker info
            output = client.cmd_output
            find_start = findfirst(">>>", output)
            if isnothing(find_start)
                error("Empty output from bootstrap command")
            end
            find_end = findfirst("<<<", output)
            if isnothing(find_end)
                error("Couldn't read worker info from bootstrap command")
            end

            toml_str = output[find_start.stop + 1:find_end.start - 1]
            worker_info = TOML.parse(toml_str)
            client.worker_info = worker_info

            ws_port = worker_info["1"]["websocket-port"]
            bridge_port = worker_info["1"]["karabo-bridge-port"]

            local_ws_port = getavailableport(ws_port; interface=Sockets.localhost)
            client.ws_forwarder = ssh.Forwarder(session, local_ws_port, ssh_state.address, ws_port;
                                                localinterface=Sockets.localhost)
        end

        @guiasync handle_server(state)
    catch ex
        output_str = if isnothing(bootstrap_process)
            ""
        else
            "Command output:\n" * String(copy(bootstrap_process.out)) * "\n\n"
        end

        backtrace = Util.exception2str(ex, catch_backtrace())
        full_error = output_str * "Exception:\n" * backtrace

        client.last_error = full_error
        client.status = RemoteStatus_Error
    end
end

function connect_engine()
    client = state[].client
    if client.embedded_engine
        initialize_engine(state[])
    else
        ssh_initialize(state[])
    end
end

function disconnect_engine(state, shutdown_engine)
    client = state.client
    client.status = RemoteStatus_Disconnecting

    if shutdown_engine && !isnothing(client.websocket)
        if !WebSockets.isclosed(client.websocket)
            send(client, Shutdown())
        end

        # Wait for the websocket to be closed before killing the connection
        timedwait(() -> WebSockets.isclosed(client.websocket), 10)
    end

    if client.embedded_engine
        rm("worker-info.toml"; force=true)
    end

    close(state.client)
    # Note that we use setfield!() here to bypass the locking, which would
    # otherwise cause locking mismatches.
    setfield!(state, :client, ClientState(load_settings()))
end

# Create a Int32 hash to use for ImNodes
node_hash(x) = reinterpret(Cint, crc32c(x))

function build_context_state(state, ctx_info)
    ctx_state = Dict{String, Any}()

    group_names = Set(ctx_info["groups"])
    is_group_var(name) = any(startswith(name, "$(g).") for g in group_names)
    group_of(name) = first(g for g in group_names if startswith(name, "$(g)."))

    # Build regular (non-group) variable nodes
    for (name, deps) in ctx_info["dag"]
        if is_group_var(name)
            continue
        end

        ctx_state[name] = Dict{String, Any}("id" => node_hash(name))

        ctx_state[name]["dependencies"] = []
        ctx_state[name]["outputs"] = []
        ctx_state[name]["type"] = :variable
        ctx_state[name]["origin"] = ctx_info["origins"][name]
        ctx_state[name]["draw_parameters"] = true

        for (value_name, current_values) in [("dependencies", deps),
                                             ("outputs", ["", ctx_info["subvariables"][name]...])]
            for value in current_values
                attr_id = node_hash("$(name).$(value_name).$(value)")
                push!(ctx_state[name][value_name], (attr_id, value))
            end
        end
    end

    # Build group nodes with member variables folded in as inputs/outputs
    for name in ctx_info["groups"]
        group_filter = startswith("$(name).")

        ctx_state[name] = Dict{String, Any}("id" => node_hash(name))
        ctx_state[name]["dependencies"] = []
        ctx_state[name]["outputs"] = []
        ctx_state[name]["type"] = :group
        ctx_state[name]["origin"] = ctx_info["origins"][name]
        ctx_state[name]["draw_parameters"] = true
        ctx_state[name]["links"] = []
        ctx_state[name]["parameters"] = Dict{String, Any}()

        # Add dependencies from group member variables as inputs on the group node
        for (var_name, deps) in ctx_info["dag"]
            if !group_filter(var_name)
                continue
            end
            for (arg_name, dep) in deps
                if dep isa Dependency && dep.kind == DepKind_Group
                    continue
                end
                if dep isa Parameter
                    continue
                end
                attr_id = node_hash("$(var_name).dependencies.$(arg_name => dep)")
                push!(ctx_state[name]["dependencies"], (attr_id, arg_name => dep))
            end
        end

        # Add group inputs as outputs
        inputs = filter(group_filter, keys(ctx_info["inputs"]))
        for input_name in inputs
            stripped_name = chopprefix(input_name, "$(name).")
            push!(ctx_state[name]["outputs"], (node_hash(input_name), stripped_name))
        end

        # Add group variables from the DAG as outputs
        for (var_name, _) in ctx_info["dag"]
            if !group_filter(var_name)
                continue
            end
            stripped_name = chopprefix(var_name, "$(name).")

            # The variable itself
            attr_id = node_hash("$(var_name).outputs.")
            push!(ctx_state[name]["outputs"], (attr_id, stripped_name))

            # Its subvariables
            for subvar in ctx_info["subvariables"][var_name]
                subvar_id = node_hash("$(var_name).outputs.$(subvar)")
                push!(ctx_state[name]["outputs"], (subvar_id, subvar))
            end
        end

        for (param_name, param) in ctx_info["parameters"]
            if group_filter(param_name)
                stripped_name = chopprefix(param_name, "$(name).")
                ctx_state[name]["parameters"][stripped_name] = param
            end
        end
    end

    for name in keys(ctx_info["inputs"])
        # Inputs that are part of groups will have been added before
        if any(startswith(name, "$(group).") for group in ctx_info["groups"])
            continue
        end

        if !haskey(ctx_info, name)
            ctx_state[name] = Dict{String, Any}("id" => node_hash(name))
            ctx_state[name]["dependencies"] = []
            ctx_state[name]["outputs"] = [(node_hash(name), name)]
            ctx_state[name]["type"] = :input
            ctx_state[name]["links"] = []
        end
    end

    node_dag = Dict(name => String[] for name in keys(ctx_state))

    new_links = []
    for (name, deps) in ctx_info["dag"]
        # Determine which node this variable belongs to
        node_name = is_group_var(name) ? group_of(name) : name

        for (arg_name, dep) in deps
            # Skip deps that weren't added as pins
            if is_group_var(name) && dep isa Dependency && dep.kind == DepKind_Group
                continue
            end

            link_end_id = node_hash("$(name).dependencies.$(arg_name => dep)")

            if dep isa Dependency && dep.kind == DepKind_Variable
                if is_group_var(dep.name)
                    # Link from the group node's output pin for this variable
                    link_start_id = node_hash("$(dep.name).outputs.")
                    dep_node = group_of(dep.name)
                else
                    link_start_id = ctx_state[dep.name]["outputs"][1][1]
                    dep_node = dep.name
                end
                link_id = node_hash("$(link_start_id)->$(link_end_id)")
                push!(new_links, (link_id, link_start_id, link_end_id))

                if dep_node != node_name
                    push!(node_dag[node_name], dep_node)
                end
            elseif dep isa Dependency && dep.kind == DepKind_Karabo
                input_name = ctx_info["dep_to_input"][dep.name]
                link_start_id = node_hash(input_name)
                link_id = node_hash("$(link_start_id)->$(link_end_id)")
                push!(new_links, (link_id, link_start_id, link_end_id))

                input_node_name = split(input_name, ".")[1]
                if input_node_name != node_name
                    push!(node_dag[node_name], input_node_name)
                end
            end
        end

        ctx_state[node_name]["links"] = new_links
    end

    # positions = NetworkLayout.squaregrid(adj_matrix) .* 200
    # positions[node2index[name]]
    new_positions = Dict{String, Point2d}()
    levels = coffman_graham(node_dag)
    for (level, nodes) in levels
        x_pos = level * 400
        for (i, node) in enumerate(nodes)
            new_positions[node] = Point2d(x_pos + i * 300, i * 200)
        end
    end

    state.client.context.node_positions = merge(new_positions, state.client.context.node_positions)

    for var_data in values(ctx_state)
        var_data["renaming"] = false
    end

    # Build variable names list for DepText autocompletion
    var_names = String[]
    for (name, _) in ctx_info["dag"]
        push!(var_names, name)
        for subvar in ctx_info["subvariables"][name]
            push!(var_names, "$(name).$(subvar)")
        end
    end
    sort!(var_names)
    state.client.variable_names = var_names

    return ctx_state
end

function coffman_graham(dag; W=3)
    order = XfaEngine.Context.topological_sort(dag)
    levels = Dict(0 => String[])
    current_level = 0
    for node in order
        if length(levels[current_level]) < W
            push!(levels[current_level], node)
        else
            current_level += 1
            levels[current_level] = String[node]
        end
    end

    return levels
end

function schema_property_names(schema::Dict)
    props = DeviceProperties()
    collect_properties!(props, "", schema)
    slow_order = sortperm(props.slow.names)
    sorted_slow = PropertyList(props.slow.names[slow_order], props.slow.displayed_names[slow_order],
                               props.slow.descriptions[slow_order], props.slow.value_types[slow_order])
    sorted_fast = Dict{String, PropertyList}()
    for (pipeline, plist) in props.fast
        order = sortperm(plist.names)
        sorted_fast[pipeline] = PropertyList(plist.names[order], plist.displayed_names[order],
                                             plist.descriptions[order], plist.value_types[order])
    end
    return DeviceProperties(sorted_slow, sorted_fast)
end

function collect_properties!(props, prefix, node::Dict, target::PropertyList=props.slow)
    for (key, value) in node
        path = isempty(prefix) ? key : "$(prefix).$(key)"
        if value isa Dict
            if get(value, "nodeType", "") == "Leaf"
                push!(target.names, path)
                push!(target.displayed_names, get(value, "displayedName", ""))
                push!(target.descriptions, get(value, "description", ""))
                push!(target.value_types, get(value, "valueType", ""))
            elseif haskey(value, "noInputShared") && haskey(value, "schema")
                pipeline_props = get!(props.fast, path, PropertyList())
                collect_properties!(props, "", value["schema"], pipeline_props)
            else
                collect_properties!(props, path, value, target)
            end
        end
    end
end

# Store or update a VariableStore for a given variable/subvariable.
function store_variable_data!(client, name, tid, data)
    if !haskey(client.variable_data, name)
        if data isa Number
            values = CircularBuffer{Float64}(SCALAR_BUFFER_CAPACITY)
            tids = CircularBuffer{Int}(SCALAR_BUFFER_CAPACITY)
            push!(values, data)
            push!(tids, tid)
            client.variable_data[name] = VariableStore(values, tids)
        elseif data isa AbstractArray
            client.variable_data[name] = VariableStore(data)
        else
            @error "Unsupported variable type: $(typeof(data))"
            return
        end
    end

    store = client.variable_data[name]
    type = if data isa Number
        VariableType_Scalar
    elseif data isa AbstractVector
        VariableType_Vector
    elseif data isa AbstractArray
        VariableType_Array
    else
        VariableType_Unknown
    end
    push!(store.updates, (tid, data, type))

    ts = store.update_timestamps
    push!(ts, time())
    if length(ts) > 100
        popfirst!(ts)
    end
    if length(ts) >= 2
        store.update_rate = 1 / nanmean(diff(ts))
    end
end

function handle_msg(state, msg, replied_to::Union{PendingRequest, Nothing}=nothing)
    client = state.client

    if msg isa Pong
        nothing
    elseif msg isa Stopped
        client.context.pipeline_status = PipelineStatus_Stopped
    elseif msg isa Devices
        if msg.device_names isa Exception
            @error "Error from server with DEVICES" exception=msg
            log_engine_error(state, "Failed to get devices", sprint(showerror, msg.device_names))
            client.webproxy_status = RequestStatus_Error
        else
            client.karabo_devices = msg.device_names
            client.device_tree = sort(
                [(topic, sort([(name, sort(collect(info); by=first))
                               for (name, info) in devices]; by=first))
                 for (topic, devices) in msg.device_names]; by=first)
            all_names = [name for (_, devices) in client.device_tree for (name, _) in devices]
            seen = Set{String}()
            ambiguous = Set{String}()
            for name in all_names
                if name in seen
                    push!(ambiguous, name)
                else
                    push!(seen, name)
                end
            end
            client.source_list = [SourceInfo((topic, name, name in ambiguous))
                                  for (topic, devices) in client.device_tree
                                  for (name, _) in devices]
            client.webproxy_status = RequestStatus_Idle
        end
    elseif msg isa AvailableTrainmatchers
        client.trainmatchers = msg.topic_trainmatchers
        client.trainmatchers_request_status = RequestStatus_Idle

        # Apply defaults to combo selection indices
        for (topic, default_tm) in msg.defaults
            matchers = client.trainmatchers[topic]
            idx = findfirst(m -> m[1] == default_tm, matchers)
            if !isnothing(idx)
                client.trainmatcher_selected_idx[topic] = Ref(Cint(idx - 1))
            end
        end
    elseif msg isa DeviceSchema
        client.source_properties[(msg.topic, msg.name)] = schema_property_names(msg.schema)
        delete!(client.device_schema_requests, (msg.topic, msg.name))
    elseif msg isa DeviceProperty
        nothing
    elseif msg isa ContextInfo
        if msg.info isa Dict
            client.context.context_state = build_context_state(state, msg.info)
            client.context.source = msg.source
            client.context_path = msg.info["path"]
            filter!(kv -> haskey(client.context.context_state, kv.first), client.variable_data)
        else
            @error "Context failed to load"
            log_engine_error(state, "Context failed to load", sprint(showerror, msg.info))
        end

        client.context.pipeline_status = msg.is_running ? PipelineStatus_Started : PipelineStatus_Stopped
    elseif msg isa TrainData
        for variable in msg.variables
            store_variable_data!(client, variable.name, variable.tid, variable.data)

            for (subvar_name, subvar_data) in variable.subvariables
                store_variable_data!(client, subvar_name, variable.tid, subvar_data)
            end
        end
    elseif msg isa ParameterChanged
        param = msg.parameter
        # Update the parameter in the context state. Parameter names are
        # prefixed with the group name (e.g. "bridge.address").
        parts = split(param.name, "."; limit=2)
        if length(parts) == 2
            group, param_name = parts
            group = String(group)
            param_name = String(param_name)
            ctx_state = client.context.context_state
            if haskey(ctx_state, group) && haskey(ctx_state[group], "parameters")
                if haskey(ctx_state[group]["parameters"], param_name)
                    ctx_state[group]["parameters"][param_name].value = param.value
                end
            end
        end
    elseif msg isa RemoteReplState
        client.remoterepl_mode[] = msg.enabled
        client.remoterepl_status = msg.enabled ? RemoteReplStatus_Running : RemoteReplStatus_Stopped
    elseif msg isa Ack
        if !isnothing(msg.error)
            @error "Server reported an error" exception=msg.error
            log_engine_error(state, "Server reported an error", sprint(showerror, msg.error))
        end

        if !isnothing(replied_to) && replied_to.msg_type == Start
            if isnothing(msg.error)
                client.context.pipeline_status = PipelineStatus_Started
            else
                client.context.pipeline_status = PipelineStatus_Stopped
            end
        end
    else
        @warn "Received unsupported message of type '$(typeof(msg))'"
    end
end

function handle_server(state)
    client = state.client
    port = client.embedded_engine ? client.engine.websocket_port : client.ws_forwarder.localport

    # If an SSH tunnel is used it can take a couple of seconds to set up, so we
    # allow multiple attempts.
    max_attempts = 10
    attempts = 0
    while attempts < max_attempts
        try
            # Note that we only support websockets available on localhost, either
            # because the server is running locally or because it's running remotely
            # and we've forwarded the port. Connecting to open servers is not
            # support for the moment.
            WebSockets.open("ws://localhost:$(port)") do ws
                client.websocket = ws

                # The first messages we receive are our client ID and engine directory
                id = WebSockets.receive(ws)
                client.client_id = id
                client.remote_engine_dir = WebSockets.receive(ws)

                client.status = RemoteStatus_Connected
                get_devices(client)

                for msg_bytes in ws
                    buffer = IOBuffer(msg_bytes)
                    envelope::Envelope = deserialize(buffer)

                    replied_to = if !isnothing(envelope.reply_to)
                        pop!(client.pending_requests, envelope.reply_to, nothing)
                    else
                        nothing
                    end

                    callback = if !isnothing(envelope.reply_to)
                        pop!(client.engine_request_callbacks, envelope.reply_to, nothing)
                    else
                        nothing
                    end

                    try
                        @invokelatest handle_msg(state, envelope.msg, replied_to)
                        if !isnothing(callback)
                            @invokelatest callback(envelope.msg)
                        end
                    catch ex
                        @error "Error handling message!" exception=(ex, catch_backtrace())
                    end
                end

                @info "Connection to server closed ❌"
            end

            # Break from the attempt-retry loop after the connection has been
            # closed normally.
            break
        catch ex
            # If the client was already connected then we don't try again
            if !isnothing(client.websocket)
                break
            end

            # If the port is not bound yet (e.g. if the SSH tunnel hasn't been
            # set up), we allow it to fail and retry.
            if ex isa HTTP.ConnectError
                attempts += 1
                @warn "Connection to server attempt $(attempts) failed..."
                sleep(2)
            else
                client.last_error = Util.exception2str(ex, catch_backtrace())
                client.status = RemoteStatus_Error
            end
        end
    end

    # If we've reached the maximum possible number of attempts, error out
    if client.status != RemoteStatus_Connected && attempts == max_attempts
        client.last_error = "Connection to server failed after $(attempts) attempts."
        client.status = RemoteStatus_Error

        # Call the shutdown function to ensure that the tunnel is killed too
        disconnect_engine(state, false)
    else
        # Otherwise we've disconnected normally
        client.status = RemoteStatus_Unconnected
    end
end

function get_devices(client)
    client.devices_request = send(client, GetDevices())
end

function get_trainmatchers(client)
    send(client, GetTrainmatchers())
    client.trainmatchers_request_status = RequestStatus_Waiting
end

function load_context(state)
    client = state.client
    send(client, LoadContext(client.context_path))
    client.context.pipeline_status = PipelineStatus_LoadingContext
end

function revise_engine(state)
    client = state.client
    if client.status == RemoteStatus_Connected && !isnothing(client.websocket)
        send(client, ReviseCode())
    end
end

function change_parameter(param::Parameter)
    send(state[].client, ChangeParameter(param))
end

function start(state)
    for store in values(state.client.variable_data)
        empty!(store.update_timestamps)
        store.update_rate = 0
    end

    send(state.client, Start())
    state.client.context.pipeline_status = PipelineStatus_Starting
end

function stop(state)
    send(state.client, Stop())
    state.client.context.pipeline_status = PipelineStatus_Stopping
end

function set_topic_trainmatcher(client, topic, trainmatcher)
    client.trainmatcher_set_request = send(client, SetTopicTrainmatcher(topic, trainmatcher))
end

function set_debug_mode(state)
    client = state.client
    client.debug_mode_request = send(client, SetDebugMode(client.debug_mode[]))
end

function set_remoterepl(state)
    client = state.client
    client.remoterepl_status = RemoteReplStatus_Changing
    send(client, SetRemoteRepl(client.remoterepl_mode[]))
end
