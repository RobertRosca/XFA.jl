module ImGuiHelpers

import ...Util

export MenuItem, EditableComboBox, Spinner, SafeInputText, BoxedText, @guiasync, @Disabled, IsItemDisabled, InfoMarker

import CImGui as IG
import CImGui: IM_COL32, ImVec2
import CImGui.CSyntax: @c


function MenuItem(label::String, selected::Ref{Bool}, enabled::Bool=true)
    IG.MenuItem(label, C_NULL, selected, enabled)
end

# Based on: https://github.com/ocornut/imgui/issues/718#issuecomment-1249822993
function EditableComboBox(label, text, completions;
                          max_len=63, flags=IG.ImGuiInputTextFlags_None)
    flags |= IG.ImGuiInputTextFlags_EnterReturnsTrue

    # Initialize a buffer to hold the input, and copy the initial text into it
    input = zeros(UInt8, max_len + 1)
    Util.strcpy!(input, text)
    enter_pressed = IG.InputText(label, pointer(input), max_len, flags)

    if IG.IsItemActivated()
        IG.OpenPopup(label)
    end

    IG.SetNextWindowPos(ImVec2(IG.GetItemRectMin().x, IG.GetItemRectMax().y))
    popup_flags = IG.ImGuiWindowFlags_NoTitleBar
    popup_flags |= IG.ImGuiWindowFlags_NoMove
    popup_flags |= IG.ImGuiWindowFlags_NoResize
    popup_flags |= IG.ImGuiWindowFlags_ChildWindow

    edited = false
    current_input = unsafe_string(pointer(input))
    if IG.BeginPopup(label, popup_flags)
        # If the widget isn't active or we've finished editing, close the popup
        # Otherwise, build the list of completions
        for option in completions
            if IG.Selectable(option)
                IG.igClearActiveID()
                Util.strcpy!(input, option)
            end
        end

        if enter_pressed || (!IG.IsItemActive() && !IG.IsWindowFocused())
            IG.CloseCurrentPopup()
            edited = true
        end

        IG.EndPopup()
    end

    return edited, unsafe_string(pointer(input))
end

function SafeInputText(label; max_len=63, hint="", current_text="",
                       flags=IG.ImGuiInputTextFlags_EnterReturnsTrue)
    input = zeros(UInt8, max_len + 1) # Add 1 for the null pointer
    Util.strcpy!(input, current_text)

    if IG.InputTextWithHint(label, hint, pointer(input), length(input), flags)
        return true, unsafe_string(pointer(input))
    else
        return false, nothing
    end
end

function BoxedText(label, text)
    if IG.BeginChild("##webproxy_error_child", ImVec2(0, 0), true,
                     IG.ImGuiWindowFlags_HorizontalScrollbar)
        IG.TextUnformatted(text)
        IG.EndChild()
    end
end

# Diabolically stolen from: https://github.com/ocornut/imgui/issues/1901#issuecomment-400563921
function Spinner(text)
    characters = "|/-\\"
    idx = 1 + (trunc(Int, time() / 0.07) & (length(characters) - 1))

    IG.PushStyleColor(IG.ImGuiCol_Text, IM_COL32(255, 255, 255, 150))
    IG.Text(text * " " * characters[idx])
    IG.PopStyleColor()
end

macro guiasync(expr)
    return :(errormonitor(Threads.@spawn :interactive $(esc(expr))))
end

macro Disabled(cond, expr)
    return quote
        local disable = $(esc(cond))

        IG.igBeginDisabled(disable)

        $(esc(expr))

        if disable
            IG.igEndDisabled()
        end
    end
end

# Stolen from: https://github.com/ocornut/imgui/pull/4675
function IsItemDisabled()
    imgui_ctx = unsafe_load(IG.GetCurrentContext())
    return (imgui_ctx.LastItemData.InFlags & IG.ImGuiItemFlags_Disabled) != 0
end

function InfoMarker(message::AbstractString, marker::AbstractString="?")
    IG.TextDisabled("[$(marker)]")
    if IG.IsItemHovered() && IG.BeginTooltip()
        IG.Text(message)
        IG.EndTooltip()
    end
end

end
