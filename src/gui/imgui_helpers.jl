module ImGuiHelpers

import ...Util

export MenuItem, EditableComboBox, Spinner, SafeInputText, BoxedText, @guiasync, @Disabled, IsItemDisabled, InfoMarker

import CImGui as ig
import CImGui: IM_COL32, ImVec2
import CImGui.CSyntax: @c

mutable struct SafeInputTextState
    buffer::Vector{UInt8}
    reference_text::String
end

function SafeInputTextState(max_len::Int, reference_text::String)
    buffer = zeros(UInt8, max_len + 1) # Add 1 for the null pointer
    SafeInputTextState(buffer, reference_text)
end

safe_input_text_cache = Dict{UInt32, SafeInputTextState}()


function MenuItem(label::String, selected::Ref{Bool}, enabled::Bool=true)
    ig.MenuItem(label, C_NULL, selected, enabled)
end

# Based on: https://github.com/ocornut/imgui/issues/718#issuecomment-1249822993
function EditableComboBox(label, text, completions;
                          max_len=63, flags=ig.ImGuiInputTextFlags_None)
    flags |= ig.ImGuiInputTextFlags_EnterReturnsTrue

    # Initialize a buffer to hold the input, and copy the initial text into it
    input = zeros(UInt8, max_len + 1)
    Util.strcpy!(input, text)
    enter_pressed = ig.InputText(label, pointer(input), max_len, flags)

    if ig.IsItemActivated()
        ig.OpenPopup(label)
    end

    ig.SetNextWindowPos(ImVec2(ig.GetItemRectMin().x, ig.GetItemRectMax().y))
    popup_flags = ig.ImGuiWindowFlags_NoTitleBar
    popup_flags |= ig.ImGuiWindowFlags_NoMove
    popup_flags |= ig.ImGuiWindowFlags_NoResize
    popup_flags |= ig.ImGuiWindowFlags_ChildWindow

    edited = false
    current_input = unsafe_string(pointer(input))
    if ig.BeginPopup(label, popup_flags)
        # If the widget isn't active or we've finished editing, close the popup
        # Otherwise, build the list of completions
        for option in completions
            if ig.Selectable(option)
                ig.ClearActiveID()
                Util.strcpy!(input, option)
            end
        end

        if enter_pressed || (!ig.IsItemActive() && !ig.IsWindowFocused())
            ig.CloseCurrentPopup()
            edited = true
        end

        ig.EndPopup()
    end

    return edited, unsafe_string(pointer(input))
end

function SafeInputText(label; max_len=63, hint="", current_text="", password=false)
    id = ig.GetID(label)
    if !haskey(safe_input_text_cache, id)
        safe_input_text_cache[id] = SafeInputTextState(max_len, current_text)
        Util.strcpy!(safe_input_text_cache[id].buffer, current_text)
    end

    state = safe_input_text_cache[id]

    flags = ig.ImGuiInputTextFlags_EnterReturnsTrue
    if password
        flags |= ig.ImGuiInputTextFlags_Password
    end

    modified = unsafe_string(pointer(state.buffer)) != current_text

    if modified
        ig.PushStyleColor(ig.ImGuiCol_FrameBg, ig.IM_COL32(143, 98, 0, 255))
    end
    ret = ig.InputTextWithHint(label, hint, pointer(state.buffer), length(state.buffer), flags)
    if modified
        ig.PopStyleColor()
    end

    return ret, unsafe_string(pointer(state.buffer))
end

function BoxedText(label, text)
    if ig.BeginChild("##webproxy_error_child", ImVec2(0, 0), true,
                     ig.ImGuiWindowFlags_HorizontalScrollbar)
        ig.TextUnformatted(text)
        ig.EndChild()
    end
end

# Diabolically stolen from: https://github.com/ocornut/imgui/issues/1901#issuecomment-400563921
function Spinner(text="")
    characters = "|/-\\"
    idx = 1 + (trunc(Int, time() / 0.07) & (length(characters) - 1))

    ig.PushStyleColor(ig.ImGuiCol_Text, IM_COL32(255, 255, 255, 150))
    ig.Text(text * " " * characters[idx])
    ig.PopStyleColor()
end

macro guiasync(expr)
    return :(errormonitor(Threads.@spawn $(esc(expr))))
end

macro Disabled(cond, expr)
    return quote
        local disable = $(esc(cond))

        if disable
            ig.BeginDisabled(disable)
        end

        $(esc(expr))

        if disable
            ig.EndDisabled()
        end
    end
end

# Stolen from: https://github.com/ocornut/imgui/pull/4675
function IsItemDisabled()
    imgui_ctx = unsafe_load(ig.GetCurrentContext())
    return (imgui_ctx.LastItemData.ItemFlags & ig.ImGuiItemFlags_Disabled) != 0
end

function InfoMarker(message::AbstractString, marker::AbstractString="?")
    ig.TextDisabled("[$(marker)]")
    if ig.IsItemHovered() && ig.BeginTooltip()
        ig.Text(message)
        ig.EndTooltip()
    end
end

end
