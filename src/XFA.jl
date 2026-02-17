module XFA

const Maybe{T} = Union{T, Nothing}

include("util.jl")
include("gui.jl")
include("settings.jl")

# using PrecompileTools: @compile_workload

end
