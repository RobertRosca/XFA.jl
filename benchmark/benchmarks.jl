using Mmap
using Printf

using HDF5
using BenchmarkTools

using XFA


const H5_NAME::String = "data.h5"

function mmap_read(h5_path, ds_name)
    f = h5open(h5_path)
    mapped_file = mmap(h5_path)

    ds = f[ds_name]
    addrs, sizes = XFA.getchunkaddrs(ds)
    XFA.loadchunks(ds, mapped_file, addrs, sizes)
    close(f)
end

function default_read(h5_path, ds_name)
    h5open(h5_path) do f
        read(f[ds_name])
    end
end

function mkbenchmarks(data_dir)
    h5_path = joinpath(data_dir, H5_NAME)

    suite = BenchmarkGroup()
    suite["hdf5_reader"] = BenchmarkGroup()
    suite["hdf5_reader"]["mmap"] = BenchmarkGroup()
    suite["hdf5_reader"]["default"] = BenchmarkGroup()

    for ds_name in ["float32", "compressed_uint16"]
        suite["hdf5_reader"]["mmap"][ds_name] = @benchmarkable mmap_read($h5_path, $ds_name) samples=10
        suite["hdf5_reader"]["default"][ds_name] = @benchmarkable default_read($h5_path, $ds_name) samples=10
    end

    return suite
end

function runbenchmarks(n_trains::Int=10)
    # Write dummy data
    data_dir = mktempdir(pwd())
    h5open(joinpath(data_dir, H5_NAME), "w") do f
        float32_data = rand(Float32, 128, 512, 352 * n_trains)
        uint16_data = rand(UInt16, size(float32_data))

        f["float32", chunk=(128, 512, 1)] = float32_data
        f["compressed_uint16", chunk=(128, 512, 1), shuffle=(), deflate=1] = uint16_data
    end

    h5_size = filesize(joinpath(data_dir, H5_NAME))
    println(@sprintf "Wrote %d trains into a %.2fMB file\n" n_trains (h5_size / 1e6))

    results = nothing
    try
        suite = mkbenchmarks(data_dir)
        results = run(suite; verbose=true)
    catch e
        throw(e)
    finally
        rm(data_dir; recursive=true)
    end

    println()
    for ds_name in ["float32", "compressed_uint16"]
        mmap_results = results["hdf5_reader"]["mmap"][ds_name]
        default_results = results["hdf5_reader"]["default"][ds_name]

        r = ratio(mean(default_results), mean(mmap_results))
        println(@sprintf "%s performance: %.2fx" ds_name r.time)
    end
    println()

    return results
end

