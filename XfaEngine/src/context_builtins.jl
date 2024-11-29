@Group struct KaraboBridge
    @Parameter hostname::String
    @Parameter port::Int
    @Parameter sources::Vector{String}
end

@Input function stream(bridge::KaraboBridge, output)
    @show bridge
    put!(output, (0, Dict("foo" => 42)))
end
