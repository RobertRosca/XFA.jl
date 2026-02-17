function settings_path()
    config_dir = get(ENV, "XFA_CONFIG_DIR", joinpath(homedir(), ".xfa"))
    joinpath(config_dir, "settings.toml")
end

function load_settings()::Dict{String,Any}
    path = settings_path()
    isfile(path) ? TOML.parsefile(path) : Dict{String, Any}()
end

function save_settings(state::GuiState, updated_field=nothing)
    fields_to_save = (:address, :engine_environment, :client_type_current_item)
    if !isnothing(updated_field) && updated_field ∉ fields_to_save
        return
    end

    plots = map(state.client.plots) do plot
        if plot isa Plot
            Dict("type" => "Plot", "name" => plot.name)
        else
            Dict("type" => "CorrelationPlot")
        end
    end

    settings = Dict(
        "address" => state.address,
        "engine_environment" => state.engine_environment,
        "client_type" => state.client_type_current_item,
        "plots" => plots,
    )

    path = settings_path()
    mkpath(dirname(path))
    open(path, "w") do io
        TOML.print(io, settings)
    end
end
