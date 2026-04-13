using Base.JuliaSyntax: @K_str, parseall, SyntaxNode, children, is_leaf, kind, byte_range


"""
    replace_variable_name(source, old_name, new_name) -> String

Rename a variable in the context source code. Replaces the variable's definition
name and all references to it in other @Variable definitions. Returns the
modified source, or the original source unchanged if the variable was not found.
"""
function replace_variable_name(source::String, old_name::String, new_name::String)
    tree = parseall(SyntaxNode, source; ignore_errors=true)

    # Find all identifier leaves with the old name inside @Variable macrocalls
    variable_macros = find_nodes(tree) do node
        kind(node) == K"macrocall" && any(children(node)) do c
            is_leaf(c) && kind(c) == K"MacroName" && c.val == Symbol("@Variable")
        end
    end

    targets = SyntaxNode[]
    for vm in variable_macros
        append!(targets, find_nodes(vm) do node
            is_leaf(node) && kind(node) == K"Identifier" && node.val == Symbol(old_name)
        end)
    end

    if isempty(targets)
        @warn "No occurrences of '$(old_name)' found in context file"
        return source
    end

    # Replace in reverse byte order to preserve offsets
    sort!(targets; by=n -> first(byte_range(n)), rev=true)
    for node in targets
        br = byte_range(node)
        source = source[1:first(br)-1] * new_name * source[last(br)+1:end]
    end

    return source
end

function rename_variable(state, old_name::String, new_name::String)
    client = state.client
    source = client.context.source

    if isempty(source)
        @error "No context source available for renaming"
        return
    end

    new_source = replace_variable_name(source, old_name, new_name)
    if new_source == source
        return
    end

    # Write modified file back to server
    if client.embedded_engine
        write(client.context_path, new_source)
    else
        open(client.context_path, client.sftp; write=true) do f
            write(f, new_source)
        end
    end

    # Reload the context
    load_context(state)
end

"""
Find all descendant nodes matching a predicate.
"""
function find_nodes(pred, node::SyntaxNode, results=SyntaxNode[])
    if pred(node)
        push!(results, node)
    end
    if !is_leaf(node)
        for child in children(node)
            find_nodes(pred, child, results)
        end
    end
    return results
end

"""
Find the `@Variable` macrocall node that defines a given variable name.
"""
function find_variable_node(tree::SyntaxNode, var_name::String)
    variable_macros = find_nodes(tree) do node
        kind(node) == K"macrocall" && any(children(node)) do c
            is_leaf(c) && kind(c) == K"MacroName" && c.val == Symbol("@Variable")
        end
    end

    for vm in variable_macros
        vm_children = children(vm)
        isnothing(vm_children) && continue

        for child in vm_children
            # Shorthand form: @Variable name -> karabo"..."
            # Tree: [macrocall @Variable [-> [tuple name] ...]]
            if kind(child) == K"->"
                cs = children(child)
                isnothing(cs) && continue
                tuple_node = cs[1]
                tuple_cs = children(tuple_node)
                if !isnothing(tuple_cs) && !isempty(tuple_cs)
                    first_child = tuple_cs[1]
                    if is_leaf(first_child) && first_child.val == Symbol(var_name)
                        return vm
                    end
                end
            end

            # Call form: @Variable name(arg -> karabo"...") ... end
            # Tree: [macrocall @Variable [call name [-> ...]]]
            if kind(child) == K"call"
                cs = children(child)
                if !isnothing(cs) && !isempty(cs)
                    name_node = cs[1]
                    if is_leaf(name_node) && name_node.val == Symbol(var_name)
                        return vm
                    end
                end
            end

            # Function form: @Variable function name(...) ... end
            # Tree: [macrocall @Variable [function [call name [-> ...]] ...]]
            if kind(child) == K"function"
                cs = children(child)
                if !isnothing(cs) && !isempty(cs)
                    call_node = cs[1]
                    call_cs = children(call_node)
                    if !isnothing(call_cs) && !isempty(call_cs)
                        name_node = call_cs[1]
                        if is_leaf(name_node) && name_node.val == Symbol(var_name)
                            return vm
                        end
                    end
                end
            end
        end
    end

    return nothing
end

# Return the string content inside a Karabo string macro literal, i.e. the
# dependency string without the topic prefix.
function karabo_dep_content(dep::Dependency)
    if occursin(':', dep.source)
        "$(dep.source)[$(dep.property)]"
    else
        "$(dep.source).$(dep.property)"
    end
end

# Convert a Dependency to its source code representation.
function dep_to_source(dep::Dependency)
    if dep.kind == DepKind_Karabo
        content = karabo_dep_content(dep)
        if isnothing(dep.topic)
            "karabo\"$(content)\""
        else
            "karabo\"$(dep.topic)//$(content)\""
        end
    else
        dep.name
    end
end

# Find the arrow node for a specific argument in a @Variable definition.
function find_arg_arrow(var_node::SyntaxNode, variable_name::String, arg_name::String)
    arrow_nodes = find_nodes(var_node) do node
        kind(node) == K"->" || return false
        cs = children(node)
        isnothing(cs) && return false

        lhs = cs[1]
        if kind(lhs) == K"tuple"
            tuple_cs = children(lhs)
            !isnothing(tuple_cs) && !isempty(tuple_cs) &&
                is_leaf(tuple_cs[1]) && tuple_cs[1].val in (Symbol(arg_name), Symbol(variable_name))
        else
            is_leaf(lhs) && lhs.val == Symbol(arg_name)
        end
    end

    return isempty(arrow_nodes) ? nothing : arrow_nodes[1]
end

"""
    replace_dep(source, variable_name, arg_name, new_dep) -> String

Replace the dependency for a specific argument within a `@Variable` definition
in the source code. Works for both Karabo and variable dependencies by replacing
the entire RHS of the arrow expression. Returns the modified source, or the
original source unchanged if the variable or argument was not found.
"""
function replace_dep(source::String, variable_name::String, arg_name::String, new_dep::Dependency)
    tree = parseall(SyntaxNode, source; ignore_errors=true)
    var_node = find_variable_node(tree, variable_name)
    if isnothing(var_node)
        @warn "Could not find @Variable definition for '$(variable_name)'"
        return source
    end

    arrow = find_arg_arrow(var_node, variable_name, arg_name)
    if isnothing(arrow)
        @warn "No argument '$(arg_name)' found in @Variable definition for '$(variable_name)'"
        return source
    end

    rhs = children(arrow)[2]
    br = byte_range(rhs)
    return source[1:first(br)-1] * dep_to_source(new_dep) * source[last(br)+1:end]
end

# Find the KaraboBridge(...) call node assigned to `bridge_name` in the AST.
function find_bridge_call(tree::SyntaxNode, bridge_name::String)
    for node in find_nodes(n -> kind(n) == K"=", tree)
        cs = children(node)
        isnothing(cs) || length(cs) < 2 && continue

        lhs, rhs = cs[1], cs[2]
        if is_leaf(lhs) && lhs.val == Symbol(bridge_name) &&
           kind(rhs) == K"call" && !isempty(children(rhs)) &&
           is_leaf(children(rhs)[1]) && children(rhs)[1].val == :KaraboBridge
            return rhs
        end
    end
    return nothing
end

# Add or replace the `address` keyword argument in a KaraboBridge constructor
# call assigned to `bridge_name`.
function replace_bridge_address(source::String, bridge_name::String, new_address::String)
    tree = parseall(SyntaxNode, source; ignore_errors=true)
    call_node = find_bridge_call(tree, bridge_name)
    if isnothing(call_node)
        @warn "Could not find KaraboBridge assignment for '$(bridge_name)'"
        return source
    end

    # Look for an existing `parameters` node (the kwargs after `;`)
    params_node = nothing
    for c in children(call_node)
        if kind(c) == K"parameters"
            params_node = c
            break
        end
    end

    if !isnothing(params_node)
        # Find the address= kwarg inside the parameters node
        address_node = nothing
        for c in children(params_node)
            if kind(c) == K"=" && !isempty(children(c)) &&
               is_leaf(children(c)[1]) && children(c)[1].val == :address
                address_node = c
                break
            end
        end

        if !isnothing(address_node)
            # Replace just the address kwarg value
            br = byte_range(address_node)
            return source[1:first(br)-1] * "address=\"$(new_address)\"" * source[last(br)+1:end]
        else
            # Parameters exist but no address kwarg — append it
            br = byte_range(params_node)
            return source[1:last(br)] * ", address=\"$(new_address)\"" * source[last(br)+1:end]
        end
    else
        # No kwargs at all — insert before the closing paren
        call_end = last(byte_range(call_node))
        return source[1:call_end-1] * "; address=\"$(new_address)\"" * source[call_end:end]
    end
end

function set_bridge_address(state, bridge_name::String, new_address::String)
    client = state.client
    source = client.context.source

    if isempty(source)
        @error "No context source available for editing"
        return
    end

    new_source = replace_bridge_address(source, bridge_name, new_address)
    if new_source == source
        return
    end

    if client.embedded_engine
        write(client.context_path, new_source)
    else
        open(client.context_path, client.sftp; write=true) do f
            write(f, new_source)
        end
    end

    load_context(state)
end

# Replace a dependency (Karabo or variable) in the source code and reload.
function rename_dep(state, variable_name::String, arg_name::String, old_dep::Dependency, new_dep::Dependency)
    client = state.client
    source = client.context.source

    if isempty(source)
        @error "No context source available for editing"
        return
    end

    new_source = replace_dep(source, variable_name, arg_name, new_dep)
    if new_source == source
        return
    end

    if client.embedded_engine
        write(client.context_path, new_source)
    else
        open(client.context_path, client.sftp; write=true) do f
            write(f, new_source)
        end
    end

    load_context(state)
end
