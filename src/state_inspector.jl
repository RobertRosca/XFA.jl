function _inspector_value_str(value)
    sprint(show, value; context=IOContext(stdout, :compact => true, :displaysize => (10, 100)))
end

function _inspector_value_str(ws::WebSockets.WebSocket)
    "WebSocket()"
end

const INSPECTOR_DEPTH_COLORS = [
    ig.ImVec4(0.6, 0.9, 1.0, 1.0),  # cyan
    ig.ImVec4(0.6, 1.0, 0.6, 1.0),  # green
    ig.ImVec4(1.0, 0.8, 0.5, 1.0),  # orange
    ig.ImVec4(0.9, 0.6, 1.0, 1.0),  # purple
    ig.ImVec4(1.0, 1.0, 0.5, 1.0),  # yellow
]

function _draw_inspector(value, label::String, depth=1)
    T = typeof(value)
    nonrecursive_types = (String, Nothing, ReentrantLock,
                          ssh.Session, ssh.SshChannel, ssh.SftpSession, ssh.Forwarder,
                          WebSockets.WebSocket,
                          PasswordStore)
    recursive_vector_type = T ∈ (Vector{SshState},)
    recursive_type = (T ∉ nonrecursive_types &&
        (recursive_vector_type || !(T <: AbstractVector)) &&
        !(T <: Ref) && isstructtype(T) &&
        !(T <: Channel))

    color = INSPECTOR_DEPTH_COLORS[mod1(depth, length(INSPECTOR_DEPTH_COLORS))]
    ig.PushStyleColor(ig.ImGuiCol_Text, color)

    if recursive_vector_type
        if ig.TreeNode(label * " :: " * string(T) * " ($(length(value)) elements)")
            ig.PopStyleColor()
            for (i, elem) in enumerate(value)
                _draw_inspector(elem, string(i), depth + 1)
            end
            ig.TreePop()
        else
            ig.PopStyleColor()
        end
    elseif value isa AbstractDict
        if ig.TreeNode(label * " :: " * string(T) * " ($(length(value)) entries)")
            ig.PopStyleColor()
            for (k, v) in value
                _draw_inspector(v, _inspector_value_str(k), depth + 1)
            end
            ig.TreePop()
        else
            ig.PopStyleColor()
        end
    elseif recursive_type
        if ig.TreeNode(label * " :: " * string(typeof(value)))
            ig.PopStyleColor()
            for name in fieldnames(typeof(value))
                try
                    field_value = getfield(value, name)
                    _draw_inspector(field_value, string(name), depth + 1)
                catch e
                    ig.Text("$(name): <error: $(e)>")
                end
            end
            ig.TreePop()
        else
            ig.PopStyleColor()
        end
    else
        ig.Text("$(label): $(_inspector_value_str(value))")
        ig.PopStyleColor()
    end
end

function draw_state_inspector(show_window::Base.RefValue)
    gui_state = state[]

    ig.SetNextWindowSize((500, 500), ig.ImGuiCond_FirstUseEver)
    if ig.Begin("State Inspector", show_window)
        _draw_inspector(gui_state, "GuiState")
    end
    ig.End()
end
