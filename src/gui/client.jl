module Client

import TOML
import Sockets
using Serialization

import LibSSH as ssh
import HTTP
import HTTP: WebSockets
import SumTypes: @cases

import XfaEngine: getavailableport
import XfaEngine.Context: Dependency, Parameter
import XfaEngine.Protocol: Message, send
import ..States: GuiState, SshState, ClientState, RemoteStatus, WebproxyStatus, KbdintPromptState
import ..ImGuiHelpers: @guiasync
import ...Util


const BASTION = "bastion.desy.de"
const GATEWAY = "exflgateway.desy.de"

function peekall(buffer::IOBuffer)
    return String(take!(copy(buffer)))
end

function ssh_initialize(state::GuiState)
    client = state.client
    client.status = RemoteStatus'.CONNECTING

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
        ssh.authenticate(session; password=ssh_state.password, throw_on_error=false)
    elseif auth_method == ssh.AuthMethod_Interactive
        kbdint_answers = [prompt.answer for prompt in ssh_state.kbdint_prompts]

        ssh.authenticate(session; kbdint_answers, throw_on_error=false)
    else
        ssh.authenticate(session; throw_on_error=false)
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
    client.status = RemoteStatus'.CONNECTING
    address = state.address
    ssh_state = client.ssh_hops[end]
    session = ssh_state.session

    bootstrap_process = nothing

    try
        is_local = state.address == "localhost"
        working_dir = is_local ? pwd() : "/scratch/xfa"

        environment = state.engine_environment
        is_shared_environment = startswith(environment, "@")
        if is_shared_environment
            environment = environment[2:end]
        end

        # Find the Julia binary to use
        which_proc = run(ignorestatus(`bash -c 'which julia'`), session; print_out=false)
        if !success(which_proc)
            error("Couldn't find a Julia binary")
        end
        julia_binary = strip(String(which_proc.out))

        # Warning: do not put single quotes in this string! It'll break the
        # escaping into the SSH command.
        bootstrap = """
                    import Pkg
                    import TOML
                    using Printf

                    # Install the package
                    Pkg.activate("$(environment)"; shared=$(is_shared_environment))
                    proxy = "exflproxy01:3128"
                    dependencies = ["Revise", "LoggingFormats", "LoggingExtras"]

                    if $(is_local)
                        Pkg.develop(path=joinpath(homedir(), "git/XFA/XfaEngine"))
                        for pkg in dependencies
                            Pkg.add(pkg)
                        end
                        Pkg.instantiate()
                    else
                        withenv("http_proxy" => proxy, "https_proxy" => proxy) do
                            Pkg.develop(path=joinpath(homedir(), "git/XFA/XfaEngine"))
                            for pkg in dependencies
                                Pkg.add(pkg)
                            end
                            Pkg.instantiate()
                        end
                    end

                    # Check if a worker file already exists
                    working_dir = "$(working_dir)"
                    toml_path = joinpath(working_dir, "worker-info.toml")
                    if isfile(toml_path)
                       worker_info = TOML.parsefile(toml_path)
                       headnode_pid = worker_info["1"]["pid"]

                       # If it does but its old and the process does not exist anymore, delete it
                       pid_alive = @ccall kill(headnode_pid::Cint, 0::Cint)::Cint
                       if pid_alive != 0
                           rm(toml_path)
                       end
                    end

                    # Launch the engine if necessary
                    if !isfile(toml_path)
                        import XfaEngine
                        launcher_script = joinpath(dirname(pathof(XfaEngine)), "launcher.jl")
                        mkpath(working_dir)
                        cd(working_dir) do
                            cmd = `$(julia_binary) --project="$(state.engine_environment)" --color=no --startup-file=no \$(launcher_script)`
                            println("Launching: " * string(cmd))
                            run(detach(cmd); wait=false)
                        end
                    end

                    # Wait for up to 30s for it to start
                    start = time()
                    while !isfile(toml_path) || filesize(toml_path) == 0
                        elapsed = time() - start
                        if elapsed > 30
                            error("Timeout while waiting for engine to start in \$(working_dir)")
                        else
                            elapsed_str = @sprintf "%.2fs" elapsed
                            println("Waiting for engine to start... \$(elapsed_str)")
                            sleep(1)
                        end
                    end

                    # Print the config
                    println(">>>")
                    print(read(toml_path, String))
                    println("<<<")
                    """

        bootstrap_cmd = `$(julia_binary) --color=no -E "$(bootstrap)"`
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
        client.status = RemoteStatus'.ERROR
    end
end

function disconnect(state, shutdown_engine)
    client = state.client
    if shutdown_engine && !isnothing(client.websocket)
        if !WebSockets.isclosed(client.websocket)
            send(client.websocket, Message'.HCF)
        end

        # Wait for the websocket to be closed before killing the connection
        timedwait(() -> WebSockets.isclosed(client.websocket), 10)
    end

    close(state.client)
    state.client = ClientState()
end

function build_context_state(state, ctx_info)
    ctx_state = state.context_state
    new_ctx_state = Dict{String, Any}()

    used_ids = Set()
    for (name, value) in ctx_state
        push!(used_ids, value["id"])
        for (dep_id, _) in value["dependencies"]
            push!(used_ids, dep_id)
        end
        for (output_id, _) in value["outputs"]
            push!(used_ids, output_id)
        end
        for (link_id, _, _) in value["links"]
            push!(used_ids, link_id)
        end
    end

    id_pool = setdiff(Set(1:999), used_ids)

    for (name, deps) in ctx_info["dag"]
        var_exists = haskey(ctx_state, name)
        if var_exists
            new_ctx_state[name] = ctx_state[name]
        else
            new_ctx_state[name] = Dict{String, Any}("id" => pop!(id_pool))
        end

        new_ctx_state[name]["dependencies"] = []
        new_ctx_state[name]["outputs"] = []

        old_params = var_exists ? ctx_state[name]["parameters"] : Dict()
        params = Dict([dep.name => dep for dep in values(deps) if dep isa Parameter])
        for param in values(params)
            if haskey(old_params, param.name) && typeof(param.value) == typeof(old_params[param.name].value)
                params[param.name] = old_params[param.name]
            end
        end

        new_ctx_state[name]["parameters"] = params
        non_param_deps = [dep for dep in deps if !(dep isa Parameter)]

        for (value_name, current_values) in [("dependencies", non_param_deps),
                                             ("outputs", ["output", ctx_info["subvariables"][name]...])]
            old_values = var_exists ? map(x -> x[2], ctx_state[name][value_name]) : []

            for value in current_values
                old_idx = findfirst(==(value), old_values)

                if old_idx != nothing
                    push!(new_ctx_state[name][value_name],
                          ctx_state[name][value_name][old_idx])
                else
                    push!(new_ctx_state[name][value_name], (pop!(id_pool), value))
                end
            end
        end
    end

    new_links = []
    for (name, deps) in ctx_info["dag"]
        for (i, dep_pair) in enumerate(deps)
            dep = dep_pair.second
            if dep isa Dependency
                link_start_id = new_ctx_state[dep.name]["outputs"][1][1]
                link_end_id = new_ctx_state[name]["dependencies"][i][1]
                push!(new_links, (pop!(id_pool), link_start_id, link_end_id))
            end
        end

        new_ctx_state[name]["links"] = new_links
    end

    return new_ctx_state
end

function handle_msg(state, msg)
    @cases msg begin
        PONG => nothing

        DEVICES(data) => begin
            if data isa Exception
                @error "Error from server with DEVICES" exception=data
                state.webproxy_status = WebproxyStatus'.ERROR
            else
                state.karabo_devices = data
                state.webproxy_status = WebproxyStatus'.IDLE
                state.trainmatchers = filter(x -> occursin("Matcher", x.second["classId"]),
                                             state.karabo_devices)
            end
        end

        CONTEXT_INFO(info) => begin
            state.context_state = build_context_state(state, info)
        end

        [PING, HCF, GET_DEVICES, LOAD_CONTEXT, REVISE] => nothing
    end
end

function handle_server(state)
    client = state.client
    port = client.ws_forwarder.localport

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

                client.status = RemoteStatus'.CONNECTED

                for msg_bytes in ws
                    buffer = IOBuffer(msg_bytes)
                    msg::Message = deserialize(buffer)

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
            # If the port is not bound yet (e.g. if the SSH tunnel hasn't been
            # set up), we allow it to fail and retry.
            if ex isa HTTP.ConnectError
                attempts += 1
                @warn "Connection to server attempt $(attempts) failed..."
                sleep(2)
            else
                client.last_error = Util.exception2str(ex, catch_backtrace())
                client.status = RemoteStatus'.ERROR
            end
        end
    end

    # If we've reached the maximum possible number of attempts, error out
    if client.status != RemoteStatus'.CONNECTED && attempts == max_attempts
        client.last_error = "Connection to server failed after $(attempts) attempts."
        client.status = RemoteStatus'.ERROR

        # Call the shutdown function to ensure that the tunnel is killed too
        disconnect(state, false)
    else
        # Otherwise we've disconnected normally
        client.status = RemoteStatus'.UNCONNECTED
    end
end

"""
Simple function to create a client and print server messages.

This is an internal function meant to help with debugging.
"""
function test_connect(port=1331)
    client = Client()
    address = "ws://localhost:$(port)"

    t = Threads.@spawn WebSockets.open(address) do ws
        client.websocket = ws

        id = WebSockets.receive(ws)
        client.client_id = id

        for msg_bytes in ws
            buffer = IOBuffer(msg_bytes)
            msg::Message = deserialize(buffer)
            @show msg
        end

        @info "Connection to $(address) closed"
    end

    return client, errormonitor(t)
end

function get_devices(state)
    send(state.client.websocket, Message'.GET_DEVICES(state.webproxy))
    state.webproxy_status = WebproxyStatus'.WAITING_FOR_DEVICES
    empty!(state.karabo_devices)
    empty!(state.trainmatchers)
end

function load_context(state)
    send(state.client.websocket, Message'.LOAD_CONTEXT(state.context_path))
end

function revise_engine(state)
    if state.client.status == RemoteStatus'.CONNECTED && !isnothing(state.client.websocket)
        send(state.client.websocket, Message'.REVISE)
    end
end

end
