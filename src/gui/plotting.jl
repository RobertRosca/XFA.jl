mutable struct Plot
    name::String
    id::String
    data::Observable
    figure::GLMakie.Figure
    axis::GLMakie.Axis
    open::Ref{Bool}
end

function Base.close(plot::Plot)
    ig.delete_figure!(plot.figure)
    empty!(plot.figure)
end

function Plot(name, data::Observable)
    f = GLMakie.Figure()

    if data[] isa AbstractVector
        ax, _ = GLMakie.lines(f[1, 1], data)
    elseif data[] isa AbstractMatrix
        ax, _ = GLMakie.image(f[1, 1], data)
    end

    id = name * "##" * String(rand('a':'z', 10))

    return Plot(name, id, data, f, ax, Ref(true))
end

function draw_plot(p::Plot)
    if ig.Begin(p.id, p.open)
        ig.MakieFigure(p.id, p.figure; auto_resize_x=true, auto_resize_y=true)
    end

    ig.End()
end
