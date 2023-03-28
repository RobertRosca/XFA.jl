using Distributed

using HDF5
using Hwloc
using LibDeflate
using ThreadPinning
using ChunkSplitters
using EllipsisNotation

function mergechunks(addrs, sizes)
    if length(addrs) != length(sizes)
        throw(ArgumentError("Lengths of addrs and sizes don't match: $(length(addrs)) and $(length(sizes))"))
    end

    merged_addrs = UInt64[addrs[1]]
    merged_sizes = UInt64[sizes[1]]
    group_start_chunks = Int32[1]
    group_sizes = Int32[1]

    n_groups_guess = length(addrs) ÷ 10
    for x in [merged_addrs, merged_sizes, group_start_chunks, group_sizes]
        sizehint!(x, n_groups_guess)
    end

    @views for (addr, size) in Iterators.zip(addrs[2:end], sizes[2:end])
        if merged_addrs[end] + merged_sizes[end] == addr
            merged_sizes[end] += size
            group_sizes[end] += 1
        else
            push!(group_start_chunks, group_start_chunks[end] + group_sizes[end])
            push!(group_sizes, 1)
            push!(merged_addrs, addr)
            push!(merged_sizes, size)
        end
    end

    return (merged_addrs, merged_sizes, group_start_chunks, group_sizes)
end

function getchunkaddrs(ds::HDF5.Dataset)
    n_chunks = HDF5.get_num_chunks(ds)
    addrs = Vector{UInt64}(undef, n_chunks)
    sizes = Vector{UInt64}(undef, n_chunks)

    for i in 1:n_chunks
        info = HDF5.API.h5d_get_chunk_info(ds, i - 1)
        addrs[i] = info.addr
        sizes[i] = info.size
    end

    # If fletcher32 checksums are enabled, the last 4 bytes will be the checksum
    # and should be skipped.
    filters = typeof.(HDF5.get_create_properties(ds).filters)
    if Filters.Fletcher32 in filters
        sizes .-= 4
    end

    return (addrs, sizes)
end

function getchunkaddrs(path_and_ds::Tuple{String, String})
    h5_path, ds_name = path_and_ds

    h5open(h5_path) do f
        getchunkaddrs(f[ds_name])
    end
end

function indexpath(h5_path)
    h5_path = abspath(h5_path)
    data_dir = splitpath(h5_path)[end - 1]

    return "$(splitext(h5_path)[1])-index.h5"
end

hasindex(h5_path) = isfile(indexpath(h5_path))

function writeindex(h5_path, ds_names)
    index_path = indexpath(h5_path)

    readers = addprocs(length(ds_names))
    Distributed.remotecall_eval(Main, readers, :(using XFA))

    try
        h5open(index_path, "w") do index_file
            indexes = pmap(getchunkaddrs, [(h5_path, x) for x in ds_names])

            for (ds_name, (addrs, sizes)) in Iterators.zip(ds_names, indexes)
                index_file["$(ds_name)/addrs"] = addrs
                index_file["$(ds_name)/sizes"] = sizes
            end
        end
    finally
        rmprocs(readers)
    end

    return index_path
end

function deshuffle_impl(data, out::Type{A}) where A <: AbstractArray{T} where T
    eltype_size = sizeof(T)

    quote
        byte_stride = length(out)
        # @show byte_stride, $eltype_size
        GC.@preserve out begin
            out_ptr = Base.unsafe_convert(Ptr{UInt8}, out)
            out_bytes = unsafe_wrap(Array, out_ptr, length(data))

            for i in 1:byte_stride
                out_i = 1 + (i - 1) * $eltype_size
                Base.Cartesian.@nexprs $eltype_size j -> out_bytes[out_i + j - 1] = data[i + ((j - 1) * byte_stride)]
            end
        end
    end
end

@generated function deshuffle(data::Vector{UInt8}, out)
    # 1 + 1
    deshuffle_impl(data, out)
end

function iscompressed(ds::HDF5.Dataset)
    ds_properties = HDF5.get_create_properties(ds)
    filters = ds_properties.filters
    filter_types = typeof.(filters)

    return Filters.Deflate in filter_types
end

function decompresschunk!(codec, compressed_chunk, chunk_dest, decompression_tmp)
    decomp_ret = zlib_decompress!(codec, decompression_tmp, compressed_chunk, length(decompression_tmp))
    if !(decomp_ret isa Int)
        error("Decompression error: $(decomp_ret)")
    end

    deshuffle(decompression_tmp, chunk_dest)
end

function loadchunks(ds::HDF5.Dataset, mapped_file::Vector{UInt8},
                    addrs, sizes, dest=nothing;
                    n_readers::Int=-1)
    n_threads = Threads.nthreads(:default)
    if n_readers == -1
        n_readers = max(1, n_threads ÷ 2)
    end

    merged_addrs, merged_sizes, group_start_chunks, group_sizes = mergechunks(addrs, sizes)

    if n_threads < n_readers
        error("Only $(n_threads) threads configured, must be at least $(n_readers) to match the requested number of reader threads")
    end

    eltype_size::Int = sizeof(eltype(ds))
    n_bytes::Int = prod(size(ds)) * eltype_size

    ds_properties = HDF5.get_create_properties(ds)
    chunk_size::Int = prod(ds_properties.chunk) * sizeof(eltype(ds))

    if dest === nothing
        dest = Array{eltype(ds)}(undef, (ds_properties.chunk..., HDF5.get_num_chunks(ds)))
    end
    dest_bytes = reinterpret(UInt8, dest)

    if length(dest_bytes) != n_bytes
        throw(ArgumentError("dest buffer can only hold $(length(dest)) elements, but it must have at least $(prod(size(ds)))"))
    end

    codecs = [Decompressor() for _ in 1:n_readers]
    is_compressed = false
    filters = ds_properties.filters
    if length(filters) > 0
        filter_types = typeof.(filters)
        if Filters.Shuffle in filter_types && Filters.Deflate in filter_types
            error("Dataset $(HDF5.name(ds)) is compressed, which is not currently supported: $(filters)")
        else
            is_compressed = true
        end
    end

    chunk_offsets = 1 .+ circshift(cumsum(sizes), 1)
    chunk_offsets[1] = 1

    decompression_buffers = [Vector{UInt8}(undef, chunk_size) for _ in 1:n_readers]
    # Check that the buffers are allocated at least a cacheline away
    buffer_addrs = map(pointer, decompression_buffers)
    buffer_shares_cacheline = [buffer_addrs[i] - buffer_addrs[i - 1] < cachelinesize().L1
                               for i in 2:length(buffer_addrs)]
    if any(buffer_shares_cacheline)
        error("Decompression buffers sharing a cacheline")
    end

    @sync for (idxs, thread_id) in chunks(merged_addrs, n_readers, :batch)
        @tspawnat thread_id for chunk_group_idx in idxs
            group_addr = merged_addrs[chunk_group_idx] + 1
            group_size = merged_sizes[chunk_group_idx]

            offset = chunk_offsets[group_start_chunks[chunk_group_idx]]
            copyto!(dest_bytes, offset, mapped_file, group_addr, group_size)
        end
    end

    return reshape(dest, size(ds))
end
