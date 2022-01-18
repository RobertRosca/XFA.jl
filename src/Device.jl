export Device, printschema

"""
    Device("MID_EXP_EPIX-1/DET/RECEIVER", Dict(
        ":daqOutput" => Dict(
            "data.image.pixels" => Float32[704, 768],
            "data.backTemp" => Float32),
        "rxConf" => Dict(
            "rxLane" => Int,
            "rxVc" => Int,
            "save" => Bool),
        "relHumidity" => Float32
    ))

Create an object representing a Karabo device, with property names and their types.
"""
struct Device
    name::String
    schema::Dict{String, Any}
    distributed_parts::Int

    function Device(name::String, schema::Dict{String, Any}, distributed_parts::Int=1)
        if distributed_parts > 1 && '*' ∉ name
            throw(ArgumentError("device name doesn't contain a '*', this is necessary if the device has more than 1 distributed_parts"))
        end

        new(name, schema, distributed_parts)
    end
end

"""
    length(device)

Number of properties of the device.
"""
function Base.length(device::Device)
    function count_elements(dict)
        properties = 0

        for v ∈ values(dict)
            properties += v isa Dict ? count_elements(v) : 1
        end

        return properties
    end

    return count_elements(device.schema)
end

function Base.show(io::IO, device::Device)
    print(io, "Device($(device.name))")
end

function printschema(device::Device)
    control_properties = [p for p in device if ':' ∉ p[1]]
    instrument_properties = [p for p in device if ':' ∈ p[1]]
    sort!(control_properties, by=p -> p[1])
    sort!(instrument_properties, by=p -> p[1])

    function print_properties(label, properties)
        if !isempty(properties)
            print("$(label):")
            for p in properties
                print("\n  $(p[1])")
            end
        end
    end

    println("$(device.name) has $(length(device)) properties:")
    print_properties("Control", control_properties)
    if !isempty(control_properties) && !isempty(instrument_properties)
        println()
    end
    print_properties("Instrument", instrument_properties)
end

function Base.iterate(device::Device)
    prefix = device.name
    iterator_states = Any[(device.schema, prefix, iterate(device.schema))]

    return Base.iterate(device, iterator_states)
end

function Base.iterate(device::Device, iterator_states)
    item = nothing

    # While we haven't found any items
    while item == nothing && !isempty(iterator_states)
        # Check if we've already seen all properties in this node
        (current_dict, prefix, next) = iterator_states[end]
        if next == nothing
            pop!(iterator_states)
            continue
        end

        # Otherwise, check out the next property
        (node, state) = next
        node_name, node_schema = node

        # Advance the current state so we don't revisit node_schema
        iterator_states[end] = (current_dict, prefix, iterate(current_dict, state))

        # If it's a Dict, traverse into it
        if node_schema isa Dict
            # Traverse node_schema
            prefix *= startswith(node_name, ':') ? node_name : ".$(node_name)"
            push!(iterator_states, (node_schema, prefix, iterate(node_schema)))
        else
            # If it's not a Dict, we have found a property and we can return it
            name = ':' ∈ prefix ? "$prefix[$(node_name)]" : "$prefix.$(node_name)"
            item = (name, node_schema)
        end
    end

    if item == nothing
        return nothing
    else
        return (item, iterator_states)
    end
end
