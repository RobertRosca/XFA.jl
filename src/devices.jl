using Printf
using Random

using EllipsisNotation
using InterProcessCommunication

export Device, ShmemHandle, get_instrument_sources, get_control_properties, printschema, makedetector, makeagipd, nextslot

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
mutable struct Device
    name::String
    schema::Dict{String}

    function Device(name::String, schema::Pair{String}...)
        new_device = new(name, Dict(schema))

        return finalizer(new_device) do device
            for (property, value_hint) in device
                if value_hint isa ShmemHandle
                    finalize(value_hint)
                end
            end
        end
    end
end

get_instrument_sources(device::Device) = unique([split(x[1], "[")[1] for x in device if ':' ∈ x[1]])
get_control_properties(device::Device) = [x[1][length(device.name) + 2:end] for x in device if ':' ∉ x[1]]

mutable struct DeviceGroup
    name::String
    devices::Vector{Device}
    distributed_parts::Int

    function DeviceGroup(name::String, devices::Vector{Device}; distributed_parts::Int=1)
        if distributed_parts < 1
            throw(ArgumentError("Attempted to create a DeviceGroup '$(name)' with $(distributed_parts) distributed parts," *
                                " this cannot be less than 1"))
        end

        new_dg = new(name, devices, distributed_parts)
        return finalizer(new_dg) do dg
            for device in dg.devices
                finalize(device)
            end
        end
    end
end

mutable struct ShmemHandle
    prefix::String
    num_slots::Int
    current_slot_index::Int
    buffer::SharedMemory
    array::WrappedArray
    generator::Function

    function ShmemHandle(f::Function, device_name::String, shape::Tuple;
                         output_pipeline::String="dataOutput", dtype=Float32, num_slots=10)
        shmem_name = "/" * replace("$(device_name):$(output_pipeline)", "/" => "_")
        dtype_str = type_to_dtype_str(dtype)
        shape_str = join((shape..., num_slots), ",")
        prefix = "$(shmem_name)\$$(dtype_str)\$$(shape_str)\$"

        buffer_size = prod(shape) * sizeof(dtype) * num_slots
        buffer = SharedMemory(shmem_name, buffer_size)
        array = WrappedArray(buffer, dtype, shape..., num_slots)

        new_handle = new(prefix, num_slots, 0, buffer, array, f)
        return finalizer(new_handle) do handle
            shmrm(handle.buffer)
        end
    end
end

function ShmemHandle(device_name::String, shape::Tuple; dtype=Float32, kwargs...)
    return ShmemHandle(device_name, shape; dtype, kwargs...) do trainid, out
        rand!(out)
    end
end

function nextslot(handle::ShmemHandle, trainid::Int)
    handle.current_slot_index = (handle.current_slot_index % handle.num_slots) + 1
    handle.generator(trainid, @view handle.array[.., handle.current_slot_index])

    return handle.prefix * "$(handle.current_slot_index)"
end

function makedetector(prefix::String;
                      n_quadrants=4, n_modules=16, dtype=Float32, module_shape=(128, 512),
                      output_pipeline="dataOutput", distributed_parts=4)
    devices = Device[]
    modules_per_quadrant = n_modules ÷ n_quadrants

    for i in 0:n_modules - 1
        quadrant_number = i ÷ 4 + 1
        module_number = i % 4 + 1
        device_name = @sprintf("%s%02d_Q%dM%d", prefix, i, quadrant_number, module_number)

        handle = ShmemHandle(device_name, module_shape; output_pipeline, dtype)
        device = Device(device_name,
                        ":$(output_pipeline)" => (
                            "image.data" => handle,
                            "calngShmemPaths" => ["image.data"]))
        push!(devices, device)
    end

    return DeviceGroup(prefix, devices; distributed_parts)
end

function makeagipd(instrument::String; kwargs...)
    prefix = "$(instrument)_DET_AGIPD1M-1/CALNG/CORRECT"

    return makedetector(prefix; kwargs...)
end

"""
    length(device)

Number of properties of the device.
"""
function Base.length(device::Device)
    function count_elements(dict)
        properties = 0

        for v in values(dict)
            properties += v isa Tuple ? count_elements(v) : 1
        end

        return properties
    end

    return count_elements(device.schema)
end

function Base.getindex(device::Device, source_name::String, property_name::String)
    sep = ':' ∈ source_name ? "" : "."
    full_source_name = "$(device.name)$(sep)$(source_name)"
    source = device[source_name]

    if !(source isa Dict)
        error("$(full_source_name) doesn't have any sub-properties, can't retrieve property '$(property_name)'")
    end

    for (prop_name, value) in source
        if prop_name == property_name
            return value
        end
    end

    error("Couldn't find property '$(property_name)' in $(full_source_name)")
end

function Base.getindex(device::Device, property_name::String)
    if property_name ∉ keys(device.schema)
        error("'$(property_name)' is not a property of $(device.name)")
    end

    property = device.schema[property_name]
    return property isa Tuple ? Dict(property) : property
end

"""
    length(dg::DeviceGroup)

Number of devices in the DeviceGroup.
"""
Base.length(dg::DeviceGroup) = length(dg.devices)

function Base.show(io::IO, device::Device)
    print(io, "Device($(device.name))")
end

function Base.show(io::IO, dg::DeviceGroup)
    print(io, "DeviceGroup($(dg.name), distributed_parts=$(dg.distributed_parts)) [$(length(dg.devices)) devices]")
end

"""
    printschema(device::Device)

Pretty-print the schema of a device.
"""
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

"""
    iterate(device::Device)

Iterate over all properties of a device (in no particular order).
"""
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
        if next === nothing
            pop!(iterator_states)
            continue
        end

        # Otherwise, check out the next property
        (node, state) = next
        node_name, node_schema = node

        # Advance the current state so we don't revisit node_schema
        iterator_states[end] = (current_dict, prefix, iterate(current_dict, state))

        # If it's a Dict, traverse into it
        if node_schema isa Tuple
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

"""
    iterate(dg::DeviceGroup)

Iterate over all devices in a group.
"""
Base.iterate(dg::DeviceGroup) = iterate(dg.devices)
