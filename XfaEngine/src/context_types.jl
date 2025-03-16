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
    name::Union{String, Nothing} # Name of the argument in the function signature
    type::DataType
end

GroupDependency(type::DataType) = GroupDependency(nothing, type)

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
    Expr(:call, :KaraboDependency, esc(Base.Meta.parse("\"$(escape_string(str))\"")))
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
                            push!(dependencies, :(($arg_name_expr, Context.GroupDependency($T))))
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
            function $func_name($(new_args...))
                $new_body
            end

            if $side_effects
                Context.registered_variables[$func_name] = $dependencies_expr
                Context.registered_subvariables[$func_name] = $subvariables_expr
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
    _variable(__module__, expr, true)
end

mutable struct Parameter{T}
    name::String
    value::T
    set_by_user::Bool
end

function Base.:(==)(one::Parameter{T}, two::Parameter{T}) where T
    one.name == two.name && one.value == two.value && one.set_by_user == two.set_by_user
end

Parameter(value) = Parameter("", value, false)
Parameter(name, value) = Parameter(name, value, false)

function tryset(param::Parameter, value; force=false)
    if param.set_by_user && force
        param.set_by_user = false
    end

    if !param.set_by_user
        remote_do(set_parameter, 1, param.name, value, Meta.name[])
        return true
    else
        return false
    end
end

Base.getindex(param::Parameter) = param.value

function set_parameter(name::String, value, requestor::String)
    @info "Setting parameter '$(name)' to $(value) as requested by '$(requestor)'"
end

function _input(ctx_module, expr, side_effects)
    if !(expr isa Expr)
        throw(ArgumentError("Must pass an Expr to @Input"))
    end

    if @capture(expr, function name_(args__) body_ end)
        dependencies, new_args = _parse_function_args(args; is_input=true)
        if length(new_args) == 2
            if isempty(dependencies) || !@capture(dependencies[1], (_, Context.GroupDependency(_)))
                throw(XfaContextException("The first argument of a two-argument @Input must be a @Group"))
            end
        elseif length(new_args) != 1
            throw(XfaContextException("@Input functions must accept 1-2 arguments, '$(name)' has $(length(args)) arguments"))
        end

        dependencies_expr = Expr(:vect, dependencies...)
        new_expr = quote
            function $name($(args...))
                $body
            end

            if $side_effects
                Context.registered_inputs[$name] = $dependencies_expr
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
    _input(__module__, expr, true)
end


struct Group
    type::DataType
    variables::Vector{Function}
end

function Base.:(==)(x::Group, y::Group)
    x.type === y.type && x.parameters == y.parameters && x.variables == y.variables
end

function _group(ctx_module, expr, side_effects)
    if !(expr isa Expr)
        throw(ArgumentError("Must pass an Expr to @Group"))
    end

    if @capture(expr, struct name_ fields__ end) || @capture(expr, mutable struct name_ fields__ end)
        # # Look through the fields for parameters
        # param_fields = []
        # new_fields = [if @capture(field, field_name_::Parameter{T_})
        #                   push!(param_fields, field_name)
        #                   :($field_name::$T)
        #               else
        #                   field
        #               end
        #               for field in fields]

        # new_expr = quote
        #     struct $name
        #         $(new_fields...)
        #     end

        #     if $side_effects
        #         Context.registered_groups[$name] = $param_fields
        #     end

        #     $name
        # end

        new_expr = quote
            $(expr)

            if $side_effects
                Context.registered_groups[$name] = []
            end

            $name
        end

        return esc(new_expr)
    end

    throw(ArgumentError("Could not construct a group from expression: $(prettify(expr))"))
end

"""
Mark a struct as a group of @Variable's.
"""
macro Group(expr)
    _group(__module__, expr, true)
end
