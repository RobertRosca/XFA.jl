module Context

export @karabo_str, @Variable, @Parameter, @Input, @Group

import MacroTools
import MacroTools: @capture, postwalk, prettify
import OrderedCollections: OrderedDict


struct XfaContextException <: Exception
    msg::String
end

struct XfaExecutionException <: Exception
    msg::String
end

abstract type AbstractDependency end

struct Dependency <: AbstractDependency
    name::String
end

Base.string(dep::Dependency) = dep.name

struct SubvariableDependency <: AbstractDependency
    parent::String
    name::String
end

Base.string(dep::SubvariableDependency) = "$(dep.parent).$(dep.name)"

struct GroupDependency <: AbstractDependency
    struct_name::String
end

struct KaraboDependency <: AbstractDependency
    source::String
    property::String
end

struct FunctionArgument
    name::String
    type::Union{Nothing, Type}
end

function KaraboDependency(str::AbstractString)
    slow_data_re = r"^(\S+?)\.([\w|\.]+)$"
    fast_data_re = r"^(\S+):(\S+)\[(\S+)\]$"

    m = match(slow_data_re, str)
    if m != nothing
        return KaraboDependency(m.captures[1], m.captures[2])
    end

    m = match(fast_data_re, str)
    if m != nothing
        return KaraboDependency("$(m.captures[1]):$(m.captures[2])", m.captures[3])
    end

    throw(ArgumentError("'$(str)' is not a valid Karabo device property"))
end

function Base.string(kp::KaraboDependency)
    if occursin(':', kp.source)
        return "$(kp.source)[$(kp.property)]"
    else
        return "$(kp.source).$(kp.property)"
    end
end

"""
@karabo_str macro for creating Karabo device dependencies.

Example usage:
    karabo"MID_EXP_UPP/MOTOR/T5.actualPosition"
    karabo"SA2_XTD1_XGM/XGM/DOOCS:output[data.intensityTD]"
"""
macro karabo_str(str)
    Expr(:call, :KaraboDependency, esc(Meta.parse("\"$(escape_string(str))\"")))
end


"""
Helper function to parse the arguments of a function.
"""
function _parse_function_args(args; is_input=false)
    dependencies = []
    new_args = [postwalk(arg) do arg_expr
                    if @capture(arg_expr, arg_name_ -> value_)
                        # Strip quote nodes etc
                        value = MacroTools.unblock(value)

                        if @capture(value, head_.tail_)
                            # If it's of the form `head.tail`, that's a
                            # subvariable and we convert it to a string so it's
                            # not evaluated.
                            value = :(Context.SubvariableDependency($("$head"), $("$tail")))
                        elseif !(value isa AbstractDependency || @capture(value, @karabo_str _))
                            # Otherwise, we convert all non-Karabo
                            # dependencies (i.e. variable and maybe future
                            # parameter dependencies) into Dependency's.
                            value = :(Context.Dependency($("$value")))
                        end
                        push!(dependencies, :(($("$arg_name"), $value)))

                        # Replace the original argument expression with just
                        # the argument name.
                        return arg_name

                    elseif @capture(arg_expr, (::T_) | (arg_name_::T_))
                        arg_name_expr = isnothing(arg_name) ? :(nothing) : :($("$arg_name"))

                        if !is_input || (is_input && i == 1 && length(args) == 2)
                            # If the first argument has a type and no explicit
                            # dependency, then we assume it belongs to a group.
                            push!(dependencies, :(($arg_name_expr, Context.GroupDependency($("$T")))))
                        else
                            # Otherwise it's just a regular function argument
                            push!(dependencies, :(($arg_name_expr, Context.FunctionArgument($arg_name_expr, $T))))
                        end

                        return arg_expr
                    else
                        return arg_expr
                    end
                end
                for (i, arg) in enumerate(args)]

    return dependencies, new_args
end

function _variable(ctx_module, expr, side_effects)
    if !(expr isa Expr)
        throw(ArgumentError("Must pass an Expr to @Variable"))
    end

    # Handle declarations of the form `@Variable name -> karabo"..."`
    if @capture(expr, name_ -> value_)
        # Strip quote nodes etc
        value = MacroTools.unblock(value)

        # For this shorthand-form we only allow proper dependencies, not
        # arbitrary expressions.
        if value isa KaraboDependency || (value isa Expr && @capture(value, @karabo_str _))
            function_expr = quote
                function $name(data -> $value)
                    return data
                end
            end

            # Recurse with the generated function
            return _variable(ctx_module, function_expr, side_effects)
        else
            throw(ArgumentError("Unrecognized dependency: $(value)"))
        end

    elseif @capture(expr, function func_name_(args__) body_ end)
        # And now we handle explicit function declarations

        # Extract dependency information
        dependencies, new_args = _parse_function_args(args)

        # Look through the body for subvariables, and replace all the toplevel
        # ones.
        subvariables = String[]
        new_body = []
        for body_expr in body.args
            if @capture(body_expr, subvar_name_ = @Variable subvar_expr_)
                push!(subvariables, "$(func_name).$(subvar_name)")
                body_expr = :($subvar_name = $subvar_expr)
            end

            push!(new_body, body_expr)
        end
        new_body = Expr(:block, new_body...)

        # Once all the toplevel subvariables have been replaced, recurse
        # through all the expressions and throw an error if we find a
        # non-toplevel subvariable.
        postwalk(new_body) do body_expr
            if @capture(body_expr, subvar_name_ = @Variable _)
                throw(ArgumentError("Subvariable '$(func_name).$(subvar_name)' must be defined at the toplevel of the function"))
            end

            body_expr
        end

        # Combine all the dependency expressions into a vector expr, which will
        # get interpolated/evaluated properly.
        dependencies_expr = Expr(:vect, dependencies...)
        subvariables_expr = Expr(:vect, subvariables...)
        new_function = quote
            if $side_effects
                _xfa_variables[$("$func_name")] = $dependencies_expr
                _xfa_subvariables[$("$func_name")] = $subvariables_expr
            end

            function $func_name($(new_args...))
                $new_body
            end
        end

        return esc(new_function)
    end

    throw(ArgumentError("Could not construct variable from expression: $(prettify(expr))"))
end

"""
Mark functions for execution in XFA.
"""
macro Variable(expr)
    side_effects = :_xfa_generated_module in names(__module__; all=true)
    _variable(__module__, expr, side_effects)
end


mutable struct Parameter{T}
    const name::String
    value::T
end

Base.:(==)(one::Parameter{T}, two::Parameter{T}) where T = one.name == two.name && one.value == two.value
Base.string(param::Parameter{T}) where T = param.name

function _parameter(ctx_module, expr, side_effects)
    if !(expr isa Expr)
        throw(ArgumentError("Must pass an Expr to @Parameter"))
    end

    if @capture(expr, name_::T_ -> value_)
        body = quote
            if $side_effects
                push!(_xfa_parameters, Context.Parameter($("$name"), $value::$T))
            end
        end
        return esc(body)
    end

    throw(ArgumentError("Could not construct parameter from expression: $(prettify(expr))"))
end

"""
Mark things as parameters.
"""
macro Parameter(expr)
    side_effects = :_xfa_generated_module in names(__module__; all=true)
    _parameter(__module__, expr, side_effects)
end


function _input(ctx_module, expr, side_effects)
    if !(expr isa Expr)
        throw(ArgumentError("Must pass an Expr to @Input"))
    end

    if @capture(expr, function name_(args__) body_ end)
        dependencies, new_args = _parse_function_args(args; is_input=true)
        if length(dependencies) == 2
            if !@capture(dependencies[1], (_, Context.GroupDependency(_)))
                throw(XfaContextException("The first argument of a two-argument @Input must be a @Group"))
            end
        elseif length(dependencies) != 1
            throw(XfaContextException("@Input functions must accept 1-2 arguments, '$(name)' has $(length(args)) arguments"))
        end

        dependencies_expr = Expr(:vect, dependencies...)
        new_expr = quote
            function $name($(args...))
                $body
            end

            if $side_effects
                _xfa_inputs[$("$name")] = $dependencies_expr
            end
        end

        return esc(new_expr)
    end

    throw(ArgumentError("Could not construct an input from expression: $(prettify(expr))"))
end

"""
Mark a function as an input (i.e a trigger).
"""
macro Input(expr)
    side_effects = :_xfa_generated_module in names(__module__; all=true)
    _input(__module__, expr, side_effects)
end


struct Group
    name::String
    type::DataType
    parameters::Dict{Symbol, DataType}
    variables::Vector{String}
end

function Base.:(==)(x::Group, y::Group)
    x.name == y.name && x.parameters == y.parameters && x.variables == y.variables
end

function _group(ctx_module, expr, side_effects)
    if !(expr isa Expr)
        throw(ArgumentError("Must pass an Expr to @Group"))
    end

    if @capture(expr, struct name_ fields__ end)
        # Look through the fields for parameters
        param_fields = []
        new_fields = [if @capture(field, @Parameter field_name_::T_)
                          push!(param_fields, field_name)
                          :($field_name::$T)
                      else
                          field
                      end
                      for field in fields]

        new_expr = quote
            if $side_effects
                _xfa_groups[$("$name")] = $param_fields
            end

            struct $name
                $(new_fields...)
            end
        end

        return esc(new_expr)
    end

    throw(ArgumentError("Could not construct a group from expression: $(prettify(expr))"))
end

"""
Mark a struct as a group of @Variable's.
"""
macro Group(expr)
    side_effects = :_xfa_generated_module in names(__module__; all=true)
    _group(__module__, expr, side_effects)
end


@kwdef mutable struct XfaContext10
    functions::Dict{String, Any}
    group_types::Dict{String, Group}
    groups::Dict{String, Any}
    dag::Dict{String, OrderedDict}
    subvariables::Dict{String, Vector{String}}
    parameters::Dict{String, Parameter}
    exprs::Vector{Expr}

    inputs::Dict{String, Any}
    ext_inputs_channel::Union{Channel, Nothing} = nothing
    inputs_tasks::Dict{String, Task} = Dict()
    exec_task::Union{Task, Nothing} = nothing
    variable_outputs_channel::Union{Channel, Nothing} = nothing
end

XfaContext = XfaContext10

function Base.show(io::IO, ctx::XfaContext)
    n_variables = length(ctx.functions)
    n_params = length(ctx.parameters)
    print(io, "XfaContext($(n_variables) variables, $(n_params) parameters)")
end

"""
Finds all external dependencies (i.e. from Karabo) required by the context.
"""
function external_dependencies(ctx::XfaContext)
    ext_deps = Set{KaraboDependency}()
    for (_, deps) in ctx.dag
        for dep in values(deps)
            if dep isa KaraboDependency
                push!(ext_deps, dep)
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

function _execute_input(ctx::XfaContext, input_name)
    deps = ctx.inputs[input_name]
    args = []
    if length(deps) == 2
        push!(args, ctx.groups[deps[1].struct_name])
    end
    push!(args, ctx.ext_inputs_channel)

    try
        ctx.functions[input_name](args...)
    catch ex
        @error "Error executing input $(input_name)!" exception=ex
    end
end

function _execute_pipeline(ctx::XfaContext)
    train_inputs = OrderedDict{Int, Any}()
    wake_condition = Threads.Condition()

    reader_task = Threads.@spawn begin
        for (train_id, data) in ctx.ext_inputs_channel
            train_inputs[train_id] = merge(get(train_inputs, train_id, Dict()), data)
            @lock wake_condition notify(wake_condition)
        end

        empty!(train_inputs)
        @lock wake_condition notify(wake_condition)
    end

    while !istaskdone(reader_task)
        @lock wake_condition wait(wake_condition)

        # If there are no inputs, that's the sign that a stop has been requested
        if isempty(train_inputs)
            break
        end

        execute_variables(ctx, popfirst!(train_inputs))
    end
end

function start_pipeline(ctx::XfaContext; input_buffer_size::Int=50)
    required_inputs = external_dependencies(ctx)

    # Clear any state from previous executions
    if !isnothing(ctx.ext_inputs_channel) && isopen(ctx.ext_inputs_channel)
        throw(XfaExecutionException("Context is still being executed, cannot start it twice"))
    end
    ctx.ext_inputs_channel = Channel(input_buffer_size)

    empty!(ctx.inputs_tasks)
    for name in keys(ctx.inputs)
        ctx.inputs_tasks[name] = Threads.@spawn _execute_input(ctx, name)
    end

    ctx.exec_task = Threads.@spawn _execute_pipeline(ctx)
end

function stop_pipeline(ctx::XfaContext; timeout=5)
    close(ctx.ext_inputs_channel)
end

function load_from_string(ctx_str::AbstractString)
    ctx_module = Module()
    ctx_module._xfa_generated_module = true
    ctx_module._xfa_variables = Dict{String, Vector{Any}}()
    ctx_module._xfa_subvariables = Dict{String, Vector{String}}()
    ctx_module._xfa_parameters = Parameter[]
    ctx_module._xfa_inputs = Dict{String, Any}()
    ctx_module._xfa_groups = Dict{String, Any}()

    exprs = Expr[:(using XfaEngine.Context)]

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
    group_types = Dict{String, Group}()
    for (group_name, param_fields) in ctx_module._xfa_groups
        group_struct = getproperty(ctx_module, Symbol(group_name))
        parameters = Dict([field => fieldtype(group_struct, field) for field in param_fields])
        group_types[group_name] = Group(group_name, group_struct, parameters, String[])
    end

    parameters = Dict([param.name => param for param in ctx_module._xfa_parameters])

    # Check if there are any parameters with the same name as a variable
    common_var_param_names = intersect(keys(ctx_module._xfa_variables),
                                       keys(parameters))
    if !isempty(common_var_param_names)
        names_str = join(common_var_param_names, ", ")
        throw(XfaContextException("@Variable's and @Parameter's exist with the same name: $(names_str)"))
    end

    # Look up all the functions that will be called
    functions = Dict{String, Any}()
    for name in keys(ctx_module._xfa_variables)
        functions[name] = getproperty(ctx_module, Symbol(name))
    end

    # Create the DAG (it's just an adjaceny list)
    dag = Dict{String, OrderedDict}()
    for (name, deps) in mergewith(_ -> throw(XfaContextException("Found Variable's and Input's with duplicate names")),
                                  ctx_module._xfa_variables, ctx_module._xfa_inputs)
        # If it's a group dependency, we don't schedule it yet. That's done at
        # the end only for the instantiated group structs.
        if length(deps) > 0 && deps[1][2] isa GroupDependency
            push!(group_types[deps[1][2].struct_name].variables, name)
            continue
        end

        # Don't add inputs to the DAG, only variables
        if haskey(ctx_module._xfa_variables, name)
            dag[name] = _get_deps(name, parameters, ctx_module)
        end
    end

    # At this point we've added all the non-grouped variables to the DAG and we
    # know which variables belong to which group, so we can schedule all the
    # instantiated groups.
    groups = Dict{String, Any}()
    inputs = Dict{String, Any}()

    # Look at all the top-level names and check if they're groups
    for (group_name, group_type_name, object) in _get_group_objects(ctx_module, group_types)
        # value = getproperty(ctx_module, group_name)
        # group_type_name = findfirst(g -> value isa g.type, group_types)
        # if group_type_name == nothing
        #     continue
        # end

        groups[group_name] = object

        # If so, then add all their variables to the DAG
        for variable_name in group_types[group_type_name].variables
            # If it's an input, handle it later
            if haskey(ctx_module._xfa_inputs, variable_name)
                continue
            end

            dag_deps = _get_deps(variable_name, parameters, ctx_module)

            # Replace the GroupDependency that originally contained the group
            # type name, with a GroupDependency that names the instatiated
            # group.
            argument_names = collect(keys(dag_deps))
            arg_idx = findfirst(key -> dag_deps[key] == GroupDependency(group_type_name),
                                argument_names)
            dag_deps[argument_names[arg_idx]] = GroupDependency(group_name)

            group_var_name = "$group_name.$variable_name"
            dag[group_var_name] = dag_deps
            functions[group_var_name] = functions[variable_name]

            # Dependencies of the form `foo.bar` are saved as
            # SubvariableDependency's. But these may also refer to groups, so
            # now we go through all the dependencies for all variables and check
            # if any are actually group variables instead of subvariables.
            for var_deps in values(dag)
                for i in eachindex(var_deps)
                    if var_deps[i] == SubvariableDependency(group_name, variable_name)
                        var_deps[i] = Dependency(group_var_name)
                    end
                end
            end
        end

        # And add all the parameters too
        for (param_sym, param_type) in group_types[group_type_name].parameters
            param_name = "$group_name.$param_sym"
            parameters[param_name] = Parameter(param_name, getproperty(object, param_sym))
        end

        # And all the inputs
        for (input_name, deps) in ctx_module._xfa_inputs
            if length(deps) == 2
                input_group_type_name = deps[1][2].struct_name
                if input_group_type_name == group_type_name
                    group_input_name = "$group_name.$input_name"
                    new_deps = OrderedDict(deps)
                    # Similarly to variables, we replace the GroupDependency
                    # that contained the group type name with one that contains
                    # the instantiated name.
                    new_deps[first(keys(new_deps))] = GroupDependency(group_name)
                    inputs[group_input_name] = new_deps
                end
            end
        end
    end

    # Now we do the same for the inputs: go through all of the declared ones and
    # add them to the context if they're not part of a group. All the grouped
    # inputs should already have been added.
    for (name, deps) in ctx_module._xfa_inputs
        if length(deps) == 1
            inputs[name] = Dict(deps)
        end
    end

    # Check that it has no cycles by attempting to sort it
    topological_sort(dag)

    return XfaContext(; functions, group_types, groups, dag,
                      subvariables=ctx_module._xfa_subvariables, parameters, exprs,
                      inputs)
end

function load_from_file(ctx_path::AbstractString)
    if !isfile(ctx_path)
        throw(ArgumentError("$(ctx_path) is not a file!"))
    end

    return load_from_string(read(ctx_path, String))
end

function _get_group_objects(ctx_module, group_types)
    group_objects = Tuple{String, String, Any}[]

    for name in names(ctx_module; all=true)
        object = getproperty(ctx_module, name)
        group_type_name = findfirst(g -> object isa g.type, group_types)
        if group_type_name != nothing
            push!(group_objects, (string(name), group_type_name, object))
        end
    end

    return group_objects
end

function _get_deps(var_name, parameters, ctx_module)
    final_deps = OrderedDict()

    for (arg_name, dep) in ctx_module._xfa_variables[var_name]
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
