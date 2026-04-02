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

function SafeInputText(label; max_len=63, hint="", current_text="", password=false, reset=false,
                       callback=C_NULL, user_data=C_NULL)
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
    if callback !== C_NULL
        flags |= ig.ImGuiInputTextFlags_CallbackAlways
    end

    modified = unsafe_string(pointer(state.buffer)) != current_text

    if modified
        ig.PushStyleColor(ig.ImGuiCol_FrameBg, ig.IM_COL32(143, 98, 0, 255))
    end
    ret = ig.InputTextWithHint(label, hint, pointer(state.buffer), length(state.buffer),
                               flags, callback, user_data)
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

"""
    fuzzy_match(query, text) -> (matches::Bool, score::Int)

Simple fuzzy match: checks if all characters in `query` appear in `text` in
order (case-insensitive). Score is based on consecutive matches and early
positions.
"""
function fuzzy_match(query::AbstractString, text::AbstractString)
    q = lowercase(query)
    t = lowercase(text)
    qi = 1
    score = 0
    prev_match_pos = 0

    for (ti, tc) in enumerate(t)
        qi > length(q) && break
        if tc == q[qi]
            # Bonus for consecutive matches and early positions
            score += (ti == prev_match_pos + 1) ? 10 : 1
            score += max(0, length(t) - ti)
            prev_match_pos = ti
            qi += 1
        end
    end

    return qi > length(q), score
end

"""
    fuzzy_match(query, completions, completion_text; n=20)

Fuzzy-match `query` against `completions`, returning the top `n` results sorted
by score (descending). Uses a partial sort to avoid scoring more than necessary.
"""
function fuzzy_match(query::AbstractString, completions::AbstractVector, completion_text::Base.Callable; n=40)
    scored = Tuple{Int, Any}[]
    for item in completions
        matched, score = fuzzy_match(query, completion_text(item))
        matched || continue
        if length(scored) < n
            push!(scored, (score, item))
        elseif score > first(scored[1])
            scored[1] = (score, item)
            sort!(scored; by=first)  # keep min at front for cheap replacement
        end
    end

    return scored
end

"""
Default completion renderer: just renders the text of the completion as a
Selectable.
"""
function default_completion_renderer(completion, idx, is_selected)
    ig.Selectable(completion, is_selected)
end

const _autocomplete_selected_idx = Dict{UInt32, Int}()

"""
    draw_autocomplete_popup(label, query, completions, completion_text,
                            completion_renderer) -> Union{Nothing, String}

Draw the autocomplete popup below the current item. Returns the selected
completion text if one was chosen, `nothing` otherwise.

- `completions`: iterable of completion items (any type)
- `completion_text(item) -> String`: extracts the text to match against and to
  return on selection
- `completion_renderer(item, index, is_selected)`: draws a single completion row
"""
function draw_autocomplete_popup(label, query, completions, completion_text,
                                 completion_renderer)
    popup_label = "##autocomplete-$(label)"
    id = ig.GetID(label)

    scored = fuzzy_match(query, completions, completion_text)

    selected_idx = get(_autocomplete_selected_idx, id, 1)
    result = nothing
    popup_hovered = false

    if !isempty(scored)
        # Position popup below the input
        input_min = ig.GetItemRectMin()
        input_max = ig.GetItemRectMax()
        row_height = ig.GetTextLineHeightWithSpacing()
        max_rows = 8
        popup_height = min(length(scored), max_rows) * row_height + 2 * unsafe_load(ig.GetStyle().WindowPadding.y)
        popup_width = 600

        ig.SetNextWindowPos(ImVec2(input_min.x, input_max.y))
        ig.SetNextWindowSize(ImVec2(popup_width, popup_height))

        flags = ig.ImGuiWindowFlags_NoTitleBar | ig.ImGuiWindowFlags_NoResize |
                ig.ImGuiWindowFlags_NoMove | ig.ImGuiWindowFlags_NoFocusOnAppearing |
                ig.ImGuiWindowFlags_NoSavedSettings | ig.ImGuiWindowFlags_Tooltip

        if ig.Begin(popup_label, C_NULL, flags)
            popup_hovered = ig.IsWindowHovered() || ig.IsWindowFocused()

            # Keyboard navigation
            if ig.IsKeyPressed(ig.ImGuiKey_DownArrow)
                selected_idx = min(selected_idx + 1, length(scored))
            elseif ig.IsKeyPressed(ig.ImGuiKey_UpArrow)
                selected_idx = max(selected_idx - 1, 1)
            end

            for (i, (_, item)) in enumerate(scored)
                is_selected = (i == selected_idx)
                ig.PushID(i)
                if completion_renderer(item, i, is_selected)
                    result = completion_text(item)
                end
                if is_selected && (ig.IsKeyPressed(ig.ImGuiKey_Tab) || ig.IsKeyPressed(ig.ImGuiKey_Enter))
                    result = completion_text(item)
                end
                ig.PopID()
            end

            ig.End()
        end
    end

    selected_idx = clamp(selected_idx, 1, max(length(scored), 1))
    _autocomplete_selected_idx[id] = selected_idx

    return result, popup_hovered
end

function ElidedText(label::AbstractString, text::AbstractString;
                    max_chars::Int=30, editable::Bool=false,
                    completions=nothing,
                    completion_text::Function=string,
                    completion_renderer::Function=default_completion_renderer,
                    callback=C_NULL, user_data=C_NULL)
    id = ig.GetID(label)
    state = get(elided_text_editing, id, ElidedEditState_NoEdit)

    if editable && state != ElidedEditState_NoEdit
        just_started = state == ElidedEditState_WantEdit
        if just_started
            ig.SetKeyboardFocusHere()
            elided_text_editing[id] = ElidedEditState_Edit
            _autocomplete_selected_idx[id] = 1
        end
        ig.SetNextItemWidth(ig.CalcTextSize(text).x + 40)
        edited, new_text = SafeInputText("##elided-$(label)"; current_text=text, reset=just_started,
                                         callback, user_data)
        lost_focus = !just_started && ig.IsItemDeactivated() && !ig.IsItemActive()

        # Draw autocomplete popup if completions are provided
        ac_result = nothing
        ac_hovered = false
        if !isnothing(completions)
            ac_completions, ac_text_fn, ac_renderer, ac_query = if completions isa Base.Callable
                completions(new_text)
            else
                (completions, completion_text, completion_renderer, new_text)
            end
            ac_result, ac_hovered = draw_autocomplete_popup(label, ac_query, ac_completions,
                                                            ac_text_fn, ac_renderer)
        end

        if !isnothing(ac_result)
            # Autocomplete selection takes priority
            elided_text_editing[id] = ElidedEditState_NoEdit
            delete!(_autocomplete_selected_idx, id)
            return true, ac_result
        elseif edited
            elided_text_editing[id] = ElidedEditState_NoEdit
            delete!(_autocomplete_selected_idx, id)
            if new_text != text && !isempty(new_text)
                return true, new_text
            end
        elseif ig.IsKeyPressed(ig.ImGuiKey_Escape)
            elided_text_editing[id] = ElidedEditState_NoEdit
            delete!(_autocomplete_selected_idx, id)
        elseif lost_focus && !ac_hovered
            elided_text_editing[id] = ElidedEditState_NoEdit
            delete!(_autocomplete_selected_idx, id)
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

mutable struct KaraboDepTextState
    override_text::String
    cursor_pos::Cint
    device::Maybe{String}
    # If >= 0, the callback will move the cursor to this position and clear the
    # selection on the next frame, then reset to -1.
    wanted_cursor_pos::Cint
end

KaraboDepTextState() = KaraboDepTextState("", -1, nothing, -1)


function dep_text_callback(callback_data::Ptr{ig.ImGuiInputTextCallbackData})::Cint
    user_data_ptr = unsafe_load(callback_data.UserData)
    state::KaraboDepTextState = unsafe_pointer_to_objref(user_data_ptr)

    state.cursor_pos = unsafe_load(callback_data.CursorPos)

    if state.wanted_cursor_pos >= 0
        pos = state.wanted_cursor_pos
        state.wanted_cursor_pos = -1
        callback_data.CursorPos = pos
        callback_data.SelectionStart = pos
        callback_data.SelectionEnd = pos
    end

    return 0
end

function device_completion_renderer(item, i, selected)
    name, topic = item
    clicked = ig.Selectable("##device-$i", selected)
    ig.SameLine(0, 0)
    ig.Text(name)
    ig.SameLine()
    ig.TextDisabled("($topic)")
    return clicked
end

function property_completion_renderer(item, i, selected)
    clicked = ig.Selectable("##prop-$i", selected)
    ig.SameLine(0, 0)
    ig.Text(item)
    return clicked
end

"""
    KaraboDepText(label, text, dep_state, device_list, property_completions)
        -> (edited::Bool, new_text::String)

Editable text for KaraboDependency fields with autocompletion. Completions
switch automatically based on cursor position: if the cursor is before the dot,
device name completions are shown; if after, property completions are shown.
When a device is selected from completions (no dot in the result), a dot is
appended and the widget stays in edit mode for property entry.

The caller manages the `KaraboDepTextState` and should check `dep_state.device`
after each call to determine which device property completions are needed for,
passing them via `property_completions` on the next frame.
"""
function KaraboDepText(label, text, dep_state::KaraboDepTextState,
                       device_list, property_completions)
    id = ig.GetID(label)
    current_text = isempty(dep_state.override_text) ? text : dep_state.override_text

    cb = @cfunction(dep_text_callback, Cint, (Ptr{ig.ImGuiInputTextCallbackData},))

    edited, new_text = ElidedText(label, current_text;
        editable=true,
        callback=cb,
        user_data=pointer_from_objref(dep_state),
        completions=input -> begin
            di = findfirst('.', input)
            cursor = dep_state.cursor_pos
            cursor_after_dot = !isnothing(di) && cursor >= 0 && cursor > di - 1

            if isnothing(di) || !cursor_after_dot
                query = isnothing(di) ? input : input[1:di-1]
                (device_list, first, device_completion_renderer, query)
            else
                dev = @view input[1:di-1]
                query = @view input[di+1:end]
                (property_completions, prop -> "$(dev).$(prop)", property_completion_renderer, query)
            end
        end)

    # Update the device field based on current text and cursor position
    dot_idx = findfirst('.', isempty(dep_state.override_text) ? (edited ? new_text : current_text) : dep_state.override_text)
    cur = dep_state.cursor_pos
    if !isnothing(dot_idx) && cur >= 0 && cur > dot_idx - 1
        dep_state.device = current_text[1:dot_idx-1]
    else
        dep_state.device = nothing
    end

    if edited
        if isnothing(findfirst('.', new_text))
            # Device selected — append dot and stay in edit mode for property
            dot_idx = findfirst('.', current_text)
            property_suffix = if !isnothing(dot_idx)
                current_text[dot_idx:end]
            else
                "."
            end
            dep_state.override_text = new_text * property_suffix
            dep_state.device = new_text
            dep_state.wanted_cursor_pos = ncodeunits(dep_state.override_text)
            elided_text_editing[id] = ElidedEditState_WantEdit
            return false, text
        else
            dep_state.override_text = ""
            dep_state.cursor_pos = -1
            dep_state.device = nothing
            return true, new_text
        end
    end

    # Clean up state when editing is dismissed
    if get(elided_text_editing, id, ElidedEditState_NoEdit) == ElidedEditState_NoEdit
        dep_state.override_text = ""
        dep_state.cursor_pos = -1
        dep_state.device = nothing
    end

    return false, text
end
