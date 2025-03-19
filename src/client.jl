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

    push!(client.ssh_hops, SshState(; address))

    # Start by initializing the first hop
    ssh_initialize_hop(state, 1, user)
end

function ssh_initialize_hop(state, hop_idx, user)
    client = state.client
    ssh_state = client.ssh_hops[hop_idx]

    if hop_idx > firstindex(client.ssh_hops)
        # Connect to the forwarded port 22
        forwarder = client.ssh_hops[hop_idx - 1].forwarder
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
        if hop_idx == lastindex(client.ssh_hops)
            # If we're the last hop in the SSH chain and authentication succeeded, start
            # the engine too.
            initialize_engine(state)
        else
            # Otherwise, create a Forwarder and initialize the next hop
            next_hop = client.ssh_hops[hop_idx + 1]
            next_hop.auth_state = :connecting

            localport = getavailableport(1332; interface=Sockets.localhost)
            ssh_state.forwarder = ssh.Forwarder(session, localport,
                                                next_hop.address, next_hop.port;
                                                localinterface=Sockets.localhost)
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

function initialize_engine(state)
    client = state.client
    client.status = RemoteStatus_Connecting

    bootstrap_process = nothing

    try
        if client.is_local
            client.local_engine = XfaEngine.main(; wait=false)
        else
            address = state.address
            ssh_state = client.ssh_hops[end]
            session = ssh_state.session

            is_local = state.address == "localhost"
            working_dir = is_local ? pwd() : "/scratch/xfa"

            # Find the Julia binary to use
            which_proc = run(ignorestatus(`bash -c 'which julia'`), session; print_out=false)
            if !success(which_proc)
                error("Couldn't find a Julia binary")
            end
            julia_binary = strip(String(which_proc.out))

            bootstrap_jl = joinpath(working_dir, "bootstrap.jl")
            ssh.SftpSession(session) do sftp
                code = read(joinpath(@__DIR__, "bootstrap.jl"))

                mkpath(dirname(bootstrap_jl), sftp)
                open(bootstrap_jl, sftp; write=true) do f
                    write(f, code)
                end
            end

            bootstrap_env = Dict("XFA_ENVIRONMENT" => client.engine_environment,
                                 "XFA_ENGINE_DIR" => "git/XFA.jl/XfaEngine",
                                 "XFA_WORKING_DIR" => working_dir,
                                 "XFA_JULIA_BINARY" => julia_binary)
            bootstrap_env_str = join(["$(key)=$(value)" for (key, value) in bootstrap_env], " ")
            bootstrap_cmd = "$(bootstrap_env_str) bash -c '$(julia_binary) --color=no $(bootstrap_jl)'"
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
    if client.is_local
        initialize_engine(state[])
    else
        ssh_initialize(state[])
    end
end

function disconnect_engine(state, shutdown_engine)
    client = state.client
    if shutdown_engine && !isnothing(client.websocket)
        if !WebSockets.isclosed(client.websocket)
            send(client.websocket, Shutdown())
        end

        # Wait for the websocket to be closed before killing the connection
        timedwait(() -> WebSockets.isclosed(client.websocket), 10)
    end

    close(state.client)
    state.client = ClientState()
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

    state.client.node_positions = merge(new_positions, state.client.node_positions)

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
    elseif msg isa Started
        client.pipeline_status = PipelineStatus_Started
    elseif msg isa Stopped
        client.pipeline_status = PipelineStatus_Stopped
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
            client.context_state = build_context_state(state, msg.info)
        else
            @error "Context failed to load"
        end
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
            push!(store.updates, (variable.tid, variable.data))
        end
    else
        @warn "Received unsupported message of type '$(typeof(msg))'"
    end
end

function handle_server(state)
    client = state.client
    port = client.is_local ? client.local_engine.websocket_port : client.ws_forwarder.localport

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
    send(client.websocket, GetDevices(client.webproxy))
    client.webproxy_status = WebproxyStatus_WaitingForDevices
    empty!(client.karabo_devices)
    empty!(client.trainmatchers)
end

function load_context(state)
    client = state.client
    send(client.websocket, LoadContext(client.context_path))
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
    state.client.pipeline_status = PipelineStatus_Starting
end

function stop(state)
    send(state.client.websocket, Stop())
    state.client.pipeline_status = PipelineStatus_Stopping
end
