mutable struct SafeInputTextState
    buffer::Vector{UInt8}
    reference_text::String
end

function SafeInputTextState(max_len::Int, reference_text::String)
    buffer = zeros(UInt8, max_len + 1) # Add 1 for the null pointer
    SafeInputTextState(buffer, reference_text)
end

const safe_input_text_cache = Dict{UInt32, SafeInputTextState}()


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

function SafeInputText(label; max_len=63, hint="", current_text="", password=false, reset=false)
    id = ig.GetID(label)
    if !haskey(safe_input_text_cache, id) || reset
        safe_input_text_cache[id] = SafeInputTextState(max_len, current_text)
        Util.strcpy!(safe_input_text_cache[id].buffer, current_text)
    end

    state = safe_input_text_cache[id]

    if state.reference_text != current_text
        state.reference_text = current_text
        Util.strcpy!(state.buffer, current_text)
    end

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

function BorderedText(text; color=IM_COL32(255, 0, 0, 255), thickness=2.0, padding=ImVec2(4, 4))
    draw_list = ig.GetWindowDrawList()
    cursor = ig.GetCursorScreenPos()
    text_size = ig.CalcTextSize(text)
    p_min = ImVec2(cursor.x - padding.x, cursor.y - padding.y)
    p_max = ImVec2(cursor.x + text_size.x + padding.x, cursor.y + text_size.y + padding.y)
    ig.AddRect(draw_list, p_min, p_max, color, 0.0, 0, thickness)
    ig.Text(text)
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

@enum ElidedEditState begin
    ElidedEditState_NoEdit
    ElidedEditState_WantEdit
    ElidedEditState_Edit
end

const elided_text_editing = Dict{UInt32, ElidedEditState}()

function ElidedText(label::AbstractString, text::AbstractString; max_chars::Int=30, editable::Bool=false)
    id = ig.GetID(label)
    state = get(elided_text_editing, id, ElidedEditState_NoEdit)

    if editable && state != ElidedEditState_NoEdit
        just_started = state == ElidedEditState_WantEdit
        if just_started
            ig.SetKeyboardFocusHere()
            elided_text_editing[id] = ElidedEditState_Edit
        end
        ig.SetNextItemWidth(ig.CalcTextSize(text).x + 40)
        edited, new_text = SafeInputText("##elided-$(label)"; current_text=text, reset=just_started)
        lost_focus = ig.IsItemDeactivated() && !ig.IsItemActive()
        if edited
            elided_text_editing[id] = ElidedEditState_NoEdit
            if new_text != text && !isempty(new_text)
                return true, new_text
            end
        elseif ig.IsKeyPressed(ig.ImGuiKey_Escape) || lost_focus
            elided_text_editing[id] = ElidedEditState_NoEdit
        end
    else
        elide = length(text) > max_chars
        display_text = elide ? text[1:max_chars] * "…" : text

        if editable
            text_size = ig.CalcTextSize(display_text)
            padding = ImVec2(2, 2)
            cursor = ig.GetCursorPos()
            ig.SetCursorPos(ImVec2(cursor.x, cursor.y - padding.y))
            ig.InvisibleButton("##elided-btn-$(label)", ImVec2(text_size.x + 2 * padding.x, text_size.y + 2 * padding.y))
            hovered = ig.IsItemHovered()
            clicked = ig.IsItemClicked()

            draw_list = ig.GetWindowDrawList()
            p_min = ig.GetItemRectMin()
            p_max = ig.GetItemRectMax()
            if hovered
                ig.AddRectFilled(draw_list, p_min, p_max, ig.IM_COL32(60, 60, 80, 255))
            end
            text_pos = ImVec2(p_min.x + padding.x, p_min.y + padding.y)
            ig.AddText(draw_list, text_pos, ig.GetColorU32(ig.ImGuiCol_Text), display_text)

            if hovered && elide
                ig.SetTooltip(text)
            end
            if clicked
                elided_text_editing[id] = ElidedEditState_WantEdit
            end
        else
            ig.Text(display_text)
            if ig.IsItemHovered() && elide
                ig.SetTooltip(text)
            end
        end
    end

    return false, text
end

ElidedText(text::AbstractString; max_chars::Int=30) = ElidedText("", text; max_chars)

function InfoMarker(message::AbstractString, marker::AbstractString="?")
    ig.TextDisabled("[$(marker)]")
    if ig.IsItemHovered() && ig.BeginTooltip()
        ig.Text(message)
        ig.EndTooltip()
    end
end

function CopyButton(label, text)
    ig.PushStyleVar(ig.ImGuiStyleVar_FramePadding, ImVec2(1, 1))
    ig.PushStyleVar(ig.ImGuiStyleVar_FrameBorderSize, 0)
    ig.PushStyleColor(ig.ImGuiCol_Button, ImVec4(0, 0, 0, 0))
    ig.PushStyleColor(ig.ImGuiCol_ButtonActive, ImVec4(0, 0, 0, 0))
    if ig.Button("\uf0c5##$(label)")
        ig.SetClipboardText(text)
    end
    ig.PopStyleColor(2)
    ig.PopStyleVar(2)
end

# A combo box where each item has a copy-to-clipboard button. Also shows a copy
# button on the combo preview when hovered. Returns true if the selection
# changed.
function CopyableCombo(label, items, selected_idx::Ref{Cint})
    changed = false
    sel = selected_idx[] + 1
    preview = 1 <= sel <= length(items) ? items[sel] : ""

    copy_btn_w = ig.CalcTextSize("\uf0c5").x + unsafe_load(ig.GetStyle().FramePadding.x) * 2
    btn_h = ig.GetFontSize() + 2  # font size + CopyButton FramePadding.y * 2

    # AllowOverlap so the copy button overlaid on the preview can receive clicks
    ig.SetNextItemAllowOverlap()
    if ig.BeginCombo("##$label", preview)
        popup_w = ig.GetWindowSize().x
        for (i, name) in enumerate(items)
            # Each row is: [Selectable (full width)] [Text (overlaid)] [CopyButton (right-aligned)]
            # AllowOverlap lets the copy button receive clicks over the selectable
            ig.SetNextItemAllowOverlap()
            if ig.Selectable("##$label-$i")
                new_idx = i - 1
                if new_idx != selected_idx[]
                    selected_idx[] = new_idx
                    changed = true
                end
            end

            row_min = ig.GetItemRectMin()
            row_max = ig.GetItemRectMax()
            ig.SameLine(0, 0)
            ig.Text(name)

            # Right-align the copy button, accounting for window padding on both sides
            ig.SameLine(popup_w - copy_btn_w - unsafe_load(ig.GetStyle().WindowPadding.x) * 2)

            # Only show the copy button when hovering the row. Use IsMouseHoveringRect
            # over the selectable's rect so the button stays visible as the mouse
            # moves from the row text to the button (unlike IsItemHovered which flickers).
            if ig.IsMouseHoveringRect(row_min, ImVec2(row_max.x, row_max.y))
                CopyButton("$label-$i", name)
            else
                # Always reserve space to keep row height consistent
                ig.Dummy(ImVec2(copy_btn_w, btn_h))
            end
        end
        ig.EndCombo()
    end

    # Overlay a copy button inside the combo preview, just left of the dropdown arrow.
    # We move the cursor back into the combo's rect to position the button.
    combo_rect_min = ig.GetItemRectMin()
    combo_rect_max = ig.GetItemRectMax()
    combo_w = combo_rect_max.x - combo_rect_min.x
    combo_h = combo_rect_max.y - combo_rect_min.y
    arrow_w = ig.GetFrameHeight()
    save_cursor = ig.GetCursorPos()
    ig.SameLine(0, 0)
    ig.SetCursorPosX(ig.GetCursorPosX() - arrow_w - copy_btn_w - 4)
    ig.SetCursorPosY(ig.GetCursorPosY() + (combo_h - btn_h) / 2)
    if ig.IsMouseHoveringRect(combo_rect_min, combo_rect_max)
        CopyButton("$label-preview", preview)
    end

    # Restore the cursor and register the combo's right edge as the line position,
    # so the caller's SameLine() places content after the combo, not the overlay button.
    ig.SetCursorPos(save_cursor)
    ig.SameLine(0, 0)
    ig.SetCursorPosX(combo_rect_min.x - ig.GetWindowPos().x + combo_w)
    ig.NewLine()

    return changed
end
