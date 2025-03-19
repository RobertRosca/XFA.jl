mutable struct Plot
    name::String
    id::String
    data::Observable
    figure::GLMakie.Figure
    axis::GLMakie.Axis

    open::Ref{Bool}
    old_limits::Rect2d
end

function Base.close(plot::Plot)
    ig.delete_figure!(plot.figure)
    empty!(plot.figure)
end


function Plot(name, data::Observable)
    f = GLMakie.Figure(; fontsize=18)

    is_dimarray = data[] isa DimArray
    data_dims = is_dimarray ? DD.dims(data[]) : nothing
    xlabel = is_dimarray ? DD.label(data_dims[1]) : ""
    label = is_dimarray ? DD.label(data[]) : name

    if data[] isa AbstractVector
        ax, _ = GLMakie.lines(f[1, 1], data;
                              axis=(; xlabel),
                              label)
        GLMakie.axislegend(ax)
    elseif data[] isa AbstractMatrix
        ax, _ = GLMakie.image(f[1, 1], data; colormap=:viridis, interpolate=false)
    end

    GLMakie.autolimits!(ax)

    id = name * "##" * String(rand('a':'z', 10))

    return Plot(name, id, data, f, ax, Ref(true), ax.finallimits[])
end

function draw_plot(plot::Plot, was_updated)
    ig.SetNextWindowSize((800, 500), ig.ImGuiCond_FirstUseEver)

    if ig.Begin(plot.id, plot.open)
        if was_updated && plot.axis.finallimits[] == plot.old_limits
            GLMakie.autolimits!(plot.axis)
            plot.old_limits = plot.axis.finallimits[]
        end

        region_avail = ig.GetContentRegionAvail()
        region_size = (Int(region_avail.x), Int(region_avail.y))

        if ig.BeginChild("plot", (0, region_size[2] - 50))
            ig.MakieFigure(plot.id, plot.figure; auto_resize_x=true, auto_resize_y=true)
        end
        ig.EndChild()

        ig.Dummy(0, 5)

        if ig.BeginChild("settings")
            if ig.Button("Autolimits")
                GLMakie.autolimits!(plot.axis)
                plot.old_limits = plot.axis.finallimits[]
            end
        end
        ig.EndChild()
    end

    ig.End()
end
