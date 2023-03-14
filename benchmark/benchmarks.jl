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
    addrs, sizes = h5open(XFA.indexpath(h5_path)) do index_file
        addrs = HDF5.readmmap(index_file["$(ds_name)/addrs"])
        sizes = HDF5.readmmap(index_file["$(ds_name)/sizes"])

        return addrs, sizes
    end

    XFA.loadchunks(ds, mapped_file, addrs, sizes)
    close(f)
end

function default_read(h5_path, ds_name)
    h5open(h5_path) do f
        read(f[ds_name])
    end
end

function dataset_typename(h5_path, ds_name)
    h5open(h5_path) do f
        ds = f[ds_name]
        dtype = lowercase(string(eltype(ds)))

        return (XFA.iscompressed(ds) ? "compressed_" : "") * dtype
    end
end

function mkbenchmarks(h5_path; generated_file=false)
    suite = BenchmarkGroup()
    suite["hdf5_reader"] = BenchmarkGroup()
    suite["hdf5_reader"]["mmap"] = BenchmarkGroup()
    suite["hdf5_reader"]["default"] = BenchmarkGroup()

    file_datasets = if generated_file
        ["float32", "compressed_uint16"]
    else
        ["INSTRUMENT/MID_DET_AGIPD1M-1/DET/0CH0:xtdf/image/data",
         "INSTRUMENT/MID_DET_AGIPD1M-1/DET/0CH0:xtdf/image/mask"]
    end
    ds_names = Dict([dataset_typename(h5_path, x) => x for x in file_datasets])

    # Create indexes if they don't already exist
    if !XFA.hasindex(h5_path)
        print("Creating indexes...")
        XFA.writeindex(h5_path, file_datasets)
        println(" done")
    end

    for (k, v) in ds_names
        suite["hdf5_reader"]["mmap"][k] = @benchmarkable mmap_read($h5_path, $v) samples=10
        suite["hdf5_reader"]["default"][k] = @benchmarkable default_read($h5_path, $v) samples=10
    end

    return suite
end

function runbenchmarks(n_trains::Int=10, data_dir=pwd(); use_file=nothing)
    # Write dummy data if necessary
    generated_file = use_file === nothing
    if generated_file
        data_dir = mktempdir(data_dir)
        h5open(joinpath(data_dir, H5_NAME), "w") do f
            float32_data = rand(Float32, 128, 512, 352 * n_trains)
            uint16_data = rand(UInt16, size(float32_data))

            f["float32", chunk=(128, 512, 1)] = float32_data
            f["compressed_uint16", chunk=(128, 512, 1), shuffle=true, deflate=1] = uint16_data
        end
    end

    h5_path = if generated_file
        joinpath(data_dir, H5_NAME)
    else
        use_file
    end

    h5_size = filesize(h5_path)
    println(@sprintf "Benchmarking a %.2fMB file\n" (h5_size / 1e6))

    results = nothing
    try
        suite = mkbenchmarks(h5_path; generated_file=generated_file)
        results = run(suite; verbose=true)
    finally
        if generated_file
            rm(data_dir; recursive=true)
        end
    end

    println()
    group = results["hdf5_reader"]["mmap"]
    for ds_name in keys(group)
        mmap_results = results["hdf5_reader"]["mmap"][ds_name]
        default_results = results["hdf5_reader"]["default"][ds_name]

        r = ratio(mean(default_results), mean(mmap_results))
        println(@sprintf "%s performance: %.2fx" ds_name r.time)
    end
    println()

    return results
end
