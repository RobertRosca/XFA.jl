@kwdef mutable struct KaraboBridgeGuiState
    zmq_outputs::Union{Vector{String}, Exception, Nothing} = nothing
    zmq_outputs_request::Maybe{Int} = nothing
    selected_output::Cint = 0
end

function draw_variable_content(::Val{Symbol("XfaEngine.Context.KaraboBridge")}, name, var_data, gui_state)
    var_data["draw_parameters"] = false
    client = state[].client
    params = var_data["parameters"]

    if isnothing(gui_state)
        gui_state = KaraboBridgeGuiState()
    end

    ig.Text("Parameters:")
    draw_parameter("trainmatcher", params["trainmatcher"])
    draw_parameter("manual_configuration", params["manual_configuration"])

    if params["manual_configuration"].value
        draw_parameter("address", params["address"])
    else
        # Fetch zmqOutputs from the trainmatcher device
        tm = params["trainmatcher"].value
        if !isempty(tm.topic) && !isempty(tm.name) && !is_pending(client, gui_state.zmq_outputs_request)
            if isnothing(gui_state.zmq_outputs)
                gui_state.zmq_outputs_request = send_with_callback(
                    client, GetDeviceProperty(tm.topic, tm.name, "zmqOutputs"),
                    msg -> begin
                        if msg.value isa Exception
                            gui_state.zmq_outputs = msg.value
                        else
                            gui_state.zmq_outputs = String[out["address"] for out in msg.value]
                        end
                        gui_state.zmq_outputs_request = nothing
                    end
                )
            end
        end

        if is_pending(client, gui_state.zmq_outputs_request)
            Spinner("Fetching outputs...")
        elseif gui_state.zmq_outputs isa Exception
            ig.TextColored(ig.ImVec4(1, 0.4, 0.4, 1), sprint(showerror, gui_state.zmq_outputs))
        elseif gui_state.zmq_outputs isa Vector && !isempty(gui_state.zmq_outputs)
            # Sync combo selection with the current address parameter
            current_address = params["address"].value
            if !isempty(current_address)
                found = findfirst(==(current_address), gui_state.zmq_outputs)
                if !isnothing(found)
                    gui_state.selected_output = Cint(found - 1)
                end
            end

            ig.SetNextItemWidth(350)
            idx = Ref(gui_state.selected_output)
            if CopyableCombo("Output", gui_state.zmq_outputs, idx)
                gui_state.selected_output = idx[]
                new_address = gui_state.zmq_outputs[idx[] + 1]
                address_param = params["address"]
                change_parameter(Parameter(address_param.name, new_address))
                @guiasync set_group_param(state[], name, "address", "\"$(new_address)\"")
            end
        elseif isempty(gui_state.zmq_outputs)
            ig.Text("No ZMQ outputs found")
        end

        if !is_pending(client, gui_state.zmq_outputs_request)
            ig.SameLine()
            if ig.Button("Refresh##zmq_outputs_$(name)")
                gui_state.zmq_outputs = nothing
            end
        end
    end

    return gui_state
end
