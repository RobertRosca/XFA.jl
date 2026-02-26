const BASTION = "bastion.desy.de"
const GATEWAY = "exflgateway.desy.de"

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
        ssh.authenticate(session; password=ssh_state.password, throw=false)
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
        @info "Syncing files" changed_files

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

    julia_binary = if is_local
        "julia"
    else
        out = readchomp("$(julia_module_prefix); which julia", client.ssh_hops[end].session)
        split(out, "\n")[end]
    end

    client.remote_engine_dir = if is_local
        pkgdir(XfaEngine)
    else
        cmd_str = "$(julia_module_prefix); julia --project=@xfa-default -E 'import XfaEngine; pkgdir(XfaEngine)'"
        cmd = `bash -c $(cmd_str)`
        @show cmd
        proc = run(ignorestatus(cmd),
                   client.ssh_hops[end].session; print_out=false)
        string(chomp(String(proc.out))[2:end - 1])
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
                                 "XFA_ENGINE_DIR" => client.remote_engine_dir,
                                 "XFA_WORKING_DIR" => working_dir,
                                 "XFA_JULIA_BINARY" => julia_binary)
            bootstrap_env_str = join(["$(key)=$(value)" for (key, value) in bootstrap_env], " ")
            bootstrap_cmd = "$(bootstrap_env_str) bash -c '$(julia_module_prefix); julia --color=no $(bootstrap_jl)'"
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
            send(client.websocket, Shutdown())
        end

        # Wait for the websocket to be closed before killing the connection
        timedwait(() -> WebSockets.isclosed(client.websocket), 10)
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

    for (name, deps) in ctx_info["dag"]
        ctx_state[name] = Dict{String, Any}("id" => node_hash(name))

        ctx_state[name]["dependencies"] = []
        ctx_state[name]["outputs"] = []
        ctx_state[name]["type"] = :variable

        for (value_name, current_values) in [("dependencies", deps),
                                             ("outputs", ["", ctx_info["subvariables"][name]...])]
            for value in current_values
                attr_id = node_hash("$(name).$(value_name).$(value)")
                push!(ctx_state[name][value_name], (attr_id, value))
            end
        end
    end

    for name in ctx_info["groups"]
        group_filter = startswith("$(name).")

        ctx_state[name] = Dict{String, Any}("id" => node_hash(name))
        ctx_state[name]["dependencies"] = []
        ctx_state[name]["outputs"] = []
        ctx_state[name]["type"] = :group
        ctx_state[name]["links"] = []
        ctx_state[name]["parameters"] = Dict{String, Any}()

        inputs = filter(group_filter, keys(ctx_info["inputs"]))
        for input_name in inputs
            stripped_name = chopprefix(input_name, "$(name).")
            push!(ctx_state[name]["outputs"], (node_hash(input_name), stripped_name))
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
        for (i, dep) in enumerate(values(deps))
            link_end_id = ctx_state[name]["dependencies"][i][1]

            if dep isa Dependency
                link_start_id = ctx_state[dep.name]["outputs"][1][1]
                link_id = node_hash("$(link_start_id)->$(link_end_id)")
                push!(new_links, (link_id, link_start_id, link_end_id))

                push!(node_dag[name], dep.name)
            elseif dep isa KaraboDependency
                input_name = only(keys(ctx_info["inputs"]))
                link_start_id = node_hash(input_name)
                link_id = node_hash("$(link_start_id)->$(link_end_id)")
                push!(new_links, (link_id, link_start_id, link_end_id))

                input_node_name = split(input_name, ".")[1]
                push!(node_dag[name], input_node_name)
            end
        end

        ctx_state[name]["links"] = new_links
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

function handle_msg(state, msg)
    client = state.client

    if msg isa Pong
        nothing
    elseif msg isa AvailableTopics
        client.available_topics = msg.topics

        if !isempty(client.available_topics)
            set_default_topic(state)
        end
    elseif msg isa Started
        client.context.pipeline_status = PipelineStatus_Started
    elseif msg isa Stopped
        client.context.pipeline_status = PipelineStatus_Stopped
    elseif msg isa Devices
        if msg.device_names isa Exception
            @error "Error from server with DEVICES" exception=msg
            client.webproxy_status = WebproxyStatus_Error
        else
            client.karabo_devices = msg.device_names
            client.webproxy_status = WebproxyStatus_Idle
            client.trainmatchers = filter(x -> occursin("Matcher", x.second["classId"]),
                                          client.karabo_devices)
        end
    elseif msg isa ContextInfo
        if msg.info isa Dict
            client.context.context_state = build_context_state(state, msg.info)
        else
            @error "Context failed to load"
        end

        client.context.pipeline_status = msg.is_running ? PipelineStatus_Started : PipelineStatus_Stopped
    elseif msg isa TrainData
        for variable in msg.variables
            is_new = !haskey(client.variable_data, variable.name)

            if is_new
                if variable.data isa Number
                    array = DimArray([variable.data], (; trainId=[variable.tid]); name=variable.name)
                    client.variable_data[variable.name] = VariableStore(array)
                elseif variable.data isa AbstractArray
                    client.variable_data[variable.name] = VariableStore(variable.data)
                else
                    @error "Unsupported variable type: $(typeof(variable.data))"
                    continue
                end
            end

            store = client.variable_data[variable.name]
            type = if variable.data isa Number
                VariableType_Scalar
            elseif variable.data isa AbstractVector
                VariableType_Vector
            elseif variable.data isa AbstractArray
                VariableType_Array
            else
                VariableType_Unknown
            end
            push!(store.updates, (variable.tid, variable.data, type))
        end
    elseif msg isa RemoteReplState
        client.remoterepl_mode[] = msg.enabled
        client.remoterepl_status = msg.enabled ? RemoteReplStatus_Running : RemoteReplStatus_Stopped
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

                # The first message we receive is our client ID
                id = WebSockets.receive(ws)
                client.client_id = id

                client.status = RemoteStatus_Connected

                for msg_bytes in ws
                    buffer = IOBuffer(msg_bytes)
                    msg::AbstractMessage = deserialize(buffer)

                    try
                        @invokelatest handle_msg(state, msg)
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

function get_devices(state)
    client = state.client
    send(client.websocket, GetDevices())
    client.webproxy_status = WebproxyStatus_WaitingForDevices
    empty!(client.karabo_devices)
    empty!(client.trainmatchers)
end

function load_context(state)
    client = state.client
    send(client.websocket, LoadContext(client.context_path))
    client.context.pipeline_status = PipelineStatus_LoadingContext
end

function revise_engine(state)
    client = state.client
    if client.status == RemoteStatus_Connected && !isnothing(client.websocket)
        send(client.websocket, ReviseCode())
    end
end

function change_parameter(param::Parameter)
    send(state[].client.websocket, ChangeParameter(param))
end

function start(state)
    send(state.client.websocket, Start())
    state.client.context.pipeline_status = PipelineStatus_Starting
end

function stop(state)
    send(state.client.websocket, Stop())
    state.client.context.pipeline_status = PipelineStatus_Stopping
end

function set_default_topic(state)
    client = state.client
    idx = client.default_topic_idx[] + 1 # Add 1 to go from a C index to a Julia index
    topic = client.available_topics[idx]
    send(client.websocket, SetDefaultTopic(topic))
end

function set_debug_mode(state)
    client = state.client
    send(client.websocket, SetDebugMode(client.debug_mode[]))
end

function set_remoterepl(state)
    client = state.client
    client.remoterepl_status = RemoteReplStatus_Changing
    send(client.websocket, SetRemoteRepl(client.remoterepl_mode[]))
end
