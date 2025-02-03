import Pkg
import TOML
using Printf

environment = ENV["XFA_ENVIRONMENT"]
engine_dir = ENV["XFA_ENGINE_DIR"]
working_dir = ENV["XFA_WORKING_DIR"]
julia_binary = ENV["XFA_JULIA_BINARY"]

ENV["JULIA_DEBUG"] = "XfaEngine"

@info "Bootstrapping..." environment engine_dir working_dir julia_binary

# Install the package
Pkg.activate(environment; shared=startswith(environment, "@"))
proxy = "exflproxy01:3128"
dependencies = ["Revise", "LoggingFormats", "LoggingExtras", "DistributedNext"]

function init_environment()
    Pkg.develop(path=joinpath(homedir(), engine_dir))
    Pkg.add(dependencies)
    Pkg.instantiate()
end

if haskey(ENV, "SASE") && endswith(gethostname(), ".desy.de")
    # If we're on the online cluster, set the proxy so we can connect to the internet
    withenv("http_proxy" => proxy, "https_proxy" => proxy) do
        init_environment()
    end
else
    init_environment()
end

# Check if a worker file already exists
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
        cmd = `$(julia_binary) --project="$(environment)" --color=no --startup-file=no -t auto $(launcher_script)`
        println("Launching: " * string(cmd))
        run(detach(cmd); wait=false)
    end
end

# Wait for up to 60s for it to start
start = time()
while !isfile(toml_path) || filesize(toml_path) == 0
    elapsed = time() - start
    if elapsed > 60
        error("Timeout while waiting for engine to start in $(working_dir)")
    else
        elapsed_str = @sprintf "%.2fs" elapsed
        println("Waiting for engine to start... $(elapsed_str)")
        sleep(1)
    end
end

# Print the config
println(">>>")
print(read(toml_path, String))
println("<<<")
