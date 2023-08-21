import Pkg
using Distributed

include("launcher_utils.jl")


redirect_io()
initialize_logger()

# Add workers
@info "Adding workers..."
addprocs(2)

@info "Added $(extra_workers()) workers 💪"

try
    # Redirect their IO
    @everywhere workers() include("launcher_utils.jl")
    @everywhere workers() redirect_io()

    @everywhere import XfelAnalyserEngine as Engine

    Engine.main()
catch ex
    @error "Caught error, cleaning up workers and exiting" exception=ex
    throw(ex)
finally
    @info "Shutting down all workers..."
    rmprocs(workers())
    @info "All workers shutdown"
end
