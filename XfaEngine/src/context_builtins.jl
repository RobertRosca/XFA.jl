using DataStructures: CircularBuffer
using FHist: Hist2D, bincounts, binedges
using NaNStatistics: nanmean, nansum, nanmean!, nansum!, allocate_nanmean, allocate_nansum

@Group struct MockInput end

update_sources(::MockInput, _) = nothing

struct KaraboDevice
    topic::String
    name::String
end

# Parse a KaraboDevice from a string, which may contain a topic prefix
# (e.g. "TOPIC//device_name").
function KaraboDevice(str::AbstractString)
    m = match(Context.topic_prefix_re, str)
    if !isnothing(m)
        return KaraboDevice(m.captures[1], m.captures[2])
    end
    return KaraboDevice("", str)
end

## KaraboBridge group

@Group mutable struct KaraboBridge
    manual_configuration::Parameter{Bool} = Parameter(false)
    trainmatcher::Parameter{KaraboDevice}
    address::Parameter{String} = Parameter("")

    sources::Vector{String} = String[]

    # Reusable receive buffers for array payloads, keyed by (source, path).
    # See karabo_bridge.jl BufferRing for the rotation policy.
    buffer_pool::BufferPool = BufferPool()

    # Internal field for testing: when set, get_sources() returns this
    # instead of querying the WebProxy.
    _mock_sources::Union{Vector{String}, Nothing} = nothing
end

input_topic(bridge::KaraboBridge) = let t = bridge.trainmatcher[].topic; isempty(t) ? nothing : t end
input_device(bridge::KaraboBridge) = let dev = bridge.trainmatcher[]
    isempty(dev.name) ? nothing : dev
end

function get_sources(bridge::KaraboBridge)
    if !isnothing(bridge._mock_sources)
        return bridge._mock_sources
    end

    try
        wp = XfaEngine.get_webproxy(bridge.trainmatcher[])
        devices = XfaEngine.get_devices(wp)
        return collect(keys(devices))
    catch ex
        @error "Failed to get sources from KaraboBridge" exception=(ex, catch_backtrace())
        return String[]
    end
end

function update_sources(bridge::KaraboBridge, sources)
    if bridge.manual_configuration[]
        @warn "KaraboBridge is in manual configuration mode, cannot automatically configure a trainmatcher"
        return
    end

    XfaEngine.put_property(bridge.trainmatcher[], "sources", [Dict("source" => s) for s in sources])
end

@Input function stream(bridge::KaraboBridge, output)
    if !bridge.manual_configuration[]
        declare_sources(Meta.name[], get_sources(bridge))

        # If no address is set, pick the first available one from the trainmatcher
        if isempty(bridge.address[])
            config = XfaEngine.get_config(bridge.trainmatcher[])
            outputs = config["zmqOutputs"]
            isempty(outputs) && error("No ZMQ outputs available from trainmatcher")
            bridge.address.value = outputs[1]["address"]

            # Notify clients of the new address
            engine_state = XfaEngine.current_engine_state
            if !isnothing(engine_state)
                for client in values(engine_state.clients)
                    XfaEngine.Protocol.server_send(client.websocket,
                                                   XfaEngine.ParameterChanged(bridge.address))
                end
            end
        end
    end

    if isempty(bridge.address[])
        error("No address configured for KaraboBridge")
    end
    client = KaraboBridgeClient(bridge.address[])

    # Start a task just to read from the bridge. Note that this is separate from
    # the task to put it into the output channel to avoid a race condition where
    # the output channel is closed while we're stuck waiting for the next bridge
    # message.
    bridge_msgs = Channel(10)
    input_task = Threads.@spawn try
        while isopen(bridge_msgs)
            # take!() may throw an exception when the client is closed
            local msg
            try
                msg = take!(client, bridge.buffer_pool)
            catch
                break
            end

            # If the channel is full we drop the train data
            if Base.n_avail(bridge_msgs) ≥ bridge_msgs.sz_max
                @warn "Input buffer for $(Meta.name[]) is full, dropping train"
                continue
            else
                put!(bridge_msgs, msg)
            end
        end
    finally
        close(output)
    end
    errormonitor(input_task)
    bind(bridge_msgs, input_task)

    output_task = Threads.@spawn for msg in bridge_msgs
        data, metadata = msg
        tid = first(values(metadata))["timestamp.tid"]

        # put!() may throw when the channel is closed
        try
            put!(output, (tid, data))
        catch
        end
    end

    try
        while isopen(output)
            sleep(0.1)
        end
    catch ex
        if !(ex isa InvalidStateException)
            rethrow()
        end
    finally
        close(client)
        close(bridge_msgs)
        wait(input_task)
        wait(output_task)
    end
end

## Correlation group

@Group mutable struct Correlation
    buffer_size::Parameter{Int} = Parameter(update_buffer_size, 10_000)
    nbins::Parameter{Int} = Parameter(invalidate_histogram, 100)
    pulses::Parameter{Vector{Int}} = Parameter(invalidate_histogram, Int[])
    x::Parameter{Dependency}
    y::Parameter{Dependency}

    histogram::Hist2D{Float64} = Hist2D(; binedges=(1:10, 1:10))
    rebuild_histogram::Bool = true
    x_buffers::Vector{CircularBuffer{Float64}} = CircularBuffer{Float64}[]
    y_buffers::Vector{CircularBuffer{Float64}} = CircularBuffer{Float64}[]
    last_edge_update::Float64 = 0.0
end

function Base.show(io::IO, corr::Correlation)
    x = corr.x[]
    y = corr.y[]
    print(io, Correlation, "(x=$(x), y=$(y))")
end

function update_buffer_size(corr::Correlation, value)
    for buf in corr.x_buffers
        resize!(buf, value)
    end
    for buf in corr.y_buffers
        resize!(buf, value)
    end
    invalidate_histogram(corr, nothing)
end

function invalidate_histogram(corr::Correlation, _)
    corr.rebuild_histogram = true
end

function compute_edges(buffer::AbstractVector, pulses, nbins)
    if isempty(buffer) || isempty(buffer[1]) || (!isempty(pulses) && isempty(intersect(eachindex(buffer), pulses)))
        return range(-1.0, 1.0; length=nbins + 1)
    end

    lo = floatmax()
    hi = floatmin()

    pulses = isempty(pulses) ? eachindex(buffer) : pulses
    for i in pulses
        if i <= length(buffer)
            pulse_lo, pulse_hi = extrema(buffer[i])
            lo = min(lo, pulse_lo)
            hi = max(hi, pulse_hi)
        end
    end

    if lo == hi
        lo -= 1
        hi += 1
    end

    return range(lo, hi; length=nbins + 1)
end

function build_histogram(corr::Correlation)
    binedges = (compute_edges(corr.x_buffers, corr.pulses[], corr.nbins[]),
                compute_edges(corr.y_buffers, corr.pulses[], corr.nbins[]))
    corr.histogram = Hist2D(; binedges, overflow=true)

    pulses = isempty(corr.pulses[]) ? eachindex(corr.x_buffers) : corr.pulses[]
    for i in pulses
        for (x, y) in zip(corr.x_buffers[i], corr.y_buffers[i])
            push!(corr.histogram, x, y)
        end
    end

    corr.rebuild_histogram = false
    corr.last_edge_update = time()
end

# Correlate two vector-valued variables by accumulating their points in
# per-pulse circular buffers and producing a 2D histogram.
@Variable function correlate(corr::Correlation, x -> Correlation.x, y -> Correlation.y)
    x_num = x isa Number
    y_num = y isa Number
    x_vec = x isa AbstractVector
    y_vec = y isa AbstractVector
    if !((x_num && y_num) || (x_vec && y_vec))
        return
    end

    # Figure out how many pulses we're working with
    n_pulses = 1
    if x_vec
        n_pulses = min(length(x), length(y))
    end

    # Adjust the internal buffers to the number of pulses
    if length(corr.x_buffers) < n_pulses
        while length(corr.x_buffers) < n_pulses
            push!(corr.x_buffers, CircularBuffer{Float64}(corr.buffer_size[]))
            push!(corr.y_buffers, CircularBuffer{Float64}(corr.buffer_size[]))
        end
    elseif length(corr.x_buffers) > n_pulses
        while length(corr.x_buffers) > n_pulses
            pop!(corr.x_buffers)
            pop!(corr.y_buffers)
        end
    end

    # Rebuild the histogram if necessary
    old_bins = time() - corr.last_edge_update >= 5
    if !isempty(corr.x_buffers)
        few_bins = length(corr.x_buffers[1]) < 20

        if corr.rebuild_histogram || old_bins || few_bins
            build_histogram(corr)
        end
    end

    for i in 1:n_pulses
        push!(corr.x_buffers[i], x[i])
        push!(corr.y_buffers[i], y[i])

        if isempty(corr.pulses[]) || i ∈ corr.pulses[]
            push!(corr.histogram, x[i], y[i])
        end
    end

    # Transform histogram weights (indexed [x_bin, y_bin]) into image-style
    # layout: first dim = row (top→bottom with y_max at top), second dim = col
    # (left→right with x_max at right).
    xe, ye = binedges(corr.histogram)
    data = reverse(permutedims(bincounts(corr.histogram)), dims=1)
    return VariableData(; data,
                        x_axis=collect(xe), y_axis=collect(ye),
                        xlabel=corr.x.value.name, ylabel=corr.y.value.name,
                        fixed_aspect=false)
end

## Reducer postprocessor

# Postprocessor that reduces a variable's data with `nanmean`. With an empty
# `dims` (the default) all dimensions are reduced to a scalar; otherwise the
# mean is taken along the given dims via nanmean's `dim` kwarg (which drops
# the reduced axes) using a buffer preallocated via `allocate_nanmean`. The
# buffer is reallocated when the input type or requested dims change.
@kwdef mutable struct Reducer{R, D, A} <: AbstractPostprocessor where {R, A}
    dims::Parameter{OptionalDims} = Parameter(OptionalDims())
    buffer::AbstractArray = []
    buffer_key::UInt = UInt(0)

    default_name::String
    reducer::R
    dims_reducer::D
    allocator::A
end

function Base.show(io::IO, r::Reducer)
    print(io, Reducer, "($(nameof(r.reducer)))")
end

default_name(r::Reducer) = r.default_name

Mean(; dims=()) = Reducer(; dims=Parameter(OptionalDims(isempty(dims) ? Int[] : Vector{Int}(collect(dims)))),
                          default_name="mean",
                          reducer=nanmean,
                          dims_reducer=nanmean!,
                          allocator=allocate_nanmean)

Sum(; dims=()) = Reducer(; dims=Parameter(OptionalDims(isempty(dims) ? Int[] : Vector{Int}(collect(dims)))),
                          default_name="sum",
                          reducer=nansum,
                          dims_reducer=nansum!,
                          allocator=allocate_nansum)

function (r::Reducer)(data)
    dims = Tuple(r.dims[].dims)
    if isempty(dims)
        return r.reducer(data)
    end

    key = hash((size(data), eltype(data), dims))
    if key != r.buffer_key
        r.buffer = r.allocator(data, dims)
        r.buffer_key = key
    end

    return r.dims_reducer(r.buffer, data; dim=dims)
end
