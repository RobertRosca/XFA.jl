module Context

export @karabo_str, @Variable, @Parameter, @Input, @Group

import DistributedNext: RemoteChannel

import Dagger
import Dagger: DTask
import MacroTools
import MacroTools: @capture, postwalk, prettify
import OrderedCollections: OrderedDict


const registered_variables = Dict{Function, Vector{Any}}()
const registered_subvariables = Dict{Function, Vector{String}}()
const registered_inputs = Dict{Function, Any}()
const registered_groups = Dict{DataType, Any}()

include("context_types.jl")
include("context_builtins.jl")

@kwdef mutable struct XfaContext
    functions::Dict{String, Any}
    group_types::Dict{DataType, Group}
    groups::Dict{String, Any}
    dag::Dict{String, OrderedDict}
    subvariables::Dict{String, Vector{String}}
    parameters::Dict{String, Parameter}
    exprs::Vector{Expr}

    inputs::Dict{String, Any}
    input_channels::Dict{String, RemoteChannel} = Dict()
    input_dtasks::Dict{String, DTask} = Dict()
    input_variables_dtasks::Dict{String, DTask} = Dict()

    external_dependency_dtasks::Dict{String, DTask} = Dict()

    variable_dtasks::Dict{String, DTask} = Dict()
    variable_output::RemoteChannel = RemoteChannel(() -> Channel(100))
end

function Base.show(io::IO, ctx::XfaContext)
    n_variables = length(ctx.functions)
    n_params = length(ctx.parameters)
    print(io, "XfaContext($(n_variables) variables, $(n_params) parameters)")
end

"""
Finds all external dependencies (i.e. from Karabo) required by the context.
"""
function external_dependencies(ctx::XfaContext)
    ext_deps = Dict{String, KaraboDependency}()
    for (name, deps) in ctx.dag
        for (_, dep) in deps
            if dep isa KaraboDependency
                ext_deps[name] = dep
            end
        end
    end

    return ext_deps
end

function to_dict(ctx::XfaContext)
    return Dict("dag" => ctx.dag,
                "subvariables" => ctx.subvariables,
                "parameters" => ctx.parameters)
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
                results[name] = ctx.functions[name](args...)
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

struct VariableData{T}
    tid::UInt64
    name::String
    data::T
end

VariableData(tid, name, data) = VariableData(UInt64(tid), name, data)

function input_wrapper(ctx::XfaContext, name)
    f = ctx.functions[name]
    channel = ctx.input_channels[name]

    try
        f(channel)
    catch ex
        if !(ex isa InvalidStateException)
            @error "Caught exception while executing input '$(name)'" exception=(ex, catch_backtrace())
        end

        rethrow()
    finally
        close(channel)
    end
end

function _maybe_send_output(ctx::XfaContext, data::TrainData)
    # Semi-arbitrarily set a threshold of 30MB, which is just under twice the
    # size of a Float32 2k camera.
    threshold = 30_000_000

    if Base.summarysize(data) < threshold
        put!(ctx.variable_output, data)
    else
        put!(ctx.variable_output, TrainData(data.tid, :threshold_exceeded))
    end
end

function _execute_input(ctx::XfaContext, name)
    try
        tid, sources = take!(ctx.input_channels[name])
        return TrainData(tid, sources)
    catch ex
        if !(ex isa InvalidStateException)
            @error "Couldn't get input data from '$(name)'" exception=(ex, catch_backtrace())
        end

        return Dagger.finish_stream()
    end
end

function _execute_external_dependency(ctx::XfaContext, name, input)
    if haskey(input.data, name)
        td = TrainData(input.tid, input.data[name])
        return td
    else
        return nothing
    end
end

function _execute_variable(ctx::XfaContext, name, args...)
    if any(isnothing.(args))
        return nothing
    end

    unwrapped_args = [arg.data for arg in args]
    tid = first(args).tid

    try
        out = ctx.functions[name](unwrapped_args...)
        out = VariableData(tid, name, out)
        put!(ctx.variable_output, out)
        return out
    catch ex
        @error "Execution of variable '$(name)' failed" exception=(ex, catch_backtrace())
    end
end

function start_pipeline(ctx::XfaContext; input_buffer_size::Int=50)
    # Start the input functions to feed the DAG
    for name in keys(ctx.inputs)
        ctx.input_channels[name] = RemoteChannel()
        ctx.input_dtasks[name] = Dagger.@spawn input_wrapper(ctx, name)
    end

    Dagger.spawn_streaming() do
        # Start the input variables
        for name in keys(ctx.inputs)
            ctx.input_variables_dtasks[name] = Dagger.@spawn _execute_input(ctx, name)
        end

        # Start the external dependency variables
        input_variable = only(values(ctx.input_variables_dtasks))
        for (_, dep) in external_dependencies(ctx)
            name = string(dep)
            ctx.external_dependency_dtasks[name] = Dagger.spawn(_execute_external_dependency, ctx, name, input_variable)
        end

        # Start the variables themselves
        execution_order = topological_sort(ctx)
        for name in execution_order
            # Build up the argument list
            args = []
            for dep in values(ctx.dag[name])
                dep_key = string(dep)

                if dep isa KaraboDependency
                    push!(args, ctx.external_dependency_dtasks[dep_key])
                elseif dep isa Dependency
                    push!(args, ctx.variable_dtasks[dep_key])
                elseif dep isa Parameter
                    push!(args, ctx.parameters[dep_key].value)
                elseif dep isa GroupDependency
                    push!(args, ctx.groups[dep.struct_name])
                else
                    throw(XfaContextException("Unrecognized dependency type: $(typeof(dep))"))
                end
            end

            ctx.variable_dtasks[name] = Dagger.spawn(_execute_variable, ctx, name, args...)
        end
    end
end

function stop_pipeline(ctx::XfaContext; timeout=5)
    for ch in values(ctx.input_channels)
        close(ch)
    end

    # Close the input dtasks
    timer = Timer(timeout) do _
        @warn "Cancelling input dtasks"
        foreach(Dagger.cancel!, values(ctx.input_dtasks))
    end
    for dtask in values(ctx.input_dtasks)
        wait(dtask)
    end
    close(timer)

    # Close the streaming input dtasks
    timer = Timer(timeout) do _
        @warn "Cancelling streaming input dtasks"
        foreach(Dagger.cancel!, values(ctx.input_variables_dtasks))
    end
    for dtask in values(ctx.input_variables_dtasks)
        wait(dtask)
    end
    close(timer)

    # Close the variables dtasks
    timer = Timer(timeout) do _
        @warn "Cancelling variables dtasks"
        foreach(Dagger.cancel!, values(ctx.variable_dtasks))
    end
    for dtask in values(ctx.variable_dtasks)
        wait(dtask)
    end
    close(timer)

    close(ctx.variable_output)
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

function load_from_string(ctx_str::AbstractString)
    # Clean up all the registered things from previous evaluations of the
    # context file. This isn't strictly necessary but it makes debugging
    # simpler.
    for item_cache in (registered_variables, registered_subvariables, registered_inputs, registered_groups)
        for key in keys(item_cache)
            parent_modules = string.(fullname(parentmodule(key)))
            if any(startswith.(parent_modules, "XfaContext"))
                pop!(item_cache, key)
            end
        end
    end

    ctx_module = Module(Symbol(:XfaContext, gensym()))
    init_expr = quote
        using XfaEngine.Context
        import XfaEngine.Context: Parameter, KaraboBridge

        _xfa_parameters = Parameter[]
    end
    @eval ctx_module $init_expr

    exprs = Expr[]

    # Parse everything
    expr, pos = Meta.parse(ctx_str, 1)
    while expr != nothing
        push!(exprs, expr)
        expr, pos = Meta.parse(ctx_str, pos)
    end

    # Evaluate all exprs
    for expr in exprs
        @eval ctx_module $expr
    end

    # Check if we have any duplicate parameters
    if !allunique([param.name for param in ctx_module._xfa_parameters])
        throw(XfaContextException("Duplicate @Parameter's exist"))
    end

    # Load the group types
    group_types = Dict{DataType, Group}()
    for (group_struct, param_fields) in registered_groups
        parameters = Dict([field => fieldtype(group_struct, field) for field in param_fields])
        group_types[group_struct] = Group(group_struct, parameters, Function[])

        for (func, deps) in registered_variables
            if isempty(deps)
                continue
            end

            first_arg_type = deps[1][2]
            if first_arg_type isa GroupDependency && first_arg_type.type == group_struct
                push!(group_types[group_struct].variables, func)
            end
        end
    end

    parameters = Dict([param.name => param for param in ctx_module._xfa_parameters])

    # Check if there are any parameters with the same name as a variable
    ctx_variables = filter(pair -> parentmodule(pair.first) === ctx_module, registered_variables)
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

    # Find all the inputs defined in the context file itself
    ctx_inputs = filter(pair -> parentmodule(pair.first) == ctx_module, registered_inputs)

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
        # value = getproperty(ctx_module, group_name)
        # group_type_name = findfirst(g -> value isa g.type, group_types)
        # if group_type_name == nothing
        #     continue
        # end

        groups[group_name] = object

        # If so, then add all their variables to the DAG
        for variable_func in group_types[group_type].variables
            # If it's an input, handle it later
            if haskey(registered_inputs, variable_func)
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
        for (param_sym, param_type) in group_types[group_type].parameters
            param_name = "$group_name.$param_sym"
            parameters[param_name] = Parameter(param_name, getproperty(object, param_sym))
        end

        # And all the inputs
        for (input_func, deps) in registered_inputs
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

    # Now we do the same for the inputs: go through all of the declared ones and
    # add them to the context if they're not part of a group. All the grouped
    # inputs should already have been added.
    for (func, deps) in ctx_inputs
        if isempty(deps) || length(deps) == 1
            name = string(nameof(func))
            inputs[name] = Dict(deps)
            functions[name] = func
        end
    end

    # Check that it has no cycles by attempting to sort it
    topological_sort(dag)

    ctx_subvariables = Dict{String, Vector{String}}()
    for (func, subvars) in registered_subvariables
        if parentmodule(func) !== ctx_module
            continue
        end

        ctx_subvariables[string(nameof(func))] = subvars
    end

    return XfaContext(; functions, group_types, groups, dag,
                      subvariables=ctx_subvariables, parameters, exprs,
                      inputs)
end

function load_from_file(ctx_path::AbstractString)
    if !isfile(ctx_path)
        throw(ArgumentError("$(ctx_path) is not a file!"))
    end

    return load_from_string(read(ctx_path, String))
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

    for (arg_name, dep) in registered_variables[func]
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

end
