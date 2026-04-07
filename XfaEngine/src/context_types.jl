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
    topic::Union{String, Nothing}
    source::String
    property::String
end

KaraboDependency(source::AbstractString, property::AbstractString) = KaraboDependency(nothing, source, property)

struct FunctionArgument
    name::String
    type::Union{Nothing, Type}
end

const slow_data_re = r"^(\S+?)\.([\w|\.]+)$"
const fast_data_re = r"^(\S+):(\S+)\[(\S+)\]$"
const topic_prefix_re = r"^(\w+)//(.+)$"

function KaraboDependency(str::AbstractString)
    topic = nothing
    m = match(topic_prefix_re, str)
    if !isnothing(m)
        topic = m.captures[1]
        str = m.captures[2]
    end

    m = match(slow_data_re, str)
    if !isnothing(m)
        return KaraboDependency(topic, m.captures[1], m.captures[2])
    end

    m = match(fast_data_re, str)
    if !isnothing(m)
        return KaraboDependency(topic, "$(m.captures[1]):$(m.captures[2])", m.captures[3])
    end

    throw(ArgumentError("'$(str)' is not a valid Karabo device property"))
end

function Base.string(kp::KaraboDependency)
    device_str = if occursin(':', kp.source)
        "$(kp.source)[$(kp.property)]"
    else
        "$(kp.source).$(kp.property)"
    end

    if isnothing(kp.topic)
        return device_str
    else
        return "$(kp.topic)//$(device_str)"
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
                        elseif value isa AbstractDependency || @capture(value, @karabo_str _)
                            # Keep as-is
                        elseif value isa Symbol
                            value = :(Context.Dependency($("$value")))
                        else
                            throw(ArgumentError("Unrecognized dependency expression: $(value)"))
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

# Helper functions for detecting variable references. A reference can be a
# module-qualified name (MyLib.func), a bare symbol (func), or a call on
# either of those with dependency overrides (MyLib.func(data -> ...)).
_is_qualified_name(expr) = expr isa Expr && expr.head == :.
_is_ref_name(expr) = expr isa Symbol || _is_qualified_name(expr)
_is_variable_ref(expr) = _is_ref_name(expr) || (expr isa Expr && expr.head == :call && _is_ref_name(expr.args[1]))

function _ref_basename(expr)
    if expr isa Expr && expr.head == :call
        return _ref_basename(expr.args[1])
    elseif _is_qualified_name(expr)
        return expr.args[2].value
    elseif expr isa Symbol
        return expr
    end
end

function _split_ref(expr)
    if expr isa Expr && expr.head == :call
        return expr.args[1], expr.args[2:end]
    else
        return expr, []
    end
end

# Generates code for a variable that references an existing variable from
# another module. Creates a wrapper function and registers trait methods
# that delegate to the original, with optional dependency overrides.
function _variable_reference(new_name, ref_expr, side_effects)
    orig_func_expr, override_args = _split_ref(ref_expr)

    # Build dependency registration code
    if !isempty(override_args)
        overrides, _ = _parse_function_args(override_args)
        overrides_expr = Expr(:vect, overrides...)
        deps_code = quote
            let orig_deps = Context.variable_dependencies($orig_func_expr),
                overrides = Dict{String, Any}($overrides_expr)
                Context.variable_dependencies(::typeof($new_name)) = [(name, get(overrides, name, dep)) for (name, dep) in orig_deps]
            end
        end
    else
        deps_code = :(Context.variable_dependencies(::typeof($new_name)) = Context.variable_dependencies($orig_func_expr))
    end

    # Build subvariable registration code, remapping names if renamed.
    # When names match the replace is a no-op.
    orig_name_str = string(_ref_basename(ref_expr))
    new_name_str = string(new_name)
    subvars_code = quote
        Context.variable_subvariables(::typeof($new_name)) = [replace(s, $orig_name_str => $new_name_str, count=1)
                                                              for s in Context.variable_subvariables($orig_func_expr)]
    end

    return esc(quote
        function $new_name(args...)
            $orig_func_expr(args...)
        end

        if $side_effects
            Context.variable_origin(::typeof($new_name)) = $orig_func_expr
            $deps_code
            $subvars_code
        end
    end)
end

function _variable(ctx_module, expr, side_effects)
    if !(expr isa Expr)
        throw(ArgumentError("Must pass an Expr to @Variable"))
    end

    # Handle the `->` shorthand form. The right-hand side can be:
    # - A Karabo dependency: @Variable cam -> karabo"camera.pixels"
    # - A variable reference (qualified or bare symbol), optionally with
    #   dependency overrides:
    #     @Variable my_norm -> MyLib.normalize
    #     @Variable my_norm -> normalize
    #     @Variable my_norm -> MyLib.normalize(data -> karabo"other.source")
    #   Bare symbols are only allowed here (not without ->), because without
    #   a rename the new wrapper function would conflict with the imported name.
    if @capture(expr, name_ -> value_)
        # Strip quote nodes etc
        value = MacroTools.unblock(value)

        if value isa KaraboDependency || (value isa Expr && @capture(value, @karabo_str _))
            function_expr = quote
                function $name(data -> $value)
                    return data
                end
            end

            # Recurse with the generated function
            return _variable(ctx_module, function_expr, side_effects)
        elseif _is_variable_ref(value)
            return _variable_reference(name, value, side_effects)
        else
            throw(ArgumentError("Unrecognized dependency: $(value)"))
        end

    elseif @capture(expr, function func_name_(args__) body_ end)
        # And now we handle explicit function declarations

        # Extract dependency information
        dependencies, new_args = _parse_function_args(args)

        # Look through the body for @add_subvariable calls to register them.
        # Only toplevel calls are allowed. Note that we capture the macro name
        # and check it explicitly because MacroTools doesn't handle the
        # underscore in the name properly.
        subvariables = String[]
        for body_expr in body.args
            if @capture(body_expr, @macroname_(subvar_name_, _)) && macroname == Symbol("@add_subvariable")
                push!(subvariables, "$(func_name).$(subvar_name)")
            end
        end

        postwalk(body) do body_expr
            if @capture(body_expr, @macroname_(subvar_name_, _)) && macroname == Symbol("@add_subvariable")
                if "$(func_name).$(subvar_name)" ∉ subvariables
                    throw(ArgumentError("Subvariable '$(func_name).$(subvar_name)' must be defined at the toplevel of the function"))
                end
            end

            body_expr
        end

        # Combine all the dependency expressions into a vector expr, which will
        # get interpolated/evaluated properly.
        dependencies_expr = Expr(:vect, dependencies...)
        subvariables_expr = Expr(:vect, subvariables...)
        new_function = quote
            function $func_name($(new_args...))
                $body
            end

            if $side_effects
                Context.variable_dependencies(::typeof($func_name)) = $dependencies_expr
                Context.variable_subvariables(::typeof($func_name)) = $subvariables_expr
            end
        end

        return esc(new_function)

    elseif _is_qualified_name(expr) || (expr isa Expr && expr.head == :call && _is_qualified_name(expr.args[1]))
        # Handle module-qualified references without rename:
        #   @Variable MyLib.func
        #   @Variable MyLib.func(data -> karabo"other.source")
        # Requires a qualified name (not a bare symbol) to avoid conflicting
        # with the imported binding.
        new_name = _ref_basename(expr)
        return _variable_reference(new_name, expr, side_effects)
    end

    throw(ArgumentError("Could not construct variable from expression: $(prettify(expr))"))
end

# Register a subvariable value in the current execution context. This is
# emitted by the @Variable macro when it encounters inner subvariable
# declarations, and should not be called directly.
macro add_subvariable(name, value)
    esc(quote
        let _val = $value
            _key = "$(Context.Meta.name[]).$($name)"
            Context.Meta.subvariables[][_key] = _val
            _val
        end
    end)
end

"""
Mark functions for execution in XFA.
"""
macro Variable(expr)
    _variable(__module__, expr, true)
end

mutable struct Parameter{T, F, G}
    name::String
    value::Union{T, Nothing}
    set_by_user::Bool

    update_handler::F
    initializer::G
end

function Base.:(==)(one::Parameter{T}, two::Parameter{T}) where T
    one.name == two.name && one.value == two.value && one.set_by_user == two.set_by_user
end

Parameter(name::String, value) = Parameter(name, value, false, nothing, nothing)
Parameter(value) = Parameter("", value, false, nothing, nothing)

function Parameter(f::Base.Callable, value)
    if !isnothing(f) && !applicable(f, value)
        throw(ArgumentError("Parameter update handler must be either `nothing` or a callable that takes a single argument"))
    end

    Parameter("", value, false, f, nothing)
end

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
Base.setindex!(param::Parameter, value) = param.value = value

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
                Context.input_dependencies(::typeof($name)) = $dependencies_expr
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
                Context.group_fields(::Type{$name}) = []
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
