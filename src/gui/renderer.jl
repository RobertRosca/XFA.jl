module Renderer

import ..ImNodes

import ImPlot
import CImGui
import LibCImGui as LCIG
import ImGuiGLFWBackend
import ImGuiOpenGLBackend as GLBackend
import ImGuiGLFWBackend.LibGLFW as GLFW


# Callback function for GLFW errors
error_callback(err::Exception) = @error "GLFW ERROR: code $(err.code) msg: $(err.description)"

const FontList = Vector{Tuple{String, Int}}

struct ImGuiApp
    window::Ptr{ImGuiGLFWBackend.GLFWwindow}
    imgui_ctx::Ptr{CImGui.ImGuiContext}
    implot_ctx::Ptr{ImPlot.ImPlotContext}
    imnodes_ctx::Ptr{ImNodes.ImNodesContext}
    glfw_ctx::ImGuiGLFWBackend.Context
    opengl_ctx::GLBackend.Context

    """Initialize the renderer and app state."""
    function ImGuiApp(; width=1280, height=720, title::AbstractString="Demo", fonts::FontList=FontList())
        # Setup GLFW error callback
        GLFW.glfwSetErrorCallback(Ref(error_callback))

        # Reset the window hints. Otherwise repeated calls to this function will
        # fail in mysterious ways, like the GLFW window not appearing and the render
        # loop getting stuck waiting for it to close.
        GLFW.glfwDefaultWindowHints()
        GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MAJOR, 3)
        glsl_version = -1
        if Sys.isapple()
            glsl_version = 150
            GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MINOR, 2)
            GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_PROFILE, GLFW.GLFW_OPENGL_CORE_PROFILE) # 3.2+ only
            GLFW.glfwWindowHint(GLFW.GLFW_OPENGL_FORWARD_COMPAT, GL_TRUE) # required on Mac
        else
            glsl_version = 130
            GLFW.glfwWindowHint(GLFW.GLFW_CONTEXT_VERSION_MINOR, 0)
        end

        # Create window
        window = GLFW.glfwCreateWindow(width, height, title, C_NULL, C_NULL)
        @assert window != C_NULL
        GLFW.glfwMakeContextCurrent(window)

        # Enable vsync
        GLFW.glfwSwapInterval(1)

        glfw_ctx = ImGuiGLFWBackend.create_context(window, install_callbacks = true)
        opengl_ctx = GLBackend.create_context(glsl_version)

        # Setup Dear ImGui context
        imgui_ctx = CImGui.CreateContext()
        CImGui.SetCurrentContext(imgui_ctx)

        # Setup ImPlot
        implot_ctx = ImPlot.CreateContext()
        ImPlot.SetImGuiContext(imgui_ctx)

        # Setup ImNodes
        imnodes_ctx = ImNodes.CreateContext()

        # Setup Dear ImGui style
        CImGui.StyleColorsDark()

        # Load fonts
        font_atlas = unsafe_load(CImGui.GetIO().Fonts)
        for (font, font_size) in fonts
            CImGui.AddFontFromFileTTF(font_atlas, font, font_size)
        end

        # Enable viewports before initializing the GLFW backend. This is necessary
        # because it does some extra steps during initialization if viewports are
        # enabled, and enabling viewports later without those extra steps will cause
        # a segfault.
        io = CImGui.GetIO()
        io.ConfigFlags = unsafe_load(io.ConfigFlags) | CImGui.ImGuiConfigFlags_ViewportsEnable

        # Setup Platform/Renderer bindings
        ImGuiGLFWBackend.init(glfw_ctx)
        GLBackend.init(opengl_ctx)

        # Now that we know the stuff for the viewports have been enabled we can
        # disable it again by default.
        io.ConfigFlags = unsafe_load(io.ConfigFlags) & ~CImGui.ImGuiConfigFlags_ViewportsEnable

        return new(window, imgui_ctx, implot_ctx, imnodes_ctx, glfw_ctx, opengl_ctx)
    end
end

function renderloop(app::ImGuiApp, ui=()->nothing; hotloading=false, on_exit=()->nothing)
    io = CImGui.GetIO()

    try
        while GLFW.glfwWindowShouldClose(app.window) == 0
            GLFW.glfwPollEvents()

            # Start the Dear ImGui frame
            GLBackend.new_frame(app.opengl_ctx)
            ImGuiGLFWBackend.new_frame(app.glfw_ctx)
            CImGui.NewFrame()

            # Build the interface
            hotloading ? Base.invokelatest(ui) : ui()

            # Render it
            CImGui.Render()
            GLFW.glfwMakeContextCurrent(app.window)

            width, height = Ref{Cint}(), Ref{Cint}()
            GLFW.glfwGetFramebufferSize(app.window, width, height)
            display_w = width[]
            display_h = height[]

            GLBackend.glViewport(0, 0, display_w, display_h)
            GLBackend.glClearColor(0.2, 0.2, 0.2, 1)
            GLBackend.glClear(GLBackend.GL_COLOR_BUFFER_BIT)
            GLBackend.render(app.opengl_ctx)

            if unsafe_load(CImGui.GetIO().ConfigFlags) & CImGui.ImGuiConfigFlags_ViewportsEnable == CImGui.ImGuiConfigFlags_ViewportsEnable
                backup_current_context = GLFW.glfwGetCurrentContext()
                CImGui.igUpdatePlatformWindows()
                CImGui.igRenderPlatformWindowsDefault(C_NULL, pointer_from_objref(app.opengl_ctx))
                GLFW.glfwMakeContextCurrent(backup_current_context)
            else
                GLFW.glfwMakeContextCurrent(app.window)
            end

            GLFW.glfwSwapBuffers(app.window)
            yield()
        end
    catch e
        @error "Error in renderloop!" exception=e
        Base.show_backtrace(stderr, catch_backtrace())
    finally
        try
            on_exit()
        catch exit_ex
            @error "Error in on_exit() function!" exception=exit_ex
        end

        GLBackend.shutdown(app.opengl_ctx)
        ImGuiGLFWBackend.shutdown(app.glfw_ctx)
        ImNodes.DestroyContext(app.imnodes_ctx)
        ImPlot.DestroyContext(app.implot_ctx)
        CImGui.DestroyContext(app.imgui_ctx)
        GLFW.glfwDestroyWindow(app.window)
    end
end

function render(ui, args...; hotloading=false, kwargs...)
    app = ImGuiApp(args...; kwargs...)
    return render(ui, app; hotloading)
end

function render(ui, app::ImGuiApp; hotloading=false, on_exit=()->nothing)
    t = Threads.@spawn :interactive renderloop(app, ui; hotloading, on_exit)
    return errormonitor(t)
end

end
