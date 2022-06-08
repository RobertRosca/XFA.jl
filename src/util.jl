"""
    wait_timeout(waitable, timeout::Real)

Wait for a waitable object with a timeout. Similar to `timedwait()`, returns
either `:ok` or `:timed_out`.
"""
function wait_timeout(waitable, timeout::Real)
    chan = Channel()

    # Create tasks to write to the channel when they're done
    waitable_task = @async (wait(waitable); put!(chan, :ok))
    timeout_task = @async (sleep(timeout); put!(chan, :timed_out))

    # Bind the tasks to the channel
    bind(chan, waitable_task)
    bind(chan, timeout_task)

    return take!(chan)
end

function dtype_str_to_type(dtype::String)
    if dtype == "float16"
        Float16
    elseif dtype == "float32"
        Float32
    elseif dtype == "float64"
        Float64
    elseif dtype == "int8"
        Int8
    elseif dtype == "int16"
        Int16
    elseif dtype == "int32"
        Int32
    elseif dtype == "int64"
        Int64
    elseif dtype == "uint8"
        UInt8
    elseif dtype == "uint16"
        UInt16
    elseif dtype == "uint32"
        UInt32
    elseif dtype == "uint64"
        UInt64
    elseif dtype == "bool"
        Bool
    else
        error("Unsupported dtype: '$dtype'")
    end
end

function type_to_dtype_str(type::DataType)
    return lowercase(string(type))
end
