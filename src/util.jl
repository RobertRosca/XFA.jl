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
