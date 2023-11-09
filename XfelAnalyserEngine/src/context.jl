module Context

export @karabo_str, @Variable

import MacroTools
import MacroTools: @capture, postwalk, prettify


abstract type AbstractDependency end

struct KaraboDependency <: AbstractDependency
    source::String
    property::String
end

struct Dependency <: AbstractDependency
    name::String
end

struct SubvariableDependency <: AbstractDependency
    parent::String
    name::String
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
                                value = :(Context.Dependency(string($value)))
                            end
                            push!(dependencies, value)

                            # Replace the original argument expression with just
                            # the argument name.
                            return arg_name
                        else
                            return arg_expr
                        end
                    end
                    for arg in args]

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


mutable struct XfaContext4
    functions::Dict{String, Any}
    dag::Dict{String, Vector{Any}}
    subvariables::Dict{String, Vector{String}}
    exprs::Vector{Expr}
end

XfaContext = XfaContext4

function external_dependencies(ctx::XfaContext)
    ext_deps = Set()
    for (_, deps) in ctx.dag
        for dep in deps
            if dep isa KaraboDependency
                push!(ext_deps, dep)
            end
        end
    end

    return ext_deps
end

function Base.show(io::IO, ctx::XfaContext)
    n_variables = length(ctx.functions)
    print(io, "<XfaContext with $(n_variables) variables>")
end


function load_context(ctx_str::AbstractString)
    ctx_module = Module()
    ctx_module._xfa_generated_module = true
    ctx_module._xfa_variables = Dict{String, Vector{Any}}()
    ctx_module._xfa_subvariables = Dict{String, Vector{String}}()

    exprs = Expr[:(using XfelAnalyserEngine.Context)]

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

    # Look up all the functions that will be called
    functions = Dict{String, Any}()
    for name in keys(ctx_module._xfa_variables)
        functions[name] = getproperty(ctx_module, Symbol(name))
    end

    # Create the DAG (it's just an adjaceny list)
    dag = Dict{String, Vector{Any}}()
    for (name, deps) in ctx_module._xfa_variables
        dag[name] = []
        for dep in deps
            if !(dep isa AbstractDependency)
                throw(ArgumentError("Dependency of type '$(typeof(dep))' is not allowed"))
            end

            push!(dag[name], dep)
        end
    end

    return XfaContext(functions, dag, ctx_module._xfa_subvariables, exprs)
end

end

## Example context file

# @Parameter energy_cutoff::Int => 0

# @Parameter function peak_roi(image)::RectROI
#     return RectROI(0, 0, 100, 100)
# end

# @Parameter peak2_roi::RectROI => RectROI(0, 0, 100, 100)

# @Variable t4 => karabo"MID_EXP_UPP/MOTOR/T4.actualPosition"

# @Variable function xgm(intensity => karabo"SA2_XTD10_XGM/DOOCS/XGM:output[data.intensityTD]",
#                        energy => karabo"SA2_XTD10_XGM/DOOCS/XGM.photonFlux.photonEnergy",
#                        t4 => t4,
#                        energy_cutoff => energy_cutoff)
#     pulse_mean = nanmean(intensity, dims=1)

#     return intensity, @Variable(pulse_mean; style="-", title="Foo", max_points=10_000, vline=energy_cutoff)
# end

# @Variable function camera_roi(data::Array, roi::RectROI)
#     roi_data = data[roi]
#     roi_mean = nanmean(roi_data)

#     return roi_data, @Variable(roi_mean; name="intensity")
# end
