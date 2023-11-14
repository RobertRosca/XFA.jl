module Client

import TOML
using Serialization

import HTTP
import HTTP: WebSockets
import SumTypes: @cases

import XfaEngine.Context: Dependency
import XfaEngine.Protocol: Message, send
import ..States: RemoteStatus, HeadNode, WebproxyStatus
import ..ImGuiHelpers: @guiasync
import ...Util


function peekall(buffer::IOBuffer)
    return String(take!(copy(buffer)))
end

function initialize_engine(state)
    headnode = state.headnode
    stderr_buf = IOBuffer()

    try
        state.headnode_cmd_output = IOBuffer()
        headnode.status = RemoteStatus'.CONNECTING

        is_local = headnode.address == "localhost"
        working_dir = is_local ? pwd() : "/scratch/xfa"

        environment = state.engine_environment
        is_shared_environment = startswith(environment, "@")
        if is_shared_environment
            environment = environment[2:end]
        end

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
                            # Pkg.add(path=joinpath(homedir(), "git/XFA"), subdir="XfaEngine")
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
                            cmd = `julia --project="$(state.engine_environment)" --color=no --startup-file=no \$(launcher_script)`
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

        if is_local
            run(pipeline(`julia --color=no --startup-file=no -E "$(bootstrap)"`,
                         stdout=state.headnode_cmd_output, stderr=stderr_buf))
        else
            run(pipeline(`ssh -t $(headnode.address) "julia --color=no --startup-file=no -E '$(bootstrap)'"`;
                         stdout=state.headnode_cmd_output, stderr=stderr_buf))
        end

        # Read the worker info
        output = peekall(state.headnode_cmd_output)
        toml_str = output[findfirst(">>>", output).stop + 1:findfirst("<<<", output).start - 1]
        worker_info = TOML.parse(toml_str)
        headnode.worker_info = worker_info

        if !is_local
            ws_port = worker_info["1"]["websocket-port"]
            bridge_port = worker_info["1"]["karabo-bridge-port"]

            # Explanation of ssh options:
            # -n: Stops ssh from reading stdin, which is necessary since
            #     `run(; wait=false)` passes /dev/null to stdin.
            # -N: Don't execute a remote command. Otherwise we'd have to run `sleep`
            #     or something.
            # -T: Don't allocate a TTY.
            headnode.ssh_process = run(`ssh -nNT -L $(ws_port):localhost:$(ws_port) -L $(bridge_port):localhost:$(bridge_port) $(headnode.address)`;
                                       wait=false)
        end

        @guiasync handle_server(state)
    catch ex
        output = peekall(state.headnode_cmd_output)
        backtrace = Util.exception2str(ex, catch_backtrace())
        full_error = "Command output:\n" * output * peekall(stderr_buf) * "\n\n" * "Exception:\n" * backtrace

        headnode.last_error = full_error
        headnode.status = RemoteStatus'.ERROR
    end
end

function shutdown_server(state)
    headnode = state.headnode
    if headnode.websocket == nothing
        return
    end

    if !WebSockets.isclosed(headnode.websocket)
        send(headnode.websocket, Message'.HCF)
        # close(headnode.websocket)
        headnode.status = RemoteStatus'.UNCONNECTED
    end

    # Wait for the websocket to be closed before killing the connection
    start = time()
    while time() - start < 10
        if WebSockets.isclosed(headnode.websocket)
            break
        else
            sleep(1)
        end
    end

    # Kill the SSH tunnel
    if headnode.ssh_process != nothing && process_running(headnode.ssh_process)
        kill(headnode.ssh_process)
    end
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
        for (value_name, current_values) in [("dependencies", deps),
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
        for (i, dep) in enumerate(deps)
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
            end
        end

        CONTEXT_INFO(info) => begin
            state.context_state = build_context_state(state, info)
        end

        [PING, HCF, GET_DEVICES, LOAD_CONTEXT, REVISE] => nothing
    end
end

function handle_server(state)
    headnode = state.headnode
    port = headnode.worker_info["1"]["websocket-port"]

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
                headnode.websocket = ws

                # The first message we receive is our client ID
                id = WebSockets.receive(ws)
                headnode.client_id = id

                headnode.status = RemoteStatus'.CONNECTED

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
                @warn "Connection to server attempt $(attempts) failed..." # exception=(ex, catch_backtrace())
                sleep(2)
            else
                headnode.last_error = Util.exception2str(ex, catch_backtrace())
                headnode.status = RemoteStatus'.ERROR
            end
        end
    end

    # If we've reached the maximum possible number of attempts, error out
    if headnode.status != RemoteStatus'.CONNECTED && attempts == max_attempts
        headnode.last_error = "Connection to server failed after $(attempts) attempts."
        headnode.status = RemoteStatus'.ERROR

        # Call the shutdown function to ensure that the tunnel is killed too
        shutdown_server(state)
    else
        # Otherwise we've disconnected normally
        headnode.status = RemoteStatus'.UNCONNECTED
    end
end

"""
Simple function to create a client and print server messages.

This is an internal function meant to help with debugging.
"""
function test_connect(port=1331)
    headnode = HeadNode()
    headnode.address = "ws://localhost:$(port)"

    t = Threads.@spawn WebSockets.open(headnode.address) do ws
        headnode.websocket = ws

        id = WebSockets.receive(ws)
        headnode.client_id = id

        for msg_bytes in ws
            buffer = IOBuffer(msg_bytes)
            msg::Message = deserialize(buffer)
            @show msg
        end

        @info "Connection to $(headnode.address) closed"
    end

    return headnode, errormonitor(t)
end

function get_devices(state)
    send(state.headnode.websocket, Message'.GET_DEVICES(state.webproxy))
    state.webproxy_status = WebproxyStatus'.WAITING_FOR_DEVICES
end

function load_context(state)
    send(state.headnode.websocket, Message'.LOAD_CONTEXT(state.context_path))
end

function revise_engine(state)
    send(state.headnode.websocket, Message'.REVISE)
end

end
