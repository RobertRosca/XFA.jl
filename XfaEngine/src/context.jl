module Context

export @karabo_str, @Variable, @Input, @Group, @add_subvariable, Parameter, tryset, KaraboDevice

import Base.ScopedValues: @with

import DistributedNext: RemoteChannel, remote_do

import MacroTools
import MacroTools: @capture, postwalk, prettify
import OrderedCollections: OrderedDict
import DimensionalData as DD
import ..XfaEngine

# Trait functions for dispatch-based metadata registration.
# Overloaded by @Variable, @Input, and @Group macros for each
# function/type they define, enabling Revise compatibility.
function variable_dependencies end
function input_dependencies end
function group_fields end
variable_subvariables(_) = String[]
# For variable references (@Variable name -> MyLib.func), returns the
# original function. Used to exclude origin functions from the context
# when they are already represented by a reference wrapper.
variable_origin(f) = f

struct Neighbour
    name::String
    channel::RemoteChannel
end

# Container module for train/variable-specific information. This conflicts with
# Base.Meta but we accept that for the convenience of the name. In this module
# and the context file, usage of Base.Meta should always explicitly refer to
# `Base.Meta` to avoid confusion.
module Meta

import Base.ScopedValues: ScopedValue

const tid = ScopedValue{Int}()
const run_number = ScopedValue{Int}()
const proposal = ScopedValue{Int}()
const name = ScopedValue{String}()

const scratch = ScopedValue(Dict{String, Any}())
const subvariables = ScopedValue(Dict{String, Any}())

end

include("context_types.jl")
include("trainmatching.jl")

import ..KaraboBridge: KaraboBridgeClient
include("context_builtins.jl")

@kwdef mutable struct WorkerState
    task_locks = Dict{String, ReentrantLock}()
    dag_functions = Dict{String, Function}()
    parameters = Dict{String, Parameter}()
    current_ctx_module::Module = Module()
end

@kwdef mutable struct XfaContext
    functions::Dict{String, Any} = Dict()
    group_types::Dict{DataType, Group} = Dict()
    groups::Dict{String, Any} = Dict()
    dag::Dict{String, OrderedDict} = Dict()
    subvariables::Dict{String, Vector{String}} = Dict()
    parameters::Dict{String, Parameter} = Dict()
    exprs::Vector{Expr} = Expr[]

    inputs::Dict{String, Any} = Dict()
    input_channels::Dict{String, Channel} = Dict()
    input_tasks::Dict{String, Task} = Dict()
    available_sources::Dict{String, Vector{String}} = Dict()

    input_variable_channels::Dict{String, Dict{String, RemoteChannel}} = Dict()
    input_variables_tasks::Dict{String, Task} = Dict()

    external_dependency_channels::Dict{String, Dict{String, RemoteChannel}} = Dict()
    external_dependency_tasks::Dict{String, Task} = Dict()

    variable_tasks::Dict{String, Task} = Dict()
    variable_channels::Dict{String, Dict{String, RemoteChannel}} = Dict()

    stream_output::Union{RemoteChannel, Nothing} = nothing
    forwarder::Function = Returns(nothing)
    output_forwarder_task::Union{Task, Nothing} = nothing

    path::String = ""

    is_running::Threads.Atomic{Bool} = Threads.Atomic{Bool}(false)
    events_channel::Union{RemoteChannel, Nothing} = nothing
    watcher_task::Task = Task(Returns(nothing))
end

worker_state::WorkerState = WorkerState()
current_ctx::Union{XfaContext, Nothing} = nothing

function Base.show(io::IO, ctx::XfaContext)
    n_variables = length(ctx.functions)
    n_params = length(ctx.parameters)
    print(io, "XfaContext($(n_variables) variables, $(n_params) parameters)")
end

"""
Finds all external dependencies (i.e. from Karabo) required by the context.
"""
function external_dependencies(ctx::XfaContext; per_variable=false)
    deps_per_variable = Dict{String, Vector{KaraboDependency}}()
    all_deps = KaraboDependency[]

    for (name, deps) in ctx.dag
        for (_, dep) in deps
            if dep isa KaraboDependency
                deps_vec = get!(deps_per_variable, name, KaraboDependency[])
                push!(deps_vec, dep)
                push!(all_deps, dep)
            end
        end
    end

    return per_variable ? deps_per_variable : unique(all_deps)
end

# Returns the name used to match a dependency against a variable name.
# For most dependencies this is the full string, but for SubvariableDependency
# it's the parent name since subvariables share their parent's channel.
dep_variable_name(x) = string(x)
dep_variable_name(x::SubvariableDependency) = x.parent

function find_downstream_neighbours(ctx::XfaContext, dep_name, T::DataType)
    neighbours = Set{String}()
    for (var_name, deps) in ctx.dag
        for (_, dep) in deps
            if dep isa T && dep_variable_name(dep) == dep_name
                push!(neighbours, var_name)
            end
        end
    end

    return neighbours
end

# Return the origin path for a variable function or group type, stripping the
# anonymous context module prefix so that context-local definitions are just
# their name (e.g. "foo") and imported ones keep their module path
# (e.g. "MyLib.bar").
function origin_path(x)
    origin = x isa Function ? variable_origin(x) : x
    mod = parentmodule(origin)
    parts = String[]
    while !startswith(string(nameof(mod)), "XfaContext")
        pushfirst!(parts, string(nameof(mod)))
        if mod === parentmodule(mod)
            break
        end
        mod = parentmodule(mod)
    end
    push!(parts, string(nameof(origin)))
    return join(parts, ".")
end

function to_dict(ctx::XfaContext)
    inputs = Dict{String, Vector{String}}()
    for (name, deps) in ctx.inputs
        inputs[name] = collect(keys(deps))
    end

    groups = sort(collect(keys(ctx.groups)))

    origins = Dict{String, String}()
    for (name, func) in ctx.functions
        origins[name] = origin_path(func)
    end
    for (group_type, _) in ctx.group_types
        for (name, obj) in ctx.groups
            if obj isa group_type
                origins[name] = origin_path(group_type)
            end
        end
    end

    return Dict("dag" => ctx.dag,
                "subvariables" => ctx.subvariables,
                "parameters" => ctx.parameters,
                "inputs" => inputs,
                "groups" => groups,
                "origins" => origins,
                "path" => ctx.path)
end

"""
Return a sorted order of functions in the context to execute.

Subvariables are taken into account, but excluded from the output since only
their parents are functions that can be executed.
"""
function topological_sort(dag)
    # First we create a copy of the DAG with some changes:
    # - Remove all Parameter dependencies (TODO: don't do this when parameter
    #   functions are implemented)
    # - All external dependencies (i.e from Karabo) removed
    # - All subvariables represented by their parent function
    # - All dependencies converted to strings for simplicity
    # - All group object arguments are removed
    internal_dag = Dict{String, Vector{String}}()
    for (name, deps) in dag
        internal_dag[name] = [x isa SubvariableDependency ? x.parent : string(x) for x in values(deps)
                              if !(x isa KaraboDependency) && !(x isa Parameter) && !(x isa GroupDependency)]
    end

    sorted_graph = String[]
    working_set = Set([name for (name, deps) in internal_dag if isempty(deps)])

    while !isempty(working_set)
        variable = pop!(working_set)
        push!(sorted_graph, variable)

        for (name, deps) in internal_dag
            idxs = findall(x -> x == variable, deps)

            if !isempty(idxs)
                deleteat!(deps, idxs)

                if isempty(deps)
                    push!(working_set, name)
                end
            end
        end
    end

    if !all(isempty.(values(internal_dag)))
        throw(XfaContextException("Context graph has a cycle, cannot construct a DAG"))
    end

    return sorted_graph
end

topological_sort(ctx::XfaContext) = topological_sort(ctx.dag)

function execute_variables(ctx::XfaContext, inputs::Dict)
    execution_order = topological_sort(ctx)
    results = Dict{String, Any}()

    for name in execution_order
        # Build up the argument list
        args = []
        for dep in values(ctx.dag[name])
            dep_key = string(dep)

            if dep isa KaraboDependency
                if haskey(inputs, dep_key)
                    push!(args, inputs[dep_key])
                end
            elseif dep isa Dependency
                if haskey(results, dep_key)
                    push!(args, results[dep_key])
                end
            elseif dep isa Parameter
                push!(args, ctx.parameters[dep_key].value)
            elseif dep isa GroupDependency
                push!(args, ctx.groups[dep.struct_name])
            else
                throw(XfaContextException("Unrecognized dependency type: $(typeof(dep))"))
            end
        end

        # Call the function
        if length(args) == length(ctx.dag[name])
            try
                results[name] = @invokelatest ctx.functions[name](args...)
            catch ex
                @error "Error executing $(name)!" exception=ex
            end
        end
    end

    return results
end

struct TrainData{T}
    tid::UInt64
    data::T
end

TrainData(tid, data) = TrainData(UInt64(tid), data)

function change_parameter(new_param::Parameter)
    pause_pipeline() do
        ctx_param = worker_state.parameters[new_param.name]
        if !isnothing(ctx_param.update_handler)
            try
                ctx_param.update_handler(new_param.value)
            catch ex
                @error "Exception in update handler for parameter '$(ctx_param.name)'" exception=ex
            end
        end

        ctx_param.value = new_param.value
    end
end

function input_wrapper(name, group, channel)
    f = worker_state.dag_functions[name]

    try
        if isnothing(group)
            @with Meta.name => name f(channel)
        else
            @with Meta.name => name f(group, channel)
        end
    catch ex
        if !(ex isa InvalidStateException)
            @error "Caught exception while executing input '$(name)'" exception=(ex, catch_backtrace())
        end
    finally
        close(channel)
    end
end

function maybe_send_output(channel, data::VariableData)
    # Semi-arbitrarily set a threshold of 30MB, which is just under twice the
    # size of a Float32 2k camera.
    threshold = 30_000_000

    if Base.summarysize(data) < threshold
        put!(channel, data)
    else
        put!(channel, VariableData(data.tid, nothing, :threshold_exceeded))
    end
end

function putall!(channels, value)
    for channel in channels
        put!(channel, value)
    end
end

function stream_input(name, channel, downstream_neighbours)
    try
        while isopen(channel) || isready(channel)
            tid, sources = take!(channel)

            putall!(values(downstream_neighbours), TrainData(tid, sources))
            @debug "Pushed input data from '$(name)' to: $(keys(downstream_neighbours))"
        end
    catch ex
        if !(ex isa InvalidStateException)
            # If it's not an error about the channel being closed, show the exception
            @error "Couldn't get input data from '$(name)'" exception=(ex, catch_backtrace())
        end
    finally
        @debug "Finishing input '$(name)'"
        for neighbour_channel in values(downstream_neighbours)
            close(neighbour_channel)
        end
    end
end

function stream_external_dependency(name, input_neighbour, downstream_neighbours)
    channel = input_neighbour.channel

    dep = KaraboDependency(name)
    property_value = dep.property * ".value"

    try
        while isopen(channel) || isready(channel)
            input = take!(channel)
            data = nothing

            if haskey(input.data, dep.source)
                source_data = input.data[dep.source]
                if haskey(source_data, dep.property)
                    data = input.data[dep.source][dep.property]
                elseif haskey(source_data, property_value)
                    data = input.data[dep.source][property_value]
                end
            end

            result = VariableData(input.tid, name, data)
            putall!(values(downstream_neighbours), result)
            @debug "Pushed data for '$(name)' to: $(keys(downstream_neighbours))"
        end
    catch ex
        if !(ex isa InvalidStateException)
            @error "Executing external dependency '$(name)' failed" exception=(ex, catch_backtrace())
        end
    finally
        @debug "Finishing external dependency '$(name)'"
        close(channel)
        for channel in values(downstream_neighbours)
            close(channel)
        end
    end
end

function stream_variable(name, stream_output, upstream, downstream, deps)
    # Initialize the scratch space
    scratch = Dict{String, Any}()

    matcher = Trainmatcher(k for (k, v) in upstream if v isa RemoteChannel)
    matched_trains = Dict{Int, Any}()
    args = Vector{Any}(undef, length(deps))
    try
        while true
            while isempty(matched_trains)
                for arg in values(upstream)
                    if arg isa RemoteChannel
                        variable = take!(arg)

                        if !isempty(match_train!(matched_trains, matcher, variable))
                            break
                        end
                    end
                end
            end

            tid, matched_data = only(matched_trains)
            empty!(matched_trains)

            # Build args from deps, extracting subvariable values as needed
            for (i, (arg_name, dep)) in enumerate(deps)
                if dep isa GroupDependency
                    args[i] = upstream[dep.name]
                elseif dep isa SubvariableDependency
                    args[i] = matched_data[dep.parent].subvariables[string(dep)]
                else
                    args[i] = matched_data[string(dep)].data
                end
            end

            # Don't execute the variable if any inputs are `nothing`
            empty_result = VariableData(tid, name, nothing)
            if any(isnothing, args)
                putall!(values(downstream), empty_result)
                continue
            end

            # Execute the variable
            f = worker_state.dag_functions[name]
            subvar_values = Dict{String, Any}()
            @debug "Executing variable '$(name)'..."
            @lock worker_state.task_locks[name] try
                out = @with(Meta.tid => tid,
                            Meta.name => name,
                            Meta.scratch => scratch,
                            Meta.subvariables => subvar_values,
                            f(args...))
            catch ex
                @error "Execution of variable '$(name)' failed" exception=(ex, catch_backtrace())
                putall!(values(downstream), empty_result)
                continue
            end

            # Send output
            out = VariableData(tid, name, out, subvar_values)
            maybe_send_output(stream_output, out)
            putall!(values(downstream), out)
            @debug "Pushed output from '$(name)' to: $(keys(downstream))"
        end
    catch ex
        if !(ex isa InvalidStateException)
            @error "Streaming '$(name)' failed" exception=(ex, catch_backtrace())
        end
    finally
        @debug "Finishing variable '$(name)'"

        # Close upstream and downstream channels
        for arg in values(upstream)
            if arg isa RemoteChannel
                close(arg)
            end
        end

        for channel in values(downstream)
            close(channel)
        end
    end
end

# Simple function that will asynchronously watch the DAG and close the
# `stream_output` if all variables are finished.
function watch_context(ctx::XfaContext)
    while true
        if all(istaskdone.(values(ctx.variable_tasks)))
            close(ctx.stream_output)
            return
        end

        sleep(0.1)
    end
end

"""
    declare_sources(input_name, new_sources)

Notify the system of a new list of sources that can be read from `input`.
An Input should call this function whenever its sources changes.
"""
function declare_sources(input_name, new_sources)
    current_ctx.available_sources[input_name] = new_sources

    pause_pipeline() do
    end
end

function update_input_sources(ctx::XfaContext)
    deps = external_dependencies(ctx)
    sources = [occursin(':', dep.source) ? dep.source : string(dep) for dep in deps]
    group_dependency = only(values(only(values(ctx.inputs))))
    for (group_name, group) in ctx.groups
        if group isa group_dependency.type
            update_sources(group, sources)
        end
    end
end

function pause_pipeline(f::Function)
    foreach(lock, values(worker_state.task_locks))

    try
        f()
    finally
        foreach(unlock, values(worker_state.task_locks))
    end
end

function start_pipeline(ctx::XfaContext; input_buffer_size::Int=50)
    ctx.stream_output = RemoteChannel(() -> Channel(100))
    ctx.events_channel = RemoteChannel(() -> Channel(100))
    ctx.output_forwarder_task = Threads.@spawn ctx.forwarder(ctx.stream_output)
    errormonitor(ctx.output_forwarder_task)

    global current_ctx = ctx

    # Start the input functions to feed the DAG
    for (name, deps) in ctx.inputs
        group = nothing
        if !isempty(deps)
            first_arg = first(keys(deps))
            if deps[first_arg] isa GroupDependency
                group = ctx.groups[deps[first_arg].name]
            else
                error("Couldn't schedule input '$(name)', it has a non-group dependency: $(deps[1])")
            end
        end

        ctx.input_channels[name] = Channel(1)
        ctx.input_tasks[name] = Threads.@spawn input_wrapper(name, group, ctx.input_channels[name])
        errormonitor(ctx.input_tasks[name])
    end

    # Start the input variables
    for name in keys(ctx.inputs)
        downstream_neighbours = Dict{String, RemoteChannel}()
        for dep in external_dependencies(ctx)
            downstream_neighbours[string(dep)] = RemoteChannel()
        end
        ctx.input_variable_channels[name] = downstream_neighbours

        ctx.input_variables_tasks[name] = Threads.@spawn stream_input(name, ctx.input_channels[name], downstream_neighbours)
        errormonitor(ctx.input_variables_tasks[name])
    end

    # Start the external dependency variables
    unique_external_deps = external_dependencies(ctx)
    for dep in unique_external_deps
        dep_name = string(dep)
        input_name = only(keys(ctx.inputs))
        input_channel = ctx.input_variable_channels[input_name][dep_name]
        input_neighbour = Neighbour(input_name, input_channel)

        downstream_neighbours = Dict{String, RemoteChannel}()
        for neighbour in find_downstream_neighbours(ctx, dep_name, KaraboDependency)
            downstream_neighbours[neighbour] = RemoteChannel()
        end
        ctx.external_dependency_channels[dep_name] = downstream_neighbours

        ctx.external_dependency_tasks[dep_name] = Threads.@spawn stream_external_dependency(dep_name, input_neighbour, downstream_neighbours)
        errormonitor(ctx.external_dependency_tasks[dep_name])
    end

    # Update the inputs
    update_input_sources(ctx)

    # Start the variables themselves
    execution_order = topological_sort(ctx)
    for name in execution_order
        # Build up the upstream channel list, deduplicating channels for
        # SubvariableDependency's that share their parent's channel.
        args = OrderedDict{String, Any}()
        for dep in values(ctx.dag[name])
            dep_name = string(dep)

            if dep isa KaraboDependency
                args[dep_name] = ctx.external_dependency_channels[dep_name][name]
            elseif dep isa SubvariableDependency
                if !haskey(args, dep.parent)
                    args[dep.parent] = ctx.variable_channels[dep.parent][name]
                end
            elseif dep isa Dependency
                args[dep_name] = ctx.variable_channels[dep_name][name]
            elseif dep isa GroupDependency
                args[dep.name] = ctx.groups[dep.name]
            else
                throw(XfaContextException("Unrecognized dependency type: $(typeof(dep))"))
            end
        end

        # Find downstream variables, including those that depend on our
        # subvariables.
        downstream = Dict{String, RemoteChannel}()
        for neighbour in find_downstream_neighbours(ctx, name, Dependency)
            downstream[neighbour] = RemoteChannel()
        end
        for neighbour in find_downstream_neighbours(ctx, name, SubvariableDependency)
            if !haskey(downstream, neighbour)
                downstream[neighbour] = RemoteChannel()
            end
        end
        ctx.variable_channels[name] = downstream

        ctx.variable_tasks[name] = Threads.@spawn stream_variable(name, ctx.stream_output, args, downstream, ctx.dag[name])
        errormonitor(ctx.variable_tasks[name])
    end

    # Start the watcher task
    ctx.watcher_task = Threads.@spawn watch_context(ctx)
    errormonitor(ctx.watcher_task)

    ctx.is_running[] = true

    return nothing
end

function stop_pipeline(ctx::XfaContext; timeout=5)
    ctx.is_running[] = false

    for ch in values(ctx.input_channels)
        close(ch)
    end

    # Close the input tasks
    for task in values(ctx.input_tasks)
        wait(task)
    end

    # Close the streaming input tasks
    for outputs in values(ctx.input_variable_channels)
        for channel in values(outputs)
            close(channel)
        end
    end
    for task in values(ctx.input_variables_tasks)
        wait(task)
    end

    # Close the external dependency tasks
    for outputs in values(ctx.external_dependency_channels)
        for channel in values(outputs)
            close(channel)
        end
    end
    for task in values(ctx.external_dependency_tasks)
        wait(task)
    end

    # Close the variables tasks
    for outputs in values(ctx.variable_channels)
        for channel in values(outputs)
            close(channel)
        end
    end
    for task in values(ctx.variable_tasks)
        wait(task)
    end

    wait(ctx.watcher_task)
    if !isnothing(ctx.output_forwarder_task)
        wait(ctx.output_forwarder_task)
    end

    global current_ctx = nothing

    @debug "Pipeline fully stopped"

    return nothing
end

function run(f::Function, ctx::XfaContext; timeout=10, kwargs...)
    start_pipeline(ctx; kwargs...)

    task = nothing
    timer = Timer(timeout) do _
        @warn "Function timed out, killing it"
        Threads.@spawn Base.throwto(task, InterruptException())
    end

    parent_testset = get(task_local_storage(), :__BASETESTNEXT__, [])
    try
        task = Threads.@spawn begin
            # Set the parent testset so that all @test's get recorded properly
            task_local_storage(:__BASETESTNEXT__, parent_testset)
            f()
        end

        wait(task)
    finally
        close(timer)
        stop_pipeline(ctx)
    end
end

function _is_context_method(m::Method)
    # Check if the method's type parameter belongs to an XfaContext module.
    # For variable/input traits: signature is Tuple{typeof(f), typeof(func)}
    #   where parentmodule(func) is the context module
    # For group traits: signature is Tuple{typeof(f), Type{T}}
    #   where parentmodule(T) is the context module
    length(m.sig.parameters) >= 2 || return false
    T = m.sig.parameters[2]

    owner = if T <: Type
        T.parameters[1]  # extract T from Type{T}
    elseif isdefined(T, :instance)
        T.instance        # extract func from typeof(func)
    else
        return false      # not a concrete singleton (e.g. the default method)
    end

    mod_names = string.(fullname(parentmodule(owner)))
    return any(startswith.(mod_names, "XfaContext"))
end

function _cleanup_context_methods()
    for f in (variable_dependencies, variable_subvariables, input_dependencies, group_fields)
        for m in methods(f)
            if _is_context_method(m)
                Base.delete_method(m)
            end
        end
    end
end

function load_from_string(ctx_str::AbstractString)
    _cleanup_context_methods()

    ctx_module = Module(Symbol(:XfaContext, gensym()))
    init_expr = quote
        using XfaEngine.Context
        import XfaEngine.Context: Parameter, KaraboBridge, Meta

        # _xfa_parameters = Parameter[]
    end
    @eval ctx_module $init_expr

    exprs = Expr[]

    # Parse everything
    expr, pos = Base.Meta.parse(ctx_str, 1)
    while expr != nothing
        push!(exprs, expr)
        expr, pos = Base.Meta.parse(ctx_str, pos)
    end

    # Evaluate all exprs
    for expr in exprs
        @eval ctx_module $expr
    end

    @invokelatest load_from_module(ctx_module, exprs)
end

function load_from_module(ctx_module::Module, exprs::Vector{Expr})
    parameters = Dict{String, Parameter}()

    # Discover all variables, inputs, group types, and parameters defined
    # in ctx_module by scanning its names and checking for trait methods.
    ctx_variables = Dict{Function, Vector{Any}}()
    ctx_inputs = Dict{Function, Vector{Any}}()
    group_types = Dict{DataType, Group}()

    # Scan ctx_module for variables and parameters
    for name in names(ctx_module; all=true)
        isdefined(ctx_module, name) || continue
        obj = getfield(ctx_module, name)

        if obj isa Parameter
            obj.name = string(name)
            parameters[string(name)] = obj
        elseif obj isa Function && parentmodule(obj) === ctx_module &&
               hasmethod(variable_dependencies, Tuple{typeof(obj)})
            ctx_variables[obj] = variable_dependencies(obj)
        end
    end

    # Collect origin functions that are already represented by context
    # variable references, so we don't add them again as separate variables.
    ctx_origins = Set(variable_origin(f) for f in keys(ctx_variables) if variable_origin(f) !== f)

    # Discover all registered variables, inputs, and group types from trait
    # methods. This includes builtins and variables from included modules.
    all_variables = copy(ctx_variables)
    for m in methods(variable_dependencies)
        F = m.sig.parameters[2]
        isdefined(F, :instance) || continue
        func = F.instance
        if !haskey(all_variables, func) && func ∉ ctx_origins
            all_variables[func] = variable_dependencies(func)
        end
    end

    for m in methods(group_fields)
        T = m.sig.parameters[2].parameters[1]
        group_types[T] = Group(T, Function[])
    end

    for m in methods(input_dependencies)
        F = m.sig.parameters[2]
        func = F.instance
        ctx_inputs[func] = input_dependencies(func)
    end

    # Associate variables with their group types
    for (group_struct, group) in group_types
        for (func, deps) in merge(all_variables, ctx_inputs)
            if !isempty(deps) && deps[1][2] isa GroupDependency && deps[1][2].type == group_struct
                push!(group.variables, func)
            end
        end
    end

    # Check if there are any parameters with the same name as a variable
    ctx_variable_names = string.(nameof.(keys(ctx_variables)))
    common_var_param_names = intersect(ctx_variable_names,
                                       keys(parameters))
    if !isempty(common_var_param_names)
        names_str = join(common_var_param_names, ", ")
        throw(XfaContextException("@Variable's and @Parameter's exist with the same name: $(names_str)"))
    end

    # Look up all the functions that will be called
    functions = Dict{String, Any}()
    for func in keys(ctx_variables)
        functions[string(nameof(func))] = func
    end

    # Check for duplicate variable/input names
    ctx_variable_names = Set(nameof.(keys(ctx_variables)))
    ctx_input_names = Set(nameof.(keys(ctx_inputs)))
    if !isdisjoint(ctx_variable_names, ctx_input_names)
        throw(XfaContextException("Found Variable's and Input's with duplicate names"))
    end

    # Create the DAG (it's just an adjaceny list)
    dag = Dict{String, OrderedDict}()
    for (func, deps) in merge(ctx_variables, ctx_inputs)
        name = nameof(func)

        # If it's a group dependency, we don't schedule it yet. That's done at
        # the end only for the instantiated group structs.
        if length(deps) > 0 && deps[1][2] isa GroupDependency
            continue
        end

        # Don't add inputs to the DAG, only variables
        if name in ctx_variable_names
            dag[string(name)] = _get_deps(func, parameters)
        end
    end

    # At this point we've added all the non-grouped variables to the DAG and we
    # know which variables belong to which group, so we can schedule all the
    # instantiated groups.
    groups = Dict{String, Any}()
    inputs = Dict{String, Any}()

    # Look at all the top-level names and check if they're groups
    for (group_name, group_type, object) in _get_group_objects(ctx_module, group_types)
        groups[group_name] = object

        # If so, then add all their variables to the DAG
        for variable_func in group_types[group_type].variables
            # If it's an input, handle it later
            if haskey(ctx_inputs, variable_func)
                continue
            end

            dag_deps = _get_deps(variable_func, parameters)

            # Replace the GroupDependency that originally contained the group
            # type name, with a GroupDependency that names the instatiated
            # group.
            argument_names = collect(keys(dag_deps))
            arg_idx = findfirst(key -> dag_deps[key] == GroupDependency(group_type),
                                argument_names)
            dag_deps[argument_names[arg_idx]] = GroupDependency(group_name, group_type)

            func_name = string(nameof(variable_func))
            group_var_name = "$group_name.$func_name"
            dag[group_var_name] = dag_deps
            functions[group_var_name] = variable_func

            # Dependencies of the form `foo.bar` are saved as
            # SubvariableDependency's. But these may also refer to groups, so
            # now we go through all the dependencies for all variables and check
            # if any are actually group variables instead of subvariables.
            for var_deps in values(dag)
                for i in eachindex(var_deps)
                    if var_deps[i] == SubvariableDependency(group_name, func_name)
                        var_deps[i] = Dependency(group_var_name)
                    end
                end
            end
        end

        # And add all the parameters too
        # for (param_sym, param_type) in group_types[group_type].parameters
        #     param_name = "$group_name.$param_sym"
        #     parameters[param_name] = Parameter(param_name, getproperty(object, param_sym))
        # end
        for field in fieldnames(group_type)
            if fieldtype(group_type, field) <: Parameter
                param = getproperty(object, field)
                param.name = "$(group_name).$(field)"
                parameters[param.name] = param
            end
        end

        # And all the inputs
        for (input_func, deps) in ctx_inputs
            input_name = string(nameof(input_func))

            if length(deps) == 1
                input_group_type = deps[1][2].type
                if input_group_type === group_type
                    group_input_name = "$group_name.$input_name"
                    new_deps = OrderedDict(deps)
                    # Similarly to variables, we replace the GroupDependency
                    # that contained the group type name with one that contains
                    # the instantiated name.
                    new_deps[first(keys(new_deps))] = GroupDependency(group_name, group_type)
                    inputs[group_input_name] = new_deps
                    functions[group_input_name] = input_func
                end
            end
        end
    end

    for (func, deps) in ctx_inputs
        if isempty(deps) || !(deps[1][2] isa GroupDependency)
            name = string(nameof(func))
            throw(XfaContextException("'$(name)' must belong to a Group to be a valid Input"))
        end
    end

    # Check that it has no cycles by attempting to sort it
    topological_sort(dag)

    ctx_subvariables = Dict{String, Vector{String}}()
    for func in keys(ctx_variables)
        ctx_subvariables[string(nameof(func))] = variable_subvariables(func)
    end

    global worker_state = WorkerState(; dag_functions=functions, current_ctx_module=ctx_module, parameters)
    for name in keys(worker_state.dag_functions)
        worker_state.task_locks[name] = ReentrantLock()
    end

    return XfaContext(; functions, group_types, groups, dag,
                      subvariables=ctx_subvariables, parameters, exprs,
                      inputs)
end

function load_from_file(ctx_path::AbstractString)
    if !isfile(ctx_path)
        throw(ArgumentError("$(ctx_path) is not a file!"))
    end

    ctx = load_from_string(read(ctx_path, String))
    ctx.path = ctx_path
    return ctx
end

function _get_group_objects(ctx_module, group_types)
    group_objects = Tuple{String, DataType, Any}[]

    for name in names(ctx_module; all=true)
        object = getproperty(ctx_module, name)
        group_type = findfirst(g -> object isa g.type, group_types)
        if group_type != nothing
            push!(group_objects, (string(name), group_type, object))
        end
    end

    return group_objects
end

function _get_deps(func, parameters)
    final_deps = OrderedDict()

    for (arg_name, dep) in variable_dependencies(func)
        if !(dep isa AbstractDependency)
            throw(ArgumentError("Dependency of type '$(typeof(dep))' is not allowed"))
        end

        if dep isa Dependency && haskey(parameters, dep.name)
            dep = parameters[dep.name]
        end

        final_deps[arg_name] = dep
    end

    return final_deps
end

# Some methods to allow push!'ing to a DimArray
function Base.push!(data::DD.AbstractDimVector, x, lookup_values=nothing)
    push!(DD.parent(data), x)
    for (name, value) in pairs(lookup_values)
        push!(parent(DD.lookup(data, name)), value)
    end

    return DD.rebuild(data)
end

function Base.empty!(data::DD.DimVector)
    empty!(parent(data))
    empty!(parent(DD.lookup(data, DD.dims(data)[1])))

    return DD.rebuild(data)
end

end
