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
function karabo_dep_content(dep::KaraboDependency)
    if occursin(':', dep.source)
        "$(dep.source)[$(dep.property)]"
    else
        "$(dep.source).$(dep.property)"
    end
end

"""
    replace_karabo_dep(source, variable_name, arg_name, new_dep) -> String

Replace the karabo dependency for a specific argument within a `@Variable`
definition in the source code. For shorthand variables (`@Variable foo ->
karabo"..."`), the argument name is `"data"`. Returns the modified source, or
the original source unchanged if the variable or argument was not found.
"""
function replace_karabo_dep(source::String, variable_name::String, arg_name::String, new_dep::KaraboDependency)
    tree = parseall(SyntaxNode, source; ignore_errors=true)
    var_node = find_variable_node(tree, variable_name)
    if isnothing(var_node)
        @warn "Could not find @Variable definition for '$(variable_name)'"
        return source
    end

    # Find -> nodes where the left side matches arg_name. For shorthand
    # variables the arg name in the AST is the variable name itself.
    arrow_nodes = find_nodes(var_node) do node
        kind(node) == K"->" || return false
        cs = children(node)
        isnothing(cs) && return false

        lhs = cs[1]
        # The LHS can be a tuple node (shorthand) or a bare identifier
        if kind(lhs) == K"tuple"
            tuple_cs = children(lhs)
            !isnothing(tuple_cs) && !isempty(tuple_cs) &&
                is_leaf(tuple_cs[1]) && tuple_cs[1].val in (Symbol(arg_name), Symbol(variable_name))
        else
            is_leaf(lhs) && lhs.val == Symbol(arg_name)
        end
    end

    if isempty(arrow_nodes)
        @warn "No argument '$(arg_name)' found in @Variable definition for '$(variable_name)'"
        return source
    end

    # Find the karabo literal on the right side of the arrow
    arrow = arrow_nodes[1]
    rhs = children(arrow)[2]
    karabo_nodes = find_nodes(rhs) do n
        kind(n) == K"macrocall" && any(children(n)) do c
            is_leaf(c) && kind(c) == K"StringMacroName" && c.val == Symbol("@karabo_str") # in XfaEngine.Context._KARABO_MACRO_NAMES
        end
    end

    if isempty(karabo_nodes)
        @warn "No karabo dependency found for argument '$(arg_name)' in @Variable '$(variable_name)'"
        return source
    end

    br = byte_range(karabo_nodes[1])
    new_literal = if isnothing(new_dep.topic)
        "karabo\"$(karabo_dep_content(new_dep))\""
    else
        "karabo\"$(new_dep.topic)//$(karabo_dep_content(new_dep))\""
    end
    return source[1:first(br)-1] * new_literal * source[last(br)+1:end]
end

function rename_karabo_dep(state, variable_name::String, arg_name::String, new_dep::KaraboDependency)
    client = state.client
    source = client.context.source

    if isempty(source)
        @error "No context source available for renaming"
        return
    end

    new_source = replace_karabo_dep(source, variable_name, arg_name, new_dep)
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
