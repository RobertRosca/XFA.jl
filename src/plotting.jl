# --- GPU-accelerated heatmap rendering ---
#
# Ported from epezent/implot#254 (backends branch). Instead of using ImPlot's
# CPU-side PlotHeatmap, we render colormapped data on the GPU via an FBO and
# display the result with ImPlot.PlotImage, preserving full axes/zoom/pan.
#
# Architecture:
#   HeatmapContext (module singleton) — shared GPU resources: shaders, colormap
#       texture, and a fullscreen quad. Lazily initialized on first matrix plot.
#   GPUHeatmap (per-plot) — data texture, colormapped output texture, and FBO.
#
# Pipeline per frame (when data changes):
#   1. Upload matrix data to a single-channel 2D texture (R32F / R32I / etc.)
#   2. Render a fullscreen quad into the FBO, sampling the data texture and a
#      1D colormap texture to produce an RGBA output texture
#   3. Display the output texture via ImPlot.PlotImage

# --- Shaders ---
#
# The vertex shader draws a fullscreen quad (two triangles). The fragment shader
# normalizes the heatmap value to [0,1] using min/max uniforms, then samples a
# 1D colormap texture. Two fragment variants exist: one for float data
# (sampler2D) and one for integer data (isampler2D).

const HEATMAP_VERTEX_SHADER = """
#version 330 core
layout (location = 0) in vec2 Position;
layout (location = 1) in vec2 UV;
out vec2 Frag_UV;
void main() {
    Frag_UV = UV;
    gl_Position = vec4(Position, 0.0, 1.0);
}
"""

const HEATMAP_FRAGMENT_FLOAT = """
#version 330 core
precision mediump float;
in vec2 Frag_UV;
out vec4 Out_Color;
uniform sampler1D colormap;
uniform sampler2D heatmap;
uniform float min_val;
uniform float max_val;
void main() {
    float value = float(texture(heatmap, Frag_UV).r);
    // NaN pixels become fully transparent
    if (isnan(value)) {
        Out_Color = vec4(0.0, 0.0, 0.0, 0.0);
        return;
    }
    // Half-texel inset avoids sampling beyond the colormap edges
    float min_tex_offs = 0.5 / float(textureSize(colormap, 0));
    float offset = (value - min_val) / (max_val - min_val);
    offset = mix(min_tex_offs, 1.0 - min_tex_offs, clamp(offset, 0.0, 1.0));
    Out_Color = texture(colormap, offset);
}
"""

const HEATMAP_FRAGMENT_INT = """
#version 330 core
precision mediump float;
in vec2 Frag_UV;
out vec4 Out_Color;
uniform sampler1D colormap;
uniform isampler2D heatmap;
uniform float min_val;
uniform float max_val;
void main() {
    float min_tex_offs = 0.5 / float(textureSize(colormap, 0));
    float value = float(texture(heatmap, Frag_UV).r);
    float offset = (value - min_val) / (max_val - min_val);
    offset = mix(min_tex_offs, 1.0 - min_tex_offs, clamp(offset, 0.0, 1.0));
    Out_Color = texture(colormap, offset);
}
"""

# --- GL helpers ---

"""Compile a GLSL shader from source, raising on error."""
function compile_shader(source::String, type::GLenum)
    shader = glCreateShader(type)
    glShaderSource(shader, 1, Ref(pointer(source)), C_NULL)
    glCompileShader(shader)
    status = Ref{GLint}(0)
    glGetShaderiv(shader, GL_COMPILE_STATUS, status)
    if status[] != GL_TRUE
        log_len = Ref{GLint}(0)
        glGetShaderiv(shader, GL_INFO_LOG_LENGTH, log_len)
        log_buf = Vector{UInt8}(undef, log_len[])
        glGetShaderInfoLog(shader, log_len[], C_NULL, pointer(log_buf))
        error("Shader compilation failed: $(String(log_buf))")
    end
    return shader
end

"""Link a vertex + fragment shader into a program, raising on error."""
function link_program(vertex::GLuint, fragment::GLuint)
    program = glCreateProgram()
    glAttachShader(program, vertex)
    glAttachShader(program, fragment)
    glLinkProgram(program)
    status = Ref{GLint}(0)
    glGetProgramiv(program, GL_LINK_STATUS, status)
    if status[] != GL_TRUE
        log_len = Ref{GLint}(0)
        glGetProgramiv(program, GL_INFO_LOG_LENGTH, log_len)
        log_buf = Vector{UInt8}(undef, log_len[])
        glGetProgramInfoLog(program, log_len[], C_NULL, pointer(log_buf))
        error("Program link failed: $(String(log_buf))")
    end
    return program
end

# --- Shared GPU state (module singleton) ---

"""
Shared GPU resources for heatmap rendering, created once and reused across all
plots. Contains compiled shader programs (float + integer variants), a 1D
colormap texture sampled from ImPlot, and a fullscreen quad VAO/VBO.
"""
mutable struct HeatmapContext
    # Shader programs — float variant uses sampler2D, int uses isampler2D
    shader_float::GLuint
    shader_int::GLuint

    # Uniform locations for each shader variant
    loc_min_float::GLint
    loc_max_float::GLint
    loc_heatmap_float::GLint
    loc_colormap_float::GLint

    loc_min_int::GLint
    loc_max_int::GLint
    loc_heatmap_int::GLint
    loc_colormap_int::GLint

    # 1D RGBA8 texture (256 entries) built from ImPlot's active colormap
    colormap_tex::GLuint
    colormap_id::Int  # which ImPlot colormap is currently uploaded (-1 = none)

    # Fullscreen quad geometry for FBO rendering
    vao::GLuint
    vbo::GLuint
end

function create_heatmap_context()
    # Compile vertex shader (shared between float and int variants)
    vert = compile_shader(HEATMAP_VERTEX_SHADER, GL_VERTEX_SHADER)

    frag_f = compile_shader(HEATMAP_FRAGMENT_FLOAT, GL_FRAGMENT_SHADER)
    shader_float = link_program(vert, frag_f)
    glDeleteShader(frag_f)

    frag_i = compile_shader(HEATMAP_FRAGMENT_INT, GL_FRAGMENT_SHADER)
    shader_int = link_program(vert, frag_i)
    glDeleteShader(frag_i)

    glDeleteShader(vert)

    # Cache uniform locations for both shader variants
    loc_min_float = glGetUniformLocation(shader_float, "min_val")
    loc_max_float = glGetUniformLocation(shader_float, "max_val")
    loc_heatmap_float = glGetUniformLocation(shader_float, "heatmap")
    loc_colormap_float = glGetUniformLocation(shader_float, "colormap")

    loc_min_int = glGetUniformLocation(shader_int, "min_val")
    loc_max_int = glGetUniformLocation(shader_int, "max_val")
    loc_heatmap_int = glGetUniformLocation(shader_int, "heatmap")
    loc_colormap_int = glGetUniformLocation(shader_int, "colormap")

    # Allocate colormap texture (filled lazily by update_colormap!)
    colormap_tex_ref = Ref{GLuint}(0)
    glGenTextures(1, colormap_tex_ref)
    colormap_tex = colormap_tex_ref[]

    # Build a fullscreen quad: two triangles covering [-1,1] in clip space.
    # UV is flipped vertically (v=1 at bottom, v=0 at top) so that row 0 of
    # the matrix appears at the top of the image.
    #   Each vertex: (x, y, u, v)
    quad_vertices = Float32[
        -1, -1, 0, 1,  # bottom-left
         1, -1, 1, 1,  # bottom-right
        -1,  1, 0, 0,  # top-left
         1, -1, 1, 1,  # bottom-right
         1,  1, 1, 0,  # top-right
        -1,  1, 0, 0,  # top-left
    ]

    vao_ref = Ref{GLuint}(0)
    vbo_ref = Ref{GLuint}(0)
    glGenVertexArrays(1, vao_ref)
    glGenBuffers(1, vbo_ref)
    vao = vao_ref[]
    vbo = vbo_ref[]

    glBindVertexArray(vao)
    glBindBuffer(GL_ARRAY_BUFFER, vbo)
    glBufferData(GL_ARRAY_BUFFER, sizeof(quad_vertices), quad_vertices, GL_STATIC_DRAW)
    stride = 4 * sizeof(Float32)
    # layout(location = 0) — position
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, stride, C_NULL)
    glEnableVertexAttribArray(0)
    # layout(location = 1) — UV
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, stride, Ptr{Cvoid}(2 * sizeof(Float32)))
    glEnableVertexAttribArray(1)
    glBindVertexArray(0)
    glBindBuffer(GL_ARRAY_BUFFER, 0)

    return HeatmapContext(
        shader_float, shader_int,
        loc_min_float, loc_max_float, loc_heatmap_float, loc_colormap_float,
        loc_min_int, loc_max_int, loc_heatmap_int, loc_colormap_int,
        colormap_tex, -1,
        vao, vbo,
    )
end

function destroy!(ctx::HeatmapContext)
    glDeleteProgram(ctx.shader_float)
    glDeleteProgram(ctx.shader_int)
    tex_ref = Ref(ctx.colormap_tex)
    glDeleteTextures(1, tex_ref)
    vao_ref = Ref(ctx.vao)
    vbo_ref = Ref(ctx.vbo)
    glDeleteVertexArrays(1, vao_ref)
    glDeleteBuffers(1, vbo_ref)
end

"""
Re-upload the 1D colormap texture if the active ImPlot colormap has changed.
Samples 256 points from the colormap and uploads as GL_RGBA8 with linear
filtering (smooth gradient between color stops).
"""
function update_colormap!(ctx::HeatmapContext, cmap::ImPlot.ImPlotColormap_)
    ctx.colormap_id == cmap && return

    n = 256
    pixels = Vector{UInt8}(undef, n * 4)
    for i in 0:n-1
        t = i / (n - 1)
        col = ImPlot.SampleColormap(t, cmap)
        idx = i * 4
        pixels[idx + 1] = round(UInt8, clamp(col.x, 0, 1) * 255)
        pixels[idx + 2] = round(UInt8, clamp(col.y, 0, 1) * 255)
        pixels[idx + 3] = round(UInt8, clamp(col.z, 0, 1) * 255)
        pixels[idx + 4] = round(UInt8, clamp(col.w, 0, 1) * 255)
    end

    glBindTexture(GL_TEXTURE_1D, ctx.colormap_tex)
    glTexImage1D(GL_TEXTURE_1D, 0, GL_RGBA8, n, 0, GL_RGBA, GL_UNSIGNED_BYTE, pixels)
    glTexParameteri(GL_TEXTURE_1D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_1D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
    glTexParameteri(GL_TEXTURE_1D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    glBindTexture(GL_TEXTURE_1D, 0)

    ctx.colormap_id = cmap
end

# Lazily initialized module-level singleton
const _heatmap_ctx = Ref{Union{Nothing, HeatmapContext}}(nothing)

function get_heatmap_context()
    if isnothing(_heatmap_ctx[])
        _heatmap_ctx[] = create_heatmap_context()
    end
    return _heatmap_ctx[]
end

"""Destroy shared heatmap GPU resources. Call before tearing down the GL context."""
function destroy_heatmap_context!()
    if !isnothing(_heatmap_ctx[])
        destroy!(_heatmap_ctx[])
        _heatmap_ctx[] = nothing
    end
end

# --- Per-plot GPU state ---

"""
Per-plot GPU resources for heatmap rendering:
- `data_tex`:   single-channel 2D texture holding the raw matrix data
- `output_tex`: RGBA8 2D texture holding the colormapped result (fed to PlotImage)
- `fbo`:        framebuffer targeting output_tex for off-screen rendering
"""
mutable struct GPUHeatmap
    data_tex::GLuint
    output_tex::GLuint
    fbo::GLuint
    width::Int
    height::Int
    is_integer::Bool
    # Reusable buffer for data that needs conversion (e.g. Float64 → Float32).
    # Avoids allocating a new array every frame.
    convert_buf::Vector{UInt8}
    # Cached scale limits for the colorbar (1st/99th percentile)
    scale_min::Float64
    scale_max::Float64
end

function GPUHeatmap()
    tex_refs = Ref{GLuint}(0)

    glGenTextures(1, tex_refs)
    data_tex = tex_refs[]

    glGenTextures(1, tex_refs)
    output_tex = tex_refs[]

    fbo_ref = Ref{GLuint}(0)
    glGenFramebuffers(1, fbo_ref)
    fbo = fbo_ref[]

    return GPUHeatmap(data_tex, output_tex, fbo, 0, 0, false, UInt8[], 0.0, 1.0)
end

function destroy!(h::GPUHeatmap)
    for tex in (h.data_tex, h.output_tex)
        tex_ref = Ref(tex)
        glDeleteTextures(1, tex_ref)
    end
    fbo_ref = Ref(h.fbo)
    glDeleteFramebuffers(1, fbo_ref)
end

# --- Data type mapping ---
#
# Maps Julia eltypes to GL format tuples:
#   (internal_format, pixel_format, pixel_type, is_integer)
# Types without direct GL equivalents (Float64, Int64, UInt64) are converted
# to their 32-bit counterparts by prepare_data() before upload.

gl_format(::Type{Float32}) = (GL_R32F,  GL_RED,         GL_FLOAT,          false)
gl_format(::Type{Int32})   = (GL_R32I,  GL_RED_INTEGER, GL_INT,            true)
gl_format(::Type{UInt32})  = (GL_R32UI, GL_RED_INTEGER, GL_UNSIGNED_INT,   true)
gl_format(::Type{Int16})   = (GL_R16I,  GL_RED_INTEGER, GL_SHORT,          true)
gl_format(::Type{UInt16})  = (GL_R16UI, GL_RED_INTEGER, GL_UNSIGNED_SHORT, true)
gl_format(::Type{Int8})    = (GL_R8I,   GL_RED_INTEGER, GL_BYTE,           true)
gl_format(::Type{UInt8})   = (GL_R8UI,  GL_RED_INTEGER, GL_UNSIGNED_BYTE,  true)

# Target GL type for eltypes that need conversion
gl_convert_type(::Type{Float64}) = Float32
gl_convert_type(::Type{Int64})   = Int32
gl_convert_type(::Type{UInt64})  = UInt32
gl_convert_type(::Type)          = Float32  # fallback

# Types that can be uploaded directly without conversion
const GLNativeTypes = Union{Float32, Int32, UInt32, Int16, UInt16, Int8, UInt8}

"""
Convert matrix data into the reusable `convert_buf`, reinterpreted as a matrix
of the target GL type. Returns either the original data (if no conversion
needed) or a zero-copy view over the resized buffer.
"""
function prepare_data!(h::GPUHeatmap, data::AbstractMatrix{T}) where T
    if T <: GLNativeTypes
        return data
    end

    # Convert into the cached byte buffer to avoid per-frame allocations
    G = gl_convert_type(T)
    nbytes = length(data) * sizeof(G)
    resize!(h.convert_buf, nbytes)
    buf = unsafe_wrap(Matrix{G}, Ptr{G}(pointer(h.convert_buf)), size(data))
    copyto!(buf, data)

    return buf
end

"""
Upload matrix data to the GPU data texture. Converts to a GL-compatible type if
needed (reusing an internal buffer), then uploads as a single-channel 2D
texture. Resizes the output texture and re-attaches the FBO if dimensions changed.
"""
function upload_data!(h::GPUHeatmap, data::AbstractMatrix)
    gpu_data = prepare_data!(h, data)
    T = eltype(gpu_data)
    internal_fmt, pixel_fmt, pixel_type, is_integer = gl_format(T)

    rows, cols = size(gpu_data)
    h.is_integer = is_integer

    # Upload raw data to the single-channel data texture
    glBindTexture(GL_TEXTURE_2D, h.data_tex)
    # Julia matrices are column-major; GL reads column-major too, so we pass
    # cols as width and rows as height.
    glTexImage2D(GL_TEXTURE_2D, 0, internal_fmt, cols, rows, 0, pixel_fmt, pixel_type, gpu_data)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
    glBindTexture(GL_TEXTURE_2D, 0)

    # Resize the RGBA output texture and re-attach to FBO when dimensions change
    if h.width != cols || h.height != rows
        h.width = cols
        h.height = rows

        glBindTexture(GL_TEXTURE_2D, h.output_tex)
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, cols, rows, 0, GL_RGBA, GL_UNSIGNED_BYTE, C_NULL)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
        glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)
        glBindTexture(GL_TEXTURE_2D, 0)

        glBindFramebuffer(GL_FRAMEBUFFER, h.fbo)
        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, h.output_tex, 0)
        glBindFramebuffer(GL_FRAMEBUFFER, 0)
    end
end

"""
Render the colormapped heatmap into the output texture via the FBO. Binds the
data texture (unit 0) and colormap texture (unit 1), draws a fullscreen quad
with the appropriate shader, then restores the previous GL state so we don't
interfere with Dear ImGui's rendering.
"""
function render_colormapped!(h::GPUHeatmap, ctx::HeatmapContext, min_val, max_val)
    h.width == 0 && return

    # Save GL state that we'll modify (Dear ImGui expects these unchanged)
    prev_program = Ref{GLint}(0)
    prev_fbo = Ref{GLint}(0)
    prev_viewport = Vector{GLint}(undef, 4)
    glGetIntegerv(GL_CURRENT_PROGRAM, prev_program)
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, prev_fbo)
    glGetIntegerv(GL_VIEWPORT, prev_viewport)

    # Set up off-screen render target
    glBindFramebuffer(GL_FRAMEBUFFER, h.fbo)
    glViewport(0, 0, h.width, h.height)

    # Activate the appropriate shader and set uniforms
    if h.is_integer
        glUseProgram(ctx.shader_int)
        glUniform1f(ctx.loc_min_int, Float32(min_val))
        glUniform1f(ctx.loc_max_int, Float32(max_val))
        glUniform1i(ctx.loc_heatmap_int, 0)
        glUniform1i(ctx.loc_colormap_int, 1)
    else
        glUseProgram(ctx.shader_float)
        glUniform1f(ctx.loc_min_float, Float32(min_val))
        glUniform1f(ctx.loc_max_float, Float32(max_val))
        glUniform1i(ctx.loc_heatmap_float, 0)
        glUniform1i(ctx.loc_colormap_float, 1)
    end

    # Bind data texture to unit 0, colormap to unit 1
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, h.data_tex)
    glActiveTexture(GL_TEXTURE1)
    glBindTexture(GL_TEXTURE_1D, ctx.colormap_tex)

    # Render fullscreen quad
    glBindVertexArray(ctx.vao)
    glDrawArrays(GL_TRIANGLES, 0, 6)
    glBindVertexArray(0)

    # Restore previous GL state
    glActiveTexture(GL_TEXTURE0)
    glBindTexture(GL_TEXTURE_2D, 0)
    glActiveTexture(GL_TEXTURE1)
    glBindTexture(GL_TEXTURE_1D, 0)
    glBindFramebuffer(GL_FRAMEBUFFER, prev_fbo[])
    glUseProgram(prev_program[])
    glViewport(prev_viewport[1], prev_viewport[2], prev_viewport[3], prev_viewport[4])
end

# --- Plot struct with optional GPU heatmap ---

mutable struct Plot
    const name::String
    const id::String
    const open::Ref{Bool}
    const autoscale_x::Ref{Bool}
    const autoscale_y::Ref{Bool}
    const fixed_aspect::Ref{Bool}
    gpu_heatmap::Union{Nothing, GPUHeatmap}
    dock_id::UInt32
end

Plot(name, counter::Int) = Plot(name, "$(name)##plot-$(counter)")

Plot(name, id::String, dock_id = 0) = Plot(name, id, Ref(true), Ref(true), Ref(true), Ref(true), nothing, UInt32(dock_id))

function Base.close(plot::Plot)
    if !isnothing(plot.gpu_heatmap)
        destroy!(plot.gpu_heatmap)
        plot.gpu_heatmap = nothing
    end
end

clear_plot(::Plot) = nothing

function check_plot_interaction!(plot)
    io = ig.GetIO()
    mouse_wheel = unsafe_load(io.MouseWheel)
    dragging = ig.IsMouseDragging(ig.ImGuiMouseButton_Left)
    interacting = dragging || mouse_wheel != 0

    x_hovered = ImPlot.IsAxisHovered(ImPlot.ImAxis_X1)
    y_hovered = ImPlot.IsAxisHovered(ImPlot.ImAxis_Y1)
    plot_hovered = ImPlot.IsPlotHovered()

    # Disable autoscale on the axes being interacted with
    if interacting
        if plot_hovered
            plot.autoscale_x[] = false
            plot.autoscale_y[] = false
        elseif x_hovered
            plot.autoscale_x[] = false
        elseif y_hovered
            plot.autoscale_y[] = false
        end
    end

    # Double-click to re-enable autoscale
    if ig.IsMouseDoubleClicked(ig.ImGuiMouseButton_Left)
        if plot_hovered
            plot.autoscale_x[] = true
            plot.autoscale_y[] = true
        elseif x_hovered
            plot.autoscale_x[] = true
        elseif y_hovered
            plot.autoscale_y[] = true
        end
    end
end

"""Draw a small toggle button that appears highlighted when active."""
function toggle_button(label, active::Bool)
    if active
        ig.PushStyleColor(ig.ImGuiCol_Button, unsafe_load(ig.GetStyleColorVec4(ig.ImGuiCol_ButtonActive)))
    end
    clicked = ig.SmallButton(label)
    if active
        ig.PopStyleColor()
    end
    return clicked
end

"""Draw the autoscale toggle button group: [X] [Y] [XY]"""
function autoscale_buttons(plot)
    ig.AlignTextToFramePadding()
    ig.Text("Autoscale:")
    ig.SameLine()
    if toggle_button("X##$(plot.id)", plot.autoscale_x[])
        plot.autoscale_x[] = !plot.autoscale_x[]
    end
    ig.SameLine()
    if toggle_button("Y##$(plot.id)", plot.autoscale_y[])
        plot.autoscale_y[] = !plot.autoscale_y[]
    end
    ig.SameLine()
    both = plot.autoscale_x[] && plot.autoscale_y[]
    if toggle_button("XY##$(plot.id)", both)
        new_state = !both
        plot.autoscale_x[] = new_state
        plot.autoscale_y[] = new_state
    end
end

"""Call per-axis SetNextAxisToFit based on autoscale state."""
function apply_autoscale(plot)
    if plot.autoscale_x[] && plot.autoscale_y[]
        ImPlot.SetNextAxesToFit()
    elseif plot.autoscale_x[]
        ImPlot.SetNextAxisToFit(ImPlot.ImAxis_X1)
    elseif plot.autoscale_y[]
        ImPlot.SetNextAxisToFit(ImPlot.ImAxis_Y1)
    end
end

function draw_plot(plot::Plot, store::Nothing, was_updated)
    ig.SetNextWindowSize((800, 500), ig.ImGuiCond_FirstUseEver)

    if ig.Begin(plot.id, plot.open)
        plot.dock_id = ig.GetWindowDockID()
        ig.Text("Waiting for data: $(plot.name)")
    end

    ig.End()
end

function draw_plot(plot::Plot, store, was_updated)
    ig.SetNextWindowSize((800, 500), ig.ImGuiCond_FirstUseEver)

    data = store.data
    if ig.Begin(plot.id, plot.open)
        plot.dock_id = ig.GetWindowDockID()
        is_dimarray = data isa DimArray
        is_scalar = data isa CircularBuffer
        data_dims = is_dimarray ? DD.dims(data) : nothing
        xlabel = is_dimarray ? DD.label(data_dims[1]) : is_scalar ? "trainId" : ""
        label = is_dimarray ? DD.label(data) : plot.name

        apply_autoscale(plot)

        region_avail = ig.GetContentRegionAvail()
        plot_size = ImVec2(region_avail.x, max(region_avail.y - 30, 100))
        no_data = length(data) == 0

        if no_data
            ig.Text("Array has length 0, nothing to plot")
        elseif data isa AbstractVector
            if ImPlot.BeginPlot(plot.id, xlabel, "", plot_size)
                if is_scalar
                    tids = store.scalar_tids_cache
                    vals = store.scalar_data_cache
                    if length(vals) == 1
                        ImPlot.PlotScatter(label, tids, vals)
                    else
                        ImPlot.PlotLine(label, tids, vals)
                    end
                elseif length(data) == 1
                    if is_dimarray
                        ImPlot.PlotScatter(label, parent(lookup(data)[1]), parent(data))
                    else
                        ImPlot.PlotScatter(label, data)
                    end
                else
                    if is_dimarray
                        ImPlot.PlotLine(label, parent(lookup(data)[1]), parent(data))
                    else
                        ImPlot.PlotLine(label, data)
                    end
                end
                check_plot_interaction!(plot)
                ImPlot.EndPlot()
            end
        elseif data isa AbstractMatrix
            rows, cols = size(data)

            # Ensure GPU resources exist
            ctx = get_heatmap_context()
            needs_initial_upload = isnothing(plot.gpu_heatmap)
            if needs_initial_upload
                plot.gpu_heatmap = GPUHeatmap()
            end
            gpu = plot.gpu_heatmap

            # Update colormap if needed (use Viridis as default, index 4)
            update_colormap!(ctx, ImPlot.ImPlotColormap_Viridis)

            if was_updated || needs_initial_upload
                upload_data!(gpu, data)
                dmin = nanpctile(data, 1)
                dmin = !isfinite(dmin) ? 1.0 : dmin
                dmax = nanpctile(data, 99)
                dmax = !isfinite(dmax) ? 1.0 : dmax
                gpu.scale_min = dmin
                gpu.scale_max = dmax
                render_colormapped!(gpu, ctx, dmin, dmax)
            end

            # Reserve space for the colorbar on the right
            colorbar_width = 100
            plot_width = max(plot_size.x - colorbar_width, 100)

            plot_flags = plot.fixed_aspect[] ? ImPlot.ImPlotFlags_Equal : ImPlot.ImPlotFlags_None
            if ImPlot.BeginPlot(plot.id, ImVec2(plot_width, plot_size.y), plot_flags)
                tex_ref = ig.ImTextureRef(ig.ImTextureID(gpu.output_tex))
                ImPlot.PlotImage("", tex_ref,
                                 ImPlot.ImPlotPoint(0, rows),
                                 ImPlot.ImPlotPoint(cols, 0))

                # Show pixel coordinates and intensity when hovering
                if ImPlot.IsPlotHovered()
                    mouse = ImPlot.GetPlotMousePos()
                    col = floor(Int, mouse.x) + 1
                    row = rows - floor(Int, mouse.y)
                    if 1 <= col <= rows && 1 <= row <= cols
                        val = data[col, row]
                        ImPlot.AnnotationClamped(mouse.x, mouse.y,
                                                 ImVec2(10, -10),
                                                 "[$col, $row] $val")
                    end
                end

                check_plot_interaction!(plot)
                ImPlot.EndPlot()
            end

            ig.SameLine()
            ImPlot.ColormapScale("##colorbar_$(plot.id)",
                                 gpu.scale_min, gpu.scale_max,
                                 ImVec2(colorbar_width, plot_size.y),
                                 "%g",
                                 ImPlot.ImPlotColormapScaleFlags_None,
                                 ImPlot.ImPlotColormap_Viridis)
        end

        if !no_data
            autoscale_buttons(plot)

            if data isa AbstractMatrix
                ig.SameLine()
                ig.Checkbox("Fixed aspect", plot.fixed_aspect)
            end
        end
    end

    ig.End()
end

# --- Correlation plot ---

@kwdef mutable struct CorrelationPlot
    const id::String
    const open::Ref{Bool} = Ref(true)
    const variable_names::Vector{String} = String[]
    const x_var::Ref{Cint} = Ref(Cint(0))
    const y_var::Ref{Cint} = Ref(Cint(0))
    const x_data::Vector{Float64} = Float64[]
    const y_data::Vector{Float64} = Float64[]
    const autoscale_x::Ref{Bool} = Ref(true)
    const autoscale_y::Ref{Bool} = Ref(true)
    trainId::Int = -1
    dock_id::UInt32 = 0
end

function clear_plot(plot::CorrelationPlot)
    empty!(plot.x_data)
    empty!(plot.y_data)
end

function CorrelationPlot(counter::Integer)
    CorrelationPlot(; id="CorrelationPlot##plot-$(counter)")
end

function CorrelationPlot(id::String, dock_id::Integer = 0)
    CorrelationPlot(; id, dock_id=UInt32(dock_id))
end

Base.close(::CorrelationPlot) = nothing

function var_type_label(store)
    if store.type == VariableType_Scalar
        "scalar"
    elseif store.type == VariableType_Vector
        "vector"
    elseif store.type == VariableType_Array
        """array $(join(size(store.data), "×"))"""
    else
        ""
    end
end

function _var_combo(label, selected::Ref{Cint}, var_names, variable_data)
    n = length(var_names)
    preview = if n > 0
        name = var_names[selected[] + 1]
        type_label = var_type_label(variable_data[name])
        "$(name)  ($(type_label))"
    else
        ""
    end
    ig.SetNextItemWidth(250)

    changed = false
    if ig.BeginCombo(label, preview)
        for (i, name) in enumerate(var_names)
            if variable_data[name].type ∉ (VariableType_Scalar, VariableType_Vector)
                continue
            end

            is_selected = selected[] == i - 1
            if ig.Selectable(name, is_selected)
                selected[] = i - 1
                changed = true
            end

            ig.SameLine()

            ig.TextDisabled(var_type_label(variable_data[name]))
            if is_selected
                ig.SetItemDefaultFocus()
            end
        end

        ig.EndCombo()
    end

    return changed
end

function swap_arrays(x, y)
    for i in eachindex(x, y)
        x[i], y[i] = y[i], x[i]
    end
end

function draw_plot(plot::CorrelationPlot, variable_data, updated_variables)
    # Update variable names
    empty!(plot.variable_names)
    for (name, variable) in variable_data
        if variable.type in (VariableType_Scalar, VariableType_Vector)
            push!(plot.variable_names, name)
        end
    end
    sort!(plot.variable_names)

    ig.SetNextWindowSize((800, 500), ig.ImGuiCond_FirstUseEver)

    # Clamp indices to valid range
    n_variables = length(plot.variable_names)
    if n_variables > 0
        plot.x_var[] = clamp(plot.x_var[], 0, n_variables - 1)
        plot.y_var[] = clamp(plot.y_var[], 0, n_variables - 1)
    end

    if ig.Begin(plot.id, plot.open)
        plot.dock_id = ig.GetWindowDockID()
        if ig.Button("Swap axes")
            plot.x_var[], plot.y_var[] = plot.y_var[], plot.x_var[]
            swap_arrays(plot.x_data, plot.y_data)
        end

        ig.SameLine()
        x_changed = _var_combo("X", plot.x_var, plot.variable_names, variable_data)
        ig.SameLine()
        y_changed = _var_combo("Y", plot.y_var, plot.variable_names, variable_data)

        if x_changed || y_changed
            empty!(plot.x_data)
            empty!(plot.y_data)
        end

        region_avail = ig.GetContentRegionAvail()
        plot_size = ImVec2(region_avail.x, max(region_avail.y - 30, 100))

        if n_variables > 0
            x_name = plot.variable_names[plot.x_var[] + 1]
            y_name = plot.variable_names[plot.y_var[] + 1]
            x = variable_data[x_name]
            y = variable_data[y_name]

            if x.type != y.type
                ig.Text("Both variables must have the same type to correlate against each other.")
            else
                apply_autoscale(plot)

                if x.type == VariableType_Scalar
                    if haskey(updated_variables, x_name) || haskey(updated_variables, y_name)
                        new_tids = get(updated_variables, x_name, Set{Int}())
                        if haskey(updated_variables, y_name)
                            union!(new_tids, updated_variables[y_name])
                        end

                        for tid in new_tids
                            xi = findfirst(==(tid), x.scalar_tids)
                            yi = findfirst(==(tid), y.scalar_tids)
                            if !isnothing(xi) && !isnothing(yi)
                                push!(plot.x_data, x.data[xi])
                                push!(plot.y_data, y.data[yi])
                            end
                        end
                    end

                    if ImPlot.BeginPlot(plot.id, x_name, y_name, plot_size)
                        ImPlot.PushStyleVar(ImPlot.ImPlotStyleVar_FillAlpha, 0.5)
                        ImPlot.PlotScatter("$(x_name) vs $(y_name)", plot.x_data, plot.y_data)
                        ImPlot.PopStyleVar()
                        check_plot_interaction!(plot)
                        ImPlot.EndPlot()
                    end
                elseif x.type == VariableType_Vector
                    # Only update both buffers together when both variables have
                    # data from the same train.
                    needs_copy = x.type == VariableType_Vector && x.trainId == y.trainId && x.trainId != plot.trainId
                    if needs_copy
                        resize!(plot.x_data, length(x.data))
                        resize!(plot.y_data, length(y.data))
                        copyto!(plot.x_data, x.data)
                        copyto!(plot.y_data, y.data)
                        plot.trainId = x.trainId
                    end

                    if ImPlot.BeginPlot(plot.id, x_name, y_name, plot_size)
                        ImPlot.PushStyleVar(ImPlot.ImPlotStyleVar_FillAlpha, 0.5)
                        ImPlot.PlotScatter("$(x_name) vs $(y_name)", plot.x_data, plot.y_data)
                        ImPlot.PopStyleVar()
                        check_plot_interaction!(plot)
                        ImPlot.EndPlot()
                    end
                else
                    ig.Text("Unsupported correlation of data type '$(x.type)'")
                end

                autoscale_buttons(plot)
            end
        end

    end

    ig.End()
end
