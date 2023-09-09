module Client

import TOML
using Serialization

import HTTP
import HTTP: WebSockets
import SumTypes: @cases
import XfelAnalyserEngine.Protocol: Message, send
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

        # Warning: do not put single quotes in this string! It'll break the
        # escaping into the SSH command.
        bootstrap = """
                    import Pkg
                    import TOML

                    # Install the package
                    Pkg.activate("xfa-default"; shared=true)
                    proxy = "exflproxy01:3128"
                    if $(is_local)
                        Pkg.develop(path=joinpath(homedir(), "git/XFA/XfelAnalyserEngine"))
                    else
                        withenv("http_proxy" => proxy, "https_proxy" => proxy) do
                            # Pkg.add(path=joinpath(homedir(), "git/XFA"), subdir="XfelAnalyserEngine")
                            Pkg.develop(path=joinpath(homedir(), "git/XFA/XfelAnalyserEngine"))
                            Pkg.add("LoggingFormats")
                            Pkg.add("LoggingExtras")
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
                        import XfelAnalyserEngine
                        launcher_script = joinpath(dirname(pathof(XfelAnalyserEngine)), "launcher.jl")
                        mkpath(working_dir)
                        cd(working_dir) do
                            cmd = `julia --project="@xfa-default" --color=no --startup-file=no \$(launcher_script)`
                            println("Launching: " * string(cmd))
                            run(detach(cmd); wait=false)
                        end
                    end

                    # Wait for up to 30s for it to start
                    start = time()
                    while !isfile(toml_path)
                        elapsed = time() - start
                        if elapsed > 30
                            error("Timeout while waiting for engine to start in \$(working_dir)")
                        else
                            println("Waiting for engine to start... \$(elapsed)s")
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

        [PING, HCF, GET_DEVICES] => nothing
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
                    @invokelatest handle_msg(state, msg)
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

function get_devices(state)
    send(state.headnode.websocket, Message'.GET_DEVICES(state.webproxy))
    state.webproxy_status = WebproxyStatus'.WAITING_FOR_DEVICES
end

end
