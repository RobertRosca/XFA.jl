using Printf
using InterProcessCommunication

export Device, printschema, makedetector, makeagipd

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

struct DeviceGroup
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
    next_slot_index::Int
    buffer::SharedMemory
    array::WrappedArray

    function ShmemHandle(device_name::String, shape::Tuple;
                         output_pipeline::String="dataOutput", dtype=Float32, num_slots=10)
        shmem_name = "/" * replace("$(device_name):$(output_pipeline)", "/" => "_")
        dtype_str = type_to_dtype_str(dtype)
        shape_str = join((num_slots, shape...), ",")
        prefix = "$(shmem_name)\$$(dtype_str)\$$(shape_str)\$"

        buffer_size = prod(shape) * sizeof(dtype) * num_slots
        buffer = SharedMemory(shmem_name, buffer_size)
        array = WrappedArray(buffer, dtype, shape...)

        new_handle = new(prefix, num_slots, 0, buffer, array)
        return finalizer(new_handle) do handle
            shmrm(handle.buffer)
        end
    end
end

function nextslot(handle::ShmemHandle)
    shmem_name = handle.prefix * "$(handle.next_slot_index)"

    handle.next_slot_index = (handle.next_slot_index + 1) % handle.num_slots

    return shmem_name
end

function makedetector(prefix::String;
                      n_quadrants=4, n_modules=16, dtype=Float32, module_shape=(128, 512),
                      output_pipeline=":dataOutput", distributed_parts=4)
    devices = Device[]
    modules_per_quadrant = n_modules ÷ n_quadrants

    for i in 0:n_modules - 1
        quadrant_number = i ÷ 4 + 1
        module_number = i % 4 + 1
        device_name = @sprintf("%s%02d_Q%dM%d", prefix, i, quadrant_number, module_number)

        handle = ShmemHandle(device_name, module_shape; output_pipeline, dtype)
        device = Device(device_name,
                        output_pipeline => (
                            "image.data" => () -> nextslot(handle),
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
